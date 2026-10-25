#!/usr/bin/env python3
"""Sample an image region and print colour statistics.

The screenshots this repository keeps in docs/images were checked with this:
"is the window really in the shot" is a question about dominant colours, and a
flat all-white desktop answers it wrongly by eye.  Reading the file, cropping,
and counting is all it does.

  python tool/image_stats.py path.png [-crop x,y,w,h] [--save out.png] [-n 8]

Images are read with the PNG decoder in tool/lpimage.py, so no third-party
package is required.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import lpimage


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("path", type=Path)
    parser.add_argument("-crop", metavar="X,Y,W,H")
    parser.add_argument("--save", type=Path)
    parser.add_argument("-n", "--top", type=int, default=8,
                        help="how many dominant colours to list")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if not args.path.exists():
        print(f"!! no such file: {args.path}", file=sys.stderr)
        return 2
    image = lpimage.load_png(args.path)

    if args.crop:
        parts = [int(p) for p in args.crop.split(",")]
        if len(parts) != 4:
            print("!! -crop wants X,Y,W,H", file=sys.stderr)
            return 2
        image = image.crop(*parts)

    if args.save:
        image.save_png(args.save)
        print(f"saved: {args.save} ({image.width}x{image.height})")

    total = image.width * image.height
    hist = image.histogram()
    red, green, blue = image.mean()
    print(f"size={image.width}x{image.height} colors={len(hist)}")
    print(f"mean r={red:.1f} g={green:.1f} b={blue:.1f}")
    for (r, g, b), count in sorted(hist.items(), key=lambda kv: -kv[1])[:args.top]:
        print(f"  {r},{g},{b:<12} {count:>10}  {count / total:.1%}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
