#!/usr/bin/env python3
"""Build the macOS dmg.

Run on macOS, after the native libraries and the Flutter bundle are built:

    SLICES=macosx python scripts/build_apple_deps.py
    cd app && flutter build macos --release
    python scripts/build_macos_dmg.py

    VERSION=0.2.0 python scripts/build_macos_dmg.py

Output: dist/LanPlayer-<version>-macos-<arch>.dmg

The dmg holds LanPlayer.app plus an /Applications symlink, so the user drags the
app over to install it.  Ad-hoc signed (codesign -s -), which is enough for
local use; distribution still needs a Developer ID certificate and
notarization, otherwise Gatekeeper shows "cannot be opened".
"""
from __future__ import annotations

import os
import platform
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402

DITTO = "/usr/bin/ditto"
CODESIGN = "/usr/bin/codesign"
HDIUTIL = "/usr/bin/hdiutil"


def main() -> int:
    if sys.platform != "darwin":
        raise lp.ScriptError("dmg builds need macOS")

    app = lp.ROOT / "app" / "build" / "macos" / "Build" / "Products" / "Release" / "lanplayer.app"
    version = os.environ.get("VERSION", "").strip() or lp.pubspec_version()
    if not version:
        raise lp.ScriptError("cannot read the version from app/pubspec.yaml; pass VERSION=x.y.z")

    arch = platform.machine()
    out = lp.ROOT / "dist"
    dmg = out / f"LanPlayer-{version}-macos-{arch}.dmg"
    stage = out / ".dmg-stage"

    if not app.is_dir():
        raise lp.ScriptError("missing app bundle\nrun: cd app && flutter build macos --release")

    lp.step("app")
    print(f"  {lp.size_mb(app):.1f} MB  {app}")
    signature = lp.run([CODESIGN, "-dv", str(app)], check=False, capture=True)
    for line in ((signature.stderr or "") + (signature.stdout or "")).splitlines()[:3]:
        print(f"  {line}")

    out.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)

    lp.step("copy")
    # ditto, not cp -R: it preserves the extended attributes and the signature.
    # Do NOT also create a lower-case alias here -- APFS is case-insensitive by
    # default, so LanPlayer.app and lanplayer.app would be the same directory
    # and the second cleanup would delete the app we just copied.
    lp.run([DITTO, str(app), str(stage / "LanPlayer.app")])
    os.symlink("/Applications", stage / "Applications")
    print(f"  {lp.size_mb(stage / 'LanPlayer.app'):.1f} MB")

    lp.step("codesign verify")
    expected = os.environ.get("WANT_IDENTITY", "").strip()
    lp.run([CODESIGN, "--verify", "--deep", "--strict", str(stage / "LanPlayer.app")])
    print("  signature ok")
    if expected:
        info = lp.run([CODESIGN, "-dv", "--verbose=2", str(stage / "LanPlayer.app")],
                      check=False, capture=True)
        text = (info.stderr or "") + (info.stdout or "")
        if f"Authority={expected}" not in text:
            raise lp.ScriptError(f"the app is not signed with {expected}")

    lp.step("hdiutil create")
    dmg.unlink(missing_ok=True)
    # -format UDZO: compressed, read-only; zlib-level=9 for the smallest size.
    create = lp.run([HDIUTIL, "create", "-volname", "LanPlayer",
                     "-srcfolder", str(stage),
                     "-ov", "-format", "UDZO", "-imagekey", "zlib-level=9",
                     str(dmg)], check=False, capture=True)
    if create.returncode != 0:
        raise lp.ScriptError(f"hdiutil create failed\n{(create.stderr or '')[-800:]}")
    for line in (create.stdout or "").splitlines():
        if "deprecated" not in line:
            print(f"  {line}")

    if not dmg.exists():
        raise lp.ScriptError("hdiutil produced no dmg")

    lp.step("verify")
    verify = lp.run([HDIUTIL, "verify", str(dmg)], check=False, capture=True)
    for line in (verify.stdout or "").splitlines()[-2:]:
        print(f"  {line}")
    print(f"  {lp.size_mb(dmg):.1f} MB  {dmg}")

    shutil.rmtree(stage, ignore_errors=True)
    print("")
    print(f"built: {dmg}")
    print(f"sha256: {lp.sha256(dmg)}")
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
