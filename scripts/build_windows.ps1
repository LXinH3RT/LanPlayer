# Builds the native core (and its SMB transport) for Windows x64.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_windows.ps1
#   ... -Clean -RunSmoke -SmokeMedia build\media\clip.mp4
#
# Toolchain: Zig ships a complete clang + mingw-w64 libc + lld and can link the
# MinGW import libraries of the official FFmpeg Windows build, so no Visual
# Studio or MSYS2 is required.  Threads/mutexes come from
# native/src/platform/desktop/win32_pthread.h; libsmb2 gets the shim headers in
# native/platform/win32/smb2/.
param(
    [switch]$Clean,
    [switch]$RunSmoke,
    [string]$SmokeMedia = '',
    [int]$SmokeSeconds = 5,
    [switch]$NoSmb,
    # Copy lanplayer.dll + the FFmpeg DLLs here (e.g. the Flutter output folder).
    [string]$DeployTo = ''
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root '.tools'
$native = Join-Path $root 'native'
$out = Join-Path $root 'build\win-x64'

$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $tools 'zig-cache'
$env:ZIG_LOCAL_CACHE_DIR = Join-Path $tools 'zig-cache-local'
New-Item -ItemType Directory -Force -Path $env:ZIG_GLOBAL_CACHE_DIR, $env:ZIG_LOCAL_CACHE_DIR | Out-Null

function Find-Tool([string]$base, [string]$name) {
    if (-not (Test-Path $base)) { throw "missing $base - run: python tool/fetch_deps.py" }
    $hit = Get-ChildItem -LiteralPath $base -Recurse -File -Filter $name -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $hit) { throw "missing $name under $base - run: python tool/fetch_deps.py" }
    return $hit.FullName
}

function Invoke-Zig([string[]]$zigArgs, [string]$label) {
    $text = & $zig @zigArgs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n--- $label FAILED ---" -ForegroundColor Red
        Write-Host $text
        return $false
    }
    if ($text.Trim().Length -gt 0 -and $env:LP_VERBOSE) { Write-Host $text }
    return $true
}

$zig = Find-Tool (Join-Path $tools 'zig') 'zig.exe'
$ffmpegHeader = Find-Tool (Join-Path $tools 'ffmpeg') 'avformat.h'
$ffmpegRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ffmpegHeader))
$ffmpegLib = Join-Path $ffmpegRoot 'lib'
$ffmpegBin = Join-Path $ffmpegRoot 'bin'

Write-Host "zig    : $zig"
Write-Host "ffmpeg : $ffmpegRoot"

if ($Clean -and (Test-Path $out)) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force -Path $out | Out-Null

$baseFlags = @(
    '-target', 'x86_64-windows-gnu',
    '-std=gnu11',
    '-O2',
    '-g0',
    '-fno-strict-aliasing',
    '-Wall',
    '-Wno-unused-parameter',
    '-Wno-unused-variable',
    '-Wno-deprecated-declarations',
    '-Wno-microsoft-anon-tag',
    '-Wno-unused-function'
)

