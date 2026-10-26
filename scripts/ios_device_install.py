#!/usr/bin/env python3
"""Install a release build on a connected iOS device.

    TEAM_ID=ABCD123456 python scripts/ios_device_install.py [UDID]

Requires:
    - the device paired and trusted with this Mac (or wireless debugging on)
    - an Apple Development certificate in the keychain (Xcode > Settings >
      Accounts)
    - native/third_party/*/apple/iphoneos/lib built with
      SLICES=iphoneos python scripts/build_apple_deps.py

What it does:
    1. writes DEVELOPMENT_TEAM into the iOS project's Debug/Release configs
    2. flutter build ios --release (signed)
    3. devicectl install
    4. launch, then leave the console attached
"""
from __future__ import annotations

import os
import re
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402

BUNDLE_ID = "dev.lanplayer.lanplayer"
PBX = Path("app/ios/Runner.xcodeproj/project.pbxproj")


def write_team(pbx: Path, team: str) -> int:
    """Set DEVELOPMENT_TEAM on every target that carries the bundle id."""
    text = pbx.read_text(encoding="utf-8")
    pattern = re.compile(r"DEVELOPMENT_TEAM = [^;]*;")
    if pattern.search(text):
        text = pattern.sub(f"DEVELOPMENT_TEAM = {team};", text)
        count = len(pattern.findall(pbx.read_text(encoding="utf-8")))
    else:
        # No team line yet: add one right after every PRODUCT_BUNDLE_IDENTIFIER
        # line for our bundle, matching that line's indentation.  A regex with
        # a multiline replacement is avoided on purpose - older sed builds
        # reject a real newline inside a substitute pattern.
        out: list[str] = []
        for line in text.splitlines(keepends=True):
            out.append(line)
            if f"PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};" in line:
                indent = re.match(r"[ \t]*", line).group(0)
                out.append(f"{indent}DEVELOPMENT_TEAM = {team};\n")
        text = "".join(out)
        count = text.count(f"DEVELOPMENT_TEAM = {team};")

    lp.write_text(pbx, text, newline="")
    return count


def flutter_cmd() -> list[str]:
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
    if sys.platform != "darwin":
        raise lp.ScriptError("installing on an iOS device needs macOS")

    team = os.environ.get("TEAM_ID", "").strip()
    if not team:
        raise lp.ScriptError("set TEAM_ID=<10-character team id from Xcode > Settings > Accounts>")
    udid = (sys.argv[1] if len(sys.argv) > 1 else "").strip() or "<UDID>"

    root = lp.ROOT
    os.chdir(root)

    env = dict(os.environ)
    for extra in (str(Path(os.environ.get("HOME", "")) / "development" / "flutter" / "bin"),
                  "/opt/homebrew/bin"):
        if Path(extra).is_dir() and extra not in env.get("PATH", ""):
            env["PATH"] = extra + os.pathsep + env.get("PATH", "")
    env.setdefault("PUB_HOSTED_URL", "https://pub.flutter-io.cn")
    env.setdefault("FLUTTER_STORAGE_BASE_URL", "https://storage.flutter-io.cn")
    env.setdefault("COCOAPODS_DISABLE_STATS", "true")

    pbx = root / PBX
    if not pbx.exists():
        raise lp.ScriptError(f"missing {pbx}")

    lp.step(f"1. DEVELOPMENT_TEAM={team}")
    # Every target with a PRODUCT_BUNDLE_IDENTIFIER needs a team, otherwise
    # xcodebuild reports "Signing for Runner requires a development team".
    print(f"  occurrences: {write_team(pbx, team)}")

    lp.step("2. signing identities")
    identities = lp.run(["security", "find-identity", "-v", "-p", "codesigning"],
                        check=False, capture=True)
    for line in ((identities.stdout or "") + (identities.stderr or "")).splitlines()[-3:]:
        print(f"  {line}")

    lp.step("3. build (Release, automatic signing)")
    build = lp.run([*flutter_cmd(), "build", "ios", "--release"],
                   cwd=root / "app", env=env, check=False, capture=True)
    for line in ((build.stdout or "") + (build.stderr or "")).splitlines()[-20:]:
        print(f"  {line}")
    if build.returncode != 0:
        raise lp.ScriptError(f"flutter build ios failed with {build.returncode}")

    app = root / "app" / "build" / "ios" / "iphoneos" / "Runner.app"
    if not app.is_dir():
        raise lp.ScriptError(f"build produced no app bundle at {app}")
    print(f"  size: {lp.size_mb(app):.1f} MB")

    lp.step(f"4. install on {udid}")
    install = lp.run(["xcrun", "devicectl", "device", "install", "app",
                      "--device", udid, str(app)], check=False, capture=True)
    text = (install.stdout or "") + (install.stderr or "")
    for line in [l for l in text.splitlines()
                 if re.search(r"App installed|bundleID|error|Error", l)][:10]:
        print(f"  {line}")
    if install.returncode != 0:
        raise lp.ScriptError(f"devicectl install failed with {install.returncode}")

    lp.step("5. launch")
    launch = lp.run(["xcrun", "devicectl", "device", "process", "launch",
                     "--device", udid, BUNDLE_ID], check=False, capture=True)
    for line in ((launch.stdout or "") + (launch.stderr or "")).splitlines()[:6]:
        print(f"  {line}")

    print("")
    print("done. logs:")
    print(f"  xcrun devicectl device process launch --console --device {udid} {BUNDLE_ID}")
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
