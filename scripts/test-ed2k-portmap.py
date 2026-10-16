#!/usr/bin/env python3
"""隔离实网验证，不使用已安装 App 或用户数据。

用法：
  python3 scripts/test-ed2k-portmap.py --diagnose-only
    运行 build/dd-workers 中 App 的只读诊断入口；不启动引擎、不创建映射。
  python3 scripts/test-ed2k-portmap.py --mapping-only
    在家中执行：临时 amuled + mulee-torrentd 申请映射，用路由器查询核实建立及撤销。
    即使路由器 WAN 不是公网地址也执行，不以服务器/Kad 可连入作为通过条件。
  python3 scripts/test-ed2k-portmap.py
    原有完整对照：映射前后比较服务器/Kad 连入状态，需要公网 IPv4。
"""

import argparse
import hashlib
import ipaddress
import json
from pathlib import Path
import runpy
import secrets
import select
import socket
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zlib


ROOT = Path(__file__).resolve().parents[1]
MAX_XML_BYTES = 65536
MAX_SSDP_BYTES = 8192


class RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}), RejectRedirects())


def read_xml(response):
    data = response.read(MAX_XML_BYTES + 1)
    assert len(data) <= MAX_XML_BYTES, "路由器 XML 响应过大"
    text = data.decode("utf-8")
    assert "\0" not in text and "<!DOCTYPE" not in text.upper() and "<!ENTITY" not in text.upper(), "拒绝 XML 实体或文档声明"
    tree = ET.fromstring(text)

    def check(node, depth=0):
        assert depth < 32, "XML 嵌套过深"
        return 1 + sum(check(child, depth + 1) for child in node)

    assert check(tree) <= 1024, "XML 节点过多"
    return tree


def number(name, value, width=1):
    return name, {1: 2, 2: 3, 4: 4, 8: 5}[width], value.to_bytes(width, "big"), []


def string(name, value):
    return name, 6, value.encode() + b"\0", []


def encode_tags(tags):
    output = struct.pack("!H", len(tags))
    for name, kind, data, children in tags:
        nested = encode_tags(children) if children else b""
        logical = sum(tag_length(child) for child in children)
        output += struct.pack("!HBI", name * 2 + bool(children), kind, len(data) + logical)
        output += nested + data
    return output


def tag_length(tag):
    return 7 + len(tag[2]) + (2 if tag[3] else 0) + sum(tag_length(c) for c in tag[3])


