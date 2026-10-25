#!/usr/bin/env python3
"""Build the Android release APK.

Run on the machine that has the Android toolchain (the build host), because the
APK links the native libraries for arm64-v8a and needs the SDK, the NDK and a
JDK 17 (Gradle 8.3 does not work on JDK 25).

Prerequisites on the build host:
    ANDROID_NDK_HOME=<ndk> python scripts/build_android_deps.py arm64-v8a
    a JDK 17 and the Android SDK in ANDROID_SDK_ROOT / ANDROID_HOME

    python scripts/build_android_apk.py
    VERSION=0.2.0 python scripts/build_android_apk.py

Output: dist/LanPlayer-<version>-android-arm64.apk

The version comes from app/pubspec.yaml unless VERSION is set, so the APK, the
Windows installer and the dmg all carry the same number when one release is
built in one go.
"""
from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402


def flutter_cmd() -> list[str]:
    """The flutter launcher, wherever this host keeps it."""
    override = os.environ.get("FLUTTER")
    if override:
        return [override]
    bundled = lp.TOOLS / "flutter-sdk" / "bin" / "flutter"
    if bundled.exists():
        return [str(bundled)]
    found = shutil.which("flutter")
    if found:
        return [found]
    home = Path(os.environ.get("HOME", "")) / "development" / "flutter" / "bin" / "flutter"
    if home.exists():
        return [str(home)]
    raise lp.ScriptError("flutter not found; set FLUTTER=<path to flutter>")


def main() -> int:
    app = lp.ROOT / "app"
    apk = app / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
    out = lp.ROOT / "dist"

    version = os.environ.get("VERSION", "").strip() or lp.pubspec_version()
    if not version:
        raise lp.ScriptError("cannot read version from app/pubspec.yaml; pass VERSION=x.y.z")
    dest = out / f"LanPlayer-{version}-android-arm64.apk"

    env = dict(os.environ)
    # Build hosts commonly ship the toolchain outside the default PATH.
    for extra in ("/opt/homebrew/bin", str(Path(os.environ.get("HOME", "")) / "development" / "flutter" / "bin")):
        if Path(extra).is_dir() and extra not in env.get("PATH", ""):
            env["PATH"] = extra + os.pathsep + env.get("PATH", "")
    if not any(env.get(k) for k in ("ANDROID_SDK_ROOT", "ANDROID_HOME")):
        lp.warn("neither ANDROID_SDK_ROOT nor ANDROID_HOME is set; "
                "flutter may fail to locate the Android SDK")

    lp.step(f"building apk {version}")
    result = lp.run([*flutter_cmd(), "build", "apk", "--release",
                     "--target-platform", "android-arm64"], cwd=app, env=env, check=False)
    if result.returncode != 0:
        raise lp.ScriptError(f"flutter build apk failed with {result.returncode}")
    if not apk.exists():
        raise lp.ScriptError(f"missing {apk}")

    out.mkdir(parents=True, exist_ok=True)
    shutil.copy2(apk, dest)

    lp.step("built")
    print(f"{dest}  ({lp.size_mb(dest):.1f} MB)")
    print(f"built: {dest}")
    print(f"sha256: {lp.sha256(dest)}")
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
