#!/usr/bin/env python3
"""Verify torrent task and session rate limits using loopback transfers."""

import os
from pathlib import Path
import resource
import runpy
import tempfile
import time


def run():
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    target = 4096 if hard == resource.RLIM_INFINITY else min(4096, hard)
    if soft < target:
        resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))
    root = Path(__file__).resolve().parents[1]
    helpers = runpy.run_path(str(root / "scripts/test-torrentd.py"))
    daemon = helpers["Daemon"]
    fixture = helpers["fixture"]
    wait_for = helpers["wait_for"]
    binary = root / "build/thirdparty/bin/mulee-torrentd"
    assert binary.is_file(), "Build the torrent engine before running this test"
    with tempfile.TemporaryDirectory(prefix="task-limits-", dir=root / "build") as temporary:
        path = Path(temporary)
        payload = os.urandom(2 * 1024 * 1024)
        torrent, task_id, seed_path = fixture(path, "limits.bin", [("", payload)])
        seed = daemon(binary, path / "seed-state")
        try:
            port = seed.configure(seed_path)
            seed.request("add", {"torrent_file": str(torrent)})
            seed.complete(task_id)
            for index, (global_limit, task_limit) in enumerate(((32_768, 262_144), (262_144, 32_768))):
                download = daemon(binary, path / f"download-state-{index}")
                download.configure(path / f"files-{index}", download_limit=global_limit)
                download.request("add", {
                    "magnet": f"magnet:?xt=urn:btih:{task_id}&x.pe=127.0.0.1:{port}",
                    "paused": True,
                })
                download.request("set_task_limits", {
                    "id": task_id, "download_limit": task_limit, "upload_limit": 0,
                })
                download.request("resume", {"id": task_id})
                wait_for(lambda: download.torrent(task_id)["total_wanted_done"] > 0,
                         timeout=40, description="rate-limited loopback transfer")
                first = download.torrent(task_id)["total_wanted_done"]
                start = time.monotonic()
                time.sleep(4)
                last = download.torrent(task_id)
                elapsed = time.monotonic() - start
                received = last["total_wanted_done"] - first
                assert last["user_download_limit"] == task_limit
                assert received > 0, last
                # 容忍一次令牌补充与分块突发，仍能识别另一层额度被覆盖。
                assert received <= min(global_limit, task_limit) * (elapsed + 2) + 65_536, received
                download.close("shutdown")
                print(f"PASS BT global={global_limit} task={task_limit}: {received} bytes in {elapsed:.2f}s", flush=True)
            seed.close("shutdown")
        finally:
            for process in helpers["PROCESSES"]:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream and not stream.closed:
                        stream.close()
    print("PASS BT 两级限速取较小值，全部测试进程已退出", flush=True)


if __name__ == "__main__":
    run()
