# Build the Android release APK (run on the Mac, or from Windows via .tools\mac.ps1).
#
# Prerequisites on the Mac:
#   1. ANDROID_NDK_HOME=<ndk> ./scripts/build_android_deps.sh arm64-v8a
#   2. a JDK 17 (Gradle 8.3 does not work on JDK 25) and the Android SDK
#
# Usage (on the Mac):
#   ./scripts/build_android_apk.sh
#   VERSION=0.1.3 ./scripts/build_android_apk.sh
#
# Output: dist/LanPlayer-<version>-android-arm64.apk
#
# The version comes from app/pubspec.yaml unless VERSION is set, so the APK,
# the Windows installer and the dmg all carry the same number when one release
# is built in one go.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="$ROOT/app/build/app/outputs/flutter-apk/app-release.apk"
OUT="$ROOT/dist"

if [ -z "${VERSION:-}" ]; then
  VERSION=$(sed -n 's/^version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$ROOT/app/pubspec.yaml" | head -n1)
fi
if [ -z "${VERSION:-}" ]; then
  echo "error: cannot read version from app/pubspec.yaml; pass VERSION=x.y.z" >&2
  exit 1
fi
DEST="$OUT/LanPlayer-${VERSION}-android-arm64.apk"

echo "== building apk ${VERSION} =="
cd "$ROOT/app"
flutter build apk --release --target-platform android-arm64

if [ ! -f "$APK" ]; then
  echo "error: missing $APK" >&2
  exit 1
fi

mkdir -p "$OUT"
cp "$APK" "$DEST"

echo "== built =="
ls -lh "$DEST"
echo "built: $DEST"
if command -v shasum >/dev/null 2>&1; then
  echo "sha256: $(shasum -a 256 "$DEST" | awk '{print $1}')"
else
  echo "sha256: $(sha256sum "$DEST" | awk '{print $1}')"
fi
