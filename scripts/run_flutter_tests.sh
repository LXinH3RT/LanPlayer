#!/usr/bin/env bash
# 在 Windows 上跑 Flutter 测试。为什么需要这个壳：
# 这台机器的 %APPDATA%/%PUB_CACHE% 落在不可写的位置，flutter tool 一启动就
# 在 `~/.flutter_tool_state` 上失败（`Error: Flutter failed to write to a file
# at ...\.flutter_tool_state`）。所以把临时目录和 pub 缓存都重定向到仓库内的
# `.tools/`，再调用 SDK。
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tools="$here/.tools"
mkdir -p "$tools/tmp" "$tools/appdata" "$tools/pubcache"

export TMP="$tools/tmp"
export TEMP="$tools/tmp"
export APPDATA="$tools/appdata"
# `flutter analyze` 还要用 %LOCALAPPDATA%\.dartServer 放分析服务器的状态，
# 真实目录同样不可写（PathAccessException: Creation failed ... .dartServer）。
export LOCALAPPDATA="$tools/appdata"
export PUB_CACHE="$tools/pubcache"

cd "$here/app"

if [ "$#" -eq 0 ]; then
  set -- test
fi

exec "$tools/flutter-sdk/bin/flutter" "$@"