class EC:
    def __init__(self, port, password):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=10)
        opcode, tags = self.request(0x02, [string(0x0100, "Mulee-Portmap-Test"),
                                           string(0x0101, "0.1"), number(2, 0x0204, 2)])
        assert opcode == 0x4F, (opcode, tags)
        salt = int.from_bytes(tags[0x000B][1], "big")
        digest = hashlib.md5(password.encode()).hexdigest()
        salt_digest = hashlib.md5(f"{salt:X}".encode()).hexdigest()
        response = hashlib.md5((digest + salt_digest).encode()).digest()
        opcode, _ = self.request(0x50, [(1, 9, response, [])])
        assert opcode == 4, f"EC authentication failed: {opcode}"

    def read(self, count):
        data = b""
        while len(data) < count:
            part = self.socket.recv(count - len(data))
            if not part:
                raise EOFError("EC socket closed")
            data += part
        return data

    def request(self, opcode, tags=()):
        body = bytes([opcode]) + encode_tags(tags)
        self.socket.sendall(struct.pack("!II", 0x20, len(body)) + body)
        flags, length = struct.unpack("!II", self.read(8))
        assert length <= 32 * 1024 * 1024 and flags & ~0x21 == 0
        data = self.read(length)
        if flags & 1:
            data = zlib.decompress(data)
        offset = 1

        def decode_tags():
            nonlocal offset
            count = int.from_bytes(data[offset:offset + 2], "big")
            offset += 2
            result = {}
            logical = 0
            for _ in range(count):
                name, kind, size = struct.unpack_from("!HBI", data, offset)
                offset += 7
                children, child_length = decode_tags() if name & 1 else ({}, 0)
                size -= child_length
                assert size >= 0 and offset + size <= len(data)
                value = data[offset:offset + size]
                offset += size
                result[name >> 1] = kind, value, children
                logical += 7 + size + child_length + (2 if name & 1 else 0)
            return result, logical

        decoded, _ = decode_tags()
        assert offset == len(data)
        if data[0] in (3, 5):
            raise RuntimeError(f"EC rejected opcode {opcode}: {decoded}")
        return data[0], decoded

    def status(self):
        _, tags = self.request(0x0B, [number(4, 2)])
        tag = tags[5]
        flags = int.from_bytes(tag[1], "big")
        children = tag[2]
        ed2k_id = int.from_bytes(children.get(6, (0, b"", {}))[1], "big")
        client_id = int.from_bytes(children.get(10, (0, b"", {}))[1], "big")
        public_ip = socket.inet_ntoa(client_id.to_bytes(4, "little")) if client_id >= 0x1000000 else None
        return {"server": "可连入" if flags & 1 and ed2k_id >= 0x1000000
                else "无法连入" if flags & 1 else "未连接",
                "kad": "可连入" if flags & 4 and not flags & 8
                else "无法连入" if flags & 4 else "未连接",
                "client_id": client_id, "ed2k_id": ed2k_id, "reported_ip": public_ip}

    def ports(self):
        _, tags = self.request(0x3F, [number(0x1000, 4, 4), number(4, 2)])
        prefs = tags[0x1300][2]
        tcp = int.from_bytes(prefs[0x1306][1], "big")
        udp = int.from_bytes(prefs[0x1307][1], "big")
        disabled = 0x1308 in prefs
        assert 0 < tcp <= 65532 and 0 < udp <= 65535
        return {"tcp": [tcp], "udp": sorted({tcp + 3} | ({udp} if not disabled else set()))}

    def reconnect(self):
        self.request(0x2E)
        self.request(0x49)
        self.request(0x2F)
        self.request(0x48)

    def close(self):
        self.socket.close()


