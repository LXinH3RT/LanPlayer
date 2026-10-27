#!/usr/bin/env python3
"""Build the native core (and its SMB transport) for Windows x64.

    python scripts/build_windows.py
    python scripts/build_windows.py --clean --run-smoke --smoke-media build/media/clip.mp4
    python scripts/build_windows.py --deploy-to app/build/windows/x64/runner/Release

Toolchain: Zig ships a complete clang + mingw-w64 libc + lld and can link the
MinGW import libraries of the official FFmpeg Windows build, so no Visual
Studio or MSYS2 is required.  Threads/mutexes come from
native/src/platform/desktop/win32_pthread.h; libsmb2 gets the shim headers in
native/platform/win32/smb2/.
"""
from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402

BASE_FLAGS = [
    "-target", "x86_64-windows-gnu",
    "-std=gnu11",
    "-O2",
    "-g0",
    "-fno-strict-aliasing",
    "-Wall",
    "-Wno-unused-parameter",
    "-Wno-unused-variable",
    "-Wno-deprecated-declarations",
    "-Wno-microsoft-anon-tag",
    "-Wno-unused-function",
]

CORE_SOURCES = [
    "src/util/lp_str.c",
    "src/util/lp_log.c",
    "src/core/queue.c",
    "src/core/audio_ring.c",
    "src/core/nal.c",
    "src/core/demux.c",
    "src/core/video.c",
    "src/core/audio.c",
    "src/core/subtitle.c",
    "src/core/submatch.c",
    "src/core/thumb.c",
    "src/core/player.c",
    "src/source/url.c",
    "src/source/io.c",
    "src/source/smb.c",
    "src/source/file.c",
]

STUB_SOURCE = "src/platform/stub/stub_platform.c"

# win32_platform.c is the framework adapter (renderer + audio); the D3D11VA
# decoder is a second translation unit because it is the only one that touches
# libavcodec's hardware path.
WIN32_SOURCES = [
    "src/platform/win32/win32_platform.c",
    "src/platform/win32/d3d11va_decoder.c",
    "src/app/lp_preview.c",
]


class Zig:
    def __init__(self, exe: Path):
        self.exe = exe

    def run(self, args: list[str], label: str) -> bool:
        cmd = [str(self.exe), *args]
        result = lp.run(cmd, check=False, capture=True,
                        env=lp.isolated_env({"ZIG_GLOBAL_CACHE_DIR": str(lp.TOOLS / "zig-cache"),
                                             "ZIG_LOCAL_CACHE_DIR": str(lp.TOOLS / "zig-cache-local")},
                                            home=False))
        text = (result.stdout or "") + (result.stderr or "")
        if result.returncode != 0:
            print(f"\n--- {label} FAILED ---")
            print(text)
            return False
        if text.strip() and os.environ.get("LP_VERBOSE"):
            print(text)
        return True


def find_tool(base: Path, name: str) -> Path:
    if not base.is_dir():
        raise lp.ScriptError(f"missing {base} - run: python tool/fetch_deps.py")
    for path in base.rglob(name):
        if path.is_file():
            return path
    raise lp.ScriptError(f"missing {name} under {base} - run: python tool/fetch_deps.py")


