#!/usr/bin/env python3
"""Offline protocol and loopback transfer tests. Run with python3 -I."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import signal
import socket
import subprocess
import tempfile
import threading
import time


PROCESSES = []


def bencode(value):
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, str):
        value = value.encode("utf-8")
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, list):
        return b"l" + b"".join(bencode(item) for item in value) + b"e"
    if isinstance(value, dict):
        pairs = sorted((key.encode() if isinstance(key, str) else key, item)
                       for key, item in value.items())
        return b"d" + b"".join(bencode(key) + bencode(item) for key, item in pairs) + b"e"
    raise TypeError(type(value))


def fixture(root, name, entries, multi=False):
    """Generate v1 torrents with no trackers and real SHA-1 piece hashes."""
    content = b"".join(data for _, data in entries)
    piece_length = 64 * 1024
    info = {
        "name": name,
        "piece length": piece_length,
        "pieces": b"".join(hashlib.sha1(content[i:i + piece_length]).digest()
                           for i in range(0, len(content), piece_length)),
    }
    if multi:
        info["files"] = [{"length": len(data), "path": path.split("/")}
                         for path, data in entries]
    else:
        info["length"] = len(content)
    data_root = root / "seed"
    for path, data in entries:
        destination = data_root / name / path if multi else data_root / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    torrent = root / (name + ".torrent")
    torrent.write_bytes(bencode({"info": info}))
    return torrent, hashlib.sha1(bencode(info)).hexdigest(), data_root


def wait_for(function, timeout=30, description="condition"):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = function()
        if last:
            return last
        time.sleep(0.15)
    raise AssertionError(f"Timed out waiting for {description}; last={last!r}")


class Daemon:
    def __init__(self, binary, state):
        self.state = state
        self.events = []
        self.messages = queue.Queue()
        self.stderr = []
        self.sequence = 0
        self.process = subprocess.Popen(
            [str(binary), "--state-dir", str(state)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            encoding="utf-8", env={**os.environ, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"},
        )
        PROCESSES.append(self.process)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.logger = threading.Thread(target=self._log, daemon=True)
        self.reader.start()
        self.logger.start()
        self.ready = self.event("ready", timeout=15)
        assert self.ready["version"] == "0.1.0"
        assert self.ready["libtorrent"] == "2.0.15"
        assert 0 < self.ready["listen_port"] < 65536
        assert state.stat().st_mode & 0o777 == 0o700

    def _read(self):
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        except Exception as error:
            self.messages.put(error)
        finally:
            self.messages.put(None)

    def _log(self):
        for line in self.process.stderr:
            self.stderr.append(line.rstrip())

    def message(self, timeout=15):
        try:
            message = self.messages.get(timeout=timeout)
        except queue.Empty as error:
            raise AssertionError(f"No response; stderr={self.stderr[-10:]}") from error
        assert message is not None, f"Unexpected EOF; stderr={self.stderr[-10:]}"
        assert isinstance(message, dict), repr(message)
        return message

    def event(self, name, timeout=15):
        for event in self.events:
            if event["event"] == name:
                return event
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            message = self.message(max(0.1, deadline - time.monotonic()))
            if "event" in message:
                self.events.append(message)
                if message["event"] == name:
                    return message
        raise AssertionError(f"Missing event {name}")

    def raw(self, text, request_id, error=None):
        self.process.stdin.write(text + "\n")
        self.process.stdin.flush()
        while True:
            message = self.message()
            if "event" in message:
                self.events.append(message)
                continue
            assert message.get("id") == request_id, message
            if error:
                assert message["error"]["code"] == error, message
                assert isinstance(message["error"]["message"], str)
                return message
            assert "error" not in message, message
            return message["result"]

    def request(self, method, params=None, error=None):
        self.sequence += 1
        return self.raw(json.dumps({"id": self.sequence, "method": method, "params": params or {}},
                                   ensure_ascii=False), self.sequence, error)

    def configure(self, directory, download_limit=0, port=0, **changes):
        params = {
            "download_dir": str(directory), "listen_port": port,
            "download_limit": download_limit, "upload_limit": 0,
            "max_active_downloads": 8, "max_active_seeds": 8,
            "dht": False, "lsd": False, "port_mapping": False, "encryption": "prefer",
        }
        params.update(changes)
        result = self.request("configure", params)
        assert 0 < result["listen_port"] < 65536
        return result["listen_port"]

    def torrents(self):
        return self.request("list")["torrents"]

    def torrent(self, torrent_id):
        return next((item for item in self.torrents() if item["id"] == torrent_id), None)

    def complete(self, torrent_id, timeout=45):
        def completed():
            item = self.torrent(torrent_id)
            assert item and item["state"] != "error", item
            return item if item["state"] in ("seeding", "finished") and item["progress"] == 1.0 else None
        return wait_for(completed, timeout, "torrent completion")

    def close(self, method="eof"):
        if self.process.poll() is not None:
            return
        if method == "shutdown":
            self.request("shutdown")
        elif method == "signal":
            self.process.send_signal(signal.SIGTERM)
        else:
            self.process.stdin.close()
        assert self.process.wait(timeout=15) == 0, self.stderr[-10:]
        if not self.process.stdin.closed:
            self.process.stdin.close()
        self.reader.join(timeout=2)
        self.logger.join(timeout=2)
        self.process.stdout.close()
        self.process.stderr.close()


def validate_item(item):
    integers = ("total_wanted", "total_wanted_done", "download_rate", "upload_rate",
                "all_time_download", "all_time_upload", "num_peers", "num_seeds",
                "list_peers", "list_seeds", "file_count", "selected_file_count",
                "upload_limit", "added_at")
    for key in integers:
        assert type(item[key]) is int, (key, item)
    for key in ("has_metadata", "paused", "queued", "is_private"):
        assert type(item[key]) is bool, (key, item)
    for key in ("progress", "ratio"):
        assert type(item[key]) is float, (key, item)
    assert item["error"] is None
    assert item["eta"] is None or type(item["eta"]) is int
    assert item["completed_at"] is None or type(item["completed_at"]) is int
    assert len(item["id"]) == 40 and item["id"] == item["id"].lower()
    assert Path(item["save_path"]).is_absolute()
    assert item["content_path"] is None or Path(item["content_path"]).is_absolute()
    assert isinstance(item["name"], str)
    assert item["state"] in ("checking", "metadata", "downloading", "seeding", "finished", "error")


def run_tests(binary, root):
    data = os.urandom(5 * 1024 * 1024 + 123)
    single, single_id, seed_path = fixture(root, "Mulee-open-test.bin", [("", data)])
    multi_entries = [("说明.txt", "Mulee 开源测试数据\n".encode() * 100),
                     ("子目录/样本.bin", os.urandom(5 * 1024 * 1024))]
    multi, multi_id, _ = fixture(root, "开源测试集", multi_entries, multi=True)
    a = Daemon(binary, root / "state-a")
    port_a = a.configure(seed_path)
    print("PASS 启动、ready、configure", flush=True)

    mappings = {"tcp": [40123, 40123], "udp": [40126, 40133]}
    expected = {"tcp": [40123], "udp": [40126, 40133], "enabled": False}
    assert a.request("set_extra_port_mappings", mappings) == expected
    assert a.request("set_extra_port_mappings", mappings) == expected
    assert len(a.request("session_status")["extra_port_mappings"]) == 3
    for invalid in ({}, {"tcp": [0], "udp": []}, {"tcp": [], "udp": [65536]},
                    {"tcp": [True], "udp": []}, {"tcp": [1.5], "udp": []},
                    {"tcp": "40123", "udp": []}, {"tcp": [], "udp": [-1]}):
        a.request("set_extra_port_mappings", invalid, error="invalid_params")
    assert a.request("set_extra_port_mappings", mappings) == expected
    assert a.request("set_extra_port_mappings", {"tcp": [], "udp": [40134]}) == {
        "tcp": [], "udp": [40134], "enabled": False,
    }
    a.request("set_extra_port_mappings", {"tcp": [], "udp": []})
    assert a.request("session_status")["extra_port_mappings"] == []
    print("PASS 额外端口映射：校验、幂等、更新、清空、关闭时不申请映射", flush=True)

    a.request("unknown", error="unknown_method")
    a.raw("{bad-json", None, "invalid_request")
    a.raw('{"id":99}', 99, "invalid_request")
    a.raw("[]", None, "invalid_request")
    a.request("configure", error="invalid_params")
    a.request("add", error="invalid_params")
    a.request("pause", {"id": "0" * 40}, error="not_found")
    a.request("pause", error="invalid_params")
    a.request("add", {"magnet": "invalid"}, error="invalid_torrent")
    invalid = root / "invalid.torrent"
    invalid.write_bytes(b"not bencoded")
    a.request("add", {"torrent_file": str(invalid)}, error="invalid_torrent")
    a.request("add", {"torrent_file": str(root / "missing.torrent")}, error="io_error")
    a.request("add", {"torrent_file": str(single), "file_priorities": []}, error="invalid_params")
    a.request("add", {"torrent_file": str(single), "file_priorities": [8]}, error="invalid_params")
    a.configure(seed_path, encryption="require")
    a.configure(seed_path, encryption="disable")
    port_a = a.configure(seed_path)
    with socket.socket() as occupied:
        occupied.bind(("0.0.0.0", 0))
        occupied.listen()
        occupied_port = occupied.getsockname()[1]
        fallback = a.configure(seed_path, port=occupied_port)
        assert fallback != occupied_port
    port_a = a.configure(seed_path)
    print("PASS 错误码、参数校验、端口冲突回退", flush=True)

    result = a.request("add", {"torrent_file": str(single), "save_path": str(seed_path),
                               "source": "mulee-local-fixture", "file_priorities": [4]})
    assert result == {"id": single_id, "name": "Mulee-open-test.bin", "duplicate": False}
    result = a.request("add", {"torrent_file": str(multi), "file_priorities": [4, 4]})
    assert result["id"] == multi_id
    for torrent_id, count in ((single_id, 1), (multi_id, 2)):
        item = a.complete(torrent_id)
        validate_item(item)
        assert item["total_wanted"] == item["total_wanted_done"]
        assert item["file_count"] == item["selected_file_count"] == count
        assert item["completed_at"] > 0
        files = a.request("files", {"id": torrent_id})["files"]
        assert len(files) == count
        for index, file in enumerate(files):
            assert set(file) == {"index", "path", "size", "done", "priority"}
            assert file["index"] == index and file["done"] == file["size"]
            assert file["priority"] == 4
    assert a.torrent(single_id)["source"] == "mulee-local-fixture"
    assert a.torrent(single_id)["content_path"] == str(seed_path / "Mulee-open-test.bin")
    assert a.torrent(multi_id)["content_path"] == str(seed_path / "开源测试集")
    assert "说明.txt" in a.request("files", {"id": multi_id})["files"][0]["path"]
    assert a.request("add", {"magnet": f"magnet:?xt=urn:btih:{single_id}"})["duplicate"]
    a.request("set_file_priorities", {"id": multi_id, "priorities": [4]}, error="invalid_params")
    a.request("set_file_priorities", {"id": multi_id, "priorities": [4, 0]})
    wait_for(lambda: a.request("files", {"id": multi_id})["files"][1]["priority"] == 0)
    assert a.torrent(multi_id)["selected_file_count"] == 1
    a.request("set_upload_limit", {"id": single_id, "limit": 51200})
    assert a.torrent(single_id)["upload_limit"] == 51200
    a.request("set_upload_limit", {"id": single_id, "limit": -1}, error="invalid_params")
    a.request("set_upload_limit", {"id": single_id, "limit": 0})
    print("PASS 单文件、多文件中文路径、list/files、优先级和上传限速", flush=True)

    # A second process must not touch the state or emit ready.
    second = subprocess.run([str(binary), "--state-dir", str(a.state)], input="", text=True,
                            capture_output=True, timeout=15)
    assert second.returncode == 2, second
    assert json.loads(second.stdout)["event"] == "fatal"

    b_path = root / "download-b"
    b = Daemon(binary, root / "state-b")
    b.configure(b_path, download_limit=256 * 1024)
    magnet = f"magnet:?xt=urn:btih:{single_id}&x.pe=127.0.0.1:{port_a}"
    added = b.request("add", {"magnet": magnet, "source": "loopback-test"})
    assert added["id"] == single_id
    b.event("metadata_received", timeout=30)
    partial = wait_for(lambda: (item if 512 * 1024 <= item["total_wanted_done"] < len(data) else None)
                       if (item := b.torrent(single_id)) else None, 45, "partial download")
    b.request("pause", {"id": single_id})
    b.request("pause", {"id": single_id})
    assert b.torrent(single_id)["paused"]
    before = b.torrent(single_id)["total_wanted_done"]
    b.request("resume", {"id": single_id})
    b.request("resume", {"id": single_id})
    assert not b.torrent(single_id)["paused"]
    b.close()
    resume = b.state / "resume" / (single_id + ".resume")
    assert resume.stat().st_size > 0
    assert (b.state / "meta" / (single_id + ".json")).is_file()
    print("PASS 本机磁力元数据、部分下载、pause/resume、EOF 保存", flush=True)

    b = Daemon(binary, b.state)
    restored = wait_for(lambda: (item if item["state"] != "checking" else None)
                        if (item := b.torrent(single_id)) else None)
    assert restored["total_wanted_done"] >= before, (before, restored)
    assert restored["source"] == "loopback-test"
    b.configure(b_path)
    completed = b.complete(single_id, timeout=60)
    assert (b_path / "Mulee-open-test.bin").read_bytes() == data
    assert completed["all_time_download"] >= partial["all_time_download"]
    b.event("finished")
    status = b.request("session_status")
    assert set(status) == {"listen_port", "dht_nodes", "has_incoming_connections",
                           "download_rate", "upload_rate", "external_address", "port_mapping_enabled",
                           "port_mappings", "extra_port_mappings"}
    assert status["dht_nodes"] == 0
    assert type(status["has_incoming_connections"]) is bool
    assert a.request("session_status")["has_incoming_connections"]
    b.request("remove", {"id": single_id, "delete_files": True})
    wait_for(lambda: not (b_path / "Mulee-open-test.bin").exists(), description="data deletion")
    assert not resume.exists()
    assert not (b.state / "meta" / (single_id + ".json")).exists()
    assert b.torrents() == []
    b.close("shutdown")
    print("PASS 重启进度不倒退、继续完成、内容一致、删除文件和状态、单实例锁", flush=True)

    # Persist a partial transfer, SIGKILL it, then restore without graceful shutdown.
    c_path = root / "download-c"
    c = Daemon(binary, root / "state-c")
    c.configure(c_path, download_limit=96 * 1024)
    c.request("add", {"magnet": magnet})
    c.event("metadata_received", timeout=30)
    wait_for(lambda: c.torrent(single_id)["total_wanted_done"] >= 256 * 1024,
             45, "SIGKILL fixture progress")
    saved = c.state / "resume" / (single_id + ".resume")
    baseline_mtime = saved.stat().st_mtime_ns if saved.exists() else 0
    wait_for(lambda: saved.exists() and saved.stat().st_mtime_ns > baseline_mtime,
             25, "periodic checkpoint")
    c.process.kill()
    assert c.process.wait(timeout=10) == -signal.SIGKILL
    c.process.stdin.close()
    c.reader.join(timeout=2)
    c.logger.join(timeout=2)
    c.process.stdout.close()
    c.process.stderr.close()
    c = Daemon(binary, c.state)
    assert c.torrent(single_id) is not None
    c.close("signal")
    print("PASS 周期性保存后 SIGKILL 恢复、SIGTERM 优雅退出", flush=True)

    # Persist A's seed and priorities, then mix a damaged resume into the directory.
    a.request("pause", {"id": multi_id})
    a.close("shutdown")
    broken = a.state / "resume" / ("f" * 40 + ".resume")
    broken.write_bytes(b"corrupt-resume")
    a = Daemon(binary, a.state)
    assert len(a.torrents()) == 2
    assert not broken.exists() and (a.state / "broken" / broken.name).exists()
    assert a.torrent(multi_id)["paused"]
    assert a.request("files", {"id": multi_id})["files"][1]["priority"] == 0
    assert "Broken resume" in (a.state / "torrentd.log").read_text()
    a.configure(seed_path)
    a.request("remove", {"id": multi_id, "delete_files": True})
    wait_for(lambda: not (seed_path / "开源测试集/说明.txt").exists())
    wait_for(lambda: not (seed_path / "开源测试集/子目录/样本.bin").exists())
    a.request("remove", {"id": single_id, "delete_files": False})
    assert (seed_path / "Mulee-open-test.bin").is_file()
    a.close()
    print("PASS 损坏 resume 隔离、其他任务恢复、暂停和优先级持久化", flush=True)


def main():
    default = Path(__file__).resolve().parents[1] / "build/thirdparty/bin/mulee-torrentd"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", nargs="?", type=Path, default=default)
    args = parser.parse_args()
    binary = args.binary.resolve()
    assert binary.is_file(), f"Build first: scripts/build-torrentd.sh --standalone ({binary})"
    subprocess.run([str(binary), "--test-dns"], check=True, timeout=15)
    with tempfile.TemporaryDirectory(prefix="mulee-torrentd-test-") as temporary:
        try:
            run_tests(binary, Path(temporary))
        finally:
            for process in PROCESSES:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream and not stream.closed:
                        stream.close()
    assert all(process.poll() is not None for process in PROCESSES)
    print(f"PASS 全部测试通过；{len(PROCESSES)} 个测试进程均已退出，临时目录已清理", flush=True)


if __name__ == "__main__":
    main()