class Gateway:
    def __init__(self):
        locations = set()
        self.networks = {}
        self.local_addresses = set()
        routes = subprocess.check_output(["/usr/sbin/netstat", "-rn", "-f", "inet"], text=True)
        physical = {(fields[3], fields[1]) for line in routes.splitlines()
                    if len(fields := line.split()) >= 4 and fields[0] == "default"
                    and not fields[3].startswith(("utun", "lo"))}
        assert physical, "未发现物理网络默认网关"
        for interface, gateway in sorted(physical):
            try:
                address = subprocess.check_output(["/usr/sbin/ipconfig", "getifaddr", interface], text=True).strip()
                config = subprocess.check_output(["/sbin/ifconfig", interface], text=True)
                mask = next(line.split("netmask ")[1].split()[0] for line in config.splitlines()
                            if line.strip().startswith(f"inet {address} ") and "netmask " in line)
                mask = str(ipaddress.IPv4Address(int(mask, 16)))
                network = ipaddress.ip_network(f"{address}/{mask}", strict=False)
                router = ipaddress.IPv4Address(gateway)
                if router not in network or router == ipaddress.IPv4Address(address):
                    continue
                self.networks[gateway] = network
                self.local_addresses.add(address)
            except (ValueError, StopIteration, subprocess.SubprocessError):
                continue
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.bind((address, 0))
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(address))
                for target in ("urn:schemas-upnp-org:device:InternetGatewayDevice:1",
                               "urn:schemas-upnp-org:device:InternetGatewayDevice:2", "upnp:rootdevice"):
                    query = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"
                             f'ST: {target}\r\nMAN: "ssdp:discover"\r\nMX: 1\r\n\r\n')
                    sock.sendto(query.encode(), ("239.255.255.250", 1900))
                deadline = time.monotonic() + 1.2
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([sock], [], [], 0.05)
                    if not ready:
                        continue
                    data, sender = sock.recvfrom(MAX_SSDP_BYTES + 1)
                    if len(data) > MAX_SSDP_BYTES or sender[0] != gateway:
                        continue
                    lines = data.decode(errors="replace").split("\r\n")
                    if lines[0] != "HTTP/1.1 200 OK":
                        continue
                    headers = {}
                    for line in lines[1:]:
                        if not line:
                            break
                        key, separator, value = line.partition(":")
                        if not separator or key.lower() in headers:
                            headers = {}
                            break
                        headers[key.lower()] = value.strip()
                    location = headers.get("location", "")
                    if self.local_url(location):
                        locations.add(location)
        self.services = []
        for location in sorted(locations)[:2]:
            try:
                with HTTP.open(location, timeout=1) as response:
                    tree = read_xml(response)
                ns = {"d": "urn:schemas-upnp-org:device-1-0"}
                devices = [node for node in tree.findall(".//d:device", ns)
                           if node.findtext("d:deviceType", namespaces=ns) in (
                               "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
                               "urn:schemas-upnp-org:device:InternetGatewayDevice:2")]
                if len(devices) != 1:
                    continue
                base = tree.findtext("d:URLBase", default=location, namespaces=ns)
                if not self.local_url(base):
                    continue
                for service in devices[0].findall(".//d:service", ns):
                    kind = service.findtext("d:serviceType", default="", namespaces=ns)
                    path = service.findtext("d:controlURL", default="", namespaces=ns)
                    url = urllib.parse.urljoin(base, path)
                    if kind in {f"urn:schemas-upnp-org:service:{name}:{version}"
                                for name in ("WANIPConnection", "WANPPPConnection") for version in (1, 2)} \
                            and self.local_url(url):
                        self.services.append((url, kind))
            except (OSError, ValueError, AssertionError, ET.ParseError):
                continue
        assert self.services, "未确认：无法发现路由器服务"

    def local_url(self, value):
        try:
            url = urllib.parse.urlsplit(value)
            address = ipaddress.IPv4Address(url.hostname)
            network = self.networks.get(url.hostname)
            private = any(address in ipaddress.ip_network(cidr)
                          for cidr in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))
            return (url.scheme == "http" and url.username is None and url.password is None
                    and not url.fragment and 0 < (url.port or 80) <= 65535 and private
                    and network is not None and address in network
                    and address not in (network.network_address, network.broadcast_address))
        except (TypeError, ValueError):
            return False

    def call(self, service, action, fields=()):
        url, kind = service
        values = "".join(f"<{name}>{value}</{name}>" for name, value in fields)
        body = ('<?xml version="1.0"?>'
                '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
                's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
                f'<s:Body><u:{action} xmlns:u="{kind}">{values}</u:{action}></s:Body></s:Envelope>')
        request = urllib.request.Request(url, data=body.encode(), headers={
            "Content-Type": 'text/xml; charset="utf-8"', "SOAPAction": f'"{kind}#{action}"',
        })
        try:
            with HTTP.open(request, timeout=10) as response:
                tree = read_xml(response)
        except urllib.error.HTTPError as error:
            tree = read_xml(error)
        return {node.tag.rsplit("}", 1)[-1]: node.text for node in tree.iter()}

    def external_ip(self, require_public=True):
        addresses = {self.call(service, "GetExternalIPAddress").get("NewExternalIPAddress")
                     for service in self.services}
        addresses.discard(None)
        assert len(addresses) == 1, "无法唯一确认路由器公网出口"
        address = addresses.pop()
        assert isinstance(ipaddress.ip_address(address), ipaddress.IPv4Address), "路由器返回的不是 IPv4 地址"
        if require_public:
            assert ipaddress.ip_address(address).is_global, "路由器 WAN 地址不是公网地址"
        return address

    def mapping(self, protocol, port):
        found = []
        for service in self.services:
            fields = self.call(service, "GetSpecificPortMappingEntry", (
                ("NewRemoteHost", ""), ("NewExternalPort", port), ("NewProtocol", protocol.upper()),
            ))
            if fields.get("errorCode") == "714":
                continue
            assert "NewInternalPort" in fields, f"无法读取路由器映射：{fields.get('errorCode')}"
            found.append(fields)
        return found


