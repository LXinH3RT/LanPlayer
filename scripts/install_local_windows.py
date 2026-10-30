#!/usr/bin/env python3
"""Install this checkout's Windows build over the copy on this machine.

The point of this script is the *verification*, not the launching: a silent
installer can exit 0 having done nothing, and a build directory that was never
rebuilt will happily install yesterday's payload.  So every step is checked
afterwards against ``app/build/.../data/app.so``.

On integrity labels, since they mislead: a file inherits the label of the
directory it is created in, so an installer built under a Low-labelled tree
comes out labelled Low.  That label restricts what a Low *process* may write and
propagates to files unpacked under it - it does not lower the integrity of the
process that executes the installer, which inherits the launching token
(measured: a Low-labelled setup.exe installs fine from a normal shell).  What
does break an install is this script - or the shell running it - being at Low
integrity, so that is what gets checked first.

    python scripts/install_local_windows.py --check        # report only
    python scripts/install_local_windows.py --out-dir D:\\LanPlayer
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402


def find_setup() -> Path:
    """The newest installer under dist/."""
    candidates = sorted(lp.DIST.glob("LanPlayer-*-windows-x64-setup.exe"))
    if not candidates:
        raise lp.ScriptError("no installer under dist/ - run "
                             "python scripts/build_windows_installer.py first")
    return candidates[-1]


def exe_stamp(exe: Path) -> tuple[str, int]:
    """(FileVersion, mtime in ns) for the installed exe, or blanks."""
    if not exe.exists():
        return "", 0
    return file_version(exe), exe.stat().st_mtime_ns


def file_version(exe: Path) -> str:
    """The FileVersion resource of an exe, or an empty string."""
    if not exe.exists():
        return ""
    script = ("(Get-Item -LiteralPath '%s').VersionInfo.FileVersion"
              % str(exe).replace("'", "''"))
    out = lp.output(["powershell", "-NoProfile", "-Command", script]) or ""
    return out.strip()


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--setup", default="", help="installer to run (default: newest in dist/)")
    parser.add_argument("--out-dir", default=r"D:\LanPlayer",
                        help="where the app is installed (default: D:\\LanPlayer)")
    parser.add_argument("--check", action="store_true",
                        help="report the integrity situation without installing")
    args = parser.parse_args()

    setup = Path(args.setup) if args.setup else find_setup()
    if not setup.exists():
        raise lp.ScriptError(f"{setup} does not exist")
    level = lp.current_integrity()
    label = "Low" if lp.low_integrity_label(setup) else "none"
    print(f"setup: {setup.name} ({lp.size_mb(setup)} MB), file label: {label}")
    print(f"sha256: {lp.sha256(setup)}")
    print(f"this shell: {level or 'unknown'} integrity")

    restricted = level not in ("", "Medium", "High", "System")
    if args.check:
        print()
        if restricted:
            print(f"this shell runs at {level} integrity, so the installer would "
                  f"inherit that token and could not write to {args.out_dir}; "
                  f"run this from a normal shell")
        elif label == "Low":
            print("the package carries a Low label; that only matters for what "
                  "it unpacks, installing from here is fine")
        else:
            print("ready to install")
        return 0
    if restricted:
        raise lp.ScriptError(
            f"this shell runs at {level} integrity; the installer would inherit "
            f"that token and could not write to {args.out_dir}")

    dest = args.out_dir
    running = lp.output(["tasklist", "/FI", "IMAGENAME eq lanplayer.exe", "/NH"]) or ""
    if "lanplayer.exe" in running:
        print("stopping the running copy")
        subprocess.run(["taskkill", "/F", "/IM", "lanplayer.exe"],
                       capture_output=True)
        time.sleep(1.0)

    before_version, _ = exe_stamp(Path(dest) / "lanplayer.exe")
    print(f"installed now: {before_version or '(nothing)'}")

    print(f"installing into {dest}")
    result = subprocess.run([str(setup), "/S", f"/D={dest}"],
                            capture_output=True, text=True,
                            encoding="mbcs", errors="replace")
    print(f"  installer exit={result.returncode}")

    after_version, _ = exe_stamp(Path(dest) / "lanplayer.exe")
    print(f"installed now: {after_version or '(nothing)'}")
    if not after_version:
        raise lp.ScriptError("the installer reported success but nothing is at "
                             f"{dest}")

    # What actually has to match is the payload, not the launcher: the launcher
    # exe is byte-identical between builds (NSIS may even skip rewriting it when
    # nothing differs), while every change to the app lands in data/app.so.
    source_so = lp.ROOT / "app" / "build" / "windows" / "x64" / "runner" / "Release" / "data" / "app.so"
    app_so = Path(dest) / "data" / "app.so"
    if source_so.exists() and app_so.exists():
        same = lp.sha256(source_so) == lp.sha256(app_so)
        print(f"app.so installed matches the build: {same}")
        if not same:
            raise lp.ScriptError(f"{app_so} does not match {source_so}; the "
                                 f"installer did not copy the current build")
        short = after_version.split("+", 1)[0]
        blob = app_so.read_bytes()
        print(f"app.so: {lp.size_mb(app_so)} MB, carries {short}: "
              f"{short.encode('ascii') in blob}")
    print()
    print("done")
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
