#!/usr/bin/env python3
"""只使用标准库的离线 amuled 集成测试；通过 test-amuled.sh 以隔离模式运行。"""

import argparse
import hashlib
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import tempfile
import time


ENV = dict(os.environ, LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8")
FILE_NAME = "Mulee-Fictional-EC-Test.bin"
FILE_HASH = "0123456789ABCDEF0123456789ABCDEF"
LINK = f"ed2k://|file|{FILE_NAME}|1048576|{FILE_HASH}|/"


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def write_config(home, password, ec_port, peer_port, udp_port):
    """键名来自 aMule 3.1.0 src/Preferences.cpp；不继承用户配置。"""
    for name in ("Incoming", "Temp"):
        (home / name).mkdir()
    # CPath::FromUniv 先按 Latin-1 取回文件名字节，再用 UTF-8 解码。
    incoming = os.fsencode(home / "Incoming").decode("latin-1")
    temporary = os.fsencode(home / "Temp").decode("latin-1")
    config = f"""[eMule]
Nick=Mulee-EC-Test
Address=127.0.0.1
Port={peer_port}
UDPPort={udp_port}
UDPEnable=0
Autoconnect=0
Reconnect=0
ConnectToED2K=0
ConnectToKad=0
UPnPEnabled=0
Serverlist=0
AddServerListFromServer=0
AddServerListFromClient=0
IncomingDir={incoming}
TempDir={temporary}
ShareHiddenFiles=0
AutoRescanSharedDirs=0
[ExternalConnect]
AcceptExternalConnections=1
ECAddress=127.0.0.1
ECPort={ec_port}
ECPassword={hashlib.md5(password.encode()).hexdigest()}
[WebServer]
Enabled=0
[AmuleApi]
Enabled=0
[MediaMetadata]
Enabled=0
"""
    (home / "amule.conf").write_text(config, encoding="utf-8")
    (home / "amule.conf").chmod(0o600)
    for name in ("shareddir.dat", "shareddir-explicit.dat", "shareddir-recursive.dat"):
        (home / name).write_text("", encoding="utf-8")


def client(binary, home, port, password, command):
    result = subprocess.run(
        [str(binary), "-f", str(home / "remote.conf"), "-h", "127.0.0.1",
         "-p", str(port), "-P", password, "--no-log-file", "-c", command],
        env=ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, timeout=20,
    )
    return result


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def wait_ready(process, port):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        require(process.poll() is None, f"amuled 提前退出：{process.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise AssertionError("30 秒内 EC 端口没有就绪")


def stop(process):
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise AssertionError("SIGTERM 后 30 秒未退出，已清理进程")
    require(process.returncode == 0, f"amuled 没有干净退出：{process.returncode}")


def run_test(daemon, command):
    processes = []
    # macOS 临时目录使用 ASCII，且每次全新；HOME 仍指向隔离目录以防客户端回退。
    with tempfile.TemporaryDirectory(prefix="mulee-amuled-") as temporary:
        home = Path(temporary)
        password = secrets.token_hex(16)
        ports = set()
        while len(ports) < 3:
            ports.add(free_port())
        ec_port, peer_port, udp_port = sorted(ports)
        write_config(home, password, ec_port, peer_port, udp_port)
        log_path = home / "stdout.log"
        try:
            with log_path.open("w") as log:
                for attempt in range(2):
                    process = subprocess.Popen(
                        [str(daemon), "--config-dir", str(home), "--log-stdout"],
                        env=dict(ENV, HOME=str(home)), stdout=log, stderr=subprocess.STDOUT,
                    )
                    processes.append(process)
                    wait_ready(process, ec_port)
                    status = client(command, home, ec_port, password, "status")
                    require(status.returncode == 0 and "Connection established" in status.stdout,
                            f"EC status 失败：{status.stdout}")
                    require("Not connected" in status.stdout, f"离线状态异常：{status.stdout}")
                    if attempt == 0:
                        added = client(command, home, ec_port, password, f"add {LINK}")
                        require(added.returncode == 0, f"添加链接失败：{added.stdout}")
                    downloads = client(command, home, ec_port, password, "show dl")
                    require(downloads.returncode == 0 and FILE_NAME in downloads.stdout
                            and FILE_HASH.lower() in downloads.stdout.lower(),
                            f"任务读取/持久化失败：{downloads.stdout}")
                    if attempt == 0:
                        rejected = client(command, home, ec_port, "wrong-password", "status")
                        require("Authentication failed" in rejected.stdout
                                and "Connection established" not in rejected.stdout,
                                f"错误密码未被拒绝：{rejected.stdout}")
                        print("PASS: EC status / 添加虚构 ed2k / show dl / 拒绝错误密码")
                    stop(process)
                    print(f"PASS: 第 {attempt + 1} 次 SIGTERM 干净退出"
                          + ("，重启任务仍在" if attempt else ""))
            require(list((home / "Incoming").iterdir()) == [], "Incoming 应为空")
            for process in processes:
                require(process.poll() is not None, f"残留 amuled PID {process.pid}")
                try:
                    os.kill(process.pid, 0)
                except ProcessLookupError:
                    continue
                raise AssertionError(f"残留 PID {process.pid}")
            print("PASS: 两次前台进程均已回收，无本测试残留 amuled；临时目录已清理")
        except BaseException:
            print(log_path.read_text(errors="replace"))
            raise
        finally:
            for process in processes:
                if process.poll() is None:
                    try:
                        stop(process)
                    except AssertionError as error:
                        print(f"清理：{error}")


def main():
    root = Path(__file__).resolve().parent.parent
    cache = Path(os.environ.get("MULEE_THIRDPARTY_CACHE", root / "build/thirdparty"))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--amuled", type=Path, default=cache / "bin/amuled")
    parser.add_argument("--amulecmd", type=Path, default=cache / "bin/amulecmd")
    args = parser.parse_args()
    for binary in (args.amuled, args.amulecmd):
        if not binary.is_file():
            parser.error(f"缺少 {binary}；请先运行 scripts/build-amuled.sh --standalone")
    run_test(args.amuled.resolve(), args.amulecmd.resolve())


if __name__ == "__main__":
    main()
