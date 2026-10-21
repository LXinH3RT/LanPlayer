# Re-creates the plugin links Flutter expects under
# app\windows\flutter\ephemeral\.plugin_symlinks\.
#
# Why this exists: `flutter pub get` / `flutter build windows` call Dart's
# Link.createSync for every plugin that has a windows/ folder.  On a machine
# where the shell token has no SeCreateSymbolicLinkPrivilege (plain user,
# "开发者模式" enabled or not, medium integrity level) that call throws
#   FileSystemException: Cannot create link ... (OS Error: 客户端没有所需的特权。, errno = 1314)
# and the tool aborts with
#   "Building with plugins requires symlink support."
#
# Directory junctions are created with mklink /J and need NO privilege, and Dart
# reports them as FileSystemEntityType.link with Link.existsSync() == true.
# flutter_tools/lib/src/flutter_plugins.dart:_createPlatformPluginSymlinks does
#   if (link.existsSync()) continue;
# before creating the link, so a pre-made junction is accepted as-is.
#
# Run this once per checkout (and again after `flutter clean` or after adding a
# plugin with a windows/ implementation):
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fix_plugin_links.ps1
param(
    [string]$App = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $App) { $App = Join-Path $root 'app' }
$links = Join-Path $App 'windows\flutter\ephemeral\.plugin_symlinks'

$seen = @{}

function Add-Junction([string]$linkPath, [string]$target, [string]$label) {
    if ($seen.ContainsKey($label)) { return }
    $seen[$label] = $true
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host ("   {0,-22} skipped (target missing: {1})" -f $label, $target) -ForegroundColor Yellow
        return
    }
    if (Test-Path -LiteralPath $linkPath) {
        Write-Host ("   {0,-22} already linked" -f $label) -ForegroundColor DarkGray
        return
    }
    # cmd is used instead of New-Item because New-Item -ItemType SymbolicLink
    # needs the privilege we are working around, while /J does not.
    & "$env:SystemRoot\System32\cmd.exe" /c mklink /J "`"$linkPath`"" "`"$target`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "mklink /J failed for $label" }
    Write-Host ("   {0,-22} -> {1}" -f $label, $target) -ForegroundColor Green
}

New-Item -ItemType Directory -Force -Path $links | Out-Null

Write-Host "== plugin links in $links"

# 1) Our own native plugin (has windows/CMakeLists.txt + C++ sources).
Add-Junction (Join-Path $links 'lanplayer_video') `
    (Join-Path $root 'packages\lanplayer_video') 'lanplayer_video'

# 2) path_provider_windows is a Dart-only implementation, but `pub get` still
#    links every plugin folder it finds.  It lives in the pinned PUB_CACHE.
# PUB_CACHE is set explicitly on the dev box (.tools\) and by flutter_tools in
# some CI setups; otherwise pub uses %LOCALAPPDATA%\Pub\Cache.
$pubCache = $env:PUB_CACHE
if (-not $pubCache) { $pubCache = Join-Path $env:LOCALAPPDATA 'Pub\Cache' }
if (-not (Test-Path -LiteralPath $pubCache)) { $pubCache = Join-Path $root '.tools\pub-cache' }
$ppw = Get-ChildItem -LiteralPath (Join-Path $pubCache 'hosted\pub.dev') -Directory `
    -Filter 'path_provider_windows-*' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1
if ($ppw) {
    Add-Junction (Join-Path $links 'path_provider_windows') $ppw.FullName 'path_provider_windows'
} else {
    Write-Host '   path_provider_windows   skipped (run `dart pub get` in app/ first)' -ForegroundColor Yellow
}

# 3) Anything else already resolved into app/.flutter-plugins-dependencies that
#    the tool would try to link next time.
$deps = Join-Path $App '.flutter-plugins-dependencies'
if (Test-Path -LiteralPath $deps) {
    $json = Get-Content -LiteralPath $deps -Raw | ConvertFrom-Json
    foreach ($p in $json.plugins.windows) {
        $name = $p.name
        $dir = $p.path
        if ($name -and $dir) { Add-Junction (Join-Path $links $name) $dir $name }
    }
}

Write-Host "`n== done: $((Get-ChildItem -LiteralPath $links -ErrorAction SilentlyContinue).Count) link(s)" -ForegroundColor Green
Write-Host '   now: cd app; flutter build windows'
