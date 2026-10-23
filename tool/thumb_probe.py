"""缩略图接口的端到端探针：直接通过 ctypes 调 lanplayer.dll 的
lp_source_thumbnail，验证返回的 RGBA 缓冲、尺寸与像素内容。

用法：
  python tool/thumb_probe.py <url> [<url> ...]
  python tool/thumb_probe.py --user u --pass p <url> ...
"""
import ctypes
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DLL = os.path.join(ROOT, "build", "win-x64", "lanplayer.dll")


def main() -> int:
    argv = sys.argv[1:]
    user = password = ""
    urls = []
    i = 0
    while i < len(argv):
        if argv[i] == "--user":
            user = argv[i + 1]
            i += 2
        elif argv[i] == "--pass":
            password = argv[i + 1]
            i += 2
        else:
            urls.append(argv[i])
            i += 1
    options = json.dumps({"user": user, "password": password}).encode("utf-8") if user else None

    lib = ctypes.CDLL(DLL)

    lib.lp_source_thumbnail.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_int32,
        ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_int32),
        ctypes.POINTER(ctypes.c_int32),
    ]
    lib.lp_source_thumbnail.restype = ctypes.c_int32
    lib.lp_pixels_free.argtypes = [ctypes.c_void_p]
    lib.lp_pixels_free.restype = None
    lib.lp_source_last_error.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    lib.lp_source_last_error.restype = ctypes.c_int32
    lib.lp_string_free.argtypes = [ctypes.c_void_p]
    lib.lp_string_free.restype = None

    def last_error() -> str:
        out = ctypes.c_void_p()
        if lib.lp_source_last_error(ctypes.byref(out)) != 0 or not out.value:
            return ""
        try:
            return ctypes.string_at(out).decode("utf-8", "replace")
        finally:
            lib.lp_string_free(out)

    failures = 0
    if not urls:
        clips = os.path.join(ROOT, "build", "media", "clip.mp4")
        urls = ["file:///" + clips.replace("\\", "/")]

    for url in urls:
        pixels = ctypes.c_void_p()
        width = ctypes.c_int32()
        height = ctypes.c_int32()
        rc = lib.lp_source_thumbnail(
            url.encode("utf-8"), options, 320,
            ctypes.byref(pixels), ctypes.byref(width), ctypes.byref(height),
        )
        if rc != 0:
            print(f"FAIL {url}\n  rc={rc} err={last_error()}")
            failures += 1
            continue
        try:
            w, h = width.value, height.value
            buf = ctypes.string_at(pixels, w * h * 4)
            # 统计非黑像素占比，确认不是全空的图
            non_black = 0
            total = w * h
            for i in range(0, len(buf), 4):
                if buf[i] or buf[i + 1] or buf[i + 2]:
                    non_black += 1
            center = (h // 2) * w * 4 + (w // 2) * 4
            rgba = tuple(buf[center:center + 4])
            print(
                f"OK   {url}\n"
                f"  {w}x{h} bytes={len(buf)} non_black={non_black}/{total} "
                f"({100.0 * non_black / total:.1f}%) center_rgba={rgba}"
            )
            if w > 320 or w <= 0 or h <= 0:
                print("  FAIL: bad size")
                failures += 1
            if non_black == 0:
                print("  FAIL: all black (decoded nothing?)")
                failures += 1
        finally:
            lib.lp_pixels_free(pixels)

    print(f"\n{'FAILURES: %d' % failures if failures else 'all thumbnail probes passed'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
