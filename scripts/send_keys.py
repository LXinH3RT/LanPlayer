#!/usr/bin/env python3
"""Send synthetic keystrokes to a running LanPlayer window.

Why this exists: the player screen's keyboard shortcuts (space, arrows, F, M,
S, Esc) can only be proven by driving the real Win32 window -- Flutter offers
no CLI way to inject key events. The app prints one "LanPlayer key: <label>"
line per handled shortcut, so the captured stdout is the assertion.

Keys are posted rather than injected with SendInput because this machine cannot
reliably take the foreground focus of the desktop session. They go to the
focused child window (the Flutter view), not the top-level frame, because that
is where Flutter's message handler lives.

  python scripts/send_keys.py -e app/build/windows/x64/runner/Release/lanplayer.exe \
      --open D:/media/clip.mp4 [--keys Space,Right,F,M,S,Escape]
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))

import lpscript as lp
import lpwin


def show_rect(hwnd: int, when: str) -> None:
    """Print the frame geometry so the log proves F really toggled fullscreen."""
    left, top, width, height = lpwin.window_rect(hwnd)
    print(f"rect[{when}]: {width}x{height} at {left},{top}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-e", "--exe", required=True)
    parser.add_argument("--open", default="")
    parser.add_argument("--state-dir", default="")
    parser.add_argument("--log-dir", default="")
    parser.add_argument("--keys", default="Space,Right,Right,F,F,M,S,Escape")
    parser.add_argument("--warmup-ms", type=int, default=9000)
    parser.add_argument("--gap-ms", type=int, default=800)
    parser.add_argument("-o", "--out", default="")
    args = parser.parse_args()

    # A -File pass of a comma-joined list must still work, so split and trim.
    keys = [k.strip() for k in args.keys.split(",") if k.strip()]

    exe = Path(args.exe)
    log_dir = Path(args.log_dir) if args.log_dir else lp.ROOT / "build" / "media" / "keys"
    state_dir = Path(args.state_dir) if args.state_dir else log_dir / "state"
    for path in (log_dir, state_dir):
        lp.ensure_dir(path)
    if not exe.exists():
        print(f"!! missing exe: {exe}", file=sys.stderr)
        return 1

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
            focus = lpwin.focus_window(hwnd)
            print(f"window: hwnd=0x{hwnd:X} focus=0x{focus:X}")

            show_rect(hwnd, "start")
            for name in keys:
                try:
                    lpwin.post_key(focus, name)
                except ValueError:
                    print(f"?? unknown key {name}")
                    continue
                print(f"sent: {name}")
                time.sleep(args.gap_ms / 1000.0)
                if name in ("F", "Escape"):
                    show_rect(hwnd, name)

            if args.out:
                try:
                    shot = lpwin.window_grab(hwnd)
                except OSError as exc:
                    print(f"!! PrintWindow failed: {exc}")
                else:
                    shot.save_png(Path(args.out))
                    print(f"captured: {args.out}")
            time.sleep(0.4)
        finally:
            lpwin.stop_app(proc)
    time.sleep(0.3)

    print("---- stdout ----")
    print(out_log.read_text(encoding="utf-8", errors="replace"))
    print("---- stderr ----")
    print(err_log.read_text(encoding="utf-8", errors="replace"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
