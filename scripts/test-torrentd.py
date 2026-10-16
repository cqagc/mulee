#!/usr/bin/env python3
"""Offline protocol and loopback transfer tests. Run with python3 -I."""

import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import resource
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


def bdecode(data):
    """Decode fixture/state data for persistence assertions."""
    def parse(offset):
        token = data[offset:offset + 1]
        if token == b"i":
            end = data.index(b"e", offset)
            return int(data[offset + 1:end]), end + 1
        if token in (b"l", b"d"):
            values = []
            offset += 1
            while data[offset:offset + 1] != b"e":
                value, offset = parse(offset)
                values.append(value)
            if token == b"d":
                return dict(zip(values[::2], values[1::2])), offset + 1
            return values, offset + 1
        colon = data.index(b":", offset)
        size = int(data[offset:colon])
        start = colon + 1
        return data[start:start + size], start + size
    result, end = parse(0)
    assert end == len(data)
    return result


def fixture(root, name, entries, multi=False, private=False):
    """Generate v1 torrents with no trackers and real SHA-1 piece hashes."""
    content = b"".join(data for _, data in entries)
    piece_length = 64 * 1024
    info = {
        "name": name,
        "piece length": piece_length,
        "pieces": b"".join(hashlib.sha1(content[i:i + piece_length]).digest()
                           for i in range(0, len(content), piece_length)),
    }
    if private:
        info["private"] = 1
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
        assert result["connections_limit"] == 500, result
        assert result["active_limit"] == max(32, min(2147483647, params["max_active_downloads"] + params["max_active_seeds"]))
        assert result["dont_count_slow_torrents"] is True
        assert result["announce_to_all_tiers"] is True and result["announce_to_all_trackers"] is False
        assert result["unchoke_slots_limit"] == 16 and result["file_pool_size"] == 100
        expected_cache = max(1024 * 1024, min(256 * 1024 * 1024, params.get("disk_cache_bytes", 16 * 1024 * 1024)))
        assert result["disk_cache_bytes"] == expected_cache
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
            started = time.monotonic()
            assert self.request("shutdown") == {"saved": True}
            self.shutdown_ack_seconds = time.monotonic() - started
        elif method == "signal":
            self.process.send_signal(signal.SIGTERM)
        else:
            self.process.stdin.close()
        started = time.monotonic()
        assert self.process.wait(timeout=15) == 0, self.stderr[-10:]
        self.exit_seconds = time.monotonic() - started
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
    for key in ("has_metadata", "paused", "queued", "is_private", "is_finished", "sequential_download", "first_last_priority"):
        assert type(item[key]) is bool, (key, item)
    for key in ("progress", "ratio"):
        assert type(item[key]) is float, (key, item)
    assert item["max_connections"] == 250
    diagnostics = item["diagnostics"]
    assert set(diagnostics["peer_sources"]) == {"tracker", "dht", "pex", "lsd", "incoming"}
    assert diagnostics["connected_peers"] == diagnostics["ipv4"] + diagnostics["ipv6"]
    assert diagnostics["connected_peers"] == diagnostics["tcp"] + diagnostics["utp"]
    for value in diagnostics["peer_sources"].values():
        assert 0 <= value <= diagnostics["connected_peers"]
    assert diagnostics["disk_backlogged"] is None or type(diagnostics["disk_backlogged"]) is bool
    assert diagnostics["blocked_clients_count"] >= 0
    assert item["error"] is None
    assert item["eta"] is None or type(item["eta"]) is int
    assert item["completed_at"] is None or type(item["completed_at"]) is int
    assert len(item["id"]) == 40 and item["id"] == item["id"].lower()
    assert Path(item["save_path"]).is_absolute()
    assert item["content_path"] is None or Path(item["content_path"]).is_absolute()
    assert isinstance(item["name"], str)
    assert item["state"] in ("checking", "metadata", "downloading", "seeding", "finished", "error")


