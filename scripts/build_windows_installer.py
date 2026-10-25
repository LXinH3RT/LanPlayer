#!/usr/bin/env python3
"""Build the Windows installer (NSIS).

Prerequisites:
  1. python scripts/build_windows.py --deploy-to app/build/windows/x64/runner/Release
     (puts lanplayer.dll and the FFmpeg DLLs next to the exe)
  2. the Flutter desktop bundle in app/build/windows/x64/runner/Release
     (done by scripts/build_windows_desktop.py)
  3. .tools/nsis/nsis-3.10/Bin/makensis.exe (python tool/fetch_deps.py nsis)

Usage:
    python scripts/build_windows_installer.py
    python scripts/build_windows_installer.py --version 0.1.0 --open

Output: dist/LanPlayer-<version>-windows-x64-setup.exe
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

# Listed one by one on purpose: installer.nsi uses a File directive per file, so
# the staging set and the packaged set must stay identical.
RUNTIME = [
    "lanplayer.exe",
    "lanplayer.dll",
    "lanplayer_video_plugin.dll",
    "flutter_windows.dll",
    "avcodec-63.dll",
    "avfilter-12.dll",
    "avformat-63.dll",
    "avutil-61.dll",
    "swresample-7.dll",
    "swscale-10.dll",
]

CRT_FILES = [
    "msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll",
    "vcruntime140.dll", "vcruntime140_1.dll", "concrt140.dll",
]


def find_crt() -> Path:
    """The newest VC++ 2022 x64 CRT directory, for app-local deployment.

    The runtime ships next to the exe so users do not have to install the
    Redistributable.  The redist directory is versioned, so take the newest.
    """
    for base in (os.environ.get("ProgramFiles(x86)"), os.environ.get("ProgramFiles")):
        if not base:
            continue
        vswhere = Path(base) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
        if not vswhere.exists():
            continue
        vs_path = lp.output([str(vswhere), "-latest", "-products", "*", "-property", "installationPath"])
        if not vs_path:
            continue
        redist = Path(vs_path) / "VC" / "Redist" / "MSVC"
        if not redist.is_dir():
            continue
        for child in sorted((p for p in redist.iterdir() if p.is_dir()), reverse=True):
            candidate = child / "x64" / "Microsoft.VC145.CRT"
            if candidate.is_dir():
                return candidate
    raise lp.ScriptError("could not locate Microsoft.VC145.CRT (VC++ x64 redist) "
                         "- need a machine with Visual Studio")


def build(version: str, release: Path, out_dir: Path, keep_stage: bool) -> Path:
    stage = out_dir / "stage" / "windows"

    exe = release / "lanplayer.exe"
    if not exe.exists():
        raise lp.ScriptError(f"missing {exe} - run python scripts/build_windows_desktop.py first")
    for dll in ("lanplayer.dll", "avcodec-63.dll", "avformat-63.dll"):
        if not (release / dll).exists():
            raise lp.ScriptError(f"missing {dll} in {release} - run "
                                 f"python scripts/build_windows.py --deploy-to {release}")

    print(f"== staging into {stage} ==")
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    for name in RUNTIME:
        source = release / name
        if not source.exists():
            raise lp.ScriptError(f"missing {name} in {release}")
        shutil.copy2(source, stage / name)

    # avdevice is intentionally NOT shipped: dumpbin /DEPENDENTS shows no module
    # links against it, and the core never calls avdevice_*.
    if (release / "avdevice-63.dll").exists():
        print("  skipping avdevice-63.dll (nothing depends on it)")

    shutil.copytree(release / "data", stage / "data")
    (stage / "data" / "native_assets.yaml").unlink(missing_ok=True)

    crt = find_crt()
    print(f"  CRT from {crt}")
    for name in CRT_FILES:
        source = crt / name
        if not source.exists():
            raise lp.ScriptError(f"missing {name} in {crt}")
        shutil.copy2(source, stage / name)

    staged_mb = round(sum(p.stat().st_size for p in stage.rglob("*") if p.is_file()) / (1024 * 1024), 1)
    print(f"  staged {staged_mb} MB")

    nsis = lp.TOOLS / "nsis" / "nsis-3.10" / "Bin" / "makensis.exe"
    if not nsis.exists():
        raise lp.ScriptError(f"missing {nsis} - run: python tool/fetch_deps.py nsis")

    out_file = out_dir / f"LanPlayer-{version}-windows-x64-setup.exe"
    icon = lp.ROOT / "app" / "windows" / "runner" / "resources" / "app_icon.ico"
    script = lp.SCRIPTS / "windows" / "installer.nsi"

    # makensis writes temp files under %TEMP%, which may be read-only.
    tmp = lp.ensure_dir(lp.TOOLS / "tmp")
    env = dict(os.environ)
    env["TMP"] = str(tmp)
    env["TEMP"] = str(tmp)

    print("== makensis ==")
    result = subprocess.run(
        [str(nsis), "/V2", f"/DAPP_VERSION={version}", f"/DSTAGE={stage}",
         f"/DOUTFILE={out_file}", f"/DAPP_ICON={icon}", str(script)],
        env=env, text=True, capture_output=True, encoding="mbcs", errors="replace",
    )
    if result.returncode != 0:
        detail = "\n".join(((result.stdout or "") + (result.stderr or "")).strip().splitlines()[-25:])
        raise lp.ScriptError(f"makensis failed with exit code {result.returncode}\n{detail}")
    if not out_file.exists():
        raise lp.ScriptError("makensis produced no output")

    print()
    print(f"built: {out_file} ({lp.size_mb(out_file)} MB)")
    print(f"sha256: {lp.sha256(out_file)}")

    if not keep_stage:
        shutil.rmtree(stage, ignore_errors=True)
        stage_root = out_dir / "stage"
        if stage_root.is_dir() and not any(stage_root.iterdir()):
            shutil.rmtree(stage_root, ignore_errors=True)
    return out_file


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", default="",
                        help="package version (default: read from app/pubspec.yaml)")
    parser.add_argument("--release", default="",
                        help="Flutter bundle directory (default: app/build/windows/x64/runner/Release)")
    parser.add_argument("--out-dir", default="", help="output directory (default: dist)")
    parser.add_argument("--keep-stage", action="store_true")
    parser.add_argument("--open", action="store_true", help="open the output folder afterwards")
    args = parser.parse_args()

    # The version comes from app/pubspec.yaml unless told otherwise, so the
    # installer name cannot drift from the tag and the other two packages.
    version = args.version or lp.pubspec_version()
    release = Path(args.release) if args.release else lp.ROOT / "app" / "build" / "windows" / "x64" / "runner" / "Release"
    out_dir = Path(args.out_dir) if args.out_dir else lp.DIST
    out_dir.mkdir(parents=True, exist_ok=True)

    build(version, release, out_dir, args.keep_stage)

    if args.open:
        os.startfile(out_dir)  # noqa: S606 - interactive convenience flag
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
