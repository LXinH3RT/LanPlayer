# Builds the Flutter Windows desktop app WITHOUT the flutter tool.
#
# Why: the flutter CLI needs to spawn child processes with piped stdio, which
# fails in restricted environments (and it insists on MSVC anyway).  This script
# reproduces what `flutter build windows` does, step by step, using only:
#   * dart pub get            (dependency resolution)
#   * the engine's frontend_server (Dart -> kernel)
#   * cl.exe / link.exe       (runner + plugin, via scripts/msvc_chain.bat)
#   * the engine artifacts    (flutter_windows.dll, icudtl.dat, wrapper sources)
#
# Output is a DEBUG-style build: the debug engine runs data/flutter_assets/
# kernel_blob.bin (JIT).  `flutter build windows --release` produces the AOT
# variant; use that when the flutter tool is available.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_windows_app.ps1
#   powershell ... -Out build\win-app -Clean
param(
    [string]$Out = '',
    [switch]$Clean,
    [switch]$SkipKernel
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fs = Join-Path $root '.tools\flutter-sdk'
$dartSdk = Join-Path $fs 'bin\cache\dart-sdk'
$art = Join-Path $fs 'bin\cache\artifacts\engine\windows-x64'
$patched = Join-Path $fs 'bin\cache\artifacts\engine\common\flutter_patched_sdk'
$app = Join-Path $root 'app'
$eph = Join-Path $app 'windows\flutter\ephemeral'
if (-not $Out) { $Out = Join-Path $root 'build\win-app' }

function Need([string]$path, [string]$hint) {
    if (-not (Test-Path $path)) { throw "missing $path - $hint" }
}

Need (Join-Path $fs 'bin\cache\dart-sdk\bin\dart.exe') 'run: python tool/fetch_deps.py flutter'
Need (Join-Path $art 'flutter_windows.dll') 'flutter SDK engine artifacts are incomplete'

if ($Clean -and (Test-Path $Out)) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# ---------------------------------------------------------------- 1. pub get --
$cfg = Join-Path $root '.tools\flutter-cfg'
New-Item -ItemType Directory -Force -Path $cfg | Out-Null
$env:APPDATA = $cfg
$env:LOCALAPPDATA = $cfg
$env:PUB_CACHE = Join-Path $root '.tools\pub-cache'
$env:FLUTTER_ROOT = $fs

if (-not (Test-Path (Join-Path $app '.dart_tool\package_config.json'))) {
    Write-Host '== dart pub get'
    Push-Location $app
    & (Join-Path $dartSdk 'bin\dart.exe') pub get
    if ($LASTEXITCODE -ne 0) { Pop-Location; throw 'pub get failed' }
    Pop-Location
} else {
    Write-Host '== pub get: cached'
}

# ------------------------------------------------------ 2. ephemeral engine ---
Write-Host '== ephemeral engine files'
New-Item -ItemType Directory -Force -Path $eph | Out-Null
foreach ($f in 'flutter_windows.dll', 'flutter_windows.dll.lib', 'flutter_windows.dll.exp',
    'flutter_windows.dll.pdb', 'flutter_export.h', 'flutter_messenger.h',
    'flutter_plugin_registrar.h', 'flutter_texture_registrar.h', 'flutter_windows.h',
    'icudtl.dat') {
    Copy-Item (Join-Path $art $f) $eph -Force
}
if (-not (Test-Path (Join-Path $eph 'cpp_client_wrapper'))) {
    Copy-Item (Join-Path $art 'cpp_client_wrapper') (Join-Path $eph 'cpp_client_wrapper') -Recurse -Force
}
# A no-op tool_backend keeps flutter_assemble harmless if someone runs CMake.
$stub = Join-Path $root 'build\flutter-verify\stub-root\packages\flutter_tools\bin'
New-Item -ItemType Directory -Force -Path $stub | Out-Null
Set-Content -LiteralPath (Join-Path $stub 'tool_backend.bat') -Value "@echo off`r`nexit /b 0" -Encoding ascii
$genConfig = @"
# Written by scripts/build_windows_app.ps1 for offline builds.
set(FLUTTER_ROOT "$($root -replace '\\','/')/build/flutter-verify/stub-root")
set(FLUTTER_TARGET_PLATFORM "windows-x64")
set(EPHEMERAL_DIR "`${CMAKE_CURRENT_SOURCE_DIR}")
set(FLUTTER_VERSION "3.27.4")
set(FLUTTER_VERSION_MAJOR 3)
set(FLUTTER_VERSION_MINOR 27)
set(FLUTTER_VERSION_PATCH 4)
set(FLUTTER_VERSION_BUILD 0)
"@
[IO.File]::WriteAllText((Join-Path $eph 'generated_config.cmake'), $genConfig,
    (New-Object System.Text.UTF8Encoding($false)))
$links = Join-Path $eph '.plugin_symlinks'
New-Item -ItemType Directory -Force -Path $links | Out-Null
$link = Join-Path $links 'lanplayer_video'
if (-not (Test-Path $link)) {
    New-Item -ItemType Junction -Path $link -Target (Join-Path $root 'packages\lanplayer_video') | Out-Null
}

# ------------------------------------------------------------ 3. MSVC build ---
Write-Host '== runner + plugin (MSVC)'
& "$env:SystemRoot\System32\cmd.exe" /c "`"$(Join-Path $root 'scripts\msvc_chain.bat')`" `"$Out`""
if ($LASTEXITCODE -ne 0) { throw 'msvc_chain.bat failed' }

# --------------------------------------------------------- 4. runtime assets ---
$assets = Join-Path $Out 'data\flutter_assets'
New-Item -ItemType Directory -Force -Path (Join-Path $assets 'fonts') | Out-Null
Copy-Item (Join-Path $art 'icudtl.dat') (Join-Path $Out 'data') -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $art 'flutter_windows.dll') $Out -Force
$fonts = Join-Path $fs 'bin\cache\artifacts\material_fonts'
Copy-Item (Join-Path $fonts 'materialicons-regular.otf') (Join-Path $assets 'fonts\MaterialIcons-Regular.otf') -Force
[IO.File]::WriteAllText((Join-Path $assets 'FontManifest.json'),
    '[{"family":"MaterialIcons","fonts":[{"asset":"fonts/MaterialIcons-Regular.otf"}]}]',
    (New-Object System.Text.UTF8Encoding($false)))
