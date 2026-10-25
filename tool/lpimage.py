#!/usr/bin/env python3
"""Tiny raster image type plus a PNG reader and writer.

The screenshot scripts and image_stats used to lean on System.Drawing from
PowerShell: that pulled in a C# ``Add-Type`` block per script and made the
colour statistics slow enough to notice (GetPixel is roughly a hundred times
slower than walking the raw buffer).  Python has no such library here -- the
bundled interpreter ships without Pillow and without pip -- but it does ship
``zlib``, and PNG is a zlib stream with a header and a per-row filter byte.
That is all this module needs, so the scripts stay dependency-free.

Only what the scripts actually use is implemented: 8-bit, non-interlaced PNGs
in greyscale, RGB, palette, or either of those with an alpha channel.  Pixels
are held as packed RGB because every consumer here wants colour, not alpha.
"""
from __future__ import annotations

import struct
import zlib
from pathlib import Path

__all__ = ["Image", "load_png", "save_png"]

_PNG_SIG = b"\x89PNG\r\n\x1a\n"


class Image:
    """An RGB raster: ``pixels`` is width*height*3 bytes, top row first."""

    __slots__ = ("width", "height", "pixels")

    def __init__(self, width: int, height: int, pixels: bytes | bytearray) -> None:
        if width <= 0 or height <= 0:
            raise ValueError(f"bad image size {width}x{height}")
        if len(pixels) != width * height * 3:
            raise ValueError(
                f"expected {width * height * 3} bytes for {width}x{height}, got {len(pixels)}"
            )
        self.width = width
        self.height = height
        self.pixels = bytearray(pixels)

    # -- geometry -------------------------------------------------------
    def crop(self, left: int, top: int, width: int, height: int) -> "Image":
        """Return the requested rectangle, clamped to the image."""
        left = max(0, min(left, self.width))
        top = max(0, min(top, self.height))
        width = max(0, min(width, self.width - left))
        height = max(0, min(height, self.height - top))
        if width == 0 or height == 0:
            raise ValueError("crop is empty")
        out = bytearray(width * height * 3)
        stride = self.width * 3
        for row in range(height):
            src = (top + row) * stride + left * 3
            dst = row * width * 3
            out[dst:dst + width * 3] = self.pixels[src:src + width * 3]
        return Image(width, height, out)

    # -- inspection -----------------------------------------------------
    def colour_match(self, red: int, green: int, blue: int, tolerance: int = 20,
                     step: int = 8) -> float:
        """Fraction of sampled pixels within ``tolerance`` of the colour.

        Sampling every ``step`` pixels in both directions is what the shell
        version did: a full scan of a 4K desktop costs seconds and tells you
        nothing extra about "is the app on screen".
        """
        hits = 0
        total = 0
        px = self.pixels
        for y in range(0, self.height, step):
            base = y * self.width * 3
            for x in range(0, self.width, step):
                i = base + x * 3
                if (abs(px[i] - red) <= tolerance
                        and abs(px[i + 1] - green) <= tolerance
                        and abs(px[i + 2] - blue) <= tolerance):
                    hits += 1
                total += 1
        return hits / total if total else 0.0

    def mean(self) -> tuple[float, float, float]:
        px = self.pixels
        n = self.width * self.height
        return (sum(px[0::3]) / n, sum(px[1::3]) / n, sum(px[2::3]) / n)

    def histogram(self) -> dict[tuple[int, int, int], int]:
        px = self.pixels
        counts: dict[tuple[int, int, int], int] = {}
        for i in range(0, len(px), 3):
            key = (px[i], px[i + 1], px[i + 2])
            counts[key] = counts.get(key, 0) + 1
        return counts

    def bright_pixels(self, left: int, top: int, width: int, height: int,
                      threshold: int = 200) -> int:
        """Count near-white pixels inside a rectangle (may extend outside)."""
        px = self.pixels
        hits = 0
        x0 = max(0, left)
        x1 = min(self.width, left + width)
        y0 = max(0, top)
        y1 = min(self.height, top + height)
        for y in range(y0, y1):
            base = y * self.width * 3
            for x in range(x0, x1):
                i = base + x * 3
                if px[i] > threshold and px[i + 1] > threshold and px[i + 2] > threshold:
                    hits += 1
        return hits

    # -- persistence ----------------------------------------------------
    def save_png(self, path: str | Path) -> None:
        save_png(self, path)

    @classmethod
    def load_png(cls, path: str | Path) -> "Image":
        return load_png(path)