# ---------------------------------------------------------------- libsmb2 ---
$smb2Root = Join-Path $tools 'libsmb2'
$smb2Shim = Join-Path $native 'platform\win32\smb2'
$smb2Lib = $null
if (-not $NoSmb -and (Test-Path (Join-Path $smb2Root 'lib'))) {
    Write-Host "`n== libsmb2 (SMB2/3 transport)"
    $smb2Out = Join-Path $out 'smb2'
    New-Item -ItemType Directory -Force -Path $smb2Out | Out-Null
    $smb2Flags = @('cc') + $baseFlags + @(
        '-c',
        "-I$smb2Shim",
        "-I$smb2Root\include",
        "-I$smb2Root\include\smb2",

        '-DHAVE_CONFIG_H',
        '-DWIN32_LEAN_AND_MEAN',
        '-D_CRT_SECURE_NO_WARNINGS',
        '-D_CRT_NONSTDC_NO_DEPRECATE',
        '-D_FILE_OFFSET_BITS=64',
        '-D_U_=__attribute__((unused))',
        '-include', 'win32_compat.h',
        '-Wno-implicit-int'
    )
    # mingw compatibility: upstream decides between WSAGetLastError() and errno
    # after a non-blocking connect() with `#ifndef _MSC_VER`.  Under mingw
    # _MSC_VER is undefined, so it compares errno against EINPROGRESS and every
    # connect looks like a failure ("Connect failed with errno : No error(0)").
    # Branch on _WIN32 instead - identical for MSVC, correct for mingw and POSIX.
    $socketC = Join-Path $smb2Root 'lib\socket.c'
    if (Test-Path $socketC) {
        $socketSrc = [IO.File]::ReadAllText($socketC)
        if ($socketSrc.Contains('#ifndef _MSC_VER')) {
            [IO.File]::WriteAllText($socketC, $socketSrc.Replace('#ifndef _MSC_VER', '#if !defined(_WIN32)'))
            Write-Host '   patched lib/socket.c (mingw non-blocking connect)' -ForegroundColor Yellow
        }
    }

    $smb2Sources = Get-ChildItem (Join-Path $smb2Root 'lib') -Filter '*.c' |
        Where-Object { $_.Name -notlike '*test*' }
    $smb2Objects = @()
    $smb2Failed = 0
    foreach ($src in $smb2Sources) {
        $obj = Join-Path $smb2Out ($src.BaseName + '.o')
        $smb2Objects += $obj
        if (-not (Invoke-Zig ($smb2Flags + @($src.FullName, '-o', $obj)) $src.Name)) { $smb2Failed++ }
    }
    if ($smb2Failed -eq 0) {
        $lib = Join-Path $smb2Out 'libsmb2.a'
        if (Invoke-Zig (@('ar', 'rcs', $lib) + $smb2Objects) 'libsmb2.a') {
            $smb2Lib = $lib
            Write-Host "   $($smb2Sources.Count) files -> libsmb2.a" -ForegroundColor Green
        }
    } else {
        Write-Host "   $smb2Failed file(s) failed; continuing without SMB" -ForegroundColor Yellow
    }
} else {
    Write-Host "`n== libsmb2 skipped (run: python tool/fetch_deps.py libsmb2)"
}

# ------------------------------------------------------------------ core ---
# Platform adapters: the library/smoke test use the null "stub" output; the
# preview player uses the real Win32 video (GDI) + audio (waveOut) adapter.
$coreSources = @(
    'src\util\lp_str.c',
    'src\util\lp_log.c',
    'src\core\queue.c',
    'src\core\audio_ring.c',
    'src\core\demux.c',
    'src\core\video.c',
    'src\core\audio.c',
    'src\core\subtitle.c',
    'src\core\thumb.c',
    'src\core\player.c',
    'src\source\url.c',
    'src\source\io.c',
    'src\source\smb.c',
    'src\source\file.c'
)
$stubSource = 'src\platform\stub\stub_platform.c'
# win32_platform.c is the framework adapter (renderer + audio); the D3D11VA
# decoder is a second translation unit because it is the only one that touches
# libavcodec's hardware path.
$win32Sources = @(
    'src\platform\win32\win32_platform.c',
    'src\platform\win32\d3d11va_decoder.c',
    'src\app\lp_preview.c'
)

$includes = @(
    "-I$native\include",
    "-I$native\src",
    "-I$native\src\source",
    "-I$ffmpegRoot\include"
)
$defines = @(
    '-DLP_ENABLE_HTTP=1',
    '-D_FILE_OFFSET_BITS=64',
    '-D_CRT_SECURE_NO_WARNINGS'
)
if ($smb2Lib) {
    # The shim directory provides <poll.h> and friends that libsmb2 expects
    # inside our own sources as well.
    $includes += "-I$smb2Shim"
    $includes += "-I$smb2Root\include"
    # libsmb2's own headers include each other flat (<libsmb2.h>), same as when
    # building the library itself.
    $includes += "-I$smb2Root\include\smb2"
    $defines += '-DLP_HAVE_SMB2=1'
}