$dill = Join-Path $assets 'app.dill'
if (-not $SkipKernel) {
    Write-Host '== dart -> kernel'
    & (Join-Path $dartSdk 'bin\dartaotruntime.exe') `
        (Join-Path $dartSdk 'bin\snapshots\frontend_server_aot.dart.snapshot') `
        --sdk-root $patched --target=flutter `
        --packages (Join-Path $app '.dart_tool\package_config.json') `
        --output-dill $dill (Join-Path $app 'lib\main.dart') *> (Join-Path $Out 'kernel.log')
    if ($LASTEXITCODE -ne 0) {
        Get-Content (Join-Path $Out 'kernel.log') | Select-String ': Error:' | Select-Object -First 20 | ForEach-Object { Write-Host $_.Line }
        throw 'Dart compilation failed (see the errors above)'
    }
}
Copy-Item $dill (Join-Path $assets 'kernel_blob.bin') -Force

# --------------------------------------------------------------- 5. core dll ---
$nativeOut = Join-Path $root 'build\win-x64'
if (Test-Path (Join-Path $nativeOut 'lanplayer.dll')) {
    Copy-Item (Join-Path $nativeOut 'lanplayer.dll') $Out -Force
    Get-ChildItem $nativeOut -Filter '*.dll' |
        Where-Object { $_.Name -like 'av*' -or $_.Name -like 'sw*' } |
        ForEach-Object { Copy-Item $_.FullName $Out -Force }
    Write-Host '== core + ffmpeg DLLs deployed'
} else {
    Write-Host '!! lanplayer.dll missing: run scripts/build_windows.ps1 first' -ForegroundColor Yellow
}

Write-Host "`n== ready: $(Join-Path $Out 'lanplayer.exe')" -ForegroundColor Green
Write-Host '   run it, or capture a screenshot:'
Write-Host "   powershell -File scripts\capture_window.ps1 -Exe `"$(Join-Path $Out 'lanplayer.exe')`""
