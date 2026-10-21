"""列 SMB 目录，找真实视频路径供缩略图探针使用。"""
import ctypes
import json
import sys

DLL = r"D:\repo\LanPlayer\build\win-x64\lanplayer.dll"


def main() -> int:
    lib = ctypes.CDLL(DLL)
    lib.lp_source_list.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    lib.lp_source_list.restype = ctypes.c_int32
    lib.lp_string_free.argtypes = [ctypes.c_void_p]
    lib.lp_string_free.restype = None

    url = sys.argv[1]
    options = None
    if len(sys.argv) > 3:
        options = json.dumps({"user": sys.argv[2], "password": sys.argv[3]}).encode()

    out = ctypes.c_void_p()
    rc = lib.lp_source_list(url.encode(), options, ctypes.byref(out))
    if rc != 0 or not out.value:
        print(f"rc={rc} list failed")
        return 1
    try:
        data = json.loads(ctypes.string_at(out).decode("utf-8", "replace"))
    finally:
        lib.lp_string_free(out)

    for entry in data.get("entries", []):
        kind = "DIR " if entry["is_dir"] else "file"
        print(f"  {kind} {entry['path']}  ({entry.get('size', 0)} B)")
    print(f"total {len(data.get('entries', []))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