def build_smb2(root: Path, tools: Path, native: Path, out: Path, zig: Zig) -> Path | None:
    smb2_root = tools / "libsmb2"
    if not (smb2_root / "lib").is_dir():
        print("\n== libsmb2 skipped (run: python tool/fetch_deps.py libsmb2)")
        return None

    print("\n== libsmb2 (SMB2/3 transport)")
    smb2_out = out / "smb2"
    smb2_out.mkdir(parents=True, exist_ok=True)
    shim = native / "platform" / "win32" / "smb2"
    flags = [
        "cc", *BASE_FLAGS,
        "-c",
        f"-I{shim}",
        f"-I{smb2_root / 'include'}",
        f"-I{smb2_root / 'include' / 'smb2'}",
        "-DHAVE_CONFIG_H",
        "-DWIN32_LEAN_AND_MEAN",
        "-D_CRT_SECURE_NO_WARNINGS",
        "-D_CRT_NONSTDC_NO_DEPRECATE",
        "-D_FILE_OFFSET_BITS=64",
        "-D_U_=__attribute__((unused))",
        "-include", "win32_compat.h",
        "-Wno-implicit-int",
    ]

    # mingw compatibility: upstream decides between WSAGetLastError() and errno
    # after a non-blocking connect() with `#ifndef _MSC_VER`.  Under mingw
    # _MSC_VER is undefined, so it compares errno against EINPROGRESS and every
    # connect looks like a failure ("Connect failed with errno : No error(0)").
    # Branch on _WIN32 instead - identical for MSVC, correct for mingw and POSIX.
    socket_c = smb2_root / "lib" / "socket.c"
    if socket_c.is_file():
        source = socket_c.read_text(encoding="utf-8", errors="replace")
        if "#ifndef _MSC_VER" in source:
            socket_c.write_bytes(source.replace("#ifndef _MSC_VER", "#if !defined(_WIN32)")
                                 .encode("utf-8"))
            lp.warn("patched lib/socket.c (mingw non-blocking connect)")

    sources = sorted(p for p in (smb2_root / "lib").glob("*.c") if "test" not in p.name)
    objects: list[str] = []
    failed = 0
    for src in sources:
        obj = smb2_out / (src.stem + ".o")
        objects.append(str(obj))
        if not zig.run([*flags, str(src), "-o", str(obj)], src.name):
            failed += 1

    if failed:
        lp.warn(f"{failed} file(s) failed; continuing without SMB")
        return None

    lib = smb2_out / "libsmb2.a"
    if not zig.run(["ar", "rcs", str(lib), *objects], "libsmb2.a"):
        return None
    print(f"   {len(sources)} files -> libsmb2.a")
    return lib


