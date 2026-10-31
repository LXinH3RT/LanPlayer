#!/usr/bin/env python3
"""Verify the uninstaller still removes everything when lanplayer.dll is mapped.

The bug this covers: Delete on a mapped image fails silently, but NSIS carries on
and deletes the registry keys anyway.  The user then sees "uninstalled" while the
files are still there, and the next install hits the same locked DLL.  The
uninstaller now moves such a file aside and registers the leftover .old for
deletion on reboot.

What this checks:

  * with a holder mapping the DLL (so it can be neither deleted nor overwritten),
    uninstall leaves nothing but the reboot-pending .old file;
  * the registry keys are gone, so a later install starts clean;
  * once the holder is gone, an install leaves no .old behind -- the leftover is
    cleaned up by the next run rather than accumulating.

The holder maps the DLL as a real image with LoadLibraryEx.  A plain CreateFile
handle would not do: FILE_SHARE_DELETE lets the delete succeed and hides the bug.

    python scripts/verify_windows_locked_uninstall.py
    python scripts/verify_windows_locked_uninstall.py --setup ... --scratch ...

The negative control runs the same scenario against an older package and expects
the leftover files to still be there:

    python scripts/verify_windows_locked_uninstall.py \
        --setup dist/LanPlayer-0.1.3-windows-x64-setup.exe --expect-fail

That mode passes when the older uninstaller does leave files behind -- it proves
the assertions above are measuring the fix rather than the weather.
"""
from __future__ import annotations

import argparse
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

HOLDER_SOURCE = '''\
import ctypes, sys, time

k = ctypes.WinDLL("kernel32", use_last_error=True)
k.LoadLibraryExW.restype = ctypes.c_void_p
k.LoadLibraryExW.argtypes = [ctypes.c_wchar_p, ctypes.c_void_p, ctypes.c_ulong]
DONT_RESOLVE_DLL_REFERENCES = 0x1
LOAD_WITH_ALTERED_SEARCH_PATH = 0x8
handle = k.LoadLibraryExW(sys.argv[1], None,
                          DONT_RESOLVE_DLL_REFERENCES | LOAD_WITH_ALTERED_SEARCH_PATH)
print("holder ok" if handle else "holder failed", flush=True)
time.sleep(float(sys.argv[2]) if len(sys.argv) > 2 else 300.0)
'''


def run_exe(path: Path, *extra: str, timeout: float = 180.0) -> dict:
    """Start an installer / uninstaller and wait for the process itself."""
    started = time.time()
    proc = subprocess.Popen([str(path), *extra], stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            close_fds=True)
    while time.time() - started < timeout:
        if proc.poll() is not None:
            time.sleep(1.0)
            return {"code": proc.returncode,
                    "ms": int((time.time() - started) * 1000)}
        time.sleep(0.2)
    proc.kill()
    return {"code": "TIMEOUT", "ms": int((time.time() - started) * 1000)}


def reg_exists(key: str) -> bool:
    return subprocess.run(["cmd", "/c", "reg", "query", key],
                          capture_output=True).returncode == 0


def listing(directory: Path) -> list[str]:
    return sorted(p.name for p in directory.iterdir()) if directory.is_dir() else []


