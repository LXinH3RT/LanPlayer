#!/usr/bin/env python3
"""Direct MSVC build of the Flutter Windows chain (no CMake, no flutter tool).

Mirrors what app/windows/CMakeLists.txt + flutter/CMakeLists.txt would do:
runner + generated registrant + engine wrapper + our plugin, linked against
flutter_windows.dll.lib.  Used to verify the C++ side on machines where the
flutter tool cannot run; `flutter build windows` is the real build.

    python scripts/msvc_chain.py [OUT_DIR]

The MSVC environment is captured by running vcvars64.bat once and importing the
variables it prints, so no cmd.exe wrapper script is needed around the build.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402

# /W4 /WX with the warnings that the Flutter templates trip over suppressed.
CXX_FLAGS = ["/nologo", "/EHsc", "/std:c++17", "/W4", "/WX", "/wd4100", "/MD", "/O2", "/DNDEBUG"]

RUNNER_SOURCES = [
    "app/windows/runner/main.cpp",
    "app/windows/runner/flutter_window.cpp",
    "app/windows/runner/win32_window.cpp",
    "app/windows/runner/utils.cpp",
    "app/windows/flutter/generated_plugin_registrant.cc",
]

WRAPPER_SOURCES = [
    "core_implementations.cc",
    "standard_codec.cc",
    "flutter_engine.cc",
    "flutter_view_controller.cc",
    "plugin_registrar.cc",
]


def find_visual_studio() -> Path:
    """LP_VS_DIR, else the newest install that vswhere reports."""
    configured = os.environ.get("LP_VS_DIR")
    if configured:
        return Path(configured)

    candidates = []
    for base in (os.environ.get("ProgramFiles(x86)"), os.environ.get("ProgramFiles")):
        if not base:
            continue
        vswhere = Path(base) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
        if not vswhere.exists():
            continue
        found = lp.output([str(vswhere), "-latest", "-products", "*", "-property", "installationPath"])
        if found:
            candidates.append(Path(found))
    if not candidates:
        raise lp.ScriptError("could not locate Visual Studio (install the C++ desktop workload); "
                             "set LP_VS_DIR to override")
    return candidates[0]


def msvc_env(vs: Path) -> dict[str, str]:
    """The environment vcvars64.bat sets up, imported into this process."""
    vcvars = vs / "VC" / "Auxiliary" / "Build" / "vcvars64.bat"
    if not vcvars.exists():
        raise lp.ScriptError(f"{vcvars} is missing; the C++ desktop workload is not installed")

    # Reading the variables vcvars64.bat exports means running it inside
    # cmd.exe and dumping the environment afterwards.  Build a tiny .bat file
    # for that instead of nesting quotes on a command line: cmd strips the
    # outer pair whenever a /c string starts with a quote, and Python's
    # argument quoting turns the inner pair into \"…\", so the path arrives
    # mangled.
    script = lp.TOOLS / "tmp" / "vsvars.bat"
    script.parent.mkdir(parents=True, exist_ok=True)
    lp.write_text(script, f'@echo off\r\ncall "{vcvars}" >nul\r\nset\r\n', newline="")
    result = subprocess.run(["cmd", "/c", str(script)],
                            text=True, capture_output=True, encoding="mbcs", errors="replace")
    if result.returncode != 0:
        raise lp.ScriptError(f"vcvars64.bat failed ({result.returncode}): {(result.stderr or '').strip()}")

    env = dict(os.environ)
    for line in (result.stdout or "").splitlines():
        name, sep, value = line.partition("=")
        if sep and name and value:
            env[name] = value
    if "VSCMD_ARG_TGT_ARCH" not in env:
        raise lp.ScriptError("vcvars64.bat did not report a target architecture; MSVC is not usable")
    return env


def resolve_in(env: dict[str, str], name: str) -> str:
    """Absolute path of an executable looked up in the captured MSVC PATH.

    CreateProcess resolves the image using the *calling* process's PATH, not
    the environment block handed to it, so the names vcvars64.bat exports have
    to be turned into full paths here before they are usable.
    """
    for directory in env.get("PATH", "").split(os.pathsep):
        if not directory:
            continue
        for candidate in (directory, ):
            exe = Path(candidate) / name
            if exe.is_file():
                return str(exe)
            exe = Path(candidate) / (name + ".exe")
            if exe.is_file():
                return str(exe)
    raise lp.ScriptError(f"{name} is not on the MSVC PATH; the C++ desktop workload is incomplete")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("out", nargs="?", default="",
                        help="output directory (default: build/msvc-chain)")
    args = parser.parse_args()

    root = lp.ROOT
    out = Path(args.out) if args.out else root / "build" / "msvc-chain"
    obj = out / "obj"
    obj.mkdir(parents=True, exist_ok=True)

    ephemeral = root / "app" / "windows" / "flutter" / "ephemeral"
    artifacts = root / ".tools" / "flutter-sdk" / "bin" / "cache" / "artifacts" / "engine" / "windows-x64"
    if not (artifacts / "flutter_windows.dll.lib").exists():
        raise lp.ScriptError(f"{artifacts}/flutter_windows.dll.lib is missing; "
                             "run: python tool/fetch_deps.py flutter")

    vs = find_visual_studio()
    env = msvc_env(vs)
    env = lp.prepend_path(env, out)
    # Resolve the tools before use: see resolve_in() for why.
    cl = resolve_in(env, "cl")
    link = resolve_in(env, "link")

    # A normal install keeps state in %APPDATA%; a child process may not be
    # allowed to write outside the project, so runs under one get a state
    # directory inside the build output.
    env.setdefault("LP_STATE_DIR", str(out / "state"))

    defines = [
        "/DUNICODE", "/D_UNICODE", "/DNOMINMAX",
        '/DFLUTTER_VERSION=\\"3.27.4\\"',
        "/DFLUTTER_VERSION_MAJOR=3", "/DFLUTTER_VERSION_MINOR=27",
        "/DFLUTTER_VERSION_PATCH=4", "/DFLUTTER_VERSION_BUILD=0",
    ]
    includes = [
        f"/I{ephemeral}",
        f"/I{ephemeral / 'cpp_client_wrapper' / 'include'}",
        f"/I{root / 'app' / 'windows'}",
        f"/I{root / 'app' / 'windows' / 'runner'}",
        f"/I{root / 'app' / 'windows' / 'flutter'}",
        f"/I{root / 'packages' / 'lanplayer_video' / 'windows'}",
        f"/I{root / 'packages' / 'lanplayer_video' / 'windows' / 'include'}",
    ]

    def compile_one(source: Path, name: str, extra: list[str] | None = None) -> Path:
        target = obj / name
        lp.run([cl, *CXX_FLAGS, *defines, *(extra or []), *includes,
                "/c", str(source), f"/Fo{target}"], env=env, capture=False, show=False)
        return target

    print("=== compile runner + registrant + wrapper ===")
    sources = [root / rel for rel in RUNNER_SOURCES]
    sources += [ephemeral / "cpp_client_wrapper" / name for name in WRAPPER_SOURCES]
    objects = [compile_one(source, source.stem + ".obj") for source in sources]

    print("=== compile plugin (dll) ===")
    plugin_obj = compile_one(root / "packages" / "lanplayer_video" / "windows" / "lanplayer_video_plugin.cpp",
                             "plugin.obj", extra=["/DFLUTTER_PLUGIN_IMPL"])

    engine_lib = str(artifacts / "flutter_windows.dll.lib")
    plugin_objects = [str(plugin_obj)] + [str(obj / n) for n in
                                          ("core_implementations.obj", "standard_codec.obj",
                                           "plugin_registrar.obj")]

    print("=== link lanplayer_video_plugin.dll ===")
    # flutter_wrapper_plugin = core_implementations + standard_codec + plugin_registrar
    lp.run([link, "/nologo", "/DLL", f"/OUT:{out / 'lanplayer_video_plugin.dll'}",
            f"/IMPLIB:{out / 'lanplayer_video_plugin.lib'}", *plugin_objects,
            engine_lib, "user32.lib", "version.lib", "ole32.lib", "shell32.lib"],
           env=env, show=False)

    print("=== link lanplayer.exe ===")
    # The plugin reaches the executable through its import library, not as an
    # object: linking plugin.obj here too duplicates
    # LanPlayerVideoPluginRegisterWithRegistrar and loses the version.lib calls
    # that only the DLL link resolves.
    exe_objects = [str(o) for o in objects]
    lp.run([link, "/nologo", f"/OUT:{out / 'lanplayer.exe'}", "/SUBSYSTEM:WINDOWS",
            *exe_objects, str(out / "lanplayer_video_plugin.lib"), engine_lib,
            "dwmapi.lib", "user32.lib", "gdi32.lib", "shell32.lib", "ole32.lib", "advapi32.lib"],
           env=env, show=False)

    print("=== ok ===")
    for path in sorted(out.iterdir()):
        if path.suffix in (".exe", ".dll"):
            print(path.name)
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
