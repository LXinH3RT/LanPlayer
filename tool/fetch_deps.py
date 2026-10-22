#!/usr/bin/env python3
"""Download the Windows build dependencies for the native core.

The corporate/CI sandbox on this machine blocks Schannel (so curl.exe and
Invoke-WebRequest fail with SEC_E_NO_CREDENTIALS), while Python's OpenSSL stack
works, so downloads go through urllib here.

    python tool/fetch_deps.py            # everything
    python tool/fetch_deps.py --list     # just show what would be fetched

Artifacts land in .tools/ (git-ignored) and are pinned by version so a rebuild
is reproducible.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tarfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

# The Windows console defaults to a legacy code page that cannot represent
# the marks printed below; force UTF-8 so the report is readable everywhere.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / ".tools"

ARTIFACTS = {
    "zig": {
        "url": "https://ziglang.org/download/0.13.0/zig-windows-x86_64-0.13.0.zip",
        "dest": "zig.zip",
        "extract_to": "zig",
        "strip": 1,  # the zip contains a single zig-windows-x86_64-0.13.0/ root
        "why": "C compiler (clang + mingw-w64 libc + lld; links MSVC .lib fine)",
    },
    "ffmpeg": {
        "url": "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/"
               "ffmpeg-master-latest-win64-gpl-shared.zip",
        "dest": "ffmpeg.zip",
        "extract_to": "ffmpeg",
        "strip": 1,
        "why": "FFmpeg 7.x shared build: include/, lib/*.lib, bin/*.dll + ffmpeg.exe",
    },
    "libsmb2": {
        "url": "https://github.com/sahlberg/libsmb2/archive/refs/tags/v4.0.0.zip",
        "dest": "libsmb2.zip",
        "extract_to": "libsmb2",
        "strip": 1,
        "why": "SMB2/3 client sources (built later with zig cc)",
    },
    "dart": {
        "url": "https://storage.googleapis.com/dart-archive/channels/stable/release/"
               "3.5.4/sdk/dartsdk-windows-x64-release.zip",
        "dest": "dart.zip",
        "extract_to": "dart",
        "strip": 1,
        "why": "standalone Dart SDK: `dart format` parses every .dart file",
    },
    # Flutter SDK: provides the Windows plugin headers and the flutter tool.
    # Building a Windows app from it still requires Visual Studio (MSVC).
    "flutter": {
        "url": "https://storage.googleapis.com/flutter_infra_release/releases/stable/"
               "windows/flutter_windows_3.27.4-stable.zip",
        "dest": "flutter-sdk.zip",
        "extract_to": "flutter-sdk",
        "strip": 1,
        "why": "Flutter 3.27.4 SDK (engine headers for the Windows plugin)",
    },
    # Standalone Dart packages for the checks that do not need Flutter.
    # The app itself resolves everything through `flutter pub get`.
    "ffi": {
        "url": "https://pub.dev/api/archives/ffi-2.1.3.tar.gz",
        "dest": "ffi.tar.gz",
        "extract_to": "pub3/ffi",
        "strip": 0,
        "why": "dart:ffi helpers used by app/lib/core/bindings.dart",
    },
    "path_provider": {
        "url": "https://pub.dev/api/archives/path_provider-2.1.5.tar.gz",
        "dest": "path_provider.tar.gz",
        "extract_to": "pub3/path_provider",
        "strip": 0,
        "why": "state-directory lookup; drives the desktop persistence path",
    },
    # NSIS only builds the Windows installer; everything else works without it.
    # The zip keeps its own nsis-3.10/ root (strip 0) because NSIS resolves
    # Stubs/, Plugins/ and Contrib/ relative to the directory holding
    # makensis.exe, so moving Bin/ up on its own breaks it.
    "nsis": {
        "url": "https://downloads.sourceforge.net/project/nsis/NSIS%203/"
               "3.10/nsis-3.10.zip",
        "dest": "nsis.zip",
        "extract_to": "nsis",
        "strip": 0,
        "why": "NSIS 3.10: makensis.exe for scripts/windows/installer.nsi",
    },
}

def write_package_config() -> None:
    """Writes app/.dart_tool/package_config.json for the standalone checks.

    This file normally belongs to `flutter pub get`, which resolves all 38
    packages the app imports. The standalone checks only need a handful, but
    overwriting the full file would break the next Flutter build, so an
    existing file that already lists every package this function wants is left
    untouched and only a missing/one-package stub is written.
    """
    app = ROOT / "app"
    cfg_dir = app / ".dart_tool"
    cfg_file = cfg_dir / "package_config.json"

    def built() -> dict[str, dict]:
        return {"configVersion": 2, "packages": [{
            "name": "lanplayer",
            "rootUri": "../",
            "packageUri": "lib/",
            "languageVersion": "3.4",
        }]}

    needed = (("ffi", "3.0"), ("path_provider", "3.0"))
    pkgs = built()["packages"]
    missing = []
    for name, lang in needed:
        directory = TOOLS / "pub3" / name
        if not (directory / "pubspec.yaml").exists():
            missing.append(name)
            continue
        pkgs.append({
            "name": name,
            "rootUri": directory.as_uri(),
            "packageUri": "lib/",
            "languageVersion": lang,
        })

    if cfg_file.exists():
        try:
            have = {p["name"] for p in
                    json.loads(cfg_file.read_text(encoding="utf-8"))["packages"]}
        except (json.JSONDecodeError, KeyError, OSError):
            have = set()
        if have >= {p["name"] for p in pkgs}:
            print(f"  keep {cfg_file.relative_to(ROOT)} "
                  f"({len(have)} packages, already complete)")
            if missing:
                print(f"  skip standalone {', '.join(missing)}: not fetched yet")
            return

    cfg_dir.mkdir(parents=True, exist_ok=True)
    cfg_file.write_text(
        json.dumps({"configVersion": 2, "packages": pkgs}, indent=2) + "\n",
        encoding="utf-8")
    print(f"  wrote {cfg_file.relative_to(ROOT)} "
          f"({len(pkgs)} packages -- rerun `flutter pub get` before building)")

def human(n: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GiB"

def download(url: str, dest: Path, retries: int = 4) -> None:
    if dest.exists() and dest.stat().st_size > 0:
        print(f"  cached {dest.name} ({human(dest.stat().st_size)})")
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    last_err: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "lanplayer-fetch/1"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                total = int(resp.headers.get("Content-Length") or 0)
                print(f"  GET {url}\n       -> {dest} ({human(total) if total else 'size unknown'})")
                got = 0
                t0 = time.time()
                with open(part, "wb") as fh:
                    while True:
                        chunk = resp.read(1024 * 256)
                        if not chunk:
                            break
                        fh.write(chunk)
                        got += len(chunk)
                        if total and got % (1024 * 1024 * 8) < 1024 * 256:
                            pct = got * 100 // total
                            speed = got / max(1e-6, time.time() - t0)
                            print(f"       {pct:3d}%  {human(got)}  {human(speed)}/s", flush=True)
            if total and part.stat().st_size != total:
                raise IOError(f"size mismatch: {part.stat().st_size} != {total}")
            part.replace(dest)
            print(f"  done  {dest.name} ({human(dest.stat().st_size)})")
            return
        except (urllib.error.URLError, IOError, TimeoutError) as exc:
            last_err = exc
            print(f"  attempt {attempt}/{retries} failed: {exc}")
            part.unlink(missing_ok=True)
            time.sleep(2 * attempt)
    raise SystemExit(f"download failed: {url}: {last_err}")

def extract(archive: Path, dest: Path, strip_dirs: int = 1) -> None:
    if dest.exists() and any(dest.iterdir()):
        print(f"  cached {dest.name}/")
        return
    dest.mkdir(parents=True, exist_ok=True)
    tmp = dest.parent / (dest.name + ".tmp")
    if tmp.exists():
        try:
            shutil.rmtree(tmp)
        except OSError:
            tmp = dest.parent / (dest.name + f".tmp{os.getpid()}")
    tmp.mkdir(parents=True)
    print(f"  extract {archive.name} -> {dest}")
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(tmp)
    elif archive.name.endswith((".tar.xz", ".tar.gz", ".tgz")):
        # tarfile.extractall() creates directories with mode 0700, which the
        # Windows sandbox turns into unreadable directories; create them with
        # default permissions and copy file contents ourselves.
        with tarfile.open(archive) as tf:
            for member in tf.getmembers():
                target = tmp / member.name
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    source = tf.extractfile(member)
                    if source is not None:
                        with source, open(target, "wb") as out:
                            shutil.copyfileobj(source, out)
    else:
        raise SystemExit(f"unknown archive type: {archive}")

    entries = [p for p in tmp.iterdir()]
    root = tmp
    if strip_dirs > 0 and len(entries) == 1 and entries[0].is_dir():
        root = entries[0]
    for item in root.iterdir():
        target = dest / item.name
        if target.exists():
            if target.is_dir():
                shutil.rmtree(target)
            else:
                target.unlink()
        shutil.move(str(item), str(target))
    shutil.rmtree(tmp)

def find_exe(path: Path, name: str) -> Path | None:
    for p in path.rglob(name):
        if p.is_file():
            return p
    return None

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("only", nargs="*",
                    help="subset: zig ffmpeg libsmb2 dart flutter nsis")
    args = ap.parse_args(argv)

    names = args.only or list(ARTIFACTS)
    for name in names:
        spec = ARTIFACTS.get(name)
        if not spec:
            print(f"unknown artifact {name}")
            return 2
        print(f"== {name}: {spec['why']}")
        if args.list:
            print(f"   {spec['url']}")
            continue
        target = TOOLS / spec["extract_to"]
        # The unpacked tree is what every script uses, so it alone decides
        # whether work is needed. The archives are deleted after unpacking to
        # keep the checkout small; re-downloading them for nothing would undo
        # that on the very next invocation.
        if target.exists() and any(target.iterdir()):
            print(f"  cached {target.name}/")
            continue
        archive = TOOLS / spec["dest"]
        download(spec["url"], archive)
        extract(archive, target, spec["strip"])
        # Unpacked and verified -- the multi-hundred-MB archive has no further
        # use and the extract target is the cache.
        archive.unlink(missing_ok=True)
        print(f"  removed {archive.name} (extracted into {target.name}/)")

    if not args.list:
        zig = find_exe(TOOLS / "zig", "zig.exe")
        ffmpeg_exe = find_exe(TOOLS / "ffmpeg", "ffmpeg.exe")
        dart = find_exe(TOOLS / "dart", "dart.exe")
        print("\nresolved:")
        print(f"  zig      {zig}")
        print(f"  ffmpeg   {ffmpeg_exe}")
        print(f"  dart     {dart}")
        write_package_config()
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
