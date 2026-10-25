#!/usr/bin/env python3
"""Click once at a client-area coordinate of a running window.

Why a real mouse event: Flutter samples hover and tap from the actual Win32
cursor position, so PostMessage(WM_LBUTTONDOWN) never turns into a tap. The
cursor has to genuinely move and the button has to genuinely go down.

  python scripts/click_window.py -x 1184 -y 670 [-p lanplayer] [--delay 800]
                                 [--wait-ms 3000] [--double]
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))

import lpwin


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-p", "--process-name", default="lanplayer")
    parser.add_argument("-x", "--x", type=int, required=True)
    parser.add_argument("-y", "--y", type=int, required=True)
    parser.add_argument("--delay", type=int, default=800)
    parser.add_argument("--wait-ms", type=int, default=0)
    parser.add_argument("--double", action="store_true")
    args = parser.parse_args()

    lpwin.dpi_aware()

    pids = [pid for pid in lpwin.find_process_by_name(args.process_name)
            if lpwin.find_main_window(pid) != 0]
    if not pids:
        print(f"error: no {args.process_name} process with a window", file=sys.stderr)
        return 2
    hwnd = lpwin.find_main_window(pids[0])
    print(f"window: hwnd=0x{hwnd:X} title='{lpwin.window_title(hwnd)}'")

    lpwin.raise_window(hwnd, settle=0.3)
    view = lpwin.find_view(hwnd)
    origin_x, origin_y = lpwin.client_origin(view)
    print(f"view: hwnd=0x{view:X} at {origin_x},{origin_y}")

    if args.delay > 0:
        time.sleep(args.delay / 1000.0)

    target_x = origin_x + args.x
    target_y = origin_y + args.y
    # Nudge first: setting the cursor where it already is produces no
    # WM_MOUSEMOVE, and Flutter would never see the hover before the press.
    lpwin.nudge(target_x, target_y)
    time.sleep(0.12)
    lpwin.click(target_x, target_y, double=args.double)
    rounds = 2 if args.double else 1
    print(f"clicked client ({args.x},{args.y}) -> screen ({target_x},{target_y}) x{rounds}")

    if args.wait_ms > 0:
        time.sleep(args.wait_ms / 1000.0)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
