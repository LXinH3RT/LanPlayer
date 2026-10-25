#!/usr/bin/env python3
"""Prove the player page's "show controls on mouse move, hide after idle" behaviour.

Why a dedicated script: Flutter offers no CLI way to inject pointer events, and
the player page cannot be proven by screen capture (once the external video
texture is registered, a screen copy reads black). The app prints
`LanPlayer controls: shown|hidden` whenever the transport UI really appears or
disappears, so this script moves the pointer over the window and asserts on
those paired lines in stdout.

The pointer is genuinely moved with SetCursorPos rather than injected with
PostMessage: the engine asks Win32 for the cursor position instead of trusting
lParam, so a posted WM_MOUSEMOVE never sets Flutter's own "inside" state.

  python scripts/hover_probe.py -e <lanplayer.exe> [--open <video>]

Exit codes: 0 ok, 1 setup problem, 2 assertion failed.
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
    parser.add_argument("--warmup-ms", type=int, default=11000)
    parser.add_argument("--idle-ms", type=int, default=3500)
    parser.add_argument("--points", default="0.5,0.5;0.6,0.4;0.4,0.6;0.5,0.3",
                        help="semicolon separated fractions of the client area")
    args = parser.parse_args()

    exe = Path(args.exe)
    if not exe.exists():
        print(f"!! missing exe: {exe}", file=sys.stderr)
        return 1
    log_dir = Path(args.log_dir) if args.log_dir else lp.ROOT / "build" / "verify-hover"
    state_dir = Path(args.state_dir) if args.state_dir else log_dir / "state"
    for path in (log_dir, state_dir):
        lp.ensure_dir(path)
    out_log = log_dir / "stdout.txt"
    err_log = log_dir / "stderr.txt"

    points = []
    for group in args.points.split(";"):
        group = group.strip()
        if not group:
            continue
        parts = [part.strip() for part in group.split(",")]
        if len(parts) != 2:
            print(f"?? bad point {group!r}", file=sys.stderr)
            return 1
        points.append((float(parts[0]), float(parts[1])))
    if not points:
        print("!! no points", file=sys.stderr)
        return 1

    def log_lines(pattern: str) -> list[str]:
        if not out_log.exists():
            return []
        text = out_log.read_text(encoding="utf-8", errors="replace")
        return [line for line in text.splitlines() if pattern in line]

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
            width, height = lpwin.client_rect(view)
            origin_x, origin_y = lpwin.client_origin(view)
            print(f"window: hwnd=0x{hwnd:X} view=0x{view:X} client={width}x{height}")

            lpwin.raise_window(hwnd, settle=0.7)

            print("--- phase 1: sit still, the transport UI should hide on its own ---")
            time.sleep(args.idle_ms / 1000.0)
            idle_hidden = log_lines("controls: hidden")
            print(f"after {args.idle_ms} ms idle: hidden count = {len(idle_hidden)}")
            for line in idle_hidden:
                print(f"  {line}")

            print("--- phase 2: move the pointer, the UI should come back ---")
            shown_before = len(log_lines("controls: shown"))

            def park_cursor() -> None:
                # Outside the window, so the first real move is a genuine enter;
                # "already inside, moved by 0 px" produces no event at all.
                lpwin.move_cursor(2, 2)
                time.sleep(0.25)

            def send_move(fx: float, fy: float) -> None:
                target_x = origin_x + int(width * fx)
                target_y = origin_y + int(height * fy)
                lpwin.move_cursor(target_x, target_y)
                got_x, got_y = lpwin.cursor_pos()
                print(f"  cursor -> {got_x},{got_y} (wanted {target_x},{target_y})")

            park_cursor()
            for fx, fy in points:
                send_move(fx, fy)
                time.sleep(0.4)
            time.sleep(0.6)
            new_shown = len(log_lines("controls: shown")) - shown_before
            print(f"{len(points)} moves produced {new_shown} new 'shown' lines (want >= 1)")

            print("--- phase 3: sit still again, it should hide again ---")
            hidden_before = len(log_lines("controls: hidden"))
            time.sleep(args.idle_ms / 1000.0)
            hidden_after = len(log_lines("controls: hidden"))
            print(f"another {args.idle_ms} ms idle produced {hidden_after - hidden_before} "
                  f"new 'hidden' lines (want >= 1)")
        finally:
            lpwin.stop_app(proc)
    time.sleep(0.3)

    print("---- full controls log ----")
    for line in log_lines("controls:"):
        print(line)
    print("---- stderr ----")
    print(err_log.read_text(encoding="utf-8", errors="replace"))

    ok = len(idle_hidden) >= 1 and new_shown >= 1 and (hidden_after - hidden_before) >= 1
    print("hover probe: OK" if ok else "hover probe: FAILED")
    return 0 if ok else 2


if __name__ == "__main__":
    raise SystemExit(main())
