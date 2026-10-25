#!/usr/bin/env python3
"""Generate the media fixtures used by the native smoke tests.

    python scripts/make_test_media.py

Needs the FFmpeg build downloaded by tool/fetch_deps.py (it ships ffmpeg.exe).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402


def find_ffmpeg() -> Path:
    for candidate in (lp.TOOLS / "ffmpeg").rglob("ffmpeg.exe"):
        if candidate.is_file():
            return candidate
    raise lp.ScriptError("ffmpeg.exe not found - run: python tool/fetch_deps.py ffmpeg")


def generate(ff: Path, out_dir: Path) -> None:
    def encode(args: list[str], label: str) -> None:
        print(f"== {label}")
        lp.run([str(ff), "-hide_banner", "-loglevel", "error", "-y", *args])

    # 1) plain clip: 640x360 h264 + 440 Hz sine, 6 s
    encode(["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "6", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-shortest", str(out_dir / "test.mp4")],
           "test.mp4 (video + audio)")

    # 2) sidecar subtitle next to the same clip (auto-load path)
    print("== clip.srt (external subtitle)")
    cues = [
        ("00:00:00,500", "00:00:02,000", "Hello LanPlayer (external SRT)"),
        ("00:00:02,500", "00:00:04,500", "Second line subtitle"),
        ("00:00:04,600", "00:00:05,800", "Third line"),
    ]
    lines: list[str] = []
    for index, (start, end, text) in enumerate(cues, start=1):
        lines += [str(index), f"{start} --> {end}", text, ""]
    (out_dir / "clip.srt").write_text("\r\n".join(lines), encoding="utf-8", newline="")
    (out_dir / "clip.mp4").write_bytes((out_dir / "test.mp4").read_bytes())

    # 3) muxed clip with an embedded subtitle track (embedded decode path)
    encode(["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-i", str(out_dir / "clip.srt"),
            "-t", "6", "-map", "0:v", "-map", "1:a", "-map", "2:s",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-c:s", "srt", str(out_dir / "subbed.mkv")],
           "subbed.mkv (embedded subrip track)")

    # 4) solid red clip: the colour-order probe.
    #
    # The core hands out BGRA, Flutter's pixel-buffer texture reads RGBA, so the
    # plugin must swap R and B.  A pure red frame makes a missed swap impossible
    # to argue with: correct output is #FD0000, broken output is #0000FD (blue).
    # Only the flat centre is relied on, so a few pixels of YUV edge bleed are
    # harmless.
    #
    # The clip is deliberately 60 s long: capturing a 4 s probe is a race against
    # playback ending (the window then shows the ended state, not the frame),
    # which made the screenshot evidence flaky.  A flat colour compresses to a
    # few KiB, so the length costs nothing.
    color_dir = out_dir / "colortest"
    color_dir.mkdir(parents=True, exist_ok=True)
    encode(["-f", "lavfi", "-i", "color=c=red:size=640x360:rate=25:duration=60",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            str(color_dir / "red.mp4")],
           "colortest/red.mp4 (BGRA->RGBA probe)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out-dir", default="", help="output directory (default: build/media)")
    args = parser.parse_args()

    out_dir = Path(args.out_dir) if args.out_dir else lp.ROOT / "build" / "media"
    out_dir.mkdir(parents=True, exist_ok=True)

    ff = find_ffmpeg()
    generate(ff, out_dir)

    for path in sorted(out_dir.iterdir()):
        if path.is_file():
            print(f"   {path.name:<14} {path.stat().st_size / 1024:8.0f} KiB")
    print(f'\nrun: build/win-x64/lp_smoke_test.exe "{out_dir / "clip.mp4"}" 6')
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
