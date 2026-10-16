#!/usr/bin/env python3
"""Run an isolated, short Ubuntu transfer; never use the application's state."""

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", nargs="?", type=Path,
                        default=Path(__file__).resolve().parents[1] / "build/thirdparty/bin/mulee-torrentd")
    parser.add_argument("--expect", choices=["blocked", "transfer"], default="transfer")
    parser.add_argument("--timeout", type=int, default=90)
    # 用仍在发行的官方种子；过期版本会被官方 tracker 拒绝（not authorized）。
    parser.add_argument("--torrent-url", default="https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/"
                        "debian-13.7.0-amd64-netinst.iso.torrent")
    args = parser.parse_args()
    assert 0 < args.timeout <= 90
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("torrentd_tests", Path(__file__).with_name("test-torrentd.py"))
    tests = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tests)
    result = {"peers": 0, "download_bytes": 0, "dns_fallbacks": 0,
              "dht_nodes": 0, "tracker_rejected": False}
    with tempfile.TemporaryDirectory(prefix="mulee-fakeip-test-") as temporary:
        root = Path(temporary)
        torrent = root / "official.torrent"
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
                        "--max-time", "45", "--output", str(torrent),
                        args.torrent_url], check=True)
        daemon = None
        torrent_id = None
        try:
            daemon = tests.Daemon(args.binary.resolve(), root / "state")
            daemon.configure(root / "downloads", download_limit=1024 * 1024, dht=True)
            torrent_id = daemon.request("add", {"torrent_file": str(torrent),
                                               "save_path": str(root / "downloads")})["id"]
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline:
                item = daemon.torrent(torrent_id)
                assert item and item["state"] != "error", item
                result["peers"] = max(result["peers"], item["num_peers"])
                result["download_bytes"] = max(result["download_bytes"], item["all_time_download"])
                status = daemon.request("session_status")
                result["dht_nodes"] = max(result["dht_nodes"], status["dht_nodes"])
                if result["peers"] > 0 and result["download_bytes"] > 0:
                    break
                time.sleep(0.5)
        finally:
            try:
                if daemon is not None and torrent_id is not None:
                    daemon.request("remove", {"id": torrent_id, "delete_files": True})
            finally:
                try:
                    if daemon is not None:
                        daemon.close("shutdown")
                finally:
                    for process in tests.PROCESSES:
                        if process.poll() is None:
                            process.kill()
                            process.wait(timeout=10)
            log = (root / "state/torrentd.log").read_text() if (root / "state/torrentd.log").exists() else ""
            result["dns_fallbacks"] = log.count("检测到代理假地址，已改用公共 DNS 解析")
            result["tracker_rejected"] = "Requested download is not authorized for use with this tracker." in log
    print(json.dumps(result, ensure_ascii=False), flush=True)
    if args.expect == "blocked":
        assert result["peers"] == 0 and result["download_bytes"] == 0, result
    else:
        assert result["peers"] > 0 and result["download_bytes"] > 0, result
        assert result["dns_fallbacks"] > 0, "Transfer succeeded without exercising DNS fallback"


if __name__ == "__main__":
    main()