def management_tests(binary, root):
    data = b"Mulee management fixture\n" * 4096
    entries = [("content.bin", data), ("AD.URL", b"fixture"), ("广告.txt", b"fixture"),
               ("folder/keep.txt", b"fixture")]
    torrent, torrent_id, seed = fixture(root, "Management", entries, multi=True)
    daemon = Daemon(binary, root / "management-state")
    port = daemon.configure(seed)
    added = daemon.request("add", {"torrent_file": str(torrent)})
    assert [file["index"] for file in added["skipped_files"]] == [1, 2]
    assert [file["priority"] for file in daemon.request("files", {"id": torrent_id})["files"]] == [4, 0, 0, 4]
    daemon.complete(torrent_id)
    assert daemon.torrent(torrent_id)["skipped_files"] == added["skipped_files"]
    daemon.request("set_file_priorities", {"id": torrent_id, "priorities": [4, 4, 4, 4]})
    wait_for(lambda: daemon.request("files", {"id": torrent_id})["files"][1]["priority"] == 4)
    daemon.request("force_recheck", {"id": torrent_id})
    daemon.complete(torrent_id)
    daemon.request("force_reannounce", {"id": torrent_id})
    status = daemon.torrent(torrent_id)
    assert status["seed_time_seconds"] >= 0 and status["seed_inactive_seconds"] >= 0

    moved = root / "moved"
    collision = moved / "Management/content.bin"
    collision.parent.mkdir(parents=True)
    collision.write_bytes(b"existing destination")
    daemon.request("move_storage", {"id": torrent_id, "path": str(moved), "conflict": "fail"}, error="conflict")
    assert (seed / "Management/content.bin").read_bytes() == data
    daemon.request("move_storage", {"id": torrent_id, "path": str(moved), "conflict": "overwrite"})
    assert collision.read_bytes() == data and not (seed / "Management/content.bin").exists()
    daemon.request("rename_file", {"id": torrent_id, "path": "Management/content.bin", "new_path": "Management/renamed.bin"})
    daemon.request("rename_file", {"id": torrent_id, "path": "Management/folder", "new_path": "Management/renamed-folder"})
    assert (moved / "Management/renamed.bin").read_bytes() == data
    assert (moved / "Management/renamed-folder/keep.txt").read_bytes() == b"fixture"
    daemon.request("rename_file", {"id": torrent_id, "path": "Management/renamed.bin", "new_path": "../escape"}, error="invalid_params")
    daemon.request("rename_file", {"id": torrent_id, "path": "Management/renamed.bin", "new_path": "Management/AD.URL"}, error="conflict")
    kept = root / "kept"
    destination = kept / "Management/renamed.bin"
    destination.parent.mkdir(parents=True)
    destination.write_bytes(data)
    daemon.request("move_storage", {"id": torrent_id, "path": str(kept), "conflict": "keep"})
    assert destination.read_bytes() == data
    daemon.complete(torrent_id)

    class ManagementTracker(BaseHTTPRequestHandler):
        failures = False

        def do_GET(self):
            body = bencode({"failure reason": "fixture failure"} if self.failures else
                           {"interval": 1, "min interval": 0, "peers": b""})
            self.send_response(200)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    tracker = ThreadingHTTPServer(("127.0.0.1", 0), ManagementTracker)
    tracker_worker = threading.Thread(target=tracker.serve_forever, daemon=True)
    tracker_worker.start()
    url = f"http://127.0.0.1:{tracker.server_port}/announce"
    daemon.request("set_trackers", {"id": torrent_id, "trackers": [{"url": url, "tier": 2}]})
    rows = daemon.request("trackers", {"id": torrent_id})["trackers"]
    assert len(rows) == 1 and rows[0]["tier"] == 2 and rows[0]["url"] == url
    assert set(rows[0]) == {"url", "tier", "status", "last_result", "peers", "disabled_until", "subscription"}
    daemon.request("set_trackers", {"id": torrent_id, "trackers": [{"url": url, "tier": 256}]}, error="invalid_params")
    daemon.request("set_trackers", {"id": torrent_id, "trackers": []})
    assert daemon.request("trackers", {"id": torrent_id}) == {"trackers": []}
    daemon.request("add_trackers", {"id": torrent_id, "urls": [url], "subscription": True})
    ManagementTracker.failures = True

    def disabled():
        daemon.request("force_reannounce", {"id": torrent_id})
        rows = daemon.request("trackers", {"id": torrent_id})["trackers"]
        return rows and rows[0]["status"] == "disabled"

    wait_for(disabled, timeout=45, description="three subscription failures disable tracker")
    disabled_row = daemon.request("trackers", {"id": torrent_id})["trackers"][0]
    assert 86300 <= disabled_row["disabled_until"] - int(time.time()) <= 86400
    assert disabled_row["last_result"]

    # 用真实回环握手核验节点字段，测试不接触公共 swarm。
    peer = socket.create_connection(("127.0.0.1", port), timeout=3)
    peer.sendall(b"\x13BitTorrent protocol" + b"\0" * 8 + bytes.fromhex(torrent_id) + b"-MU0100-123456789012")
    rows = wait_for(lambda: daemon.request("peers", {"id": torrent_id})["peers"], description="peer detail list")
    assert rows[0]["address"] == "127.0.0.1" and rows[0]["connection"] == "tcp"
    assert {"port", "client", "progress", "download_rate", "upload_rate", "sources"} <= rows[0].keys()
    assert "incoming" in rows[0]["sources"]
    peer.close()
    daemon.request("ban_ip", {"ip": "192.0.2.10"})
    daemon.request("ban_ip", {"ip": "invalid"}, error="invalid_params")
    blocklist = root / "fixture.p2p"
    blocklist.write_text("# fixture\nExample:192.0.2.1-192.0.2.9\n", encoding="utf-8")
    assert daemon.request("import_ip_blocklist", {"path": str(blocklist)}) == {"blocked_ranges": 1}
    dat = root / "fixture.dat"
    dat.write_text("198.051.100.001 - 198.051.100.009 , 126 , blocked\n203.0.113.1 - 203.0.113.9 , 127 , allowed\n")
    assert daemon.request("import_ip_blocklist", {"path": str(dat)}) == {"blocked_ranges": 1}
    invalid = root / "invalid.dat"
    invalid.write_text("192.0.2.9 - 192.0.2.1 , 1 , reversed\n")
    daemon.request("import_ip_blocklist", {"path": str(invalid)}, error="invalid_params")
    filters = json.loads((daemon.state / "ip-filters.json").read_text())
    assert filters == {"banned": ["192.0.2.10"], "imported": [{"first": "198.51.100.1", "last": "198.51.100.9"}]}
    daemon.configure(kept, ip_blocklist_path=str(blocklist))
    assert json.loads((daemon.state / "ip-filters.json").read_text())["banned"] == ["192.0.2.10"]

    output = root / "export.torrent"
    assert daemon.request("export_torrent", {"id": torrent_id, "output": str(output)})["id"] == torrent_id
    assert hashlib.sha1(bencode(bdecode(output.read_bytes())[b"info"])).hexdigest() == torrent_id
    daemon.request("export_torrent", {"id": torrent_id, "output": str(output)}, error="conflict")
    pending_id = "0123456789abcdef0123456789abcdef01234567"
    daemon.request("add", {"magnet": f"magnet:?xt=urn:btih:{pending_id}"})
    daemon.request("export_torrent", {"id": pending_id, "output": str(root / "pending.torrent")}, error="metadata_pending")
    daemon.request("remove", {"id": pending_id, "delete_files": False})
    source = root / "hybrid-source"
    source.mkdir()
    (source / "one.bin").write_bytes(data)
    (source / "two.bin").write_bytes(data * 2)
    hybrid = root / "hybrid.torrent"
    created = daemon.request("create_torrent", {"path": str(source), "output": str(hybrid), "private": True,
                                                "trackers": [url], "comment": "Mulee fixture"})
    decoded = bdecode(hybrid.read_bytes())
    assert decoded[b"info"][b"meta version"] == 2 and b"pieces" in decoded[b"info"]
    assert decoded[b"info"][b"private"] == 1 and decoded[b"comment"] == b"Mulee fixture"
    assert daemon.request("add", {"torrent_file": str(hybrid), "save_path": str(root)})["id"] == created["id"]
    daemon.complete(created["id"])
    hybrid_export = root / "hybrid-export.torrent"
    daemon.request("export_torrent", {"id": created["id"], "output": str(hybrid_export)})
    assert bdecode(hybrid_export.read_bytes())[b"info"] == decoded[b"info"]
    assert bdecode(hybrid_export.read_bytes()).get(b"piece layers") == decoded.get(b"piece layers")
    single_created = root / "single-created.torrent"
    daemon.request("create_torrent", {"path": str(source / "one.bin"), "output": str(single_created), "private": False, "trackers": []})
    assert bdecode(single_created.read_bytes())[b"info"][b"meta version"] == 2
    daemon.close("shutdown")

    # 回读停用订阅，再改变持久化到期时间，避免测试等待一整天。
    metadata_path = daemon.state / "meta" / (torrent_id + ".json")
    metadata = json.loads(metadata_path.read_text())
    state = metadata["tracker_state"][url]
    state["failures"] = 3
    state["disabled_until"] = int(time.time()) + 86400
    metadata_path.write_text(json.dumps(metadata))
    daemon = Daemon(binary, daemon.state)
    rows = daemon.request("trackers", {"id": torrent_id})["trackers"]
    assert rows[0]["status"] == "disabled" and rows[0]["disabled_until"] == state["disabled_until"]
    assert daemon.request("add_trackers", {"id": torrent_id, "urls": [url], "subscription": True})["added"] == 0
    assert json.loads((daemon.state / "ip-filters.json").read_text())["banned"] == ["192.0.2.10"]
    assert daemon.torrent(torrent_id)["save_path"] == str(kept)
    assert any(file["path"] == "Management/renamed-folder/keep.txt" for file in daemon.request("files", {"id": torrent_id})["files"])
    daemon.close("shutdown")
    metadata = json.loads(metadata_path.read_text())
    metadata["tracker_state"][url]["disabled_until"] = int(time.time()) - 1
    metadata_path.write_text(json.dumps(metadata))
    ManagementTracker.failures = False
    daemon = Daemon(binary, daemon.state)
    rows = daemon.request("trackers", {"id": torrent_id})["trackers"]
    assert rows[0]["disabled_until"] == 0 and rows[0]["url"] == url, rows
    daemon.configure(root / "junk-disabled", skip_junk_files=False)
    daemon.request("remove", {"id": torrent_id, "delete_files": False})
    added = daemon.request("add", {"torrent_file": str(torrent), "paused": True})
    assert added["skipped_files"] == []
    assert all(file["priority"] == 4 for file in daemon.request("files", {"id": torrent_id})["files"])
    daemon.request("remove", {"id": torrent_id, "delete_files": False})
    daemon.configure(root / "junk-disabled", skip_junk_files=True, junk_file_patterns=["*.bin"])
    added = daemon.request("add", {"torrent_file": str(torrent), "paused": True})
    assert [file["index"] for file in added["skipped_files"]] == [0]
    daemon.request("remove", {"id": torrent_id, "delete_files": False})
    added = daemon.request("add", {"torrent_file": str(torrent), "file_priorities": [4, 4, 4, 4]})
    assert added["skipped_files"] == []
    daemon.request("resume", {"id": torrent_id})

    # 对比封禁前后握手，确认导入范围和手动封禁真正作用于 IP 过滤器。
    loopback = root / "loopback.p2p"
    loopback.write_text("Loopback:127.0.0.1-127.0.0.1\n")

    def handshake_blocked(instance):
        port = instance.request("session_status")["listen_port"]
        with socket.create_connection(("127.0.0.1", port), timeout=3) as peer:
            peer.sendall(b"\x13BitTorrent protocol" + b"\0" * 8 + bytes.fromhex(torrent_id) + b"-MU0100-123456789012")
            try:
                return peer.recv(68) == b""
            except ConnectionResetError:
                return True

    assert not handshake_blocked(daemon)
    daemon.configure(root / "junk-disabled", ip_blocklist_path=str(loopback))
    assert handshake_blocked(daemon)
    daemon.configure(root / "junk-disabled", ip_blocklist_path="")
    assert not handshake_blocked(daemon)
    daemon.request("ban_ip", {"ip": "127.0.0.1"})
    assert handshake_blocked(daemon)
    daemon.close("shutdown")
    daemon = Daemon(binary, daemon.state)
    assert handshake_blocked(daemon)
    daemon.close("shutdown")
    tracker.shutdown()
    tracker.server_close()
    tracker_worker.join(timeout=2)
    print("PASS D2/F1-F5：过滤反馈、存储冲突/移动/重命名、校验/宣告、tracker、peer、IP 持久化、混合种子制作/导出", flush=True)


