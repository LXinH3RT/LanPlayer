#!/usr/bin/env python3
"""Launch the desktop app, capture its window to a PNG, close it.

Used as evidence that the built runner actually renders the UI.  The capture is
PrintWindow(PW_RENDERFULLCONTENT): fast and usable while the window is behind
another one, at the cost of a black client area for Flutter windows that are not
in the foreground -- that is what capture_screen.py is for.

  python scripts/capture_window.py [-e <lanplayer.exe>] [-o <png>] [-w 7000]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))

import lpscript as lp
import lpwin


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-e", "--exe", default="")
    parser.add_argument("-o", "--out", default="")
    parser.add_argument("-w", "--wait-ms", type=int, default=7000)
    args = parser.parse_args()

    # Defaults hang off the repository this script lives in, not off one
    # machine's directory layout.
    exe = Path(args.exe) if args.exe else lp.ROOT / "build" / "msvc-chain" / "lanplayer.exe"
    out = Path(args.out) if args.out else lp.ROOT / "build" / "msvc-chain" / "window.png"
    if not exe.exists():
        print(f"!! missing exe: {exe}", file=sys.stderr)
        return 2
    lp.ensure_dir(out.parent)

    proc = lpwin.start_app(exe)
    try:
        import time

        time.sleep(args.wait_ms / 1000.0)
        hwnd = lpwin.find_main_window(proc.pid)
        if not hwnd:
            print("no visible window found")
            return 1
        print(f"window: hwnd=0x{hwnd:X} title='{lpwin.window_title(hwnd)}'")
        lpwin.window_grab(hwnd).save_png(out)
        print(f"captured: {out}")
        return 0
    finally:
        lpwin.stop_app(proc)


if __name__ == "__main__":
    raise SystemExit(main())