function Compile-Objects([string[]]$list, [string]$suffix) {
    $objs = @()
    $bad = 0
    foreach ($src in $list) {
        $full = Join-Path $native $src
        $obj = Join-Path $out (($src -replace '[\\/]', '_') -replace '\.c$', "$suffix.o")
        $objs += $obj
        Write-Host ("   " + $src)
        if (-not (Invoke-Zig (@('cc') + $baseFlags + $defines + $includes + @('-c', $full, '-o', $obj)) $src)) {
            $bad++
        }
    }
    if ($bad -gt 0) { Write-Host "   $bad file(s) failed" -ForegroundColor Red }
    return @{ Objects = $objs; Failed = $bad }
}

Write-Host "`n== compiling core"
$core = Compile-Objects $coreSources ''
if ($core.Failed -gt 0) { exit 1 }
Write-Host "   $($coreSources.Count) core sources compiled" -ForegroundColor Green

Write-Host "`n== compiling platform adapters"
$stub = Compile-Objects @($stubSource) '.stub'
if ($stub.Failed -gt 0) { exit 1 }
$win32 = Compile-Objects $win32Sources '.win32'
$win32PlatformOnly = $win32.Objects[0]
$win32HwOnly = $win32.Objects[1]
$win32PreviewOnly = $win32.Objects[2]
if ($win32.Failed -gt 0) { exit 1 }

# ------------------------------------------------------------------ link ---
$ffLibs = @(Get-ChildItem -LiteralPath $ffmpegLib -Filter 'lib*.dll.a' -File | ForEach-Object { $_.FullName })
if (-not $ffLibs) {
    $ffLibs = @(Get-ChildItem -LiteralPath $ffmpegLib -Filter '*.lib' -File |
        Where-Object { $_.Name -notlike '*.def' } | ForEach-Object { $_.FullName })
}
if (-not $ffLibs) { throw "no import libraries under $ffmpegLib" }

Write-Host "`n== linking (ffmpeg import libs: $($ffLibs.Count))"
$libTail = $ffLibs
if ($smb2Lib) { $libTail += @($smb2Lib, '-lws2_32') }

# The shipped DLL carries the real Windows output adapter (GDI target + waveOut),
# so a Flutter desktop host gets video and audio from liblanplayer.dll directly.
Write-Host "   lanplayer.dll (win32 platform)"
$dllLink = @('cc') + $baseFlags + $core.Objects + $win32PlatformOnly + $win32HwOnly + $libTail +
    @('-luser32', '-lgdi32', '-lwinmm')
if (-not (Invoke-Zig ($dllLink + @('-shared', '-o', (Join-Path $out 'lanplayer.dll'))) 'lanplayer.dll')) { exit 1 }

# Headless build for CI: same core with the null platform adapter.
$dllStubLink = @('cc') + $baseFlags + $core.Objects + $stub.Objects + $libTail
Write-Host "   lanplayer_stub.dll (null output, CI only)"
if (-not (Invoke-Zig ($dllStubLink + @('-shared', '-o', (Join-Path $out 'lanplayer_stub.dll'))) 'lanplayer_stub.dll')) { exit 1 }

Write-Host "   lp_smoke_test.exe"
$testObj = Join-Path $out 'lp_smoke_test.o'
if (-not (Invoke-Zig (@('cc') + $baseFlags + $defines + $includes + @('-c', (Join-Path $native 'tests\lp_smoke_test.c'), '-o', $testObj)) 'smoke test')) { exit 1 }
if (-not (Invoke-Zig ($dllStubLink + @($testObj, '-o', (Join-Path $out 'lp_smoke_test.exe'), '-Wl,--subsystem,console')) 'lp_smoke_test.exe')) { exit 1 }

