"""Generate a tiny PGS (Blu-ray .sup) subtitle file for testing.

There is no encoder that turns text into a bitmap subtitle, so the test
fixture used to exercise the PGS/VobSub path is written by hand: the file
contains one display set that paints a solid green rectangle at (220, 300)
in a 640x360 video and a second display set that clears it again.

Usage:
    python tool/make_pgs_fixture.py <out.sup>

The output is a valid `.sup` stream: `ffprobe` should report one
hdmv_pgs_subtitle stream.  See `docs/verification.md` for how it is used.
"""

import struct
import sys

PCS = 0x16
WDS = 0x17
PDS = 0x14
ODS = 0x15
END = 0x80


def segment(pts_90k, kind, payload):
    out = bytearray(b"PG")
    out += struct.pack(">II", pts_90k & 0xFFFFFFFF, pts_90k & 0xFFFFFFFF)
    out += bytes([kind])
    out += struct.pack(">H", len(payload))
    out += payload
    return bytes(out)


def rle_rect(width, height, color):
    """Run-length encode a solid rectangle.

    PGS RLE encodes a run as ``00 <flags> [run-low] [color]``: bit 0x40 in
    flags means a second run byte follows, bit 0x80 means a colour byte
    follows.  ``00 00`` is a newline.  Writing the raw colour byte first
    (as a naive encoder would) makes libavcodec read a 1-pixel run.
    """
    assert 0 < width <= 0x3FFF and 0 < color < 256
    data = bytearray()
    for _ in range(height):
        if width <= 0x3F:
            data += bytes([0x00, 0x80 | width, color])
        else:
            data += bytes([0x00, 0xC0 | (width >> 8), width & 0xFF, color])
        data += bytes([0x00, 0x00])
    return bytes(data)


def pcs(video_w, video_h, number, state, objects):
    payload = struct.pack(">HHBHB", video_w, video_h, 0x10, number, state)
    payload += bytes([0x00, 0x00])  # palette_update_flag, palette_id
    payload += bytes([len(objects)])
    for (obj_id, x, y) in objects:
        # object_id, window_id, object_cropped_flag, x, y
        payload += struct.pack(">HBBHH", obj_id, 0, 0x00, x, y)
    return payload


def wds(windows):
    payload = bytes([len(windows)])
    for (win_id, x, y, w, h) in windows:
        payload += struct.pack(">BHHHH", win_id, x, y, w, h)
    return payload


def pds(palette):
    payload = bytes([0x00, 0x00])  # palette_id, palette_version_number
    for (idx, y, cr, cb, t) in palette:
        payload += bytes([idx, y, cr, cb, t])
    return payload


def ods(obj_id, width, height, rle):
    body = struct.pack(">HH", width, height) + rle
    payload = struct.pack(">HBB", obj_id, 0x00, 0xC0)  # id, version, last-in-seq
    payload += struct.pack(">I", len(body))[1:]  # 24-bit object_data_length
    payload += body
    return payload


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "build/media/pgs/clip.sup"
    video_w, video_h = 640, 360
    rect_x, rect_y, rect_w, rect_h = 220, 300, 200, 40
    # Y/Cr/Cb palette: index 0 fully transparent, index 1 near pure green.
    palette = [
        (0, 16, 128, 128, 0),
        (1, 145, 54, 34, 255),
    ]
    rle = rle_rect(rect_w, rect_h, 1)

    stream = bytearray()
    # Display set 1: epoch start, one object visible.
    show = 90000  # 1.0 s at 90 kHz
    stream += segment(show, PCS, pcs(video_w, video_h, 0, 0x80,
                                     [(0, rect_x, rect_y)]))
    stream += segment(show, WDS, wds([(0, rect_x, rect_y, rect_w, rect_h)]))
    stream += segment(show, PDS, pds(palette))
    stream += segment(show, ODS, ods(0, rect_w, rect_h, rle))
    stream += segment(show, END, b"")

    # Display set 2: nothing composed any more -> clear.
    hide = 540000  # 6.0 s
    stream += segment(hide, PCS, pcs(video_w, video_h, 1, 0x00, []))
    stream += segment(hide, END, b"")

    with open(out_path, "wb") as fh:
        fh.write(bytes(stream))
    print("wrote %s (%d bytes)" % (out_path, len(stream)))


if __name__ == "__main__":
    main()
