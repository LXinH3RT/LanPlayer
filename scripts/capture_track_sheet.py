#!/usr/bin/env python3
"""Capture the audio/subtitle track sheet, or the settings page.

Why a dedicated script: capture_playback_ui.py only photographs the transport
bar. Opening the sheet needs a real click, and the transport bar hides itself
after 2 s of pointer idle -- so the pointer is nudged, the button is clicked,
and only then is the screen grabbed.

  python scripts/capture_track_sheet.py -e <lanplayer.exe> --open <video>
      [--button audio|subtitle|settings] [-o <png>]

``--button settings`` shoots the settings page instead (no --open; add
``--scroll N`` to reach the language dropdowns).

Button positions are computed from the client rect, so a different window size
does not need new magic numbers; --btn-x/--btn-y override them.
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
    parser.add_argument("--button", default="audio", choices=("audio", "subtitle", "settings"))
    parser.add_argument("--scroll", type=int, default=0,
                        help="wheel notches, only meaningful for --button settings")
    parser.add_argument("--warmup-ms", type=int, default=12000)
    parser.add_argument("--btn-x", type=int, default=0,
                        help="explicit click point in client coordinates")
    parser.add_argument("--btn-y", type=int, default=0)
    parser.add_argument("--pick-x", type=int, default=0,
                        help="second click inside the open sheet, to prove a pick sticks")
    parser.add_argument("--pick-y", type=int, default=0)
    args = parser.parse_args()

    exe = Path(args.exe)
    if not exe.exists():
        print(f"!! missing exe: {exe}", file=sys.stderr)
        return 1
    log_dir = Path(args.log_dir) if args.log_dir else lp.ROOT / "build" / "verify-track-sheet"
    state_dir = Path(args.state_dir) if args.state_dir else log_dir / "state"
    for path in (log_dir, state_dir):
        lp.ensure_dir(path)
    out = Path(args.out) if args.out else log_dir / f"track-{args.button}.png"
    lp.ensure_dir(out.parent)
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
            hwnd = lpwin.wait_for_window(proc.pid, timeout=5.0, require_title=False)
            if not hwnd:
                print("!! no visible window found")
                return 1
            view = lpwin.find_view(hwnd)
            lpwin.raise_window(hwnd, settle=0.8)

            width, height = lpwin.client_rect(view)
            origin_x, origin_y = lpwin.client_origin(view)
            print(f"window: hwnd=0x{hwnd:X} client={width}x{height} at {origin_x},{origin_y}")

            def move_to(x: int, y: int) -> None:
                lpwin.move_cursor(origin_x + x, origin_y + y)
                time.sleep(0.12)

            def click_here(x: int, y: int) -> None:
                move_to(x, y)
                time.sleep(0.2)
                lpwin.click(origin_x + x, origin_y + y)

            # Nudge the pointer so the transport bar appears and restarts its 2 s
            # timer.
            centre_x = width // 2
            centre_y = height // 2
            move_to(centre_x + 40, centre_y + 30)
            move_to(centre_x, centre_y)
            time.sleep(0.4)

            # Bottom icon row: speed 1.0x, picture, subtitles, audio, volume.
            # Measured on a 2216x1196 client by scanning the screenshot for the
            # glyph clusters, rows 1137..1165 (centre y=1151): picture icon
            # x=955, subtitle x=1101, audio x=1247, volume x=1395. The icon takes
            # the tap, not the label, so aim at the glyph. Beware the labels:
            # the subtitle text sits about one column right of the audio icon,
            # and clicking it opens the subtitle sheet instead.
            if args.button == "settings":
                # Home screen only: the settings icon is the last AppBar action.
                btn_x = width - 42
                btn_y = int(height * 0.043)
            else:
                btn_y = int(height * 0.962)
                btn_x = int(width * (0.4968 if args.button == "subtitle" else 0.5627))
            if args.btn_x > 0:
                btn_x = args.btn_x
            if args.btn_y > 0:
                btn_y = args.btn_y

            # The first click only activates the window: Windows spends the first
            # click sent to a background window on activation, so Flutter never
            # sees a tap. Where that harmless click may land depends on the page:
            # on the player page the middle of the picture is empty, but on the
            # home screen 60% down sits the "add server" button of the empty
            # state -- clicking there opens its dialog, and the next click just
            # dismisses the barrier. So aim at the app bar instead.
            if args.button == "settings":
                click_here(int(width * 0.5), int(height * 0.08))
            else:
                click_here(int(width * 0.5), int(height * 0.62))
            time.sleep(0.7)

            click_here(btn_x, btn_y)
            print(f"clicked {args.button} at client ({btn_x},{btn_y})")
            time.sleep(1.8)

            # Second click inside the open sheet, for the "picking a row really
            # selects it" scenario. The row has to be on screen; nothing scrolls.
            if args.pick_x > 0:
                click_here(args.pick_x, args.pick_y)
                print(f"picked row at client ({args.pick_x},{args.pick_y})")
                time.sleep(1.2)

            # Settings is a long list and the language tiles live below the fold,
            # so the shot needs a scroll. Wheel notches at the centre of it.
            if args.scroll > 0:
                move_to(int(width * 0.5), int(height * 0.6))
                for _ in range(args.scroll):
                    lpwin.wheel(-1, origin_x + int(width * 0.5), origin_y + int(height * 0.6))
                    time.sleep(0.12)
                time.sleep(0.7)
                print(f"scrolled {args.scroll} notches")

            # Grab the whole desktop and crop to the client rect: on a scaled
            # display the Flutter view is composited at a different offset than
            # GetWindowRect reports.
            screen = lpwin.screen_grab()
            # Keep the untouched desktop grab: when a crop lands in the wrong
            # place this file is the only way to see where the window really was.
            full = out.with_suffix(".full.png")
            screen.save_png(full)
            print(f"screen: {screen.width}x{screen.height} saved to {full}")

            crop = screen.crop(origin_x, origin_y, width, height)
            crop.save_png(out)
            print(f"captured: {out} ({crop.width}x{crop.height})")
        finally:
            lpwin.stop_app(proc)
    time.sleep(0.3)

    print("---- stdout (last 8) ----")
    tail = out_log.read_text(encoding="utf-8", errors="replace").splitlines()[-8:]
    print("\n".join(tail))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