def incomplete_file_tests(binary, root):
    root.mkdir()
    first = os.urandom(256 * 1024)
    second = os.urandom(8 * 1024 * 1024)
    torrent, torrent_id, _ = fixture(root, "stream-fixture", [
        ("first.mp4", first), ("second.mkv", second),
    ], multi=True)
    destination = root / "downloads"
    content = destination / "stream-fixture"
    content.mkdir(parents=True)
    (content / "first.mp4.mulee").write_bytes(first)
    (content / "second.mkv.mulee").write_bytes(bytes(len(second)))
    state = root / "state"
    daemon = Daemon(binary, state)
    daemon.configure(destination)
    daemon.request("add", {"torrent_file": str(torrent), "save_path": str(destination)})
    daemon.request("force_recheck", {"id": torrent_id})

    def checked_first():
        files = daemon.request("files", {"id": torrent_id})["files"]
        return files if files[0]["done"] == len(first) and files[0]["storage_path"].endswith("first.mp4") else None

    files = wait_for(checked_first, description="individual checked file rename")
    assert files[0]["path"] == "stream-fixture/first.mp4"
    assert files[0]["contiguous_done"] == len(first)
    assert files[1]["storage_path"].endswith("second.mkv.mulee")
    assert files[1]["done"] == 0 and files[1]["contiguous_done"] == 0
    assert (content / "first.mp4").read_bytes() == first
    assert not (content / "first.mp4.mulee").exists()
    assert daemon.torrent(torrent_id)["is_finished"] is False
    params = {"id": torrent_id, "file_index": 1, "enabled": True}
    result = daemon.request("set_streaming", params)
    # 第二个文件 128 个 piece，首尾各 2% 涉及 3 个 piece。
    assert len(result["priority_pieces"]) == 6, result
    assert result["priority_pieces"][:3] == [4, 5, 6]
    assert result["priority_pieces"][-3:] == [129, 130, 131]
    assert daemon.torrent(torrent_id)["sequential_download"] is True
    assert daemon.request("files", {"id": torrent_id})["files"][1]["priority"] == 7
    daemon.request("set_streaming", {**params, "file_index": 2}, error="invalid_params")
    daemon.request("set_streaming", {**params, "enabled": 1}, error="invalid_params")
    daemon.close("shutdown")
    meta = json.loads((state / "meta" / (torrent_id + ".json")).read_text())
    assert meta["mark_incomplete"] is True and meta["streaming_file"] == 1
    assert meta["original_paths"] == {"0": "stream-fixture/first.mp4", "1": "stream-fixture/second.mkv"}
    daemon = Daemon(binary, state)
    daemon.configure(destination)
    files = wait_for(checked_first, description="restored file rename mapping")
    assert files[1]["storage_path"].endswith("second.mkv.mulee")
    daemon.request("set_streaming", {**params, "enabled": False})
    assert daemon.torrent(torrent_id)["sequential_download"] is False
    assert daemon.request("files", {"id": torrent_id})["files"][1]["priority"] == 4
    daemon.request("set_streaming", params)
    daemon.request("pause", {"id": torrent_id})
    (content / "second.mkv.mulee").write_bytes(second)
    daemon.request("force_recheck", {"id": torrent_id})
    daemon.request("resume", {"id": torrent_id})
    daemon.complete(torrent_id)
    assert daemon.torrent(torrent_id)["sequential_download"] is False
    assert daemon.torrent(torrent_id)["first_last_priority"] is False
    files = daemon.request("files", {"id": torrent_id})["files"]
    assert all(not item["storage_path"].endswith(".mulee") for item in files)
    assert (content / "second.mkv").read_bytes() == second
    daemon.close("shutdown")
    daemon = Daemon(binary, state)
    daemon.configure(destination)
    daemon.complete(torrent_id)
    assert (content / "second.mkv").read_bytes() == second
    daemon.close("shutdown")
    print("PASS C2/E4：逐文件校验改名、未完成/完成重启一致、连续开头、首尾 2% 优先、取消顺序下载", flush=True)


