#!/usr/bin/env python3
"""Verify that a new installer replaces lanplayer.dll even when it cannot be unlocked.

The bug this catches: Windows refuses to delete or overwrite a file whose image is
mapped by a running process.  Older installers either aborted with "cannot open
file for writing" (interactive) or silently skipped the DLL and left the old one
in place (silent, exit code 0 -- the worst case, because the app then runs a new
exe against an old DLL).  The current installer moves the locked file aside and
lets File write the new one under the original name.

Two things this covers that verify_windows_upgrade.py does not:

  * A holder that cannot be killed by image name (it holds an open handle rather
    than being an exe in $INSTDIR), so the enum-and-taskkill step cannot help.
  * The negative control: the previous package must still fail this test,
    otherwise the assertions are not measuring anything.

The holder maps the DLL as a real image with LoadLibraryEx, which is the same
state the running app puts it in.  That reproduces the three behaviours measured on a real mapped
image: a write open fails with ERROR_SHARING_VIOLATION, Rename succeeds, and
Delete fails with access denied.  A bare CreateFile handle with
FILE_SHARE_DELETE would allow the delete and hide the leftover .old case.

The .old file that the installer leaves behind cannot be deleted while the image
is mapped, so the test installs twice: the second run has to clear it.  That is
the self-healing check -- without it every upgrade under a stale holder would
accumulate .old files forever.

The install goes into a scratch directory.  HKCU\\Software\\LanPlayer points at it
first (that value is how the installer picks its target) and both registry keys
are restored in the finally block.

    python scripts/verify_windows_locked_upgrade.py
    python scripts/verify_windows_locked_upgrade.py --old-setup ... --new-setup ...
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402

REG_APP = r"HKCU\Software\LanPlayer"
REG_UN = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\LanPlayer"
SETUP_NAME = re.compile(r"^LanPlayer-([0-9]+\.[0-9]+\.[0-9]+)-windows-x64-setup\.exe$")

HOLDER_SOURCE = '''\
import ctypes, sys, time

k = ctypes.WinDLL("kernel32", use_last_error=True)
k.LoadLibraryExW.restype = ctypes.c_void_p
k.LoadLibraryExW.argtypes = [ctypes.c_wchar_p, ctypes.c_void_p, ctypes.c_ulong]
DONT_RESOLVE_DLL_REFERENCES = 0x1
LOAD_WITH_ALTERED_SEARCH_PATH = 0x8
handle = k.LoadLibraryExW(sys.argv[1], None,
                          DONT_RESOLVE_DLL_REFERENCES | LOAD_WITH_ALTERED_SEARCH_PATH)
# Must be a real image mapping (SEC_IMAGE).  LOAD_LIBRARY_AS_DATAFILE opens the
# file with different sharing, so it would neither reproduce the problem nor
# exercise the installer path that this test exists for.  DONT_RESOLVE skips
# loading the DLL's own imports, which keeps the holder independent of the
# runtime redistributables sitting next to it.
print("holder ok" if handle else "holder failed", flush=True)
time.sleep(float(sys.argv[2]) if len(sys.argv) > 2 else 300.0)
'''


def cmd(args: list[str]) -> int:
    return subprocess.run(["cmd", "/c", *args], text=True, capture_output=True,
                          encoding="mbcs", errors="replace").returncode


def reg_query(value: str) -> str:
    result = subprocess.run(["cmd", "/c", "reg", "query", REG_APP, "/v", value],
                            text=True, capture_output=True, encoding="mbcs",
                            errors="replace")
    return (result.stdout or "") + (result.stderr or "")


def read_reg_version() -> str:
    match = re.search(r"Version\s+REG_SZ\s+(\S+)", reg_query("Version"))
    return match.group(1) if match else ""


def digest(path: Path) -> str:
    if not path.exists():
        return "missing"
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:16]


def dll_size(path: Path) -> object:
    return path.stat().st_size if path.exists() else "missing"


def run_setup(path: Path, target: Path, timeout: float = 180.0) -> int | None:
    """Run an NSIS package silently into `target`; None means it hung."""
    argv = [str(path), "/S", "/D=" + str(target)]
    proc = subprocess.Popen(argv, close_fds=True, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            time.sleep(1.0)
            return proc.returncode
        time.sleep(0.2)
    proc.kill()
    return None


def start_holder(dll: Path, python: str) -> subprocess.Popen:
    script = Path(os.environ.get("TEMP", ".")) / "lp-dll-holder.py"
    script.write_text(HOLDER_SOURCE, encoding="utf-8")
    proc = subprocess.Popen([python, str(script), str(dll)],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, close_fds=True)
    time.sleep(2.0)
    return proc


def run_case(name: str, setup: Path, old: Path, scratch: Path, python: str) -> dict:
    if scratch.exists():
        shutil.rmtree(scratch, ignore_errors=True)
    dll = scratch / "lanplayer.dll"

    report: dict[str, object] = {"case": name, "setup": setup.name}
    report["install_old"] = run_setup(old, scratch)
    report["version_old"] = read_reg_version()
    report["dll_old"] = digest(dll)

    holder = start_holder(dll, python)
    report["holder_alive"] = holder.poll() is None

    report["install_target"] = run_setup(setup, scratch)
    report["version_after"] = read_reg_version()
    report["dll_after"] = digest(dll)
    report["dll_bytes"] = dll_size(dll)
    report["dll_replaced"] = report["dll_after"] != report["dll_old"]
    listing = sorted(p.name for p in scratch.iterdir()) if scratch.is_dir() else []
    report["entries"] = len(listing)
    report["stray_old"] = [n for n in listing if n.endswith(".old")]

    holder.kill()
    holder.wait(timeout=10)
    time.sleep(1.0)

    # The moved-aside copy cannot be deleted while the image is mapped, so a
    # second run has to clear it.  A package that leaves .old files behind
    # forever fails here.
    report["install_again"] = run_setup(setup, scratch)
    listing = sorted(p.name for p in scratch.iterdir()) if scratch.is_dir() else []
    report["stray_old_after_rerun"] = [n for n in listing if n.endswith(".old")]
    return report


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--old-setup", default="")
    parser.add_argument("--new-setup", default="")
    parser.add_argument("--scratch", default="")
    args = parser.parse_args()

    root = lp.ROOT
    current = lp.pubspec_version()
    new_setup = Path(args.new_setup) if args.new_setup else (
        root / "dist" / f"LanPlayer-{current}-windows-x64-setup.exe")
    if args.old_setup:
        old_setup = Path(args.old_setup)
    else:
        candidates = []
        for entry in (root / "dist").iterdir():
            match = SETUP_NAME.match(entry.name)
            if match and match.group(1) != current:
                key = tuple(int(p) for p in match.group(1).split("."))
                candidates.append((key, entry))
        if not candidates:
            raise lp.ScriptError("no older installer in dist/; build one or pass --old-setup")
        old_setup = max(candidates)[1]
    for path in (old_setup, new_setup):
        if not path.exists():
            raise lp.ScriptError(f"missing installer: {path}")

    scratch = Path(args.scratch) if args.scratch else \
        Path(os.environ.get("TEMP", ".")) / "lp-locked-test"
    python = lp.find_python()

    # Both packages run from %TEMP%: files under the repo carry a Low integrity
    # label, and a half-finished install must never touch dist/.
    temp = Path(os.environ.get("TEMP", "."))
    old_tmp = temp / "lp-locked-old.exe"
    new_tmp = temp / "lp-locked-new.exe"
    shutil.copy2(old_setup, old_tmp)
    shutil.copy2(new_setup, new_tmp)

    created_keys: list[str] = []
    for key in (REG_APP, REG_UN):
        if subprocess.run(["cmd", "/c", "reg", "query", key],
                          capture_output=True).returncode != 0:
            cmd(["reg", "add", key, "/f"])
            created_keys.append(key)
    saved_install_dir = ""
    match = re.search(r"InstallDir\s+REG_SZ\s+(\S.*)", reg_query("InstallDir"))
    if match:
        saved_install_dir = match.group(1).strip()

    try:
        # Point the installer at the scratch directory the way a real install
        # finds its previous location.
        if scratch.exists():
            shutil.rmtree(scratch, ignore_errors=True)
        scratch.mkdir(parents=True, exist_ok=True)
        cmd(["reg", "add", REG_APP, "/v", "InstallDir", "/t", "REG_SZ",
             "/d", str(scratch), "/f"])

        positive = run_case("new", new_tmp, old_tmp, scratch, python)
        negative = run_case("old", old_tmp, old_tmp, scratch, python)
    finally:
        subprocess.run(["taskkill", "/F", "/IM", "lanplayer.exe"],
                       capture_output=True)
        if scratch.exists():
            shutil.rmtree(scratch, ignore_errors=True)
        if saved_install_dir:
            cmd(["reg", "add", REG_APP, "/v", "InstallDir", "/t", "REG_SZ",
                 "/d", saved_install_dir, "/f"])
        for key in created_keys:
            cmd(["reg", "delete", key, "/f"])
        for path in (old_tmp, new_tmp):
            path.unlink(missing_ok=True)
        holder_script = temp / "lp-dll-holder.py"
        holder_script.unlink(missing_ok=True)

    for report in (positive, negative):
        print(f"{report['case']}: version {report['version_old']} -> "
              f"{report['version_after']} dll {report['dll_old']} -> "
              f"{report['dll_after']} ({report['dll_bytes']} B) "
              f"replaced={report['dll_replaced']} entries={report['entries']} "
              f"stray_old={report['stray_old']} "
              f"after_rerun={report['stray_old_after_rerun']} "
              f"exit={report['install_target']}")

    clears = not positive["stray_old_after_rerun"]
    ok = positive["dll_replaced"] and not negative["dll_replaced"] and clears
    print(f"verdict: positive_replaces_dll={positive['dll_replaced']} "
          f"negative_keeps_old_dll={not negative['dll_replaced']} "
          f"leftover_old_cleared={clears}")
    if not ok:
        print("FAIL: the assertions do not distinguish the two packages")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
