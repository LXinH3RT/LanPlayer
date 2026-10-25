#!/usr/bin/env python3
"""Runtime evidence that the volume stored in settings.json reaches the kernel.

The volume sheet only shows a percentage, so a screenshot cannot prove the gain
was applied.  The core prints one line when a file opens:

    [LanPlayer I audio] volume 0.35 (35%) from settings

and this script asserts that line for several values, including the two clamps
(above 2.0, below 0).  The core logs to stderr (lp_log.c uses fprintf(stderr))
and the Flutter side to stdout, so both streams are scanned.

  python scripts/verify_windows_volume.py
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))

import lpscript as lp
import lpwin

LINE = re.compile(r"volume [0-9.]+ \([0-9]+%\) from settings")

CASES = [
    ("0.35", "volume 0.35 (35%) from settings"),
    ("1", "volume 1.00 (100%) from settings"),
    ("0", "volume 0.00 (0%) from settings"),
    ("5", "volume 2.00 (200%) from settings"),
    ("-3", "volume 0.00 (0%) from settings"),
]


def probe(exe: Path, media: Path, scratch: Path, value: str) -> str:
    """Run the app with one stored volume and return the kernel's log line."""
    state = scratch / "state"
    if state.exists():
        shutil.rmtree(state, ignore_errors=True)
    state.mkdir(parents=True, exist_ok=True)
    (state / "settings.json").write_text(
        json.dumps({"version": 1, "volume": json.loads(value)}), encoding="utf-8"
    )

    out_log = scratch / "out.log"
    err_log = scratch / "err.log"
    for path in (out_log, err_log):
        if path.exists():
            path.unlink()

    env = lpwin.app_env(state_dir=state, open_media=str(media))
    env["LANPLAYER_NO_TEXTURE"] = "1"
    with open(out_log, "w", encoding="utf-8") as out, open(err_log, "w", encoding="utf-8") as err:
        proc = lpwin.start_app(exe, env=env, stdout=out, stderr=err, cwd=scratch)
        try:
            proc.wait(timeout=16)
        except Exception:
            lpwin.stop_app(proc)
    # Give the OS a moment to flush the handlers before reading.
    import time

    time.sleep(0.4)

    for path in (err_log, out_log):
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        match = LINE.search(text)
        if match:
            return match.group(0)
    return ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--exe", default="")
    parser.add_argument("--media", default="")
    args = parser.parse_args()

    exe = Path(args.exe) if args.exe else (
        lp.ROOT / "app" / "windows" / "out" / "build" / "x64-VisualStudio182026"
        / "runner" / "Release" / "lanplayer.exe"
    )
    media = Path(args.media) if args.media else lp.ROOT / "build" / "media" / "clip.mp4"
    for path, what in ((exe, "exe"), (media, "media")):
        if not path.exists():
            print(f"!! missing {what}: {path}", file=sys.stderr)
            return 2

    scratch = lp.ensure_dir(lp.TOOLS / "tmp" / "volcheck")
    failures = 0
    for value, expected in CASES:
        line = probe(exe, media, scratch, value)
        if line:
            print(f"volume={value:<5} -> {line}")
        else:
            print(f"volume={value:<5} -> NO LOG LINE")
            failures += 1
        if line != expected:
            print(f"  expected: {expected}")
            failures += 1

    # Leave no stray runner behind: a hidden window would keep holding the
    # settings file the next run wants to rewrite.
    for pid in lpwin.find_process_by_name("lanplayer"):
        lp.run(["taskkill", "/F", "/PID", str(pid)], check=False, show=False)

    if failures:
        print("volume-from-settings FAILED")
        return 1
    print("PASS: settings volume reaches the kernel and is clamped to 0..2")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