# ----------------------------------------------------------------------
# PNG writing
# ----------------------------------------------------------------------
def _chunk(tag: bytes, payload: bytes) -> bytes:
    return (struct.pack(">I", len(payload)) + tag + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))


def save_png(image: Image, path: str | Path) -> None:
    """Write an 8-bit RGB PNG."""
    stride = image.width * 3
    raw = bytearray()
    px = image.pixels
    for row in range(image.height):
        raw.append(0)  # filter type 0: no prediction
        raw += px[row * stride:(row + 1) * stride]
    header = struct.pack(">IIBBBBB", image.width, image.height, 8, 2, 0, 0, 0)
    blob = (_PNG_SIG
            + _chunk(b"IHDR", header)
            + _chunk(b"IDAT", zlib.compress(bytes(raw), 6))
            + _chunk(b"IEND", b""))
    Path(path).write_bytes(blob)


# ----------------------------------------------------------------------
# PNG reading
# ----------------------------------------------------------------------
def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def _unfilter(data: bytes, height: int, stride: int, bpp: int) -> bytearray:
    """Undo the per-row filters.  ``bpp`` is bytes per complete pixel."""
    out = bytearray(height * stride)
    pos = 0
    for row in range(height):
        if pos >= len(data):
            raise ValueError("truncated PNG data")
        kind = data[pos]
        pos += 1
        line = bytearray(data[pos:pos + stride])
        pos += stride
        if len(line) != stride:
            raise ValueError("truncated PNG scanline")
        base = row * stride
        prev = base - stride
        if kind == 0:
            pass
        elif kind == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif kind == 2:
            if row:
                for i in range(stride):
                    line[i] = (line[i] + out[prev + i]) & 0xFF
        elif kind == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                up = out[prev + i] if row else 0
                line[i] = (line[i] + ((left + up) >> 1)) & 0xFF
        elif kind == 4:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                up = out[prev + i] if row else 0
                upleft = out[prev + i - bpp] if (row and i >= bpp) else 0
                line[i] = (line[i] + _paeth(left, up, upleft)) & 0xFF
        else:
            raise ValueError(f"unknown PNG filter {kind} on row {row}")
        out[base:base + stride] = line
    return out


def load_png(path: str | Path) -> Image:
    """Decode an 8-bit non-interlaced PNG into RGB."""
    blob = Path(path).read_bytes()
    if not blob.startswith(_PNG_SIG):
        raise ValueError(f"{path} is not a PNG")
    pos = len(_PNG_SIG)
    width = height = 0
    depth = colour = 0
    palette = b""
    idat = bytearray()
    while pos + 8 <= len(blob):
        length = struct.unpack(">I", blob[pos:pos + 4])[0]
        tag = blob[pos + 4:pos + 8]
        payload = blob[pos + 8:pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", payload)
            if depth != 8:
                raise ValueError(f"{path}: only 8-bit PNGs are supported (got {depth})")
            if interlace:
                raise ValueError(f"{path}: interlaced PNGs are not supported")
        elif tag == b"PLTE":
            palette = payload
        elif tag == b"IDAT":
            idat += payload
        elif tag == b"IEND":
            break
    if not width or not height:
        raise ValueError(f"{path}: no IHDR")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(colour)
    if channels is None:
        raise ValueError(f"{path}: unsupported colour type {colour}")
    stride = width * channels
    raw = _unfilter(zlib.decompress(bytes(idat)), height, stride, channels)

    out = bytearray(width * height * 3)
    if colour == 2:  # RGB
        out[:] = raw
    elif colour == 6:  # RGBA
        for i in range(width * height):
            out[i * 3:i * 3 + 3] = raw[i * 4:i * 4 + 3]
    elif colour == 0 or colour == 4:  # grey [+alpha]
        step = channels
        for i in range(width * height):
            v = raw[i * step]
            out[i * 3] = out[i * 3 + 1] = out[i * 3 + 2] = v
    elif colour == 3:  # palette
        for i in range(width * height):
            idx = raw[i] * 3
            out[i * 3:i * 3 + 3] = palette[idx:idx + 3]
    return Image(width, height, out)
