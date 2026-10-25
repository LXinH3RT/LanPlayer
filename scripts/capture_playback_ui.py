#!/usr/bin/env python3
"""Capture the player page WITH the transport UI visible, and measure the chrome.

Why not just capture_screen.py: the transport UI hides itself after 2 s of
pointer idle, so a plain "wait then grab" always photographs a bare picture.
That is why the cursor is jiggled inside the window first -- it both shows the
UI and restarts the countdown -- and only then is the screen grabbed.

Why a whole-screen grab cropped afterwards: on a scaled display the Flutter
view is composited at a different offset than GetWindowRect reports, so copying
just the window rectangle can miss the client area entirely. ClientToScreen is
the truth, and the picture is cropped from the full desktop.

  python scripts/capture_playback_ui.py -e <lanplayer.exe> --open <video>

Prints the bright-pixel counts that the layout assertions use.
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
    parser.add_argument("--open", default="")
    parser.add_argument("--state-dir", default="")
    parser.add_argument("--log-dir", default="")
    parser.add_argument("-o", "--out", default="")
    parser.add_argument("--warmup-ms", type=int, default=12000)
    args = parser.parse_args()

    exe = Path(args.exe)
    if not exe.exists():
        print(f"!! missing exe: {exe}", file=sys.stderr)
        return 1
    log_dir = Path(args.log_dir) if args.log_dir else lp.ROOT / "build" / "verify-ui"
    state_dir = Path(args.state_dir) if args.state_dir else log_dir / "state"
    for path in (log_dir, state_dir):
        lp.ensure_dir(path)
    out = Path(args.out) if args.out else log_dir / "player-ui.png"
    out_log = log_dir / "stdout.txt"
    err_log = log_dir / "stderr.txt"

    lpwin.dpi_aware()

    env = lpwin.app_env(state_dir=state_dir, open_media=args.open or None)
    with open(out_log, "w", encoding="utf-8") as out_file, \
            open(err_log, "w", encoding="utf-8") as err_file:
        proc = lpwin.start_app(exe, env=env, stdout=out_file, stderr=err_file)
        try:
            time.sleep(args.warmup_ms / 1000.0)
            if proc.poll() is not None:
                print(f"!! app exited early (code {proc.returncode})")
                print(out_log.read_text(encoding="utf-8", errors="replace"))
                print(err_log.read_text(encoding="utf-8", errors="replace"))
                return 1
            hwnd = lpwin.wait_for_window(proc.pid, timeout=5.0)
            if not hwnd:
                print("!! no visible window found")
                return 1
            view = lpwin.find_view(hwnd)
            lpwin.raise_window(hwnd, settle=0.8)

            width, height = lpwin.client_rect(view)
            origin_x, origin_y = lpwin.client_origin(view)
            print(f"window: hwnd=0x{hwnd:X} view=0x{view:X} client={width}x{height} "
                  f"at {origin_x},{origin_y}")

            # Jiggle the cursor: this is what makes the transport UI appear and
            # starts its 2 s countdown. A single move is not enough -- if the
            # pointer already sits at that exact spot Windows emits no
            # WM_MOUSEMOVE and the UI stays hidden, which is how an earlier
            # version of this script captured a bare picture.
            centre_x = origin_x + width // 2
            centre_y = origin_y + height // 2
            lpwin.move_cursor(centre_x + 40, centre_y + 30)
            time.sleep(0.08)
            for step in range(6):
                lpwin.move_cursor(centre_x - step * 6, centre_y - step * 4)
                time.sleep(0.06)
            time.sleep(0.15)

            screen = lpwin.screen_grab()
            # Keep the untouched desktop grab as well: when the crop lands in the
            # wrong place this file is the only way to see where the window
            # really was -- a bad crop cannot tell you it is wrong, it just looks
            # empty.
            full = out.with_suffix(".full.png")
            screen.save_png(full)
            print(f"screen: {screen.width}x{screen.height} saved to {full}")

            crop = screen.crop(origin_x, origin_y, width, height)
            crop.save_png(out)
            print(f"captured: {out} ({crop.width}x{crop.height})")

            # Regions are fractions of the client rect so this holds for whatever
            # window size the runner happens to use. The icons and labels are
            # near-white on dark scrims, hence the brightness test.
            strip_w = int(width * 0.14)   # wide enough for one icon button
            bar_h = int(height * 0.13)    # the top bar
            top_left = crop.bright_pixels(0, 0, strip_w, bar_h)
            top_right = crop.bright_pixels(width - strip_w, 0, strip_w, bar_h)
            mid_left = crop.bright_pixels(0, int(height * 0.42), strip_w, int(height * 0.16))
            bottom_row = crop.bright_pixels(0, height - int(height * 0.20),
                                            width, int(height * 0.20))
            print(f"bright pixels top-left={top_left} top-right={top_right} "
                  f"mid-left={mid_left} bottom-row={bottom_row}")
        finally:
            lpwin.stop_app(proc)
    time.sleep(0.3)

    print("---- stdout (last 6) ----")
    tail = out_log.read_text(encoding="utf-8", errors="replace").splitlines()[-6:]
    print("\n".join(tail))
    print("---- stderr (last 4) ----")
    tail = err_log.read_text(encoding="utf-8", errors="replace").splitlines()[-4:]
    print("\n".join(tail))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
