#!/usr/bin/env python3
"""发送 mDNS 查询并收集应答，用来判断这个局域网里有没有可发现的 SMB 主机
（决定 lp_source_discover 能不能在这台机器上实测）。

用法：
  python tool/mdns_probe.py                     # 找 _smb._tcp.local
  python tool/mdns_probe.py --service _http._tcp.local
  python tool/mdns_probe.py --all               # 先问服务类型列表，再逐个查

说明：本机 5353 已被别的进程占用（Bonjour / 系统服务），所以这里**不绑 5353**，
而是用临时端口发查询并把 QU（unicast response）位置 1，让应答直接回到本套接字。
"""
import argparse
import socket
import struct
import sys
import time

MDNS_ADDR = "224.0.0.251"
MDNS_PORT = 5353

TYPE_A = 1
TYPE_PTR = 12
TYPE_SRV = 33
TYPE_TXT = 16


def encode_name(name: str) -> bytes:
    out = b""
    for label in name.strip(".").split("."):
        b = label.encode("utf-8")
        out += bytes([len(b)]) + b
    return out + b"\x00"


def build_query(names, qtype: int = TYPE_PTR) -> bytes:
    header = struct.pack("!HHHHHH", 0, 0, len(names), 0, 0, 0)
    body = b""
    for name in names:
        # QU bit (0x8000) in the class field asks responders to answer unicast
        body += encode_name(name) + struct.pack("!HH", qtype, 0x8001)
    return header + body


def read_name(data: bytes, off: int):
    labels = []
    guard = 0
    while True:
        guard += 1
        if guard > 64 or off >= len(data):
            raise ValueError("bad name")
        n = data[off]
        if n == 0:
            off += 1
            break
        if n & 0xC0 == 0xC0:
            ptr = struct.unpack("!H", data[off:off + 2])[0] & 0x3FFF
            sub, _ = read_name(data, ptr)
            labels.append(sub)
            off += 2
            break
        labels.append(data[off + 1:off + 1 + n].decode("utf-8", "replace"))
        off += 1 + n
    return ".".join(x for x in labels if x), off


def parse_response(data: bytes):
    if len(data) < 12:
        return [], []
    _, _flags, qd, an, ns, ar = struct.unpack("!HHHHHH", data[:12])
    off = 12
    for _ in range(qd):
        try:
            _, off = read_name(data, off)
        except Exception:
            return [], []
        off += 4
    records = []
    for _ in range(an + ns + ar):
        try:
            name, off = read_name(data, off)
            rtype, _rclass, _ttl, rdlen = struct.unpack("!HHIH", data[off:off + 10])
            off += 10
            rdata = data[off:off + rdlen]
            off += rdlen
        except Exception:
            break
        records.append((name, rtype, rdata))
    return records[:an + ns], records[an + ns:]


class Prober:
    def __init__(self, local_ip: str):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((local_ip, 0))
        # 出站组播走指定网卡，否则 Windows 可能选到蓝牙那个 169.254 接口
        self.sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF,
                             socket.inet_aton(local_ip))
        self.sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
        self.sock.settimeout(0.4)

    def query(self, names, qtype=TYPE_PTR, wait=1.5):
        pkt = build_query(names, qtype)
        self.sock.sendto(pkt, (MDNS_ADDR, MDNS_PORT))
        answers, additionals = [], []
        deadline = time.time() + wait
        while time.time() < deadline:
            try:
                data, _addr = self.sock.recvfrom(9000)
            except socket.timeout:
                continue
            a, ad = parse_response(data)
            answers += a
            additionals += ad
        return answers, additionals

    def close(self):
        self.sock.close()


def collect(records):
    """把 PTR / SRV / A / TXT 理成 {instance: {...}}。"""
    found = {}
    for name, rtype, rdata in records:
        if rtype == TYPE_PTR:
            try:
                target, _ = read_name(rdata, 0)
            except Exception:
                continue
            found.setdefault(target, {"instance": target})
        elif rtype == TYPE_SRV and len(rdata) >= 6:
            port = struct.unpack("!H", rdata[4:6])[0]
            try:
                target, _ = read_name(rdata, 6)
            except Exception:
                target = "?"
            item = found.setdefault(name, {"instance": name})
            item["srv"] = target
            item["port"] = port
        elif rtype == TYPE_A and len(rdata) == 4:
            item = found.setdefault(name, {"instance": name})
            item["ip"] = ".".join(str(b) for b in rdata)
        elif rtype == TYPE_TXT:
            item = found.setdefault(name, {"instance": name})
            item["txt"] = rdata.decode("utf-8", "replace").strip("\x00").replace("\x00", " ")
    return found


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--service", action="append", default=None)
    ap.add_argument("--all", action="store_true", help="先查服务类型列表再逐个查")
    ap.add_argument("--wait", type=float, default=2.0)
    ap.add_argument("--local-ip", default=None)
    args = ap.parse_args()

    local_ip = args.local_ip
    if not local_ip:
        # 用「连到公网点选中的那张网卡」的地址，避免依赖接口枚举顺序
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect(("192.168.1.1", 9))
            local_ip = probe.getsockname()[0]
        except OSError:
            local_ip = "0.0.0.0"
        finally:
            probe.close()
    print("local-ip = %s\n" % local_ip)

    services = args.service or ["_smb._tcp.local"]
    prober = Prober(local_ip)
    try:
        if args.all:
            a, ad = prober.query(["_services._dns-sd._udp.local"], TYPE_PTR, args.wait)
            types = sorted({t["instance"] for t in collect(a + ad).values()
                            if t["instance"].endswith(".local") and not t["instance"].startswith("_services")})
            print("=== 本网段广播的服务类型 (%d) ===" % len(types))
            for t in types:
                print("  " + t)
            print()
            if types:
                services = types
            else:
                print("（没有主机应答服务类型枚举，继续直接查 _smb._tcp.local）\n")

        total = 0
        for svc in services:
            a, ad = prober.query([svc], TYPE_PTR, args.wait)
            found = collect(a + ad)
            if svc != "_services._dns-sd._udp.local":
                print("=== %s : %d 个实例 ===" % (svc, len(found)))
                for inst, info in sorted(found.items()):
                    print("  %-52s ip=%-15s port=%-5s txt=%s"
                          % (inst, info.get("ip", "-"), info.get("port", "-"),
                             (info.get("txt") or "-")[:40]))
                total += len(found)
        print("\n合计发现 %d 个实例。" % total)
        return 0 if total else 1
    finally:
        prober.close()


if __name__ == "__main__":
    sys.exit(main())
