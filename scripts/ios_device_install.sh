#!/bin/zsh
# ============================================================================
# LanPlayer iOS 真机安装 / LanPlayer iOS device install
#
# 用法 / Usage:
#   TEAM_ID=ABCD123456 ./scripts/ios_device_install.sh [UDID]
#
# 需要 / Requires:
#   - 已插线并信任过这台 Mac（或开了无线调试）
#   - Xcode 里登录过 Apple ID，且生成了 Apple Development 证书
#   - native/third_party/*/apple/iphoneos/lib 已用
#       SLICES=iphoneos ./scripts/build_apple_deps.sh
#     编好
#
# 做的事 / What it does:
#   1. 把 DEVELOPMENT_TEAM 写进 iOS 工程的 Debug/Release 配置
#   2. flutter build ios --release（带签名）
#   3. devicectl 安装到 iPad
#   4. 启动并挂日志
# ============================================================================
set -eu

TEAM_ID="${TEAM_ID:?set TEAM_ID=<10 位 Team ID，Xcode → Settings → Accounts 里能看到>}"
UDID="${1:-<UDID>}"
BUNDLE_ID="dev.lanplayer.lanplayer"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export PATH="/opt/homebrew/bin:$HOME/development/flutter/bin:$PATH"
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export COCOAPODS_DISABLE_STATS=true

PBX="app/ios/Runner.xcodeproj/project.pbxproj"

echo "== 1. 写入 DEVELOPMENT_TEAM=$TEAM_ID =="
# 每个 PRODUCT_BUNDLE_IDENTIFIER 的 target 都要有 team，否则 xcodebuild 报
# "Signing for Runner requires a development team"。
if grep -q 'DEVELOPMENT_TEAM' "$PBX"; then
  /usr/bin/sed -i '' -E "s/DEVELOPMENT_TEAM = [^;]*;/DEVELOPMENT_TEAM = $TEAM_ID;/g" "$PBX"
else
  # BSD sed 的替换式里不能出现真正的换行（会报 unescaped newline inside
  # substitute pattern），所以用 awk 在 bundle id 那一行后面追加一行。
  /usr/bin/awk -v team="$TEAM_ID" '
    /PRODUCT_BUNDLE_IDENTIFIER = dev\.lanplayer\.lanplayer;/ {
      print $0
      match($0, /^[ \t]*/)
      print substr($0, 1, RLENGTH) "DEVELOPMENT_TEAM = " team ";"
      next
    }
    { print }
  ' "$PBX" > "$PBX.tmp" && mv "$PBX.tmp" "$PBX"
fi
grep -c "DEVELOPMENT_TEAM = $TEAM_ID;" "$PBX" | sed 's/^/  occurrences: /'

echo
echo "== 2. 确认签名身份 =="
security find-identity -v -p codesigning | tail -3

echo
echo "== 3. 构建（Release，自动签名）=="
cd app
flutter build ios --release 2>&1 | tail -20
cd ..

APP="app/build/ios/iphoneos/Runner.app"
if [ ! -d "$APP" ]; then
  echo "构建失败：$APP 不存在" >&2
  exit 2
fi
echo "  产物：$(du -sh "$APP" | cut -f1)"

echo
echo "== 4. 装到 iPad $UDID =="
xcrun devicectl device install app --device "$UDID" "$APP" 2>&1 | grep -E 'App installed|bundleID|error|Error' | head -10

echo
echo "== 5. 启动 =="
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" 2>&1 | head -6

echo
echo "== 完成。看日志： =="
echo "   xcrun devicectl device process launch --console --device $UDID $BUNDLE_ID"
