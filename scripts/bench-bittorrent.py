#!/usr/bin/env python3
"""Isolated, serial 45-second official-torrent A/B/B+ benchmark."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import re
import shutil
import signal
import statistics
import subprocess
import tempfile
import threading
import time
from urllib.parse import urljoin, urlsplit


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
LOGS = BUILD / "bench-bittorrent-logs"
RESULTS = BUILD / "bench-bittorrent-results.json"
SUMMARY = BUILD / "bench-bittorrent-summary.md"
BINARIES = {
    "A": Path("/Applications/Mulee.app/Contents/Helpers/mulee-torrentd"),
    "B": BUILD / "thirdparty/bin/mulee-torrentd",
}
TRACKER_SOURCES = [
    "https://cdn.jsdelivr.net/gh/ngosang/trackerslist@master/trackers_best.txt",
    "https://cdn.jsdelivr.net/gh/XIU2/TrackersListCollection@master/best.txt",
]
CONFIGURE = {
    "listen_port": 0, "download_limit": 0, "upload_limit": 0,
    "max_active_downloads": 8, "max_active_seeds": 8,
    "dht": True, "lsd": False, "port_mapping": False, "encryption": "prefer",
}
PROCESSES = []


def fetch(url, destination, metadata, head=False):
    command = ["curl", "--fail", "--location", "--silent", "--show-error",
               "--max-time", "45", "--dump-header", str(destination) + ".headers",
               "--output", str(destination), "--write-out",
               "%{http_code} %{size_download} %{url_effective}"]
    if head:
        command.append("--head")
    completed = subprocess.run(command + [url], capture_output=True, text=True)
    record = {"url": url, "returncode": completed.returncode,
              "curl": completed.stdout, "stderr": completed.stderr, "head": head}
    metadata.append(record)
    if completed.returncode:
        raise RuntimeError(record)
    record["body_bytes"] = 0 if head else destination.stat().st_size
    return destination.read_bytes()


class Daemon:
    def __init__(self, binary, state, log):
        self.sequence = 0
        self.messages = queue.Queue()
        self.log = log
        self.process = subprocess.Popen(
            [str(binary), "--state-dir", str(state)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"},
        )
        PROCESSES.append(self.process)
        self.threads = [threading.Thread(target=self.read, daemon=True),
                        threading.Thread(target=self.stderr, daemon=True)]
        for thread in self.threads:
            thread.start()
        self.ready = self.message()
        if self.ready.get("event") != "ready":
            raise RuntimeError(self.ready)

    def read(self):
        try:
            with self.log.with_suffix(".protocol.jsonl").open("w") as output:
                for line in self.process.stdout:
                    output.write(line)
                    output.flush()
                    self.messages.put(json.loads(line))
        except Exception as error:
            self.messages.put(error)
        finally:
            self.messages.put(None)

    def stderr(self):
        with self.log.with_suffix(".stderr.log").open("w") as output:
            for line in self.process.stderr:
                output.write(line)
                output.flush()

    def message(self):
        result = self.messages.get(timeout=15)
        if not isinstance(result, dict):
            raise RuntimeError(f"Invalid response: {result!r}")
        return result

    def request(self, method, params=None):
        self.sequence += 1
        self.process.stdin.write(json.dumps({
            "id": self.sequence, "method": method, "params": params or {},
        }) + "\n")
        self.process.stdin.flush()
        while True:
            result = self.message()
            if "event" in result:
                continue
            if result.get("id") != self.sequence or "error" in result:
                raise RuntimeError(result)
            return result["result"]

    def close(self):
        try:
            if self.process.poll() is None:
                self.request("shutdown")
                self.process.wait(timeout=15)
        finally:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=10)
            for thread in self.threads:
                thread.join(timeout=2)
            for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
                stream.close()


def run_trial(sample, group, round_number, torrent, trackers):
    name = f"{sample}-r{round_number}-{group.replace('+', 'plus')}"
    temporary = Path(tempfile.mkdtemp(prefix="bench-bittorrent-", dir=BUILD))
    state = temporary / "state"
    result = {"sample": sample, "group": group, "round": round_number,
              "temporary_directory": str(temporary), "samples": []}
    daemon = None
    print(f"START {name}", flush=True)
    try:
        daemon = Daemon(BINARIES["A" if group == "A" else "B"], state, LOGS / name)
        result["pid"] = daemon.process.pid
        result["ready"] = daemon.ready
        result["configure_params"] = {**CONFIGURE, "download_dir": str(temporary / "downloads")}
        result["configure_result"] = daemon.request("configure", result["configure_params"])
        if group != "A":
            applied = result["configure_result"]
            assert applied["connections_limit"] == 500, applied
            assert applied["announce_to_all_tiers"] is True, applied
        torrent_id = daemon.request("add", {
            "torrent_file": str(torrent), "save_path": str(temporary / "downloads"),
            "paused": True,
        })["id"]
        if group == "B+":
            item = next(item for item in daemon.request("list")["torrents"] if item["id"] == torrent_id)
            diagnostics = item["diagnostics"]
            original_count = sum(diagnostics[key] for key in (
                "trackers_available", "trackers_failed", "trackers_pending",
            ))
            result["original_tracker_count"] = original_count
            result["appended_tracker_urls"] = trackers[:max(0, 50 - original_count)]
            assert result["appended_tracker_urls"], "No room for public trackers"
            result["add_trackers"] = daemon.request("add_trackers", {
                "id": torrent_id, "urls": result["appended_tracker_urls"],
            })
        started = time.monotonic()
        daemon.request("resume", {"id": torrent_id})
        for second in range(46):
            time.sleep(max(0, started + second - time.monotonic()))
            requested = time.monotonic() - started
            items = daemon.request("list")["torrents"]
            item = next(item for item in items if item["id"] == torrent_id)
            if item["state"] == "error":
                raise RuntimeError(item)
            point = {
                "second": second, "requested_seconds": requested,
                "elapsed_seconds": time.monotonic() - started,
                "download_bytes": item["all_time_download"],
                "upload_bytes": item["all_time_upload"],
                "verified_bytes": item["total_wanted_done"],
                "peers": item["num_peers"], "download_rate": item["download_rate"],
                "state": item["state"], "total_wanted": item["total_wanted"],
            }
            if group != "A":
                point["diagnostics"] = item["diagnostics"]
            result["samples"].append(point)
        daemon.request("pause", {"id": torrent_id})
        result["pause_seconds"] = time.monotonic() - started
        points = result["samples"]
        result["metrics"] = {
            "first_peer_seconds": next((p["elapsed_seconds"] for p in points if p["peers"] > 0), None),
            "first_byte_seconds": next((p["elapsed_seconds"] for p in points if p["download_bytes"] > 0), None),
            "download_bytes_45s": points[-1]["download_bytes"],
            "upload_bytes_45s": points[-1]["upload_bytes"],
            "stable_bytes_per_second": (points[45]["download_bytes"] - points[15]["download_bytes"]) / (
                points[45]["elapsed_seconds"] - points[15]["elapsed_seconds"]),
            "peak_peers": max(p["peers"] for p in points),
            "completed_within_window": any(p["verified_bytes"] >= p["total_wanted"] for p in points),
        }
    finally:
        try:
            if daemon is not None:
                daemon.close()
                result["exit_code"] = daemon.process.returncode
                result["process_exited"] = daemon.process.poll() is not None
            state_log = state / "torrentd.log"
            if state_log.exists():
                log = state_log.read_text()
                (LOGS / (name + ".daemon.log")).write_text(log)
                result["fake_ip_fallbacks"] = log.count("检测到代理假地址，已改用公共 DNS 解析")
        finally:
            shutil.rmtree(temporary)
            result["temporary_directory_removed"] = not temporary.exists()
            (LOGS / (name + ".json")).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    assert result["process_exited"] and result["exit_code"] == 0
    assert result["temporary_directory_removed"]
    print(f"DONE {name}: {json.dumps(result['metrics'], ensure_ascii=False)}; cleaned", flush=True)
    return result


def cell(values, scale=1):
    valid = [value / scale for value in values if value is not None]
    if len(valid) != len(values):
        ordered = valid + [math.inf] * (len(values) - len(valid))
        median = statistics.median(ordered)
        center = f"{median:.2f}" if math.isfinite(median) else ">45"
        lower = f"{min(valid):.2f}" if valid else ">45"
        return f"{center} [{lower}–>45]（{len(valid)}/{len(values)} 观测到）"
    return f"{statistics.median(valid):.2f} [{min(valid):.2f}–{max(valid):.2f}]"


def write_results(report):
    RESULTS.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    lines = ["# BT 45 秒 A/B/B+ 测速", "",
             "单元格为中位数 [最小–最大]，每组 3 轮；速度为 MiB/s。", "",
             "| 样本 | 组 | 首 peer（秒） | 首字节（秒） | 15–45 秒速度 | 峰值 peer | 45 秒下载（MiB） |",
             "|---|---|---|---|---|---|---|"]
    for sample in ("Debian", "Ubuntu"):
        for group in ("A", "B", "B+"):
            metrics = [r["metrics"] for r in report["trials"] if r["sample"] == sample and r["group"] == group]
            if not metrics:
                continue
            columns = [cell([m[key] for m in metrics], scale) for key, scale in (
                ("first_peer_seconds", 1), ("first_byte_seconds", 1),
                ("stable_bytes_per_second", 1024 ** 2), ("peak_peers", 1),
                ("download_bytes_45s", 1024 ** 2),
            )]
            lines.append("| " + " | ".join([sample, group] + columns) + " |")
    lines += ["", "## 结论", ""]
    for sample in ("Debian", "Ubuntu"):
        speeds = {group: [r["metrics"]["stable_bytes_per_second"] for r in report["trials"]
                          if r["sample"] == sample and r["group"] == group] for group in ("A", "B", "B+")}
        for group, baseline in (("B", "A"), ("B+", "A"), ("B+", "B")):
            values, reference = speeds[group], speeds[baseline]
            if len(values) != 3 or len(reference) != 3:
                continue
            base = statistics.median(reference)
            change = f"{(statistics.median(values) / base - 1) * 100:+.1f}%" if base else "基线为零，无法计算百分比"
            if min(values) > max(reference):
                conclusion = "速度范围完全高于基线，本次改善超过观测波动；三轮不能证明长期稳定收益"
            elif max(values) < min(reference):
                conclusion = "速度范围完全低于基线，本次出现回退"
            else:
                conclusion = "速度范围重叠，不能确认改善超过波动"
            lines.append(f"- {sample} {group} 对 {baseline}：中位数 {change}；{conclusion}。")
    down = sum(r["metrics"]["download_bytes_45s"] for r in report["trials"])
    up = sum(r["metrics"]["upload_bytes_45s"] for r in report["trials"])
    fetched = sum(r.get("body_bytes", 0) for r in report["fetches"])
    report["traffic"] = {"bt_payload_download_bytes": down, "bt_payload_upload_bytes": up,
                         "http_resource_body_bytes": fetched,
                         "observed_total_bytes": down + up + fetched,
                         "wire_total_bytes": None}
    lines += ["", f"BT 下载 {down:,} 字节，上传 {up:,} 字节；HTTP 资源正文 {fetched:,} 字节。",
              f"已统计合计 {down + up + fetched:,} 字节（{(down + up + fetched) / 1024 ** 3:.3f} GiB）。",
              "这是应用载荷口径；不含 DHT、tracker、握手、包头、重传及停止尾段，实际线路总流量不确定。", "",
              "Ubuntu 的 A/B 基线接近零，百分比受低基数影响，应以绝对速度为主。", "",
              "## 方法与限制", "",
              f"- A 应用版本 {report['old_app_version']}；0.1.8 按任务说明已包含 fake-ip 修复。",
              "- 所有组使用相同基础 configure；B/B+ 验证连接上限 500、announce_to_all_tiers=true。",
              "- B+ 在暂停状态追加去重公共 tracker（最多 50 条），随后从 resume 请求开始计时。",
              "- 每轮全新状态及下载目录，DHT 冷启动；顺序按轮 A/B/B+、B/B+/A、B+/A/B，串行。",
              "- 每秒 list 采样；首 peer/字节是首次观测时间，约 1 秒分辨率，未观测到记 null（45 秒内未出现）。",
              "- 时间中位数将未出现的事件视为 >45 秒的右删失值；不会仅对成功轮次计算中位数。",
              "- 稳定速度按 15、45 秒实际采样时间及累计载荷字节差计算；没有人为排除完成后的空闲时间。",
              "- 两引擎 ready.version 为协议版本；应用版本另从指定 Info.plist 读取。",
              "- 未访问用户状态/下载目录，未操作用户 Mulee 进程；清理只涉及脚本创建的进程和目录。",
              f"- 完成轮数：{len(report['trials'])}/18；全部清理：{report.get('cleanup_verified', False)}。", ""]
    verification = report.get("verification", {})
    if verification:
        lines += [f"- 运行恢复说明：{verification['setup_retry']}",
                  f"- 最晚末次采样 {verification['maximum_final_sample_seconds']:.3f} 秒，"
                  f"最晚暂停 {verification['maximum_pause_seconds']:.3f} 秒。", ""]
    SUMMARY.write_text("\n".join(lines))
    RESULTS.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resume", action="store_true", help="保留已完成且已清理的轮次，继续未完成轮次")
    parser.add_argument("--samples", default="Debian,Ubuntu", help="逗号分隔：Debian,Ubuntu")
    parser.add_argument("--groups", default="A,B,B+", help="逗号分隔：A,B,B+")
    parser.add_argument("--tag", default="", help="结果文件名后缀，避免覆盖上一次结果")
    args = parser.parse_args()
    if args.tag:
        global RESULTS, SUMMARY
        RESULTS = RESULTS.with_name(RESULTS.stem + "-" + args.tag + RESULTS.suffix)
        SUMMARY = SUMMARY.with_name(SUMMARY.stem + "-" + args.tag + SUMMARY.suffix)
    wanted_samples = [name.strip() for name in args.samples.split(",") if name.strip()]
    BUILD.mkdir(exist_ok=True)
    LOGS.mkdir(exist_ok=True)
    report = {"started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "fetches": [], "trials": [],
              "old_app_version": subprocess.check_output([
                  "defaults", "read", "/Applications/Mulee.app/Contents/Info.plist",
                  "CFBundleShortVersionString",
              ], text=True).strip()}
    report["binaries"] = {name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                          for name, path in BINARIES.items()}
    if args.resume:
        previous = json.loads(RESULTS.read_text())
        assert previous["binaries"] == report["binaries"]
        assert previous["old_app_version"] == report["old_app_version"]
        assert all(r["process_exited"] and r["temporary_directory_removed"] for r in previous["trials"])
        report = previous
        report["resumed_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    try:
        ubuntu = "https://releases.ubuntu.com/24.04/ubuntu-24.04.5.1-desktop-amd64.iso.torrent"
        try:
            fetch(ubuntu, LOGS / "ubuntu-head.txt", report["fetches"], head=True)
        except RuntimeError:
            index = fetch("https://releases.ubuntu.com/24.04/", LOGS / "ubuntu-index.html", report["fetches"]).decode()
            matches = re.findall(r'href="(ubuntu-[^"]+-desktop-amd64\.iso\.torrent)"', index)
            if not matches:
                raise RuntimeError("No official Ubuntu desktop torrent found")
            latest = max(matches, key=lambda name: tuple(int(n) for n in re.findall(r"\d+", name)))
            ubuntu = urljoin("https://releases.ubuntu.com/24.04/", latest)
        urls = {"Debian": "https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/debian-13.7.0-amd64-netinst.iso.torrent",
                "Ubuntu": ubuntu}
        urls = {name: url for name, url in urls.items() if name in wanted_samples}
        report["torrent_urls"] = urls
        for sample, url in urls.items():
            fetch(url, LOGS / (sample + ".torrent"), report["fetches"])
        lists = []
        for index, url in enumerate(TRACKER_SOURCES):
            data = fetch(url, LOGS / f"trackers-{index}.txt", report["fetches"]).decode()
            lists.append([line.strip() for line in data.splitlines() if line.strip()])
        trackers = []
        # Interleave sources so both contribute before the 50-entry cap.
        for index in range(max(map(len, lists))):
            for entries in lists:
                if index >= len(entries):
                    continue
                url = entries[index]
                parsed = urlsplit(url)
                if parsed.scheme in ("udp", "http", "https") and parsed.hostname and url not in trackers:
                    trackers.append(url)
        trackers = trackers[:50]
        assert trackers
        report["extra_trackers"] = trackers
        groups = [name.strip() for name in args.groups.split(",") if name.strip()]
        for round_number in range(1, 4):
            order = groups[round_number - 1:] + groups[:round_number - 1]
            for sample in urls:
                for group in order:
                    if any(r["sample"] == sample and r["group"] == group and r["round"] == round_number
                           for r in report["trials"]):
                        continue
                    result = run_trial(sample, group, round_number, LOGS / (sample + ".torrent"), trackers)
                    report["trials"].append(result)
                    write_results(report)
    finally:
        for process in PROCESSES:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
        report["cleanup_verified"] = (
            all(process.poll() is not None for process in PROCESSES)
            and all(not Path(r["temporary_directory"]).exists() for r in report["trials"])
            and not any(BUILD.glob("bench-bittorrent-*/state"))
        )
        report["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        write_results(report)
    assert len(report["trials"]) == len(report["torrent_urls"]) * len(groups) * 3 and report["cleanup_verified"]
    print("COMPLETE 18/18; all benchmark processes exited and temporary directories removed", flush=True)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda signum, frame: (_ for _ in ()).throw(KeyboardInterrupt()))
    main()
