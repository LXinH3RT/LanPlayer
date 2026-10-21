# -*- coding: utf-8 -*-
"""Windows 端 SMB 缩略图回归：路径写死在脚本里，绕开 PowerShell -> python 的 argv 编码问题。"""
import ctypes
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DLL = os.path.join(ROOT, "build", "win-x64", "lanplayer.dll")

lib = ctypes.CDLL(DLL)
lib.lp_source_thumbnail.restype = ctypes.c_int32
lib.lp_source_thumbnail.argtypes = [
    ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int32,
    ctypes.POINTER(ctypes.c_void_p),
    ctypes.POINTER(ctypes.c_int32), ctypes.POINTER(ctypes.c_int32),
]
lib.lp_pixels_free.restype = None
lib.lp_pixels_free.argtypes = [ctypes.c_void_p]
lib.lp_source_last_error.restype = ctypes.c_int32
lib.lp_source_last_error.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
lib.lp_string_free.restype = None
lib.lp_string_free.argtypes = [ctypes.c_void_p]

CASES = [
    ("SMB 1.8GB movie",
     "smb://192.168.1.10/共享/电影/movie-01/movie-01.mp4",
     json.dumps({"user": "share", "password": "share"})),
]

ok = True
for label, url, opts in CASES:
    pix = ctypes.c_void_p()
    w = ctypes.c_int32()
    h = ctypes.c_int32()
    rc = lib.lp_source_thumbnail(url.encode("utf-8"), opts.encode("utf-8"), 320,
                                 ctypes.byref(pix), ctypes.byref(w), ctypes.byref(h))
    if rc != 0:
        err = ctypes.c_void_p()
        lib.lp_source_last_error(ctypes.byref(err))
        msg = ctypes.string_at(err).decode("utf-8", "replace") if err.value else "(no detail)"
        if err.value:
            lib.lp_string_free(err)
        print("FAIL %s\n  rc=%d err=%s" % (url, rc, msg))
        ok = False
        continue
    n = w.value * h.value * 4
    buf = ctypes.string_at(pix, n)
    lib.lp_pixels_free(pix)
    # 统计非黑像素
    step = 4 * 37  # 抽样
    total = 0
    bright = 0
    for i in range(0, n - 3, step):
        total += 1
        if buf[i] > 8 or buf[i + 1] > 8 or buf[i + 2] > 8:
            bright += 1
    cx = ((h.value // 2) * w.value + w.value // 2) * 4
    print("OK   %s" % label)
    print("  %dx%d bytes=%d non_black=%d/%d (%.1f%%) center_rgba=(%d, %d, %d, %d)"
          % (w.value, h.value, n, bright, total, 100.0 * bright / max(total, 1),
             buf[cx], buf[cx + 1], buf[cx + 2], buf[cx + 3]))

sys.exit(0 if ok else 1)
