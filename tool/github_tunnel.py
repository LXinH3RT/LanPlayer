"""Minimal CONNECT tunnel proxy that pins github.com to a reachable IP.

Why: DNS returns 20.205.243.166 for github.com, and that address is not
reachable from this machine (TCP 443 times out), while several other GitHub
addresses answer normally.  TLS stays end to end, so the certificate still
matches github.com; only the TCP destination is rewritten.

Usage:
    python tool/github_tunnel.py [--port 8899] [--ip 140.82.112.3 ...]
then point git at it:
    git config --local http.proxy http://127.0.0.1:8899
"""

from __future__ import annotations

import argparse
import socket
import socketserver
import sys
import threading

PINNED = {"github.com", "www.github.com"}

# github.com is served from several anycast addresses. On this network the one
# DNS hands back is frequently black-holed while others answer, so try them in
# order and keep whichever connects.
DEFAULT_IPS = (
    "140.82.112.3",
    "140.82.113.3",
    "20.27.177.113",
    "4.237.22.38",
    "20.205.243.166",
)


class Tunnel(socketserver.BaseRequestHandler):
    upstream_ips = DEFAULT_IPS

    def _connect_pinned(self, host: str, port: int):
        """Return (socket, ip) for the first candidate that accepts a connection."""
        last = None
        for ip in self.upstream_ips:
            try:
                return socket.create_connection((ip, port), timeout=8), ip
            except OSError as exc:
                last = exc
                sys.stderr.write(f"tunnel: {host} via {ip} failed: {exc}\n")
                sys.stderr.flush()
        if last is not None:
            raise last
        raise OSError("no candidate address")

    def handle(self) -> None:
        client = self.request
        client.settimeout(30)
        try:
            head = self._read_head(client)
        except OSError:
            return
        if not head:
            return
        try:
            request_line = head.split(b"\r\n", 1)[0].decode("latin-1")
            method, target, _version = request_line.split(" ")
        except ValueError:
            client.close()
            return
        if method.upper() != "CONNECT":
            client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
            client.close()
            return
        host, _, port_text = target.rpartition(":")
        port = int(port_text or "443")
        pinned = host.lower() in PINNED
        try:
            if pinned:
                upstream, dest = self._connect_pinned(host, port)
            else:
                dest = socket.gethostbyname(host)
                upstream = socket.create_connection((dest, port), timeout=20)
        except OSError as exc:
            sys.stderr.write(f"tunnel: {host}:{port} failed: {exc}\n")
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            client.close()
            return
        sys.stderr.write(f"tunnel: {host}:{port} -> {dest}\n")
        client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        upstream.settimeout(None)
        client.settimeout(None)
        pump = threading.Thread(target=self._pipe, args=(client, upstream), daemon=True)
        pump.start()
        self._pipe(upstream, client)
        pump.join(timeout=5)
        try:
            upstream.close()
        except OSError:
            pass

    @staticmethod
    def _read_head(sock: socket.socket) -> bytes:
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = sock.recv(4096)
            if not chunk:
                return b""
            buf += chunk
            if len(buf) > 65536:
                return b""
        return buf

    @staticmethod
    def _pipe(src: socket.socket, dst: socket.socket) -> None:
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass
        finally:
            try:
                dst.shutdown(socket.SHUT_WR)
            except OSError:
                pass


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8899)
    ap.add_argument("--ip", action="append", default=None,
                    help="candidate address for pinned hosts (repeatable; defaults to a built-in list)")
    args = ap.parse_args()
    if args.ip:
        Tunnel.upstream_ips = tuple(args.ip)
    with Server(("127.0.0.1", args.port), Tunnel) as srv:
        sys.stderr.write(
            f"github tunnel on 127.0.0.1:{args.port} pinning github.com -> {', '.join(Tunnel.upstream_ips)}\n"
        )
        sys.stderr.flush()
        srv.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
