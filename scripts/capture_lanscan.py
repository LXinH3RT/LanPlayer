#!/usr/bin/env python3
"""Launch the app on the add-server page with auto scan, grab one screen shot.

Used to verify LAN scanning in the real program rather than in a test: the app
prints what mDNS discovered, and the screenshot shows the dialog holding it.

  python scripts/capture_lanscan.py [-e <exe>] [-o <png>] [-w 9000]
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))

import lpscript as lp
import lpwin


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-e", "--exe", default="")
    parser.add_argument("--state-dir", default="")
    parser.add_argument("-o", "--out", default="")
    parser.add_argument("--log-dir", default="")
    parser.add_argument("-w", "--wait-ms", type=int, default=9000)
    args = parser.parse_args()

    exe = Path(args.exe) if args.exe else (
        lp.ROOT / "app" / "build" / "windows" / "x64" / "runner" / "Release" / "lanplayer.exe")
    state_dir = Path(args.state_dir) if args.state_dir else lp.ROOT / "build" / "state-lanscan"
    out = Path(args.out) if args.out else lp.ROOT / "build" / "shots" / "lan-scan.png"
    log_dir = Path(args.log_dir) if args.log_dir else lp.ROOT / "build" / "shots" / "lan-log"
    for path in (state_dir, log_dir, out.parent):
        lp.ensure_dir(path)
    if not exe.exists():
        print(f"!! missing exe: {exe}", file=sys.stderr)
        return 2

    # A previous run's window would keep holding the state directory.
    for pid in lpwin.find_process_by_name("lanplayer"):
        lp.run(["taskkill", "/F", "/PID", str(pid)], check=False, show=False)
    time.sleep(0.4)

    stdout_path = log_dir / "app-stdout.log"
    stderr_path = log_dir / "app-stderr.log"
    for path in (stdout_path, stderr_path):
        if path.exists():
            path.unlink()

    env = lpwin.app_env(state_dir=state_dir, ui="add-server", autoscan=True)
    with open(stdout_path, "w", encoding="utf-8") as out_file, \
            open(stderr_path, "w", encoding="utf-8") as err_file:
        proc = lpwin.start_app(exe, env=env, stdout=out_file, stderr=err_file)
        try:
            time.sleep(1.5)
            hwnd = lpwin.wait_for_window(proc.pid, timeout=10.0, require_title=False)
            if not hwnd:
                print("error: no window")
                return 2
            lpwin.raise_window(hwnd, settle=0.3)
            time.sleep(args.wait_ms / 1000.0)
            left, top, width, height = lpwin.window_rect(hwnd)
            print(f"window: hwnd=0x{hwnd:X} rect={width}x{height} at {left},{top}")
            screen = lpwin.screen_grab()
            screen.crop(left, top, width, height).save_png(out)
            print(f"captured: {out}")
        finally:
            lpwin.stop_app(proc)
    time.sleep(0.4)

    print("--- stdout ---")
    print(stdout_path.read_text(encoding="utf-8", errors="replace"))
    print("--- stderr (tail) ---")
    tail = stderr_path.read_text(encoding="utf-8", errors="replace").splitlines()[-6:]
    print("\n".join(tail))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
