# Build the macOS dmg (run on the Mac, or from Windows via .tools\mac.ps1).
#
# Prerequisites on the Mac:
#   1. SLICES=macosx ./scripts/build_apple_deps.sh
#   2. cd app && flutter build macos --release
#
# Usage (on the Mac):
#   ./scripts/build_macos_dmg.sh
#   VERSION=0.2.0 ./scripts/build_macos_dmg.sh
#
# Output: dist/LanPlayer-<version>-macos-<arch>.dmg
#
# The dmg holds LanPlayer.app plus an /Applications symlink, so the user drags
# the app over to install it. Ad-hoc signed (codesign -s -), which is enough for
# local use; distribution still needs a Developer ID certificate and
# notarization, otherwise Gatekeeper shows "cannot be opened".
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/app/build/macos/Build/Products/Release/lanplayer.app"
VERSION="${VERSION:-0.1.0}"
ARCH="$(uname -m)"
OUT="$ROOT/dist"
DMG="$OUT/LanPlayer-${VERSION}-macos-${ARCH}.dmg"
VOL="LanPlayer"
STAGE="$OUT/.dmg-stage"

if [ ! -d "$APP" ]; then
  echo "error: missing $APP" >&2
  echo "run: cd app && flutter build macos --release" >&2
  exit 1
fi

echo "== app =="
du -sh "$APP"
/usr/bin/codesign -dv "$APP" 2>&1 | sed -n '1,3p' || true

mkdir -p "$OUT"
rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "== copy =="
# ditto, not cp -R: it preserves the extended attributes and the code signature.
# Do NOT also create a lower-case alias here -- APFS is case-insensitive by
# default, so LanPlayer.app and lanplayer.app would be the same directory and
# the second cleanup would delete the app we just copied.
/usr/bin/ditto "$APP" "$STAGE/LanPlayer.app"
ln -s /Applications "$STAGE/Applications"
du -sh "$STAGE/LanPlayer.app"

echo "== codesign verify =="
/usr/bin/codesign --verify --deep --strict "$STAGE/LanPlayer.app"
echo "  signature ok"

echo "== hdiutil create =="
rm -f "$DMG"
# -format UDZO: compressed, read-only; zlib-level=9 for the smallest size.
hdiutil create -volname "$VOL" \
  -srcfolder "$STAGE" \
  -ov -format UDZO -imagekey zlib-level=9 \
  "$DMG" 2>&1 | grep -v 'is deprecated' || true

if [ ! -f "$DMG" ]; then
  echo "error: hdiutil produced no dmg" >&2
  exit 1
fi

echo "== verify =="
hdiutil verify "$DMG" 2>&1 | tail -2
ls -lh "$DMG"

rm -rf "$STAGE"
echo ""
echo "built: $DMG"
echo "sha256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