def run_tests(binary, root):
    incomplete_file_tests(binary, root / "incomplete-files")
    management_tests(binary, root)

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
    for cache in (0, 1024, 1024 * 1024, 64 * 1024 * 1024, 2**63 - 1):
        a.configure(seed_path, disk_cache_bytes=cache)
    a.configure(seed_path, max_active_downloads=40, max_active_seeds=20)
    for invalid in (-1, True, 1.5, "1024"):
        a.configure(seed_path)  # Keep the valid configuration available after rejection.
        params = {"download_dir": str(seed_path), "listen_port": 0, "download_limit": 0, "upload_limit": 0,
                  "max_active_downloads": 8, "max_active_seeds": 8, "dht": False, "lsd": False,
                  "port_mapping": False, "encryption": "prefer", "disk_cache_bytes": invalid}
        a.request("configure", params, error="invalid_params")
    for invalid in ("-XL", [""], [1], ["x" * 65], ["bad\nrule"], ["x"] * 51):
        params["disk_cache_bytes"] = 16 * 1024 * 1024
        params["blocked_clients"] = invalid
        a.request("configure", params, error="invalid_params")
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
    assert result == {"id": single_id, "name": "Mulee-open-test.bin", "duplicate": False, "skipped_files": []}
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
            assert set(file) == {"index", "path", "storage_path", "contiguous_done", "size", "done", "priority"}
            assert file["index"] == index and file["done"] == file["size"]
            assert file["priority"] == 4
    assert not a.torrent(single_id)["sequential_download"]
    assert not a.torrent(single_id)["first_last_priority"]
    mode = {"id": multi_id, "sequential_download": True, "first_last_priority": True}
    assert a.request("set_download_mode", mode) == {"sequential_download": True, "first_last_priority": True}
    assert a.torrent(multi_id)["sequential_download"] and a.torrent(multi_id)["first_last_priority"]
    a.request("set_download_mode", {"id": multi_id, "sequential_download": True}, error="invalid_params")
    a.request("set_download_mode", {**mode, "first_last_priority": 1}, error="invalid_params")
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

    # Handshake through the actual peer plugin. No network beyond loopback.
    def handshake(peer_id, client=None):
        peer = socket.create_connection(("127.0.0.1", port_a), timeout=3)
        reserved = bytearray(8)
        if client is not None:
            reserved[5] = 0x10
        peer.sendall(b"\x13BitTorrent protocol" + reserved + bytes.fromhex(single_id) + peer_id)
        if client is not None:
            header = b""
            while len(header) < 68:
                block = peer.recv(68 - len(header))
                assert block
                header += block
            payload = b"\x14\x00" + bencode({"m": {}, "v": client})
            peer.sendall(len(payload).to_bytes(4, "big") + payload)
        return peer

    def blocked_count():
        return a.torrent(single_id)["diagnostics"]["blocked_clients_count"]

    with handshake(b"-XL9876-" + b"a" * 12):
        wait_for(lambda: a.torrent(single_id)["diagnostics"]["peer_sources"]["incoming"] > 0,
                 description="inbound peer source")
        sample = a.torrent(single_id)["diagnostics"]
        assert sample["ipv4"] > 0 and sample["tcp"] > 0 and sample["ipv6"] == 0
        assert blocked_count() == 0
    for index, peer_id in enumerate((b"-XL0001-" + b"b" * 12, b"-XL9876-" + b"c" * 12), 1):
        a.configure(seed_path, port=port_a, blocked_clients=["-XL"])
        with handshake(peer_id) as peer:
            wait_for(lambda: blocked_count() == index, description="peer ID filter")
            peer.settimeout(3)
            received = b""
            while chunk := peer.recv(4096):
                received += chunk
            assert not received or received.startswith(b"\x13BitTorrent protocol")
    a.configure(seed_path, port=port_a, blocked_clients=["FixtureClient"])
    with handshake(b"-ZZ1234-" + b"d" * 12, "fixtureclient/9.9"):
        wait_for(lambda: blocked_count() == 3, description="extension client name filter")
    a.configure(seed_path, port=port_a, blocked_clients=[])
    with handshake(b"-XL4321-" + b"e" * 12):
        time.sleep(0.2)
        assert blocked_count() == 3
    print("PASS 屏蔽默认关闭、任意版本 peer ID、扩展握手客户端名、次数统计和运行时关闭", flush=True)

    class Tracker(BaseHTTPRequestHandler):
        def do_GET(self):
            body = bencode({"interval": 1800, "peers": b""})
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Tracker) as tracker:
        worker = threading.Thread(target=tracker.serve_forever, daemon=True)
        worker.start()
        try:
            url = f"http://127.0.0.1:{tracker.server_port}/announce"
            a.request("add_trackers", {"id": multi_id, "urls": [url]})
            wait_for(lambda: a.torrent(multi_id)["diagnostics"]["trackers_available"] == 1,
                     description="working tracker summary")
        finally:
            tracker.shutdown()
            worker.join(timeout=2)

    tracker_urls = [f"http://127.0.0.1:9/announce?fixture={i}" for i in range(50)]
    a.request("pause", {"id": single_id})
    assert a.request("add_trackers", {"id": single_id, "urls": tracker_urls[:2] * 2}) == {"added": 2, "total": 2}
    assert a.request("add_trackers", {"id": single_id, "urls": tracker_urls[:2]}) == {"added": 0, "total": 2}
    a.request("add_trackers", {"id": single_id, "urls": tracker_urls[2:]})
    a.request("add_trackers", {"id": single_id, "urls": [tracker_urls[0] + "extra"]}, error="tracker_limit")
    for invalid_urls in (["ftp://tracker.invalid/announce"], ["https://"], ["http:///announce"], ["http://bad url"], [False], "url", tracker_urls + ["extra"]):
        a.request("add_trackers", {"id": single_id, "urls": invalid_urls}, error="invalid_params")
    a.request("resume", {"id": single_id})
    wait_for(lambda: a.torrent(single_id)["diagnostics"]["trackers_failed"] > 0
             and a.torrent(single_id)["diagnostics"]["last_tracker_error"], description="failed tracker summary")
    pending_id = "e" * 40
    a.request("add", {"magnet": f"magnet:?xt=urn:btih:{pending_id}", "paused": True})
    a.request("add_trackers", {"id": pending_id, "urls": tracker_urls[:1]}, error="metadata_pending")
    a.request("add", {"magnet": f"magnet:?xt=urn:btih:{pending_id}&tr={tracker_urls[0]}"}, error="metadata_pending")
    assert not a.torrent(pending_id)["is_finished"]
    a.request("remove", {"id": pending_id, "delete_files": False})
    private, private_id, _ = fixture(root, "private-fixture.bin", [("", b"private fixture")], private=True)
    a.request("add", {"torrent_file": str(private), "paused": True})
    assert a.torrent(private_id)["is_private"]
    a.request("add_trackers", {"id": private_id, "urls": tracker_urls[:1]}, error="private_torrent")
    a.request("add", {"magnet": f"magnet:?xt=urn:btih:{private_id}&tr={tracker_urls[0]}"}, error="private_torrent")
    a.request("remove", {"id": private_id, "delete_files": False})
    print("PASS tracker 去重、独立 tier、上限、原子校验、私有和 metadata 限制（含重复 add）", flush=True)

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
    validate_item(partial)
    assert not partial["is_finished"]
    b.request("set_download_mode", {"id": single_id, "sequential_download": True, "first_last_priority": True})
    wait_for(lambda: b.torrent(single_id)["diagnostics"]["connected_peers"] > 0, description="connected peer diagnostics")
    b.request("pause", {"id": single_id})
    b.request("pause", {"id": single_id})
    assert b.torrent(single_id)["paused"]
    before = b.torrent(single_id)["total_wanted_done"]
    b.request("resume", {"id": single_id})
    b.request("resume", {"id": single_id})
    assert not b.torrent(single_id)["paused"]
    assert b.request("shutdown") == {"saved": True}
    # The acknowledgement is a persistence barrier, before process teardown.
    resume = b.state / "resume" / (single_id + ".resume")
    assert resume.stat().st_size > 0
    b.close()
    assert (b.state / "meta" / (single_id + ".json")).is_file()
    print("PASS 本机磁力元数据、部分下载、pause/resume、shutdown 刷盘保存", flush=True)

    b = Daemon(binary, b.state)
    restored = wait_for(lambda: (item if item["state"] != "checking" else None)
                        if (item := b.torrent(single_id)) else None)
    assert restored["total_wanted_done"] >= before, (before, restored)
    assert restored["source"] == "loopback-test"
    assert not restored["is_finished"]
    assert restored["max_connections"] == 250
    assert restored["sequential_download"] and restored["first_last_priority"]
    b.request("set_download_mode", {"id": single_id, "sequential_download": False, "first_last_priority": False})
    assert not b.torrent(single_id)["sequential_download"] and not b.torrent(single_id)["first_last_priority"]
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

    # Completing only the selected file is a finished torrent, even though the
    # rest of the payload is absent. Expanding selection must revoke completion.
    selected = Daemon(binary, root / "state-selected")
    selected_path = root / "selected-downloads"
    selected.configure(selected_path, download_limit=96 * 1024)
    selected.request("add", {"magnet": f"magnet:?xt=urn:btih:{multi_id}&x.pe=127.0.0.1:{port_a}"})
    selected.event("metadata_received", timeout=30)
    selected.request("set_file_priorities", {"id": multi_id, "priorities": [4, 0]})
    selected.request("set_download_mode", {"id": multi_id, "sequential_download": True, "first_last_priority": True})
    chosen = selected.complete(multi_id)
    assert chosen["is_finished"] and chosen["selected_file_count"] == 1 and chosen["file_count"] == 2
    # Wanted bytes include the boundary piece shared with an unselected file.
    assert len(multi_entries[0][1]) <= chosen["total_wanted"] <= 64 * 1024
    assert chosen["total_wanted_done"] == chosen["total_wanted"]
    assert (selected_path / "开源测试集/说明.txt").read_bytes() == multi_entries[0][1]
    selected.request("pause", {"id": multi_id})
    selected.request("set_file_priorities", {"id": multi_id, "priorities": [4, 4]})
    wait_for(lambda: not selected.torrent(multi_id)["is_finished"], description="expanded selection unfinished")
    selected.close("shutdown")
    selected_resume = bdecode((selected.state / "resume" / (multi_id + ".resume")).read_bytes())
    assert selected_resume[b"sequential_download"] == 1
    selected = Daemon(binary, selected.state)
    recovered = wait_for(lambda: item if (item := selected.torrent(multi_id))["state"] != "checking" else None)
    assert not recovered["is_finished"] and recovered["paused"]
    assert recovered["sequential_download"] and recovered["first_last_priority"]
    assert recovered["total_wanted_done"] < recovered["total_wanted"]
    selected.close("shutdown")
    print("PASS 选择性下载完成、扩大选择撤销完成、首尾优先和顺序标志恢复", flush=True)

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
    stored = bdecode((a.state / "resume" / (single_id + ".resume")).read_bytes())
    assert stored[b"max_connections"] == 250
    assert len(stored[b"trackers"]) == 2
    assert len(stored[b"trackers"][0]) == 2 and len(stored[b"trackers"][1]) == 48
    dht_path = a.state / "dht.state"
    saved_dht = bdecode(dht_path.read_bytes())
    assert set(saved_dht) == {b"dht state"}
    # A loaded DHT snapshot survives even if this session never enables DHT.
    synthetic_dht = {b"dht state": {b"node-id": [b"n" * 20 + socket.inet_aton("127.0.0.1")],
                                   b"nodes": [socket.inet_aton("127.0.0.1") + (49001).to_bytes(2, "big")]}}
    dht_path.write_bytes(bencode(synthetic_dht))
    preserved = Daemon(binary, a.state)
    preserved.close("shutdown")
    assert "Loaded DHT state: 1 node IDs, 1 bootstrap nodes" in (a.state / "torrentd.log").read_text()
    assert bdecode(dht_path.read_bytes()) == synthetic_dht
    dht_path.write_bytes(b"damaged-dht")
    broken = a.state / "resume" / ("f" * 40 + ".resume")
    broken.write_bytes(b"corrupt-resume")
    a = Daemon(binary, a.state)
    assert len(a.torrents()) == 2
    assert not broken.exists() and (a.state / "broken" / broken.name).exists()
    assert a.torrent(multi_id)["paused"]
    assert a.torrent(multi_id)["sequential_download"] and a.torrent(multi_id)["first_last_priority"]
    assert a.torrent(single_id)["max_connections"] == 250
    assert "Ignoring damaged DHT state" in (a.state / "torrentd.log").read_text()
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
    for damaged in (bencode({"dht state": {"nodes": 1}}), bencode({"dht state": {"node-id": [b"short"]}}),
                    bencode({"dht state": {}}) + b"trailing"):
        dht_path.write_bytes(damaged)
        corrupt = Daemon(binary, a.state)
        corrupt.close("shutdown")
        assert "Ignoring damaged DHT state" in "\n".join(corrupt.stderr)
    print("PASS DHT 仅保存路由状态、重载与关闭时保留、损坏编码和类型安全忽略", flush=True)

    # A failed atomic resume write must never grant the parent fast-exit permission.
    failure = Daemon(binary, root / "state-save-failure")
    failure.configure(root / "failure-downloads")
    failure.request("add", {"torrent_file": str(single)})
    resume_directory = failure.state / "resume"
    resume_directory.rename(failure.state / "resume-backup")
    resume_directory.write_bytes(b"not-a-directory")
    reply = failure.request("shutdown", error="io_error")
    assert "result" not in reply
    assert failure.process.wait(timeout=15) == 0
    print("PASS resume 写盘失败不发送 saved 确认", flush=True)


def main():
    # SSH 的文件描述符上限过低会使 libtorrent 降低连接数，测试子进程需要足够额度。
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    target = 4096 if hard == resource.RLIM_INFINITY else min(4096, hard)
    if soft < target:
        resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))
    default = Path(__file__).resolve().parents[1] / "build/thirdparty/bin/mulee-torrentd"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", nargs="?", type=Path, default=default)
    args = parser.parse_args()
    binary = args.binary.resolve()
    assert binary.is_file(), f"Build first: scripts/build-torrentd.sh --standalone ({binary})"
    subprocess.run([str(binary), "--test-dns"], check=True, timeout=15)
    temporary_root = Path(__file__).resolve().parents[1] / "build"
    temporary_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mulee-torrentd-test-", dir=temporary_root) as temporary:
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
