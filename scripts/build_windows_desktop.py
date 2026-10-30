#!/usr/bin/env python3
"""Build the Flutter Windows desktop app with CMake + MSBuild, in ONE command.

    python scripts/build_windows_desktop.py
    python scripts/build_windows_desktop.py --core          # also rebuild lanplayer.dll (Zig)
    python scripts/build_windows_desktop.py --run           # start the app when ready

Why not `flutter build windows`?  Two host-specific facts:

 1. flutter_tools emits a CMake generator from a hard-coded switch
    (windows/visual_studio.dart: 17 => "Visual Studio 17 2022", _ => "Visual
    Studio 16 2019").  On Visual Studio 18 (the version installed here) it picks
    16 2019, which is not installed, so configure fails with "Generator Visual
    Studio 16 2019 could not find any instance of Visual Studio".
 2. `flutter pub get` wants to create plugin symlinks (SeCreateSymbolicLink
    privilege).  A plain user token does not have it.

This script does the same work with the generators/libs that DO exist here:
scripts/fix_plugin_links.py (junctions instead of symlinks) + the CMake that
ships inside Visual Studio.

Everything it produces lands next to the exe: lanplayer.exe,
lanplayer_video_plugin.dll, lanplayer.dll, flutter_windows.dll, av*/sw* DLLs,
data/icudtl.dat, data/flutter_assets/...  Release builds compile the Dart code
AOT into data/app.so; either way the bundle is self-contained.
"""
from __future__ import annotations

import argparse
import base64
import os
import re
import shutil
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


