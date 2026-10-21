# Builds the Flutter Windows desktop app with CMake + MSBuild, in ONE command.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows_desktop.ps1
#   ... -Core          # also rebuild lanplayer.dll first (Zig; no MSVC needed)
#   ... -Run           # start the built app when it is ready
#
# Why not `flutter build windows`?  Two host-specific facts:
#
#  1. flutter_tools emits a CMake generator from a hard-coded switch
#     (windows/visual_studio.dart: 17 => "Visual Studio 17 2022", _ => "Visual
#     Studio 16 2019").  On Visual Studio 18 (the version installed here) it
#     picks 16 2019, which is not installed, so configure fails with
#     "Generator Visual Studio 16 2019 could not find any instance of Visual
#     Studio".
#  2. `flutter pub get` wants to create plugin symlinks (SeCreateSymbolicLink
#     privilege).  A plain user token does not have it.
#
# This script does the same work with the generators/libs that DO exist here:
# scripts\fix_plugin_links.ps1 (junctions instead of symlinks) + the CMake that
# ships inside Visual Studio.
#
# Everything it produces lands next to the exe:
#   lanplayer.exe, lanplayer_video_plugin.dll, lanplayer.dll, flutter_windows.dll,
#   av*/sw* DLLs, data\icudtl.dat, data\flutter_assets\...
# Release builds compile the Dart code AOT into data\app.so (debug builds ship
# data\flutter_assets\kernel_blob.bin instead); either way the bundle is
# self-contained and can be copied anywhere.
param(
    [string]$Config = 'Release',
    [switch]$Core,
    [switch]$Run,
    [switch]$Clean,
    [switch]$Reconfigure,
    # Override the Flutter SDK location.  CI gets its SDK from
    # subosito/flutter-action and exposes it as $env:FLUTTER_ROOT, so that is
    # the default fallback; local builds use the pinned .tools\flutter-sdk.
    [string]$FlutterRoot = '',
    # Do not redirect APPDATA/TEMP/PUB_CACHE into .tools\.  Only needed on
    # machines where the profile directories are not writable (this dev box);
    # on a CI runner the real ones work and PUB_CACHE must keep pointing at the
    # cache the action already populated.
    [switch]$NoEnvRedirect
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'app'
$winDir = Join-Path $app 'windows'
$eph = Join-Path $winDir 'flutter\ephemeral'
if ($FlutterRoot) { $fs = $FlutterRoot }
elseif ($env:FLUTTER_ROOT) { $fs = $env:FLUTTER_ROOT }
else { $fs = Join-Path $root '.tools\flutter-sdk' }
$fs = $fs.TrimEnd('\', '/')

function Fail([string]$msg) { Write-Host "`n!! $msg" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------- 1. prerequisites -----
if (-not (Test-Path (Join-Path $fs 'bin\cache\dart-sdk\bin\dart.exe'))) {
    Fail 'Flutter SDK missing - run: python tool\fetch_deps.py flutter'
}
if (-not (Test-Path (Join-Path $winDir 'CMakeLists.txt'))) {
    Fail 'app\windows missing - run: powershell -File scripts\gen_windows_runner.ps1'
}

# ------------------------------------------------------------ 2. Visual Studio
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { Fail 'vswhere.exe not found: install Visual Studio with "Desktop development with C++"' }
$vsDir = if ($env:LP_VS_DIR) { $env:LP_VS_DIR } else {
    & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if (-not $vsDir -or -not (Test-Path $vsDir)) { Fail 'no Visual Studio with the C++ toolset found (install "Desktop development with C++")' }
$vsDir = $vsDir.Trim()

$cmake = Join-Path $vsDir 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
if (-not (Test-Path $cmake)) { Fail "cmake.exe not found under $vsDir" }

# Pick the generator that matches the installed Visual Studio major version, so
# this keeps working when VS 19 shows up.
$major = $null
if ((Split-Path $vsDir -Leaf) -match '^(\d{2})$') { $major = [int]$Matches[1] }
if (-not $major) {
    $ver = & $vswhere -latest -products * -property installationVersion
    if ($ver -and $ver -match '^(\d+)') { $major = [int]$Matches[1] }
}
if (-not $major) { Fail 'cannot determine the Visual Studio version' }
$generator = (& $cmake --help 2>&1 | Select-String -Pattern "^\s*\*?\s*Visual Studio $major \d{4}(?!\d)" |
    Select-Object -First 1)
if (-not $generator) { Fail "cmake has no generator for Visual Studio $major" }
$generator = ($generator.Line -replace '^\s*\*?\s*', '' -replace '\s*=.*$', '').Trim()

Write-Host "visual studio : $vsDir"
Write-Host "cmake         : $cmake"
Write-Host "generator     : $generator"

# ------------------------------------------------------ 3. plugin junctions ---
Write-Host "`n== plugin links"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'fix_plugin_links.ps1')
if ($LASTEXITCODE -ne 0) { Fail 'fix_plugin_links.ps1 failed' }

# --------------------------------------------------------- 4. toolchain env ---
# flutter_assemble (CMake custom target) runs the flutter tool, which writes
# under %APPDATA%\.flutter_tool_state and %TEMP%; both are redirected into the
# repo so the build works when the profile directories are not writable.
# -NoEnvRedirect keeps the real ones (needed on CI, where the Flutter action has
# already populated the SDK + PUB_CACHE).
if (-not $NoEnvRedirect) {
    $cfg = Join-Path $root '.tools\flutter-cfg'
    $tmp = Join-Path $root '.tools\tmp'
    New-Item -ItemType Directory -Force -Path $cfg, $tmp | Out-Null
    $env:APPDATA = $cfg
    $env:LOCALAPPDATA = $cfg
    $env:HOME = Join-Path $root '.tools\home'
    $env:TMP = $tmp
    $env:TEMP = $tmp
    $env:PUB_CACHE = Join-Path $root '.tools\pub-cache'
    New-Item -ItemType Directory -Force -Path $env:HOME | Out-Null
}
$env:FLUTTER_ROOT = $fs

# --------------------------------------------------------- 5. native core -----
if ($Core) {
    Write-Host "`n== native core (Zig)"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build_windows.ps1')
    if ($LASTEXITCODE -ne 0) { Fail 'build_windows.ps1 failed' }
}
$nativeOut = Join-Path $root 'build\win-x64'
if (-not (Test-Path (Join-Path $nativeOut 'lanplayer.dll'))) {
    Fail 'build\win-x64\lanplayer.dll missing - run: powershell -File scripts\build_windows.ps1'
}

# ------------------------------------------------- 6. engine + ephemeral files
if (-not (Test-Path (Join-Path $eph 'flutter_windows.dll'))) {
    Write-Host "`n== ephemeral engine files"
    $art = Join-Path $fs 'bin\cache\artifacts\engine\windows-x64'
    if (-not (Test-Path (Join-Path $art 'flutter_windows.dll'))) { Fail 'FLUTTER_ROOT engine artifacts are incomplete' }
    New-Item -ItemType Directory -Force -Path $eph | Out-Null
    foreach ($f in 'flutter_windows.dll', 'flutter_windows.dll.lib', 'flutter_windows.dll.exp',
        'flutter_windows.dll.pdb', 'flutter_export.h', 'flutter_messenger.h',
        'flutter_plugin_registrar.h', 'flutter_texture_registrar.h', 'flutter_windows.h',
        'icudtl.dat', 'generated_config.cmake') {
        if (Test-Path (Join-Path $art $f)) { Copy-Item (Join-Path $art $f) $eph -Force }
    }
    if (-not (Test-Path (Join-Path $eph 'cpp_client_wrapper'))) {
        Copy-Item (Join-Path $art 'cpp_client_wrapper') (Join-Path $eph 'cpp_client_wrapper') -Recurse -Force
    }
    $cfgText = @"
set(FLUTTER_ROOT "$($fs -replace '\\','/')")
set(FLUTTER_TARGET_PLATFORM "windows-x64")
set(EPHEMERAL_DIR "`${CMAKE_CURRENT_SOURCE_DIR}/ephemeral")
"@
    [IO.File]::WriteAllText((Join-Path $eph 'generated_config.cmake'), $cfgText,
        (New-Object System.Text.UTF8Encoding($false)))
}

# --------------------------------------------------------------- 7. cmake -----
$bd = Join-Path $winDir "out\build\x64-$($generator -replace '\s+', '')"
if ($Clean -and (Test-Path $bd)) { Remove-Item -Recurse -Force $bd }

Write-Host "`n== cmake configure ($generator)"
& $cmake -G $generator -A x64 -S $winDir -B $bd
if ($LASTEXITCODE -ne 0) { Fail 'cmake configure failed' }

Write-Host "`n== cmake build ($Config, target INSTALL)"
& $cmake --build $bd --config $Config --target INSTALL
if ($LASTEXITCODE -ne 0) { Fail 'cmake build failed' }

# --------------------------------------------------------- 8. deploy core -----
# INSTALL lays out the bundle next to the exe; the FFI core and FFmpeg are ours.
$bundle = Join-Path $bd "runner\$Config"
if (-not (Test-Path (Join-Path $bundle 'lanplayer.exe'))) { Fail "runner exe missing in $bundle" }
Copy-Item (Join-Path $nativeOut 'lanplayer.dll') $bundle -Force
Get-ChildItem -LiteralPath $nativeOut -Filter '*.dll' -File |
    Where-Object { $_.Name -like 'av*' -or $_.Name -like 'sw*' } |
    ForEach-Object { Copy-Item $_.FullName $bundle -Force }

Write-Host "`n== ready" -ForegroundColor Green
Write-Host "   $bundle\lanplayer.exe"
Get-ChildItem $bundle -File | Sort-Object Name |
    ForEach-Object { Write-Host ("   {0,-30} {1,9:N0} KiB" -f $_.Name, ($_.Length / 1KB)) }

if ($Run) {
    Write-Host "`n== launching"
    & (Join-Path $bundle 'lanplayer.exe')
}
