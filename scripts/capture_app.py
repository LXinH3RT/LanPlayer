#!/usr/bin/env python3
"""Launch the desktop app with its output redirected to files, capture, close.

Differs from capture_window.py, which discards output: this one keeps the Dart
``print`` output so a browse/open failure is visible in the evidence.  The
capture is still PrintWindow, so it shows the frame -- use capture_screen.py
when the *content* matters.

  python scripts/capture_app.py -e <lanplayer.exe> -o <png> [-w 12000]
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
    parser.add_argument("-e", "--exe", required=True)
    parser.add_argument("-o", "--out", required=True)
    parser.add_argument("--log-dir", default="")
    parser.add_argument("-w", "--wait-ms", type=int, default=12000)
    args = parser.parse_args()

    exe = Path(args.exe)
    out = Path(args.out)
    if not exe.exists():
        print(f"!! missing exe: {exe}", file=sys.stderr)
        return 2
    log_dir = Path(args.log_dir) if args.log_dir else out.parent
    lp.ensure_dir(log_dir)

    stdout_path = log_dir / "app-stdout.log"
    stderr_path = log_dir / "app-stderr.log"
    stdin_path = log_dir / "app-stdin.txt"
    stdin_path.write_text("", encoding="ascii")

    rc = 0
    with open(stdout_path, "w", encoding="utf-8") as out_file, \
            open(stderr_path, "w", encoding="utf-8") as err_file, \
            open(stdin_path, "r", encoding="ascii") as in_file:
        proc = lpwin.start_app(exe, stdout=out_file, stderr=err_file, stdin=in_file)
        try:
            time.sleep(args.wait_ms / 1000.0)
            hwnd = lpwin.find_main_window(proc.pid)
            if not hwnd:
                print("no visible window found")
                rc = 1
            else:
                print(f"window: hwnd=0x{hwnd:X} title='{lpwin.window_title(hwnd)}'")
                lpwin.window_grab(hwnd).save_png(out)
                print(f"captured: {out}")
        finally:
            lpwin.stop_app(proc)

    time.sleep(0.4)
    print("--- stdout ---")
    print(stdout_path.read_text(encoding="utf-8", errors="replace"))
    print("--- stderr ---")
    print(stderr_path.read_text(encoding="utf-8", errors="replace"))
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
