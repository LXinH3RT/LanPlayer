#!/usr/bin/env python3
"""Capture the LanPlayer window the way a user would see it.

Why this exists: PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT) returns only the
non-client frame plus a black client area for Flutter windows that are not the
foreground window (ANGLE/D3D swaps are not replayed).  Copying the pixels
straight off the screen after bringing the window to the front is the only
capture that shows what the renderer really produced.

    python scripts/capture_screen.py -e <lanplayer.exe> -o <png>

  --whole-screen      capture the entire desktop instead of the window
                      rectangle.  On a scaled display the Flutter view can be
                      composited at a different offset than GetWindowRect
                      reports, so a window-rect grab may miss the client area
                      entirely; the whole screen always contains it.
  --retries N         re-raise the window and capture again when the shot does
                      not contain the expected colour.  Raise is only a
                      request: if another window keeps the foreground the
                      desktop (not the app) is what gets copied, which is how a
                      colour probe silently turned into an all-white PNG twice.
  --expect-color      "R,G,B" the capture must contain (e.g. "253,0,0" for the
                      red probe).  The shot is rejected and retried until
                      --min-match of sampled pixels match within --tolerance.
  --width/--height    resize the window before the grab.  The window opens at
                      whatever size the runner remembers; a fixed size keeps the
                      screenshots in the docs comparable with each other.

Exit codes: 0 ok, 3 the expected colour was never found.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))

import lpscript as lp
import lpwin
from lpimage import Image


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-e", "--exe", required=True)
    parser.add_argument("--open", default="")
    parser.add_argument("--browse", default="")
    parser.add_argument("--user", default="")
    parser.add_argument("--password", default="")
    parser.add_argument("--state-dir", default="")
    parser.add_argument("--log-dir", default="")
    parser.add_argument("-o", "--out", default="")
    parser.add_argument("-w", "--wait-ms", type=int, default=9000)
    parser.add_argument("--retries", type=int, default=4)
    parser.add_argument("--expect-color", default="")
    parser.add_argument("--min-match", type=float, default=0.20)
    parser.add_argument("--tolerance", type=int, default=20)
    parser.add_argument("--width", type=int, default=0)
    parser.add_argument("--height", type=int, default=0)
    parser.add_argument("--whole-screen", action="store_true")
    return parser.parse_args(argv)


def window_shot(hwnd: int, whole_screen: bool) -> Image:
    """Copy the window rectangle out of a full-screen grab."""
    screen = lpwin.screen_grab()
    if whole_screen:
        return screen
    left, top, width, height = lpwin.window_rect(hwnd)
    return screen.crop(left, top, width, height)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    # Declare DPI awareness before any window call: otherwise GetWindowRect
    # answers in logical pixels while a screen copy is in physical ones, and the
    # crop lands somewhere else entirely.
    lpwin.dpi_aware()
    exe = Path(args.exe)
    if not exe.exists():
        print(f"!! missing exe: {exe}", file=sys.stderr)
        return 2
    out = Path(args.out) if args.out else None
    log_dir = Path(args.log_dir) if args.log_dir else (
        out.parent / "log" if out else lp.TOOLS / "tmp" / "capture-log")
    lp.ensure_dir(log_dir)
    stdout_path = log_dir / "app-stdout.log"
    stderr_path = log_dir / "app-stderr.log"
    for path in (stdout_path, stderr_path):
        if path.exists():
            path.unlink()

    want = None
    if args.expect_color:
        parts = [p.strip() for p in args.expect_color.split(",")]
        if len(parts) != 3:
            print(f"!! --expect-color wants 'R,G,B', got {args.expect_color!r}",
                  file=sys.stderr)
            return 2
        want = tuple(int(p) for p in parts)

    env = lpwin.app_env(state_dir=args.state_dir or None,
                        open_media=args.open or None,
                        browse=args.browse or None,
                        user=args.user or None,
                        password=args.password or None)

    invalid = False
    with open(stdout_path, "w", encoding="utf-8") as out_file, \
            open(stderr_path, "w", encoding="utf-8") as err_file:
        proc = lpwin.start_app(exe, env=env, stdout=out_file, stderr=err_file)
        try:
            time.sleep(args.wait_ms / 1000.0)
            hwnd = lpwin.find_main_window(proc.pid)
            if not hwnd:
                print("window: not found")
            else:
                lpwin.raise_window(hwnd)
                if args.width > 200 and args.height > 200:
                    lpwin.resize_window(hwnd, args.width, args.height)
                left, top, width, height = lpwin.window_rect(hwnd)
                print(f"window: hwnd=0x{hwnd:X} rect={width}x{height} at {left},{top}")
                if args.whole_screen:
                    screen = lpwin.screen_grab()
                    print(f"screen: {screen.width}x{screen.height}")
                else:
                    screen = None

            if out and (args.whole_screen or hwnd):
                attempt = 0
                match = -1.0
                while attempt < max(1, args.retries):
                    attempt += 1
                    if screen is not None:
                        shot = screen
                    else:
                        shot = window_shot(hwnd, False)
                    if want:
                        match = shot.colour_match(*want, tolerance=args.tolerance)
                    shot.save_png(out)
                    if match < 0 or match >= args.min_match:
                        break
                    print(f"attempt {attempt}/{args.retries}: expected colour only "
                          f"{match:.1%} of pixels, re-raising")
                    lpwin.raise_window(hwnd, settle=0.7)

                if match >= 0:
                    print(f"captured: {out} (expected-colour match={match:.1%}, "
                          f"attempts={attempt})")
                    if match < args.min_match:
                        print("warning: expected colour not found; treat this "
                              "capture as invalid evidence")
                        invalid = True
                else:
                    print(f"captured: {out} (attempts={attempt})")
        finally:
            lpwin.stop_app(proc)
    time.sleep(0.3)

    print("--- stdout ---")
    print(stdout_path.read_text(encoding="utf-8", errors="replace"))
    print("--- stderr ---")
    print(stderr_path.read_text(encoding="utf-8", errors="replace"))
    return 3 if invalid else 0


if __name__ == "__main__":
    raise SystemExit(main())
