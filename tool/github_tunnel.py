"""Minimal CONNECT tunnel proxy that pins github.com to a reachable IP.

Why: DNS returns 20.205.243.166 for github.com, and that address is not
reachable from this machine (TCP 443 times out), while several other GitHub
addresses answer normally.  TLS stays end to end, so the certificate still
matches github.com; only the TCP destination is rewritten.

Usage:
    python tool/github_tunnel.py [--port 8899] [--ip 140.82.112.3]
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


class Tunnel(socketserver.BaseRequestHandler):
    upstream_ip = "140.82.112.3"

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
        dest = self.upstream_ip if host.lower() in PINNED else None
        if dest is None:
            try:
                dest = socket.gethostbyname(host)
            except OSError:
                client.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
                client.close()
                return
        try:
            upstream = socket.create_connection((dest, port), timeout=20)
        except OSError as exc:
            sys.stderr.write(f"tunnel: {host}:{port} via {dest} failed: {exc}\n")
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
    ap.add_argument("--ip", default="140.82.112.3")
    args = ap.parse_args()
    Tunnel.upstream_ip = args.ip
    with Server(("127.0.0.1", args.port), Tunnel) as srv:
        sys.stderr.write(f"github tunnel on 127.0.0.1:{args.port} pinning github.com -> {args.ip}\n")
        sys.stderr.flush()
        srv.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