# Loads lanplayer.dll at runtime and drives the texture path, exactly like the
# Flutter Windows plugin does.  It also compiles the plugin's own BGRA->RGBA
# header, so a regression in that conversion fails here instead of turning the
# picture blue in the app.
Write-Host "   lp_win32_texture_test.exe"
$texTest = Join-Path $out 'lp_win32_texture_test.exe'
$pluginIncludes = @("-I$root\packages\lanplayer_video\windows\include")
if (-not (Invoke-Zig (@('cc') + $baseFlags + $pluginIncludes + @('-c', (Join-Path $native 'tests\lp_win32_texture_test.c'), '-o', (Join-Path $out 'lp_win32_texture_test.o'))) 'texture test')) { exit 1 }
if (-not (Invoke-Zig (@('cc') + $baseFlags + @((Join-Path $out 'lp_win32_texture_test.o'), '-o', $texTest, '-Wl,--subsystem,console')) 'lp_win32_texture_test.exe')) { exit 1 }

# Opens media through hw=auto and asserts the core really picked D3D11VA.  The
# core falls back to software silently (a warning in the log only), so a broken
# hardware decoder still produces a perfect picture - this is what catches it.
Write-Host "   lp_hw_decode_test.exe"
$hwTestSrc = Join-Path $native 'tests\lp_hw_decode_test.c'
$hwTestObj = Join-Path $out 'lp_hw_decode_test.o'
if (-not (Invoke-Zig (@('cc') + $baseFlags + $defines + $includes + @('-c', $hwTestSrc, '-o', $hwTestObj)) 'hw decode test')) { exit 1 }
$hwTestExe = Join-Path $out 'lp_hw_decode_test.exe'
if (-not (Invoke-Zig (@('cc') + $baseFlags + @($hwTestObj, '-o', $hwTestExe, '-Wl,--subsystem,console')) 'lp_hw_decode_test.exe')) { exit 1 }

Write-Host "   lanplayer_preview.exe (GUI)"
$previewLink = @('cc') + $baseFlags + $core.Objects + $win32PlatformOnly + $win32HwOnly + $win32PreviewOnly + $libTail +
    @('-luser32', '-lgdi32', '-lwinmm', '-lcomdlg32', '-lshell32', '-lole32')
if (-not (Invoke-Zig ($previewLink + @('-o', (Join-Path $out 'lanplayer_preview.exe'), '-Wl,--subsystem,windows')) 'lanplayer_preview.exe')) { exit 1 }

# Same player, console subsystem: blocks the caller and prints its report, which
# is what the automated checks (and --selftest) use.
Write-Host "   lanplayer_preview_c.exe (console, for tests)"
if (-not (Invoke-Zig ($previewLink + @('-o', (Join-Path $out 'lanplayer_preview_c.exe'), '-Wl,--subsystem,console')) 'lanplayer_preview_c.exe')) { exit 1 }


Get-ChildItem -LiteralPath $ffmpegBin -Filter '*.dll' -File | ForEach-Object {
    Copy-Item $_.FullName $out -Force
}

Write-Host "`n== artifacts in $out" -ForegroundColor Green
Get-ChildItem $out | Where-Object { $_.Extension -in '.exe', '.dll' } | Sort-Object Name |
    ForEach-Object { Write-Host ("   {0,-24} {1,8:N0} KiB" -f $_.Name, ($_.Length / 1KB)) }

if ($DeployTo) {
    if (-not (Test-Path $DeployTo)) { New-Item -ItemType Directory -Force -Path $DeployTo | Out-Null }
    Copy-Item (Join-Path $out 'lanplayer.dll') $DeployTo -Force
    Get-ChildItem -LiteralPath $ffmpegBin -Filter '*.dll' -File | ForEach-Object {
        Copy-Item $_.FullName $DeployTo -Force
    }
    Write-Host "`n== deployed to $DeployTo" -ForegroundColor Green
    Get-ChildItem $DeployTo -Filter '*.dll' | ForEach-Object { Write-Host ("   " + $_.Name) }
}

if ($RunSmoke) {
    $exe = Join-Path $out 'lp_smoke_test.exe'
    $env:PATH = "$out;$env:PATH"
    if ($SmokeMedia -and (Test-Path $SmokeMedia)) {
        $media = (Resolve-Path $SmokeMedia).Path
        Write-Host "`n== smoke test on $media"
        & $exe $media $SmokeSeconds
    } else {
        Write-Host "`n== smoke test (library load + ABI only)"
        & $exe
    }
    Write-Host "`n   exit=$LASTEXITCODE"
}
