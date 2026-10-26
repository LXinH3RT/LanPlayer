#!/usr/bin/env python3
"""Build the Flutter Windows desktop app WITHOUT the flutter tool.

Why: the flutter CLI needs to spawn child processes with piped stdio, which
fails in restricted environments (and it insists on MSVC anyway).  This script
reproduces what `flutter build windows` does, step by step, using only:

  * dart pub get                 (dependency resolution)
  * the engine's frontend_server (Dart -> kernel)
  * cl.exe / link.exe            (runner + plugin, via scripts/msvc_chain.py)
  * the engine artifacts         (flutter_windows.dll, icudtl.dat, wrapper sources)

Output is a DEBUG-style build: the debug engine runs data/flutter_assets/
kernel_blob.bin (JIT).  `flutter build windows --release` produces the AOT
variant; use that when the flutter tool is available.

    python scripts/build_windows_app.py
    python scripts/build_windows_app.py --out build/win-app --clean
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402

ENGINE_FILES = [
    "flutter_windows.dll", "flutter_windows.dll.lib", "flutter_windows.dll.exp",
    "flutter_windows.dll.pdb", "flutter_export.h", "flutter_messenger.h",
    "flutter_plugin_registrar.h", "flutter_texture_registrar.h", "flutter_windows.h",
    "icudtl.dat",
]


def need(path: Path, hint: str) -> None:
    if not path.exists():
        raise lp.ScriptError(f"missing {path} - {hint}")


def pub_get(dart: Path, app: Path, env: dict[str, str]) -> None:
    if (app / ".dart_tool" / "package_config.json").exists():
        print("== pub get: cached")
        return
    print("== dart pub get")
    lp.run([str(dart), "pub", "get"], cwd=app, env=env)


def write_ephemeral(eph: Path, artifacts: Path, build_root: Path, root: Path) -> None:
    print("== ephemeral engine files")
    eph.mkdir(parents=True, exist_ok=True)
    for name in ENGINE_FILES:
        source = artifacts / name
        if source.exists():
            shutil.copy2(source, eph / name)
    if not (eph / "cpp_client_wrapper").exists():
        shutil.copytree(artifacts / "cpp_client_wrapper", eph / "cpp_client_wrapper")

    # A no-op tool_backend keeps flutter_assemble harmless if someone runs CMake.
    stub = build_root / "flutter-verify" / "stub-root" / "packages" / "flutter_tools" / "bin"
    stub.mkdir(parents=True, exist_ok=True)
    lp.write_text(stub / "tool_backend.bat", "@echo off\r\nexit /b 0\r\n", newline="")

    config = "\n".join([
        "# Written by scripts/build_windows_app.py for offline builds.",
        f'set(FLUTTER_ROOT "{(root / "build" / "flutter-verify" / "stub-root").as_posix()}")',
        'set(FLUTTER_TARGET_PLATFORM "windows-x64")',
        'set(EPHEMERAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}")',
        'set(FLUTTER_VERSION "3.27.4")',
        "set(FLUTTER_VERSION_MAJOR 3)",
        "set(FLUTTER_VERSION_MINOR 27)",
        "set(FLUTTER_VERSION_PATCH 4)",
        "set(FLUTTER_VERSION_BUILD 0)",
        "",
    ])
    lp.write_text(eph / "generated_config.cmake", config, newline="")

    links = eph / ".plugin_symlinks"
    links.mkdir(parents=True, exist_ok=True)
    link = links / "lanplayer_video"
    if not link.exists():
        # A junction, not a symlink: creating a symlink needs a privilege a plain
        # user token does not have.
        lp.run(["cmd", "/c", "mklink", "/J", str(link), str(root / "packages" / "lanplayer_video")])


def copy_runtime(out: Path, artifacts: Path, fs: Path, skip_kernel: bool, app: Path,
                 dart_sdk: Path, patched: Path) -> None:
    assets = out / "data" / "flutter_assets"
    (assets / "fonts").mkdir(parents=True, exist_ok=True)
    icu = artifacts / "icudtl.dat"
    if icu.exists():
        shutil.copy2(icu, out / "data" / "icudtl.dat")
    shutil.copy2(artifacts / "flutter_windows.dll", out / "flutter_windows.dll")

    fonts = fs / "bin" / "cache" / "artifacts" / "material_fonts"
    shutil.copy2(fonts / "materialicons-regular.otf", assets / "fonts" / "MaterialIcons-Regular.otf")
    (assets / "FontManifest.json").write_text(
        '[{"family":"MaterialIcons","fonts":[{"asset":"fonts/MaterialIcons-Regular.otf"}]}]',
        encoding="utf-8", newline="")

    dill = assets / "app.dill"
    if not skip_kernel:
        print("== dart -> kernel")
        env = dict(os.environ)
        result = subprocess.run(
            [str(dart_sdk / "bin" / "dartaotruntime.exe"),
             str(dart_sdk / "bin" / "snapshots" / "frontend_server_aot.dart.snapshot"),
             "--sdk-root", str(patched), "--target=flutter",
             "--packages", str(app / ".dart_tool" / "package_config.json"),
             "--output-dill", str(dill), str(app / "lib" / "main.dart")],
            env=env, text=True, capture_output=True, encoding="utf-8", errors="replace",
        )
        (out / "kernel.log").write_text((result.stdout or "") + (result.stderr or ""),
                                        encoding="utf-8", errors="replace")
        if result.returncode != 0:
            errors = [line for line in (result.stderr or "").splitlines() if ": Error:" in line][:20]
            for line in errors:
                print(line)
            raise lp.ScriptError("Dart compilation failed (see the errors above)")
    shutil.copy2(dill, assets / "kernel_blob.bin")


def deploy_core(root: Path, out: Path) -> None:
    native_out = root / "build" / "win-x64"
    if not (native_out / "lanplayer.dll").exists():
        lp.warn("lanplayer.dll missing: run scripts/build_windows.py first")
        return
    shutil.copy2(native_out / "lanplayer.dll", out / "lanplayer.dll")
    for dll in native_out.iterdir():
        if dll.suffix == ".dll" and (dll.name.startswith("av") or dll.name.startswith("sw")):
            shutil.copy2(dll, out / dll.name)
    print("== core + ffmpeg DLLs deployed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="", help="output directory (default: build/win-app)")
    parser.add_argument("--clean", action="store_true")
    parser.add_argument("--skip-kernel", action="store_true")
    args = parser.parse_args()

    root = lp.ROOT
    fs = lp.TOOLS / "flutter-sdk"
    dart_sdk = fs / "bin" / "cache" / "dart-sdk"
    artifacts = fs / "bin" / "cache" / "artifacts" / "engine" / "windows-x64"
    patched = fs / "bin" / "cache" / "artifacts" / "engine" / "common" / "flutter_patched_sdk"
    app = root / "app"
    eph = app / "windows" / "flutter" / "ephemeral"
    out = Path(args.out) if args.out else root / "build" / "win-app"

    need(dart_sdk / "bin" / "dart.exe", "run: python tool/fetch_deps.py flutter")
    need(artifacts / "flutter_windows.dll", "flutter SDK engine artifacts are incomplete")

    if args.clean and out.is_dir():
        shutil.rmtree(out)
    out.mkdir(parents=True, exist_ok=True)

    # Flutter, the pub cache and Gradle all write into %APPDATA%/%PUB_CACHE%;
    # redirecting them keeps a build from touching the developer's profile.
    env = lp.isolated_env({"FLUTTER_ROOT": str(fs)})
    pub_get(dart_sdk / "bin" / "dart.exe", app, env)

    write_ephemeral(eph, artifacts, root / "build", root)

    print("== runner + plugin (MSVC)")
    lp.run([lp.find_python(), str(lp.SCRIPTS / "msvc_chain.py"), str(out)], env=env)

    copy_runtime(out, artifacts, fs, args.skip_kernel, app, dart_sdk, patched)
    deploy_core(root, out)

    print(f"\n== ready: {out / 'lanplayer.exe'}")
    print("   run it, or capture a screenshot:")
    print(f"   python scripts/capture_window.py --exe \"{out / 'lanplayer.exe'}\"")
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
