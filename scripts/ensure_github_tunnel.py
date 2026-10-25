#!/usr/bin/env python3
"""Make sure the local GitHub CONNECT tunnel is listening.

Why this exists: on this machine DNS resolves github.com to one address that is
frequently unreachable (TCP 443 times out) while other GitHub addresses answer
normally.  ``tool/github_tunnel.py`` listens on 127.0.0.1 and rewrites only the
TCP destination, so TLS stays end to end and the certificate still matches
github.com.  git only needs ``http.proxy`` pointing at it.

    python scripts/ensure_github_tunnel.py
    python scripts/ensure_github_tunnel.py --port 8899 --ip 140.82.112.3 --timeout 20

Exit codes: 0 = tunnel is listening, 1 = could not start it.
"""
from __future__ import annotations

import argparse
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402


def port_open(port: int, timeout: float = 0.4) -> bool:
    with socket.socket() as sock:
        sock.settimeout(timeout)
        try:
            sock.connect(("127.0.0.1", port))
            return True
        except OSError:
            return False


def ensure(port: int, ip: str, timeout: int) -> int:
    if port_open(port):
        lp.note(f"tunnel: already listening on 127.0.0.1:{port}")
        return 0

    script = lp.ROOT / "tool" / "github_tunnel.py"
    if not script.exists():
        lp.warn(f"tunnel: {script} is missing")
        return 1

    log_dir = lp.ensure_dir(lp.TOOLS / "tmp")
    out_log = open(log_dir / "github-tunnel.log", "w", encoding="utf-8")
    err_log = open(log_dir / "github-tunnel.err.log", "w", encoding="utf-8")
    try:
        proc = lp.background(
            [lp.find_python(), script, "--port", port, "--ip", ip],
            stdout=out_log, stderr=err_log,
        )
    finally:
        out_log.close()
        err_log.close()

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        time.sleep(0.25)
        if port_open(port):
            lp.note(f"tunnel: started on 127.0.0.1:{port} (pid {proc.pid}, github.com -> {ip})")
            return 0
        if proc.poll() is not None:
            lp.warn(f"tunnel: python exited with code {proc.returncode}")
            tail = (log_dir / "github-tunnel.err.log").read_text(
                encoding="utf-8", errors="replace").splitlines()[-5:]
            for line in tail:
                lp.warn(f"  {line}")
            return 1

    lp.kill_tree(proc)
    lp.warn(f"tunnel: did not come up within {timeout}s")
    return 1


def main() -> None:
    parser = argparse.ArgumentParser(description="Start the local GitHub tunnel if needed.")
    parser.add_argument("--port", type=int, default=8899)
    parser.add_argument("--ip", default="140.82.112.3")
    parser.add_argument("--timeout", type=int, default=20)
    args = parser.parse_args()
    sys.exit(ensure(args.port, args.ip, args.timeout))


if __name__ == "__main__":
    main()
