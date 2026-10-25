#!/usr/bin/env python3
"""Verify that a new installer upgrades over a *running* old version.

The bug this catches: the old build is still running, nobody uninstalled
anything, and the new installer must stop it, replace the exe, and put back a
DLL the test removed -- all without asking the user to uninstall first.

The test installs into a scratch directory, not into the real install location:
it deletes a DLL and appends marker bytes to the exe, which is fine on a copy and
rude on the user's own installation.  HKCU\\Software\\LanPlayer is pointed at the
scratch dir first (that value is exactly how the installer decides where to go)
and everything the install touches is restored in the finally block: both
registry keys, the desktop shortcut and the Start Menu folder.  Installing into a
scratch dir also leaves a desktop shortcut pointing at the scratch dir, so
skipping that restore quietly breaks the real install.

Seven traps, all learned the hard way:

 1. Copy the packages to %TEMP% before running them.  Files created under the
    repo carry a Low integrity label, and keeping the run away from the repo also
    means a half-finished install can never touch dist/.
 2. The launcher exe is byte-identical between releases (same size, same
    sha256), so its size proves nothing on its own.  Append marker bytes first;
    if the installer overwrites the file the size drops back.  The deleted DLL
    is the second, independent signal.
 3. Start-Process -PassThru + HasExited can hang forever on this machine, and
    `cmd /c "..." &` from a sandboxed shell leaves tasklist without a usable
    stdin.  Run cmd /c "<setup>" /S synchronously instead, and poll with the
    process list.
 4. The NSIS uninstaller copies itself to %TEMP% and returns immediately, so its
    exit code says nothing about completion; wait for the directory to
    disappear.  The installer does not do this, but the same wait is harmless.
 5. Reading the registry right after writing it can return the old value even
    though the write landed; verify registry edits with reg.exe query.
 6. Do not seed the scratch directory from dist/stage/windows: the installer
    deletes everything already in $INSTDIR, so a pre-seeded tree vanishes and
    "was the exe replaced" turns into a comparison against a missing file.
    Install the old package properly instead -- that also produces uninstall.exe.
 7. The verdict depends on where you run it from, because of PATH.  The
    StopRunningApp macro asks cmd to pipe tasklist into `find`.  Under Git Bash,
    PATH puts /usr/bin ahead of System32, so `find` resolves to GNU find, which
    rejects /FI and /I and exits non-zero -- the macro reads that as "not
    running", skips the taskkill, and the install fails with
    exe_replaced=False.  Fixed on the installer side: the macro now uses
    findstr, which Windows alone ships.

    python scripts/verify_windows_upgrade.py
    python scripts/verify_windows_upgrade.py --old-setup ... --new-setup ...
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
SETUP_NAME = re.compile(r"^LanPlayer-([0-9]+\.[0-9]+\.[0-9]+)-windows-x64-setup\.exe$")


def version_key(version: str) -> int:
    total = 0
    for part in version.split("."):
        total = total * 1000 + int(part)
    return total


def setup_version(path: Path) -> str:
    match = re.search(r"LanPlayer-([0-9]+\.[0-9]+\.[0-9]+)-windows", path.name)
    return match.group(1) if match else "unknown"


def pick_packages(root: Path, old_setup: Path | None, new_setup: Path | None) -> tuple[Path, Path]:
    """The new package is whatever app/pubspec.yaml declares; the old one is the
    newest earlier installer that happens to be in dist/.

    Versions are read rather than written down: hard-coding 0.1.1 / 0.1.2 once
    made this script silently test a pair of packages two releases behind.
    """
    current = lp.pubspec_version()
    dist = root / "dist"

    if new_setup is None and current:
        new_setup = dist / f"LanPlayer-{current}-windows-x64-setup.exe"

    if old_setup is None:
        candidates = []
        if dist.is_dir():
            for entry in dist.iterdir():
                match = SETUP_NAME.match(entry.name)
                if match and match.group(1) != current:
                    candidates.append((version_key(match.group(1)), entry))
        if candidates:
            old_setup = max(candidates)[1]

    if old_setup is None:
        raise lp.ScriptError("no old installer found; build one or pass --old-setup")
    if not old_setup.exists():
        raise lp.ScriptError(f"missing old installer: {old_setup}")
    if new_setup is None or not new_setup.exists():
        raise lp.ScriptError(f"no new installer at {new_setup}; build it first")
    return old_setup, new_setup


def cmd(args: list[str]) -> int:
    return subprocess.run(["cmd", "/c", *args], text=True, capture_output=True,
                          encoding="mbcs", errors="replace").returncode


def reg_query(value: str) -> str:
    result = subprocess.run(["cmd", "/c", "reg", "query", REG_APP, "/v", value],
                            text=True, capture_output=True, encoding="mbcs", errors="replace")
    return (result.stdout or "") + (result.stderr or "")


def reg_add(value: str, data: str) -> None:
    cmd(["reg", "add", REG_APP, "/v", value, "/t", "REG_SZ", "/d", data, "/f"])


def read_reg_version() -> str:
    text = subprocess.run(["cmd", "/c", "reg", "query", REG_APP, "/v", "Version"],
                          text=True, capture_output=True, encoding="mbcs", errors="replace").stdout or ""
    match = re.search(r"Version\s+REG_SZ\s+(\S+)", text)
    return match.group(1) if match else ""


def processes() -> list[int]:
    """PIDs of running lanplayer processes (tasklist, not a WMI query)."""
    result = subprocess.run(["cmd", "/c", "tasklist", "/FI", "IMAGENAME eq lanplayer.exe", "/NH"],
                            text=True, capture_output=True, encoding="mbcs", errors="replace")
    pids = []
    for line in (result.stdout or "").splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0].lower() == "lanplayer.exe":
            try:
                pids.append(int(fields[1]))
            except ValueError:
                pass
    return pids


def stop_app() -> None:
    subprocess.run(["cmd", "/c", "taskkill", "/F", "/IM", "lanplayer.exe"],
                   text=True, capture_output=True, encoding="mbcs", errors="replace")
    time.sleep(0.8)


def start_app(exe: Path) -> subprocess.Popen:
    return subprocess.Popen([str(exe)], cwd=str(exe.parent), close_fds=True,
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)


def run_setup(path: Path, extra: str = "") -> int:
    """Run an NSIS installer and wait for it.

    The exe is launched directly rather than through `cmd /c "path" /S`: cmd.exe
    strips the outermost pair of quotes, so a path with spaces arrives broken
    and the install silently does nothing (exit code 1, no files).  The
    installer itself exits when it is done; only the uninstaller detaches.
    """
    argv = [str(path), *([extra] if extra else [])]
    return subprocess.run(argv, text=True, capture_output=True,
                          encoding="mbcs", errors="replace").returncode


def wait_gone(directory: Path, timeout: float = 20.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not directory.exists():
            return True
        time.sleep(0.25)
    return not directory.exists()


def show_state(tag: str, exe: Path, dll: Path) -> None:
    size = exe.stat().st_size if exe.exists() else "missing"
    print(f"{tag}: reg_version={read_reg_version()} swscale={dll.exists()} "
          f"exe_bytes={size} procs=[{','.join(str(p) for p in processes())}]")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--old-setup", default="")
    parser.add_argument("--new-setup", default="")
    parser.add_argument("--scratch", default="")
    args = parser.parse_args()

    root = lp.ROOT
    old_setup, new_setup = pick_packages(
        root,
        Path(args.old_setup) if args.old_setup else None,
        Path(args.new_setup) if args.new_setup else None,
    )
    old_version = setup_version(old_setup)
    new_version = setup_version(new_setup)
    scratch = Path(args.scratch) if args.scratch else Path(os.environ.get("TEMP", ".")) / "lp-upgrade-test"

    temp = Path(os.environ.get("TEMP", "."))
    old_tmp = temp / "lp-verify-old.exe"
    new_tmp = temp / "lp-verify-new.exe"
    exe = scratch / "lanplayer.exe"
    dll = scratch / "swscale-10.dll"
    bak_app = temp / "lp-reg-app.reg"
    bak_un = temp / "lp-reg-un.reg"
    appdata = Path(os.environ.get("APPDATA", "."))
    userprofile = Path(os.environ.get("USERPROFILE", "."))
    lnk_dir = appdata / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "LanPlayer"
    lnk_desk = userprofile / "Desktop" / "LanPlayer.lnk"
    lnk_box = temp / "lp-shortcut-backup"

    shutil.copy2(old_setup, old_tmp)
    shutil.copy2(new_setup, new_tmp)

    # reg export fails when the key does not exist, which is normal on a machine
    # that has never installed the app.  Create the keys first so the backup (and
    # therefore the restore) works either way, and remember which ones we made so
    # finally can take them back out.
    created_keys: list[str] = []
    for key in (REG_APP, REG_UN):
        if subprocess.run(["cmd", "/c", "reg", "query", key],
                          capture_output=True).returncode != 0:
            cmd(["reg", "add", key, "/f"])
            created_keys.append(key)
    cmd(["reg", "export", REG_APP, str(bak_app), "/y"])
    cmd(["reg", "export", REG_UN, str(bak_un), "/y"])
    if not bak_app.exists() or not bak_un.exists():
        raise lp.ScriptError("registry backup failed")

    if lnk_box.exists():
        shutil.rmtree(lnk_box, ignore_errors=True)
    lnk_box.mkdir(parents=True, exist_ok=True)
    if lnk_dir.is_dir():
        shutil.copytree(lnk_dir, lnk_box / "LanPlayer", dirs_exist_ok=True)
    if lnk_desk.exists():
        shutil.copy2(lnk_desk, lnk_box / lnk_desk.name)

    saved_install_dir = ""
    match = re.search(r"InstallDir\s+REG_SZ\s+(\S.*)", reg_query("InstallDir"))
    if match:
        saved_install_dir = match.group(1).strip()

    try:
        stop_app()
        if scratch.exists():
            shutil.rmtree(scratch, ignore_errors=True)

        # Point the registry at the scratch dir and let both installs find it the
        # way a double-clicking user would -- no /D.  That also covers the real
        # upgrade path: the new installer must honour the InstallDir left behind
        # by the old one instead of falling back to the default location.
        reg_add("InstallDir", str(scratch))
        seen = reg_query("InstallDir")
        if str(scratch) not in seen:
            raise lp.ScriptError(f"could not point InstallDir at scratch: {seen}")

        if run_setup(old_tmp, "/S") != 0:
            raise lp.ScriptError(f"baseline install of {old_version} failed")
        show_state(f"baseline-{old_version}", exe, dll)
        if not exe.exists():
            raise lp.ScriptError("baseline install did not land in the scratch dir")

        # Append marker bytes so "was the exe replaced" is byte-exact, then
        # remove a DLL as a second, fully independent signal.
        with exe.open("ab") as handle:
            handle.write(b"MARKER-PRE-UPGRADE")
        size_before = exe.stat().st_size
        dll.unlink(missing_ok=True)

        start_app(exe)
        time.sleep(5)
        show_state("old-version-running", exe, dll)

        # The whole test: an old build is running, nobody uninstalled anything.
        started = time.time()
        code = run_setup(new_tmp, "/S")
        elapsed_ms = int((time.time() - started) * 1000)
        time.sleep(2)
        show_state("after-upgrade", exe, dll)

        size_after = exe.stat().st_size if exe.exists() else None
        replaced = size_after != size_before
        dll_back = dll.exists()
        still_alive = len(processes()) > 0
        print(f"setup_exit={code} elapsed_ms={elapsed_ms}")
        print(f"verdict: exe_replaced={replaced} dll_restored={dll_back} old_still_alive={still_alive}")
        if not replaced or not dll_back or still_alive or code != 0:
            raise lp.ScriptError("upgrade-over-running-app FAILED")

        # Launch the upgraded copy once: proves the new binaries are not corrupt.
        start_app(exe)
        time.sleep(4)
        alive = processes()
        print(f"new_build_launch: procs=[{','.join(str(p) for p in alive)}]")
        if not alive:
            raise lp.ScriptError("upgraded build did not start")
    finally:
        stop_app()
        # Run the scratch copy's uninstaller so the fake install does not linger;
        # it is allowed to fail, the directory is removed anyway.
        uninstaller = scratch / "uninstall.exe"
        if uninstaller.exists():
            cmd([f'"{uninstaller}" /S'])
        wait_gone(scratch, 20)
        shutil.rmtree(scratch, ignore_errors=True)

        cmd(["reg", "import", str(bak_app)])
        cmd(["reg", "import", str(bak_un)])
        if saved_install_dir:
            reg_add("InstallDir", saved_install_dir)
        # Keys this script had to create leave an empty shell behind after the
        # import; drop them so the machine looks exactly as it did.
        for key in created_keys:
            cmd(["reg", "delete", key, "/f"])

        if (lnk_box / "LanPlayer").is_dir():
            lnk_dir.mkdir(parents=True, exist_ok=True)
            shutil.copytree(lnk_box / "LanPlayer", lnk_dir, dirs_exist_ok=True)
        desktop_backup = lnk_box / "LanPlayer.lnk"
        if desktop_backup.exists():
            shutil.copy2(desktop_backup, lnk_desk)
        shutil.rmtree(lnk_box, ignore_errors=True)
        for path in (old_tmp, new_tmp, bak_app, bak_un):
            path.unlink(missing_ok=True)

        startmenu_links = len(list(lnk_dir.iterdir())) if lnk_dir.is_dir() else 0
        print(f"restored desktop_lnk={lnk_desk.exists()} startmenu_lnks={startmenu_links}")
        if created_keys:
            print(f"restored registry: removed the {len(created_keys)} key(s) this run created")
        else:
            print(f"restored {reg_query('InstallDir').strip()}")

    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