def wait_status(ec, seconds):
    deadline = time.monotonic() + seconds
    status = None
    last_print = 0
    while time.monotonic() < deadline:
        status = ec.status()
        if time.monotonic() - last_print > 20:
            print(json.dumps(status, ensure_ascii=False), flush=True)
            last_print = time.monotonic()
        if status["server"] == status["kad"] == "可连入":
            return status
        time.sleep(2)
    return status


def run(args):
    (ROOT / "build/dd-workers").mkdir(parents=True, exist_ok=True)
    support = runpy.run_path(str(ROOT / "scripts/test-torrentd.py"))
    amule = runpy.run_path(str(ROOT / "scripts/test-amuled.py"))
    gateway = None
    discovery_error = None
    wan = None
    try:
        gateway = Gateway()
        wan = gateway.external_ip(require_public=not args.mapping_only)
        print("路由器 WAN 地址已读取", flush=True)
    except (AssertionError, OSError) as error:
        if args.mapping_only:
            raise
        discovery_error = str(error)
        print(f"路由器核验暂不可用：{discovery_error}；仅执行未映射对照", flush=True)
    daemon = ec = process = None
    checked_ports = set()
    with tempfile.TemporaryDirectory(prefix="ed2k-portmap-", dir=ROOT / "build/dd-workers") as directory:
        root = Path(directory)
        reservations = []
        try:
            home = root / "amule"
            home.mkdir(mode=0o700)
            # 占住候选端口，确保本次独立实例不复用任何已运行引擎的监听端口。
            while True:
                tcp = amule["free_port"]()
                if tcp > 65000:
                    continue
                try:
                    for kind, port in ((socket.SOCK_STREAM, tcp), (socket.SOCK_DGRAM, tcp + 3),
                                       (socket.SOCK_DGRAM, tcp + 10)):
                        sock = socket.socket(socket.AF_INET, kind)
                        reservations.append(sock)
                        sock.bind(("0.0.0.0", port))
                    break
                except OSError:
                    for sock in reservations:
                        sock.close()
                    reservations.clear()
            ec_port = amule["free_port"]()
            password = secrets.token_hex(24)
            amule["write_config"](home, password, ec_port, tcp, tcp + 10)
            config = home / "amule.conf"
            text = config.read_text().replace("\nAddress=127.0.0.1\n", "\nAddress=\n")
            keys = ("UDPEnable",) if args.mapping_only else ("UDPEnable", "Autoconnect", "Reconnect", "ConnectToED2K", "ConnectToKad")
            for key in keys:
                text = text.replace(f"{key}=0", f"{key}=1")
            if not args.mapping_only:
                text = text.replace("Serverlist=0", "Serverlist=0\nEd2kServersUrl=https://upd.emule-security.org/server.met\nKadNodesUrl=https://upd.emule-security.org/nodes.dat")
            config.write_text(text)
            for sock in reservations:
                sock.close()
            with (root / "amuled.log").open("w") as output:
                process = subprocess.Popen([str(args.amuled), "-c", str(home)], stdout=output,
                                           stderr=subprocess.STDOUT, env=dict(amule["ENV"], HOME=str(home)))
            amule["wait_ready"](process, ec_port)
            ec = EC(ec_port, password)
            ports = ec.ports()
            print("EC 实际端口：" + json.dumps(ports), flush=True)
            # 确认 EC 数据与此实例实际持有的监听 socket 一致。
            # amuled 的部分 UDP 端口在 EC 就绪后才绑定，最多等 15 秒。
            deadline = time.monotonic() + 15
            while True:
                sockets = subprocess.check_output(["/usr/sbin/lsof", "-nP", "-a", "-p", str(process.pid),
                                                    "-i"], text=True)
                missing = [(protocol, port) for protocol, values in ports.items() for port in values
                           if not any(protocol.upper() in line and f":{port}" in line for line in sockets.splitlines())]
                if not missing or time.monotonic() > deadline:
                    break
                time.sleep(1)
            # 服务器 UDP 端口（TCP+3）由 amuled 在连上服务器后才打开；决定外部能否连入的是 TCP 和 Kad UDP。
            server_udp = {("udp", port + 3) for port in ports.get("tcp", [])}
            pending = [item for item in missing if item in server_udp]
            if pending:
                print(f"提示：服务器 UDP 端口尚未打开，仍会映射：{pending}", flush=True)
            missing = [item for item in missing if item not in server_udp]
            assert not missing, f"EC 报告的端口没有监听：{missing}\n{sockets}"
            for protocol, values in ports.items():
                for port in values:
                    if gateway is not None and discovery_error is None:
                        assert not gateway.mapping(protocol, port), "候选端口已有路由器映射，拒绝覆盖"
                        checked_ports.add((protocol, port))
            before = {"reported_ip": None}
            if not args.mapping_only:
                print("不映射对照：", flush=True)
                before = wait_status(ec, args.baseline_seconds)
                print("映射前：" + json.dumps(before, ensure_ascii=False), flush=True)
            if discovery_error is not None:
                raise AssertionError(discovery_error + "；未创建测试映射，出口直连与映射后状态未验证")
            if before["reported_ip"] is not None and before["reported_ip"] != wan:
                raise AssertionError("amuled 出口与宽带出口不一致；不改变代理规则，停止验证")
            daemon = support["Daemon"](args.torrentd, root / "torrent")
            bt_port = daemon.configure(root / "downloads")
            assert not gateway.mapping("tcp", bt_port) and not gateway.mapping("udp", bt_port), "BT 候选端口已有映射"
            checked_ports.update({("tcp", bt_port), ("udp", bt_port)})
            daemon.configure(root / "downloads", port=bt_port, port_mapping=True)
            daemon.request("set_extra_port_mappings", ports)
            deadline = time.monotonic() + args.mapping_seconds
            mapped = None
            while time.monotonic() < deadline:
                mapped = daemon.request("session_status")["extra_port_mappings"]
                if len(mapped) == sum(map(len, ports.values())) and all(
                    any(result["succeeded"] and result["external_port"] == entry["local_port"]
                        for result in entry["results"]) for entry in mapped
                ):
                    break
                time.sleep(1)
            else:
                raise AssertionError("路由器未确认全部映射：" + json.dumps(mapped, ensure_ascii=False))
            for event in daemon.events:
                if event.get("scope") == "extra" and event.get("event") in ("portmap", "portmap_error"):
                    print("映射 alert：" + json.dumps(event, ensure_ascii=False), flush=True)
            for entry in mapped:
                for result in entry["results"]:
                    if result["succeeded"]:
                        checked_ports.add((entry["protocol"], result["external_port"]))
            # 引擎的成功 alert 不能代替路由器上实际存在映射的证据。
            for protocol, values in ports.items():
                for port in values:
                    entries = gateway.mapping(protocol, port)
                    assert entries and all(int(entry["NewInternalPort"]) == port
                                           and entry.get("NewInternalClient") in gateway.local_addresses
                                           and entry.get("NewEnabled") == "1" for entry in entries), "路由器映射内容不匹配"
            print("PASS 路由器查询已核实全部电驴端口映射建立", flush=True)
            if args.mapping_only:
                daemon.request("set_extra_port_mappings", {"tcp": [], "udp": []})
                deadline = time.monotonic() + 30
                remaining = True
                while remaining and time.monotonic() < deadline:
                    remaining = any(gateway.mapping(protocol, port)
                                    for protocol, values in ports.items() for port in values)
                    if remaining:
                        time.sleep(1)
                assert not remaining, "撤销后电驴映射仍存在"
                print("PASS 撤销后路由器查询已核实电驴映射删除", flush=True)
            else:
                ec.reconnect()
                print("映射后重新连接：", flush=True)
                after = wait_status(ec, args.after_seconds)
                print("映射后：" + json.dumps(after, ensure_ascii=False), flush=True)
                assert after["reported_ip"] == wan, "无法确认 amuled 直连宽带出口；不改变代理规则"
                assert after["server"] == after["kad"] == "可连入", "映射已建立，但服务器/Kad 尚未同时证实可连入"
                print("PASS 映射成功、服务器与 Kad 可连入、amuled 出口等于路由器公网出口", flush=True)
        finally:
            for sock in reservations:
                sock.close()
            if ec is not None:
                ec.close()
            try:
                if daemon is not None:
                    # Include rewritten external ports even when validation failed before success.
                    results = list(daemon.events)
                    if daemon.process.poll() is None:
                        try:
                            snapshot = daemon.request("session_status")
                            results.extend(snapshot["port_mappings"])
                            for entry in snapshot["extra_port_mappings"]:
                                results.extend(entry["results"])
                        except (AssertionError, OSError):
                            pass
                    for result in results:
                        if result.get("succeeded") and result.get("external_port", 0) > 0 \
                                and result.get("protocol") in ("tcp", "udp"):
                            checked_ports.add((result["protocol"], result["external_port"]))
                    daemon.close("shutdown")
            finally:
                cleanup_errors = []
                for child in support["PROCESSES"]:
                    if child.poll() is None:
                        if child.stdin and not child.stdin.closed:
                            child.stdin.close()
                        try:
                            child.wait(timeout=15)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait(timeout=10)
                            cleanup_errors.append("BT 测试进程未正常退出，已强制回收")
                    for stream in (child.stdin, child.stdout, child.stderr):
                        if stream and not stream.closed:
                            stream.close()
                if process is not None:
                    try:
                        amule["stop"](process)
                    except (AssertionError, subprocess.SubprocessError) as error:
                        cleanup_errors.append(str(error))
                deadline = time.monotonic() + 30
                remaining = list(checked_ports)
                while remaining and time.monotonic() < deadline:
                    remaining = [(proto, port) for proto, port in checked_ports if gateway.mapping(proto, port)]
                    if remaining:
                        time.sleep(1)
                assert not remaining, f"退出后路由器仍有测试映射：{remaining}"
                assert not cleanup_errors, "; ".join(cleanup_errors)
                if checked_ports:
                    print("PASS 路由器上无测试端口的残留映射，测试进程已退出", flush=True)
                else:
                    print("清理完成：未创建测试映射，测试进程已退出", flush=True)
    assert not root.exists()
    print("PASS 临时目录已清理", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--diagnose-only", action="store_true")
    modes.add_argument("--mapping-only", action="store_true")
    parser.add_argument("--diagnostics-app", type=Path,
                        default=ROOT / "build/dd-workers/Build/Products/Debug/Mulee.app/Contents/MacOS/Mulee")
    parser.add_argument("--amuled", type=Path, default=ROOT / "build/thirdparty/bin/amuled")
    parser.add_argument("--torrentd", type=Path, default=ROOT / "build/thirdparty/bin/mulee-torrentd")
    parser.add_argument("--baseline-seconds", type=int, default=90)
    parser.add_argument("--mapping-seconds", type=int, default=120)
    parser.add_argument("--after-seconds", type=int, default=240)
    args = parser.parse_args()
    if args.diagnose_only:
        # 与设置页使用完全相同的 Swift 采集链路；入口在创建 App 和存储之前返回。
        result = subprocess.run([str(args.diagnostics_app), "--diagnose-network-only"],
                                check=True, text=True, capture_output=True, timeout=20)
        conclusion = result.stdout.strip()
        assert conclusion in ("未确认", "运营商没有分配公网 IPv4", "正常"), "诊断入口返回了未知结果"
        print(conclusion, flush=True)
        return
    existing = {path for path in (ROOT / "build/dd-workers").glob("ed2k-portmap-*") if path.is_dir()}
    try:
        run(args)
    finally:
        assert {path for path in (ROOT / "build/dd-workers").glob("ed2k-portmap-*") if path.is_dir()} == existing, "测试临时目录未清理"
        print("临时目录清理已确认", flush=True)


if __name__ == "__main__":
    main()