def start_holder(dll: Path, python: str) -> subprocess.Popen:
    script = lp.scratch_dir("holders") / "lp-unl-holder.py"
    script.write_text(HOLDER_SOURCE, encoding="utf-8")
    proc = subprocess.Popen([python, str(script), str(dll)],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, close_fds=True)
    line = proc.stdout.readline().decode("utf-8", "replace").strip()
    proc.stdout.close()
    proc.reported = line  # type: ignore[attr-defined]
    return proc


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--setup", default="")
    parser.add_argument("--scratch", default="")
    parser.add_argument("--expect-fail", action="store_true",
                        help="negative control: the package is expected to leave files behind")
    args = parser.parse_args()

    root = lp.ROOT
    setup = Path(args.setup) if args.setup else (
        root / "dist" / f"LanPlayer-{lp.pubspec_version()}-windows-x64-setup.exe")
    if not setup.exists():
        raise lp.ScriptError(f"missing installer: {setup}")
    scratch = Path(args.scratch) if args.scratch else \
        lp.scratch_dir("lp-locked-uninstall")
    python = lp.find_python()

    # Run from %TEMP% so the test never touches dist/.
    temp = lp.scratch_dir("verify-temp")
    setup_tmp = temp / "lp-locked-unl-setup.exe"
    shutil.copy2(setup, setup_tmp)

    saved_install_dir = ""
    query = subprocess.run(["cmd", "/c", "reg", "query", REG_APP, "/v", "InstallDir"],
                           capture_output=True, encoding="mbcs", errors="replace")
    match = re.search(r"InstallDir\s+REG_SZ\s+(\S.*)", query.stdout or "")
    if match:
        saved_install_dir = match.group(1).strip()
    created: list[str] = []
    for key in (REG_APP, REG_UN):
        if not reg_exists(key):
            subprocess.run(["cmd", "/c", "reg", "add", key, "/f"], capture_output=True)
            created.append(key)

    report: dict[str, object] = {}
    holder = None
    try:
        if scratch.exists():
            shutil.rmtree(scratch, ignore_errors=True)
        scratch.mkdir(parents=True, exist_ok=True)
        subprocess.run(["cmd", "/c", "reg", "add", REG_APP, "/v", "InstallDir",
                        "/t", "REG_SZ", "/d", str(scratch), "/f"], capture_output=True)

        report["install"] = run_exe(setup_tmp, "/S", "/D=" + str(scratch))
        report["entries_before"] = len(listing(scratch))

        holder = start_holder(scratch / "lanplayer.dll", python)
        report["holder"] = getattr(holder, "reported", "")
        report["holder_alive"] = holder.poll() is None

        report["uninstall"] = run_exe(scratch / "uninstall.exe", "/S")
        # The stub copies itself to %TEMP% and returns at once, so wait for the
        # directory to settle instead of trusting that exit code.
        deadline = time.time() + 90.0
        settled: list[str] = []
        while time.time() < deadline:
            settled = listing(scratch)
            if scratch.is_dir() and not settled:
                break
            if not [n for n in settled if not n.endswith(".old")]:
                break
            time.sleep(0.5)
        report["entries_after_uninstall"] = listing(scratch)
        report["app_key_gone"] = not reg_exists(REG_APP)
        report["uninstall_key_gone"] = not reg_exists(REG_UN)
    finally:
        if holder is not None and holder.poll() is None:
            holder.kill()
            holder.wait(timeout=10)
        time.sleep(1.0)
        leftover = listing(scratch) if scratch.is_dir() else []
        report["entries_after_holder_exit"] = leftover
        (temp / "lp-unl-holder.py").unlink(missing_ok=True)

    # Only a reboot-pending .old may survive: a mapped image cannot be deleted.
    report["left_behind"] = [n for n in report["entries_after_uninstall"]
                             if not n.endswith(".old")]

    try:
        report["reinstall"] = run_exe(setup_tmp, "/S", "/D=" + str(scratch))
        after = listing(scratch)
        report["entries_after_reinstall"] = len(after)
        report["stray_old_after_reinstall"] = [n for n in after if n.endswith(".old")]
    finally:
        subprocess.run(["cmd", "/c", "taskkill", "/F", "/IM", "lanplayer.exe"],
                       capture_output=True)
        if scratch.exists():
            shutil.rmtree(scratch, ignore_errors=True)
        if saved_install_dir:
            subprocess.run(["cmd", "/c", "reg", "add", REG_APP, "/v", "InstallDir",
                            "/t", "REG_SZ", "/d", saved_install_dir, "/f"],
                           capture_output=True)
        for key in created:
            subprocess.run(["cmd", "/c", "reg", "delete", key, "/f"], capture_output=True)
        setup_tmp.unlink(missing_ok=True)

    print(f"holder: {report['holder']} alive={report['holder_alive']}")
    print(f"install: {report['install']} entries={report['entries_before']}")
    print(f"uninstall: {report['uninstall']} left="
          f"{report['entries_after_uninstall']}")
    print(f"registry: app_key_gone={report['app_key_gone']} "
          f"uninstall_key_gone={report['uninstall_key_gone']}")
    print(f"reinstall: {report['reinstall']} entries={report['entries_after_reinstall']} "
          f"stray_old={report['stray_old_after_reinstall']}")

    clean = (report["holder_alive"]
             and report["left_behind"] == []
             and report["app_key_gone"]
             and report["uninstall_key_gone"]
             and report["entries_after_reinstall"] >= 17
             and not report["stray_old_after_reinstall"])
    print(f"verdict: only_reboot_pending_left={not report['left_behind']} "
          f"registry_clean={report['app_key_gone'] and report['uninstall_key_gone']} "
          f"reinstall_clean={report['entries_after_reinstall'] >= 17 and not report['stray_old_after_reinstall']}")

    if args.expect_fail:
        if clean:
            print("FAIL: the negative control passed -- these assertions do not test the fix")
            return 1
        print("PASS (negative control): the older package really does leave files behind")
        return 0
    if not clean:
        print("FAIL: the uninstaller left something it should not have")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
