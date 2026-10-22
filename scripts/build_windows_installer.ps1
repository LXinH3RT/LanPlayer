# Build the Windows installer (NSIS).
#
# Prerequisites:
#   1. scripts\build_windows.ps1 -DeployTo app\build\windows\x64\runner\Release
#      (this puts lanplayer.dll and the FFmpeg DLLs next to the exe)
#   2. flutter build windows --release (produces lanplayer.exe)
#   3. .tools\nsis\nsis-3.10\Bin\makensis.exe (python tool\fetch_deps.py nsis)
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows_installer.ps1
#   powershell ... -Version 0.1.0 -Open
#
# Output: dist\LanPlayer-<version>-windows-x64-setup.exe
#
# NOTE: this file is deliberately ASCII only. Windows PowerShell 5.1 reads a
# BOM-less .ps1 as ANSI, so non-ASCII comments turn into mojibake and can break
# the parser. Keep every comment and string here in plain ASCII.
[CmdletBinding()]
param(
    [string]$Version = '0.1.0',
    [string]$Release = '',
    [string]$OutDir = '',
    [switch]$KeepStage,
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

# makensis writes temp files under %TEMP%, which the sandbox blocks by default.
$tmp = Join-Path $root '.tools\tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:TMP = $tmp
$env:TEMP = $tmp

if (-not $Release) { $Release = Join-Path $root 'app\build\windows\x64\runner\Release' }
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
$stage = Join-Path $OutDir 'stage\windows'

function Fail([string]$msg) {
    Write-Host "error: $msg" -ForegroundColor Red
    exit 1
}

$exe = Join-Path $Release 'lanplayer.exe'
if (-not (Test-Path $exe)) {
    Fail "missing $exe -- run flutter build windows --release first"
}
foreach ($dll in 'lanplayer.dll', 'avcodec-63.dll', 'avformat-63.dll') {
    if (-not (Test-Path (Join-Path $Release $dll))) {
        Fail "missing $dll in $Release -- run scripts\build_windows.ps1 -DeployTo `"$Release`""
    }
}

# ---------------------------------------------------------------- 1. stage
Write-Host "== staging into $stage ==" -ForegroundColor Cyan
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# Listed one by one on purpose: installer.nsi uses a File directive per file,
# so the staging set and the packaged set must stay identical.
$runtime = @(
    'lanplayer.exe',
    'lanplayer.dll',
    'lanplayer_video_plugin.dll',
    'flutter_windows.dll',
    'avcodec-63.dll',
    'avfilter-12.dll',
    'avformat-63.dll',
    'avutil-61.dll',
    'swresample-7.dll',
    'swscale-10.dll'
)
foreach ($f in $runtime) {
    $src = Join-Path $Release $f
    if (-not (Test-Path $src)) { Fail "missing $f in $Release" }
    Copy-Item $src $stage -Force
}

# avdevice is intentionally NOT shipped: dumpbin /DEPENDENTS shows no module
# links against it, and the core never calls avdevice_*.
if (Test-Path (Join-Path $Release 'avdevice-63.dll')) {
    Write-Host "  skipping avdevice-63.dll (nothing depends on it)"
}

Copy-Item (Join-Path $Release 'data') $stage -Recurse -Force
Remove-Item (Join-Path $stage 'data\native_assets.yaml') -Force -ErrorAction SilentlyContinue

# VC++ runtime is deployed app-local so users do not need the Redistributable.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$crt = $null
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -property installationPath 2>$null
    if ($vsPath) {
        $redistRoot = Join-Path $vsPath 'VC\Redist\MSVC'
        if (Test-Path $redistRoot) {
            $crt = Get-ChildItem $redistRoot -Directory |
                   Sort-Object Name -Descending |
                   ForEach-Object { Join-Path $_.FullName 'x64\Microsoft.VC145.CRT' } |
                   Where-Object { Test-Path $_ } |
                   Select-Object -First 1
        }
    }
}
if (-not $crt) {
    Fail 'could not locate Microsoft.VC145.CRT (VC++ x64 redist) -- need a machine with Visual Studio'
}
Write-Host "  CRT from $crt"
foreach ($d in 'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll',
               'vcruntime140.dll', 'vcruntime140_1.dll', 'concrt140.dll') {
    $src = Join-Path $crt $d
    if (-not (Test-Path $src)) { Fail "missing $d in $crt" }
    Copy-Item $src $stage -Force
}

$stagedMb = [math]::Round(((Get-ChildItem $stage -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host "  staged $stagedMb MB" -ForegroundColor Green

# ---------------------------------------------------------------- 2. compile
$nsis = Join-Path $root '.tools\nsis\nsis-3.10\Bin\makensis.exe'
if (-not (Test-Path $nsis)) {
    Fail "missing $nsis -- run python tool\fetch_deps.py nsis"
}

$outFile = Join-Path $OutDir "LanPlayer-$Version-windows-x64-setup.exe"
$icon = Join-Path $root 'app\windows\runner\resources\app_icon.ico'
$script = Join-Path $root 'scripts\windows\installer.nsi'

Write-Host "== makensis ==" -ForegroundColor Cyan
& $nsis /V2 "/DAPP_VERSION=$Version" "/DSTAGE=$stage" "/DOUTFILE=$outFile" "/DAPP_ICON=$icon" $script
if ($LASTEXITCODE -ne 0) { Fail "makensis failed with exit code $LASTEXITCODE" }
if (-not (Test-Path $outFile)) { Fail "makensis produced no output" }

$sizeMb = [math]::Round((Get-Item $outFile).Length / 1MB, 1)
$hash = (Get-FileHash $outFile -Algorithm SHA256).Hash
Write-Host ""
Write-Host "built: $outFile ($sizeMb MB)" -ForegroundColor Green
Write-Host "sha256: $hash"

if (-not $KeepStage) {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    $stageRoot = Join-Path $OutDir 'stage'
    if ((Test-Path $stageRoot) -and -not (Get-ChildItem $stageRoot -Force)) {
        Remove-Item $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($Open) { Start-Process explorer.exe $OutDir }
exit 0