def compile_objects(zig: Zig, native: Path, out: Path, sources: list[str],
                    includes: list[str], defines: list[str], suffix: str) -> tuple[list[str], int]:
    objects: list[str] = []
    bad = 0
    for src in sources:
        full = native / src
        obj = out / (src.replace("\\", "/").replace("/", "_").removesuffix(".c") + f"{suffix}.o")
        objects.append(str(obj))
        print(f"   {src}")
        if not zig.run(["cc", *BASE_FLAGS, *defines, *includes, "-c", str(full), "-o", str(obj)], src):
            bad += 1
    if bad:
        lp.warn(f"{bad} file(s) failed")
    return objects, bad


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--clean", action="store_true")
    parser.add_argument("--run-smoke", action="store_true")
    parser.add_argument("--smoke-media", default="")
    parser.add_argument("--smoke-seconds", type=int, default=5)
    parser.add_argument("--no-smb", action="store_true")
    parser.add_argument("--deploy-to", default="",
                        help="copy lanplayer.dll + the FFmpeg DLLs here (e.g. the Flutter output folder)")
    args = parser.parse_args()

    root = lp.ROOT
    tools = lp.TOOLS
    native = root / "native"
    out = root / "build" / "win-x64"

    (tools / "zig-cache").mkdir(parents=True, exist_ok=True)
    (tools / "zig-cache-local").mkdir(parents=True, exist_ok=True)

    zig_exe = find_tool(tools / "zig", "zig.exe")
    ffmpeg_header = find_tool(tools / "ffmpeg", "avformat.h")
    ffmpeg_root = ffmpeg_header.parent.parent.parent
    ffmpeg_lib = ffmpeg_root / "lib"
    ffmpeg_bin = ffmpeg_root / "bin"
    print(f"zig    : {zig_exe}")
    print(f"ffmpeg : {ffmpeg_root}")

    if args.clean and out.is_dir():
        shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True, exist_ok=True)

    zig = Zig(zig_exe)

    smb2_lib = None if args.no_smb else build_smb2(root, tools, native, out, zig)

    includes = [f"-I{native / 'include'}", f"-I{native / 'src'}", f"-I{native / 'src' / 'source'}",
                f"-I{ffmpeg_root / 'include'}"]
    defines = ["-DLP_ENABLE_HTTP=1", "-D_FILE_OFFSET_BITS=64", "-D_CRT_SECURE_NO_WARNINGS"]
    if smb2_lib:
        smb2_root = tools / "libsmb2"
        # The shim directory provides <poll.h> and friends that libsmb2 expects
        # inside our own sources as well.
        includes.append(f"-I{native / 'platform' / 'win32' / 'smb2'}")
        includes.append(f"-I{smb2_root / 'include'}")
        # libsmb2's own headers include each other flat (<libsmb2.h>), same as
        # when building the library itself.
        includes.append(f"-I{smb2_root / 'include' / 'smb2'}")
        defines.append("-DLP_HAVE_SMB2=1")

    print("\n== compiling core")
    core_objects, bad = compile_objects(zig, native, out, CORE_SOURCES, includes, defines, "")
    if bad:
        return 1
    print(f"   {len(CORE_SOURCES)} core sources compiled")

    print("\n== compiling platform adapters")
    stub_objects, bad = compile_objects(zig, native, out, [STUB_SOURCE], includes, defines, ".stub")
    if bad:
        return 1
    win32_objects, bad = compile_objects(zig, native, out, WIN32_SOURCES, includes, defines, ".win32")
    if bad:
        return 1
    win32_platform_only, win32_hw_only, win32_preview_only = win32_objects

    ff_libs = sorted(str(p) for p in ffmpeg_lib.glob("lib*.dll.a"))
    if not ff_libs:
        ff_libs = sorted(str(p) for p in ffmpeg_lib.glob("*.lib") if not p.name.endswith(".def"))
    if not ff_libs:
        raise lp.ScriptError(f"no import libraries under {ffmpeg_lib}")

    print(f"\n== linking (ffmpeg import libs: {len(ff_libs)})")
    lib_tail = list(ff_libs)
    if smb2_lib:
        lib_tail += [str(smb2_lib), "-lws2_32"]

    # The shipped DLL carries the real Windows output adapter (GDI target +
    # waveOut), so a Flutter desktop host gets video and audio from
    # liblanplayer.dll directly.
    print("   lanplayer.dll (win32 platform)")
    dll_link = ["cc", *BASE_FLAGS, *core_objects, win32_platform_only, win32_hw_only, *lib_tail,
                "-luser32", "-lgdi32", "-lwinmm"]
    if not zig.run([*dll_link, "-shared", "-o", str(out / "lanplayer.dll")], "lanplayer.dll"):
        return 1

    # Headless build for CI: same core with the null platform adapter.
    dll_stub_link = ["cc", *BASE_FLAGS, *core_objects, *stub_objects, *lib_tail]
    print("   lanplayer_stub.dll (null output, CI only)")
    if not zig.run([*dll_stub_link, "-shared", "-o", str(out / "lanplayer_stub.dll")], "lanplayer_stub.dll"):
        return 1

    def build_test(name: str, source: Path, label: str, extra_link: list[str] | None = None,
                   extra_includes: list[str] | None = None) -> bool:
        print(f"   {name}")
        obj = out / (name.removesuffix(".exe") + ".o")
        cmd = ["cc", *BASE_FLAGS, *(extra_includes or defines + includes), "-c", str(source), "-o", str(obj)]
        if not zig.run(cmd, label):
            return False
        return zig.run([*(extra_link or dll_stub_link), str(obj), "-o", str(out / name),
                        "-Wl,--subsystem,console"], name)

    # Thumbnail path regression: opening a folder full of .flv used to hang
    # forever (cache-boundary spin in lp_io_read + av_seek_frame given
    # microseconds instead of stream ticks).  This binary asserts every cover
    # comes back in bounded time and with real pixels.  Same for the junk
    # filter, which keeps .DS_Store / ._foo / desktop.ini out of a listing.
    if not build_test("lp_smoke_test.exe", native / "tests" / "lp_smoke_test.c", "smoke test"):
        return 1
    if not build_test("lp_thumb_test.exe", native / "tests" / "lp_thumb_test.c", "thumb test"):
        return 1
    if not build_test("lp_junk_test.exe", native / "tests" / "lp_junk_test.c", "junk test"):
        return 1

    # 外挂字幕的配对规则：同主干、同集数、去掉发布组/语言标签后对得上都算，
    # 但异集和跨语言片名必须判否。用例取自真实片库，规则退化了这里会先红。
    if not build_test("lp_submatch_test.exe", native / "tests" / "lp_submatch_test.c",
                      "submatch test"):
        return 1

    # Loads lanplayer.dll at runtime and drives the texture path, exactly like
    # the Flutter Windows plugin does.  It also compiles the plugin's own
    # BGRA->RGBA header, so a regression in that conversion fails here instead
    # of turning the picture blue in the app.
    print("   lp_win32_texture_test.exe")
    tex_obj = out / "lp_win32_texture_test.o"
    plugin_includes = [f"-I{root / 'packages' / 'lanplayer_video' / 'windows' / 'include'}"]
    if not zig.run(["cc", *BASE_FLAGS, *plugin_includes, "-c",
                    str(native / "tests" / "lp_win32_texture_test.c"), "-o", str(tex_obj)],
                   "texture test"):
        return 1
    if not zig.run(["cc", *BASE_FLAGS, str(tex_obj), "-o", str(out / "lp_win32_texture_test.exe"),
                    "-Wl,--subsystem,console"], "lp_win32_texture_test.exe"):
        return 1

    # Opens media through hw=auto and asserts the core really picked D3D11VA.
    # The core falls back to software silently (a warning in the log only), so a
    # broken hardware decoder still produces a perfect picture - this is what
    # catches it.
    print("   lp_hw_decode_test.exe")
    hw_obj = out / "lp_hw_decode_test.o"
    if not zig.run(["cc", *BASE_FLAGS, *defines, *includes, "-c",
                    str(native / "tests" / "lp_hw_decode_test.c"), "-o", str(hw_obj)], "hw decode test"):
        return 1
    if not zig.run(["cc", *BASE_FLAGS, str(hw_obj), "-o", str(out / "lp_hw_decode_test.exe"),
                    "-Wl,--subsystem,console"], "lp_hw_decode_test.exe"):
        return 1

    preview_link = ["cc", *BASE_FLAGS, *core_objects, win32_platform_only, win32_hw_only,
                    win32_preview_only, *lib_tail,
                    "-luser32", "-lgdi32", "-lwinmm", "-lcomdlg32", "-lshell32", "-lole32"]
    print("   lanplayer_preview.exe (GUI)")
    if not zig.run([*preview_link, "-o", str(out / "lanplayer_preview.exe"), "-Wl,--subsystem,windows"],
                   "lanplayer_preview.exe"):
        return 1
    # Same player, console subsystem: blocks the caller and prints its report,
    # which is what the automated checks (and --selftest) use.
    print("   lanplayer_preview_c.exe (console, for tests)")
    if not zig.run([*preview_link, "-o", str(out / "lanplayer_preview_c.exe"), "-Wl,--subsystem,console"],
                   "lanplayer_preview_c.exe"):
        return 1

    for dll in ffmpeg_bin.glob("*.dll"):
        shutil.copy2(dll, out / dll.name)

    print(f"\n== artifacts in {out}")
    for path in sorted(out.iterdir()):
        if path.suffix in (".exe", ".dll") and path.is_file():
            print(f"   {path.name:<24} {path.stat().st_size / 1024:8.0f} KiB")

    if args.deploy_to:
        dest = Path(args.deploy_to)
        dest.mkdir(parents=True, exist_ok=True)
        shutil.copy2(out / "lanplayer.dll", dest / "lanplayer.dll")
        for dll in ffmpeg_bin.glob("*.dll"):
            shutil.copy2(dll, dest / dll.name)
        print(f"\n== deployed to {dest}")
        for dll in sorted(dest.glob("*.dll")):
            print(f"   {dll.name}")

    if args.run_smoke:
        exe = out / "lp_smoke_test.exe"
        env = dict(os.environ)
        env["PATH"] = f"{out}{os.pathsep}{env.get('PATH', '')}"
        if args.smoke_media and Path(args.smoke_media).exists():
            media = Path(args.smoke_media).resolve()
            print(f"\n== smoke test on {media}")
            rc = lp.run([str(exe), str(media), str(args.smoke_seconds)], check=False, env=env,
                        capture=False)
        else:
            print("\n== smoke test (library load + ABI only)")
            rc = lp.run([str(exe)], check=False, env=env, capture=False)
        print(f"\n   exit={rc.returncode}")
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
