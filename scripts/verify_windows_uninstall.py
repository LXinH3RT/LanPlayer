#!/usr/bin/env python3
"""Verify the Windows uninstaller: it must quit a running copy, and it must only
delete the saved servers / settings / caches when asked to.

The uninstaller only exists after an install, so the test installs the given
setup into a scratch directory first, launches the app from there, and then runs
uninstall.exe while the app is still up.  Without the StopRunningApp macro,
Delete on lanplayer.exe and the DLLs fails (they are mapped images) and the
uninstall leaves a half-deleted directory behind.

Then two more rounds cover the user-data question:

  * a plain silent uninstall must KEEP the saved data -- losing the server list on
    every upgrade would be worse than the leak the option fixes;
  * /S /PURGE must remove it, together with the vendor directory when it ends up
    empty.

Installing and uninstalling rewrite HKCU\\Software\\LanPlayer, the Uninstall key
and the desktop / Start Menu shortcuts, none of which are scoped to $INSTDIR --
all of it is backed up first and restored at the end.  Check registry writes with
reg.exe: a read right after a write can return the old value.

    python scripts/verify_windows_uninstall.py
    python scripts/verify_windows_uninstall.py --setup dist/LanPlayer-0.1.4-windows-x64-setup.exe
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


def cmd(argv: list[str]) -> int:
    return subprocess.run(["cmd", "/c", *argv], text=True, capture_output=True,
                          encoding="mbcs", errors="replace").returncode


def launch(exe: Path, *extra: str) -> int:
    """Start the installer / uninstaller and wait for the launcher.

    Launched directly: cmd.exe strips the outermost quotes, so a path with
    spaces arrives broken and the install silently does nothing.  Only the
    uninstaller detaches (it copies itself to %TEMP% and returns at once).

    Each switch is its own argument: NSIS wants /D= last and unquoted, and
    folding "/S /D=..." into one string makes it a single unrecognised option.
    """
    return subprocess.run([str(exe), *extra], text=True, capture_output=True,
                          encoding="mbcs", errors="replace").returncode


def processes() -> list[int]:
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


def start_app(exe: Path) -> None:
    subprocess.Popen([str(exe)], cwd=str(exe.parent), close_fds=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL)


def wait_gone(directory: Path, timeout: float = 20.0) -> bool:
    """The uninstaller detaches, so its exit code says nothing about completion."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not directory.exists():
            return True
        time.sleep(0.25)
    return not directory.exists()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--setup", default="")
    parser.add_argument("--scratch", default="")
    args = parser.parse_args()

    root = lp.ROOT
    setup = Path(args.setup) if args.setup else (
        lp.DIST / f"LanPlayer-{lp.pubspec_version()}-windows-x64-setup.exe")
    if not setup.exists():
        raise lp.ScriptError(f"missing setup: {setup}")

    scratch = Path(args.scratch) if args.scratch else Path(os.environ.get("TEMP", ".")) / "lp-uninstall-test"
    temp = Path(os.environ.get("TEMP", "."))
    exe = scratch / "lanplayer.exe"
    unexe = scratch / "uninstall.exe"
    tmp_exe = temp / "lp-uninstall-fixture.exe"
    bak_app = temp / "lp-reg-app.reg"
    bak_un = temp / "lp-reg-un.reg"
    appdata = Path(os.environ.get("APPDATA", "."))
    userprofile = Path(os.environ.get("USERPROFILE", "."))
    lnk_dir = appdata / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "LanPlayer"
    lnk_desk = userprofile / "Desktop" / "LanPlayer.lnk"
    lnk_box = temp / "lp-shortcut-backup"

    # %TEMP% copy: keeps the run away from dist/ so a half-finished uninstall
    # cannot disturb the artefacts being tested.  (The Low label that files under
    # this checkout inherit does not lower the installer's token; the launching
    # shell's integrity does that.)
    shutil.copy2(setup, tmp_exe)

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

    saved_install_dir = ""
    query = subprocess.run(["cmd", "/c", "reg", "query", REG_APP, "/v", "InstallDir"],
                           text=True, capture_output=True, encoding="mbcs", errors="replace")
    match = re.search(r"InstallDir\s+REG_SZ\s+(\S.*)", (query.stdout or ""))
    if match:
        saved_install_dir = match.group(1).strip()

    if lnk_box.exists():
        shutil.rmtree(lnk_box, ignore_errors=True)
    lnk_box.mkdir(parents=True, exist_ok=True)
    if lnk_dir.is_dir():
        shutil.copytree(lnk_dir, lnk_box / "LanPlayer", dirs_exist_ok=True)
    if lnk_desk.exists():
        shutil.copy2(lnk_desk, lnk_box / lnk_desk.name)

    # The saved servers, settings and thumbnail cache live outside $INSTDIR, so an
    # uninstall that does not ask for them keeps them -- and a reinstall then
    # reconnects on its own.  The path is the one path_provider builds:
    # %APPDATA%\<CompanyName>\<ProductName> plus the app's own trailing directory.
    # Whichever directory is in use, this script must not touch the developer's
    # own copy, so the real one is moved aside first and put back in finally.
    state_dir = appdata / "dev.lanplayer" / "lanplayer" / "lanplayer"
    state_bak = temp / "lp-state-backup"
    marker = state_dir / "lp-purge-marker.json"

    def write_state_fixture() -> None:
        shutil.rmtree(state_dir, ignore_errors=True)
        (state_dir / "thumbs").mkdir(parents=True, exist_ok=True)
        lp.write_text(marker, '{"servers":[{"host":"192.0.2.1"}]}',
                      encoding="ascii", newline="")
        lp.write_text(state_dir / "settings.json", "{}", encoding="ascii", newline="")
        lp.write_text(state_dir / "thumbs" / "a.jpg", "x", encoding="ascii", newline="")

    def restore_state() -> None:
        shutil.rmtree(state_dir, ignore_errors=True)
        if state_bak.exists():
            state_dir.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(state_bak), str(state_dir))

    # Move the real state aside before any fixture is written.
    if state_dir.exists():
        shutil.rmtree(state_bak, ignore_errors=True)
        shutil.move(str(state_dir), str(state_bak))
    print(f"state_backed_up={state_bak.exists()}")

    try:
        stop_app()
        shutil.rmtree(scratch, ignore_errors=True)

        # 1. Real install into the scratch directory; this is what creates
        #    uninstall.exe.  /D= has to be last and unquoted.
        code = launch(tmp_exe, "/S", f"/D={scratch}")
        print(f"install_exit={code} uninstaller={unexe.exists()} exe={exe.exists()}")
        if not unexe.exists():
            raise lp.ScriptError("installer did not produce uninstall.exe")

        # 2. Start it and leave it running.
        start_app(exe)
        time.sleep(5)
        running = len(processes())
        print(f"app_running={running > 0} files_before={len([p for p in scratch.iterdir() if p.is_file()])}")

        # 3. Uninstall without closing it first -- the whole point.
        started = time.time()
        code = launch(unexe, "/S")
        elapsed_ms = int((time.time() - started) * 1000)
        gone = wait_gone(scratch, 20)
        time.sleep(0.5)

        left = [p.name for p in scratch.iterdir() if p.is_file()] if scratch.is_dir() else []
        alive = len(processes())
        print(f"uninstall_exit={code} launcher_ms={elapsed_ms} waited_gone={gone}")
        print(f"leftover_files={len(left)} leftovers=[{','.join(left)}] app_still_alive={alive > 0}")
        print(f"dir_left={scratch.exists()}")
        if alive or left or code != 0:
            raise lp.ScriptError("uninstall-over-running-app FAILED")

        # 4. A plain silent uninstall must keep the saved data.
        write_state_fixture()
        launch(tmp_exe, "/S", f"/D={scratch}")
        if not unexe.exists():
            raise lp.ScriptError("second install did not produce uninstall.exe")
        launch(unexe, "/S")
        keep_gone = wait_gone(scratch, 20)
        time.sleep(0.5)
        marker_kept = marker.exists()
        state_kept = state_dir.exists()
        print(f"silent-keep: removed_app={keep_gone} state_dir={state_kept} marker={marker_kept}")
        if not state_kept or not marker_kept:
            raise lp.ScriptError("silent uninstall deleted the saved data; it must need /PURGE")

        # 5. ... and /PURGE must remove it, together with the wrapper directories
        #    when they end up empty.
        write_state_fixture()
        launch(tmp_exe, "/S", f"/D={scratch}")
        if not unexe.exists():
            raise lp.ScriptError("third install did not produce uninstall.exe")
        launch(unexe, "/S", "/PURGE")
        purge_gone = wait_gone(scratch, 20)
        time.sleep(0.5)
        state_after = state_dir.exists()
        vendor = appdata / "dev.lanplayer"
        print(f"silent-purge: removed_app={purge_gone} state_dir={state_after} vendor_dir={vendor.exists()}")
        if state_after or marker.exists():
            raise lp.ScriptError("uninstall /PURGE left the saved data behind")
    finally:
        stop_app()
        shutil.rmtree(scratch, ignore_errors=True)
        restore_state()

        # Restore through cmd /c with the streams discarded: reg.exe writes
        # ordinary notices to stderr, and letting those through as text turned
        # into noise that made a good restore look broken.
        cmd(["reg", "import", str(bak_app)])
        cmd(["reg", "import", str(bak_un)])
        if saved_install_dir:
            cmd(["reg", "add", REG_APP, "/v", "InstallDir", "/t", "REG_SZ",
                 "/d", saved_install_dir, "/f"])
        for key in created_keys:
            cmd(["reg", "delete", key, "/f"])

        # Shortcuts live outside $INSTDIR, so the uninstaller always takes them.
        if (lnk_box / "LanPlayer").is_dir():
            lnk_dir.mkdir(parents=True, exist_ok=True)
            shutil.copytree(lnk_box / "LanPlayer", lnk_dir, dirs_exist_ok=True)
        desktop_backup = lnk_box / "LanPlayer.lnk"
        if desktop_backup.exists():
            shutil.copy2(desktop_backup, lnk_desk)
        shutil.rmtree(lnk_box, ignore_errors=True)
        for path in (bak_app, bak_un, tmp_exe):
            path.unlink(missing_ok=True)

        startmenu_links = len(list(lnk_dir.iterdir())) if lnk_dir.is_dir() else 0
        print(f"restored desktop_lnk={lnk_desk.exists()} startmenu_lnks={startmenu_links}")

    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