def find_visual_studio() -> Path:
    configured = os.environ.get("LP_VS_DIR")
    if configured:
        return Path(configured)

    vswhere_paths = []
    for base in (os.environ.get("ProgramFiles(x86)"), os.environ.get("ProgramFiles")):
        if base:
            vswhere_paths.append(Path(base) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe")
    for vswhere in vswhere_paths:
        if not vswhere.exists():
            continue
        found = lp.output([str(vswhere), "-latest", "-products", "*",
                           "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                           "-property", "installationPath"])
        if found:
            return Path(found.strip())
    raise lp.ScriptError('no Visual Studio with the C++ toolset found '
                         '(install "Desktop development with C++")')


def vs_major(vs: Path) -> int:
    """The generator number: VS 18 lives in a directory literally named 18."""
    match = re.fullmatch(r"(\d{1,2})", vs.name)
    if match:
        return int(match.group(1))

    for vswhere in (Path(os.environ.get("ProgramFiles(x86)", "")) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe",
                    Path(os.environ.get("ProgramFiles", "")) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"):
        if not vswhere.exists():
            continue
        version = lp.output([str(vswhere), "-latest", "-products", "*", "-property", "installationVersion"])
        match = re.match(r"(\d+)", version or "")
        if match:
            return int(match.group(1))
    raise lp.ScriptError("cannot determine the Visual Studio version")


def generator_for(cmake: Path, major: int) -> str:
    """The CMake generator name matching the installed Visual Studio."""
    text = lp.output([str(cmake), "--help"])
    pattern = re.compile(rf"^\s*\*?\s*(Visual Studio {major}\s+\d{{4}})(?!\d)", re.M)
    match = pattern.search(text)
    if not match:
        raise lp.ScriptError(f"cmake has no generator for Visual Studio {major}")
    return match.group(1).strip()


def read_version(app: Path, override: str = "") -> tuple[str, tuple[int, int, int, int]]:
    """The x.y.z+build line from app/pubspec.yaml.

    Runner.rc turns FLUTTER_VERSION into the exe's FileVersion/ProductVersion, so
    a stale literal makes every release claim the previous one and the
    installer's "currently installed" check compares the wrong numbers.

    A version like `0.1.8-local.3` is also accepted: local builds should not
    bump app/pubspec.yaml, they pass `--version` instead (see §8.0 in the
    working notes). Only the leading digits go into the numeric fields.
    """
    text = ""
    if override:
        text = override.strip()
    else:
        spec = app / "pubspec.yaml"
        if not spec.exists():
            return "0.1.0+1", (0, 1, 0, 1)
        for line in spec.read_text(encoding="utf-8").splitlines():
            match = re.match(r"^\s*version:\s*(\S+)\s*$", line)
            if match:
                text = match.group(1)
                break
    # 「0.1.8-local.3」这类本地号只取前三段数字给 FileVersion，字符串字段原样保留，
    # 这样「关于」里显示的就是你指定的那个本地号。
    # Runner.rc 只在四个数字都给齐时才用 FLUTTER_VERSION，缺一个就退回
    # "1.0.0"，所以这里返回的字符串必须是带 +build 的完整形式。
    match = re.match(r"^([0-9]+)\.([0-9]+)\.([0-9]+)(?:\+([0-9]+))?", text)
    if not match:
        return "0.1.0+1", (0, 1, 0, 1)
    major, minor, patch = (int(match.group(i)) for i in (1, 2, 3))
    build = int(match.group(4)) if match.group(4) else 0
    return text or f"{major}.{minor}.{patch}+{build}", (major, minor, patch, build)


def write_generated_config(eph: Path, fs: Path, app: Path, version: str,
                           parts: tuple[int, int, int, int], dart_defines: list[str]) -> None:
    """Write the same variables flutter_tools writes (lib/src/cmake.dart).

    A hand-written stub is not enough: app/windows/flutter/CMakeLists.txt passes
    ${FLUTTER_TOOL_ENVIRONMENT} to tool_backend.bat, which exits with "PROJECT_DIR
    environment variable must be set to the location of Flutter project to be
    built." and MSBuild reports MSB8066 on the flutter_windows.dll rule.

    DART_DEFINES is a comma-separated list where EACH entry is base64 of one
    "key=value" string - not base64 of a JSON list.  See
    flutter_tools/lib/src/build_info.dart: encodeDartDefines() maps
    utf8.fuse(base64) over the list and joins on ','.  Encoding the whole list as
    JSON is the obvious-looking mistake and fails silently: the tool decodes one
    garbage entry, the define never reaches String.fromEnvironment, and the app
    starts normally with no indication that the flag was dropped.
    """
    encoded = ",".join(base64.b64encode(item.encode("utf-8")).decode("ascii") for item in dart_defines)
    # Always rewrite: the content embeds absolute paths, so a stale copy from
    # another checkout is wrong.
    major, minor, patch, build = parts
    text = "\n".join([
        "# Generated code do not commit.",
        f'file(TO_CMAKE_PATH "{fs.as_posix()}" FLUTTER_ROOT)',
        f'file(TO_CMAKE_PATH "{app.as_posix()}" PROJECT_DIR)',
        "",
        f'set(FLUTTER_VERSION "{version}" PARENT_SCOPE)',
        f"set(FLUTTER_VERSION_MAJOR {major} PARENT_SCOPE)",
        f"set(FLUTTER_VERSION_MINOR {minor} PARENT_SCOPE)",
        f"set(FLUTTER_VERSION_PATCH {patch} PARENT_SCOPE)",
        f"set(FLUTTER_VERSION_BUILD {build} PARENT_SCOPE)",
        "",
        "# Environment variables to pass to tool_backend.bat",
        "list(APPEND FLUTTER_TOOL_ENVIRONMENT",
        f'  "FLUTTER_ROOT={fs.as_posix()}"',
        f'  "PROJECT_DIR={app.as_posix()}"',
        f'  "FLUTTER_EPHEMERAL_DIR={eph.as_posix()}"',
        '  "FLUTTER_TARGET=lib/main.dart"',
        f'  "DART_DEFINES={encoded}"',
        '  "DART_OBFUSCATION=false"',
        '  "TRACK_WIDGET_CREATION=true"',
        '  "TREE_SHAKE_ICONS=true"',
        f'  "PACKAGE_CONFIG={(app / ".dart_tool" / "package_config.json").as_posix()}"',
        ")",
        "",
    ])
    lp.write_text(eph / "generated_config.cmake", text, newline="")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default="Release", help="CMake configuration (default: Release)")
    parser.add_argument("--core", action="store_true", help="also rebuild lanplayer.dll first (Zig)")
    parser.add_argument("--run", action="store_true", help="start the built app when it is ready")
    parser.add_argument("--clean", action="store_true")
    parser.add_argument("--reconfigure", action="store_true")
    parser.add_argument("--flutter-root", default="",
                        help="Flutter SDK location (default: $FLUTTER_ROOT, else .tools/flutter-sdk)")
    parser.add_argument("--no-env-redirect", action="store_true",
                        help="keep the real APPDATA/TEMP/PUB_CACHE (needed on CI, where the "
                             "Flutter action already populated them)")
    parser.add_argument("--dart-defines", action="append", default=[],
                        help="extra --dart-define value, e.g. --dart-defines LANPLAYER_UI=add-server")
    parser.add_argument("--version", default="",
                        help="override the version stamped into the exe (default: app/pubspec.yaml). "
                             "Local builds should pass a local tag like 0.1.8-local.3 instead of "
                             "bumping pubspec, which only moves when a real GitHub release ships")
    args = parser.parse_args()

    root = lp.ROOT
    app = root / "app"
    win_dir = app / "windows"
    eph = win_dir / "flutter" / "ephemeral"
    fs = Path(args.flutter_root or os.environ.get("FLUTTER_ROOT") or (lp.TOOLS / "flutter-sdk"))
    fs = Path(str(fs).rstrip("\\/"))

    if not (fs / "bin" / "cache" / "dart-sdk" / "bin" / "dart.exe").exists():
        raise lp.ScriptError("Flutter SDK missing - run: python tool/fetch_deps.py flutter")
    if not (win_dir / "CMakeLists.txt").exists():
        raise lp.ScriptError("app/windows missing - run: python scripts/gen_windows_runner.py")

    vs = find_visual_studio()
    cmake = vs / "Common7" / "IDE" / "CommonExtensions" / "Microsoft" / "CMake" / "CMake" / "bin" / "cmake.exe"
    if not cmake.exists():
        raise lp.ScriptError(f"cmake.exe not found under {vs}")
    major = vs_major(vs)
    generator = generator_for(cmake, major)

    print(f"visual studio : {vs}")
    print(f"cmake         : {cmake}")
    print(f"generator     : {generator}")

    print("\n== plugin links")
    lp.run([lp.find_python(), str(lp.SCRIPTS / "fix_plugin_links.py")])

    # flutter_assemble (a CMake custom target) runs the flutter tool, which
    # writes under %APPDATA%\.flutter_tool_state and %TEMP%; both are redirected
    # into the repo so the build works where profile directories are not
    # writable.  --no-env-redirect keeps the real ones for CI.
    env = dict(os.environ)
    if not args.no_env_redirect:
        env = lp.isolated_env()
        cfg = lp.ensure_dir(lp.TOOLS / "flutter-cfg")
        # The flutter tool writes here; PUB_CACHE must survive the isolated_env
        # defaults only when a caller already populated one.
        env["APPDATA"] = str(cfg)
        env["LOCALAPPDATA"] = str(cfg)
    env["FLUTTER_ROOT"] = str(fs)

    native_out = root / "build" / "win-x64"
    if args.core:
        print("\n== native core (Zig)")
        lp.run([lp.find_python(), str(lp.SCRIPTS / "build_windows.py")], env=env)
    if not (native_out / "lanplayer.dll").exists():
        raise lp.ScriptError("build/win-x64/lanplayer.dll missing - run: "
                             "python scripts/build_windows.py")

    artifacts = fs / "bin" / "cache" / "artifacts" / "engine" / "windows-x64"
    if not (artifacts / "flutter_windows.dll").exists():
        raise lp.ScriptError("FLUTTER_ROOT engine artifacts are incomplete")
    if not (eph / "flutter_windows.dll").exists():
        print("\n== ephemeral engine files")
        eph.mkdir(parents=True, exist_ok=True)
        for name in ENGINE_FILES:
            source = artifacts / name
            if source.exists():
                shutil.copy2(source, eph / name)
        if not (eph / "cpp_client_wrapper").exists():
            shutil.copytree(artifacts / "cpp_client_wrapper", eph / "cpp_client_wrapper")

    version, parts = read_version(app, args.version)
    # 「关于」里要显示版本号。pubspec 是唯一来源，但 Dart 读不到它，只能用
    # --dart-define 注入；只取 x.y.z，不带 +build。
    dart_defines = list(args.dart_defines)
    short = version.split("+", 1)[0]
    if not any(d.startswith("LANPLAYER_VERSION=") for d in dart_defines):
        dart_defines.append(f"LANPLAYER_VERSION={short}")
    if dart_defines:
        print(f"\n== dart-define: {' '.join(dart_defines)}")
    print(f"\n== version: {version}"
          f"{'' if args.version else ' (from app/pubspec.yaml)'}")
    write_generated_config(eph, fs, app, version, parts, dart_defines)

    build_dir = win_dir / "out" / "build" / f"x64-{re.sub(r'\\s+', '', generator)}"
    if args.clean and build_dir.is_dir():
        shutil.rmtree(build_dir, ignore_errors=True)

    print(f"\n== cmake configure ({generator})")
    configure = [str(cmake), "-G", generator, "-A", "x64", "-S", str(win_dir), "-B", str(build_dir)]
    if args.reconfigure and build_dir.is_dir():
        configure.insert(1, "--fresh")
    lp.run(configure, env=env)

    print(f"\n== cmake build ({args.config}, target INSTALL)")
    lp.run([str(cmake), "--build", str(build_dir), "--config", args.config, "--target", "INSTALL"],
           env=env)

    # INSTALL lays out the bundle next to the exe; the FFI core and FFmpeg are ours.
    bundle = build_dir / "runner" / args.config
    if not (bundle / "lanplayer.exe").exists():
        raise lp.ScriptError(f"runner exe missing in {bundle}")
    shutil.copy2(native_out / "lanplayer.dll", bundle / "lanplayer.dll")
    for dll in native_out.iterdir():
        if dll.suffix == ".dll" and (dll.name.startswith("av") or dll.name.startswith("sw")):
            shutil.copy2(dll, bundle / dll.name)

    print("\n== ready")
    print(f"   {bundle / 'lanplayer.exe'}")
    for path in sorted(p for p in bundle.iterdir() if p.is_file()):
        print(f"   {path.name:<30} {path.stat().st_size / 1024:9.0f} KiB")

    # Everything else in the repo looks for the runnable bundle in
    # app/build/windows/x64/runner/Release: build_windows_installer.py stages the
    # installer from there and the verify scripts launch the app from there.  We
    # build in app/windows/out/build/... instead, so without this copy the
    # installer silently keeps packaging the PREVIOUS build - the exe's version
    # string stays at the old value and the installer's sha256 never moves, which
    # looks like the installer build "did nothing".
    publish = app / "build" / "windows" / "x64" / "runner" / "Release"
    if publish.is_dir():
        shutil.rmtree(publish, ignore_errors=True)
    publish.mkdir(parents=True, exist_ok=True)
    shutil.copytree(bundle, publish, dirs_exist_ok=True)
    print(f"\n== published to {publish}")

    if args.run:
        print("\n== launching")
        lp.run([str(bundle / "lanplayer.exe")], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
