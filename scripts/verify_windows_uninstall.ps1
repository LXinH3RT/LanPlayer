param(
    [string]$Setup   = '',
    [string]$Scratch = ''
)

$Root = Split-Path -Parent $PSScriptRoot

# The package under test is the version app/pubspec.yaml declares, so this
# script cannot end up testing an installer two releases old.
if (-not $Setup) {
    $line = Select-String -Path (Join-Path $Root 'app\pubspec.yaml') -Pattern '^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+)' | Select-Object -First 1
    if (-not $line) {
        Write-Host 'error: cannot read the version from app/pubspec.yaml' -ForegroundColor Red
        exit 1
    }
    $Setup = Join-Path $Root ("dist\LanPlayer-$($line.Matches[0].Groups[1].Value)-windows-x64-setup.exe")
}
if (-not $Scratch) { $Scratch = Join-Path ([System.IO.Path]::GetTempPath()) 'lp-uninstall-test' }

# Verify that the uninstaller asks a running copy to quit. Without that, Delete
# on lanplayer.exe / the DLLs fails (they are mapped images) and the uninstall
# leaves a half-deleted directory behind.
#
# The uninstaller only exists after an install, so the test installs the given
# setup into a scratch directory first, launches the app from there, and then
# runs uninstall.exe while the app is still up. Pass a build with the
# StopRunningApp insert stripped for the negative control: it leaves 13 of 17
# files behind.
#
# Installing and uninstalling rewrite HKCU\Software\LanPlayer, the Uninstall
# key and the desktop / Start Menu shortcuts, none of which are scoped to
# $INSTDIR -- all of it is backed up first and restored at the end. Check
# registry writes with reg.exe: a read right after a write can return the old
# value.
#
# ASCII only: Windows PowerShell 5.1 decodes a BOM-less .ps1 as cp936, and a
# Chinese comment then turns into a garbled string literal that swallows the
# next line.

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Setup)) { throw "missing setup: $Setup" }

$exe    = Join-Path $Scratch 'lanplayer.exe'
$unexe  = Join-Path $Scratch 'uninstall.exe'
$tmpExe = Join-Path $env:TEMP 'lp-uninstall-fixture.exe'
$regApp = 'HKCU\Software\LanPlayer'
$regUn  = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\LanPlayer'
$bakApp = Join-Path $env:TEMP 'lp-reg-app.reg'
$bakUn  = Join-Path $env:TEMP 'lp-reg-un.reg'
$lnkDir  = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\LanPlayer"
$lnkDesk = "$env:USERPROFILE\Desktop\LanPlayer.lnk"
$lnkBox  = Join-Path $env:TEMP 'lp-shortcut-backup'

# %TEMP% copy: files created under this checkout carry a Low integrity label, and
# a Low-label installer cannot write to a Medium-label directory -- it exits 0
# having done nothing. %TEMP% itself is Medium.
Copy-Item $Setup $tmpExe -Force

& reg.exe export $regApp $bakApp /y | Out-Null
& reg.exe export $regUn  $bakUn  /y | Out-Null
if (-not (Test-Path $bakApp) -or -not (Test-Path $bakUn)) { throw 'registry backup failed' }

Remove-Item $lnkBox -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $lnkBox -Force | Out-Null
if (Test-Path $lnkDir)  { Copy-Item $lnkDir $lnkBox -Recurse -Force }
if (Test-Path $lnkDesk) { Copy-Item $lnkDesk $lnkBox -Force }

function Stop-App {
    Get-Process lanplayer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}

# The uninstaller copies itself to %TEMP% and returns at once, so the elapsed
# time below is only the launcher's exit -- the real work happens in the
# detached copy. Wait for the directory to go away (or time out) before judging.
function Wait-Gone([string]$dir, [int]$timeoutSec = 20) {
    for ($i = 0; $i -lt $timeoutSec * 4; $i++) {
        if (-not (Test-Path $dir)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return -not (Test-Path $dir)
}

$savedDir = (Get-ItemProperty $regApp -Name InstallDir -ErrorAction SilentlyContinue).InstallDir

try {
    Stop-App
    if (Test-Path $Scratch) { Remove-Item $Scratch -Recurse -Force }

    # 1. Real install into the scratch directory; this is what creates
    #    uninstall.exe.
    & cmd /c "`"$tmpExe`" /S /D=$Scratch"
    "install_exit=$LASTEXITCODE uninstaller=$(Test-Path $unexe) exe=$(Test-Path $exe)"
    if (-not (Test-Path $unexe)) { throw 'installer did not produce uninstall.exe' }

    # 2. Start it and leave it running.
    Start-Process $exe
    Start-Sleep -Seconds 5
    $before = @(Get-Process lanplayer -ErrorAction SilentlyContinue).Count
    "app_running=$($before -gt 0) files_before=$((Get-ChildItem $Scratch -File).Count)"

    # 3. Uninstall without closing it first -- the whole point.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & cmd /c "`"$unexe`" /S"
    $code = $LASTEXITCODE
    $sw.Stop()
    $gone = Wait-Gone $Scratch 20
    Start-Sleep -Milliseconds 500

    $left  = @(Get-ChildItem $Scratch -File -ErrorAction SilentlyContinue)
    $alive = @(Get-Process lanplayer -ErrorAction SilentlyContinue).Count
    "uninstall_exit=$code launcher_ms=$($sw.ElapsedMilliseconds) waited_gone=$gone"
    "leftover_files=$($left.Count) leftovers=[$($left.Name -join ',')] app_still_alive=$($alive -gt 0)"
    "dir_left=$(Test-Path $Scratch)"
    if ($alive -gt 0 -or $left.Count -gt 0 -or $code -ne 0) { throw 'uninstall-over-running-app FAILED' }
}
finally {
    Stop-App
    Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue

    # Restore through cmd /c with the streams discarded. Under
    # $ErrorActionPreference = 'Stop', `reg.exe ... 2>&1` turns reg's ordinary
    # stderr lines ("The operation completed successfully.") into terminating
    # errors, which killed this block halfway through and left the machine with
    # no HKCU\Software\LanPlayer at all for one run.
    & cmd /c "reg import `"$bakApp`" >nul 2>&1"
    & cmd /c "reg import `"$bakUn`" >nul 2>&1"
    if ($savedDir) {
        & cmd /c "reg add $regApp /v InstallDir /t REG_SZ /d `"$savedDir`" /f >nul 2>&1"
    }

    # Shortcuts live outside $INSTDIR, so the uninstaller always takes them.
    if (Test-Path (Join-Path $lnkBox 'LanPlayer')) {
        New-Item -ItemType Directory -Path $lnkDir -Force | Out-Null
        Copy-Item (Join-Path $lnkBox 'LanPlayer\*') $lnkDir -Force
    }
    $deskBak = Join-Path $lnkBox 'LanPlayer.lnk'
    if (Test-Path $deskBak) { Copy-Item $deskBak $lnkDesk -Force }
    Remove-Item $lnkBox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $bakApp, $bakUn, $tmpExe -Force -ErrorAction SilentlyContinue

    # Read back with reg.exe: Get-ItemProperty right after a write can still
    # return the previous value and make a good restore look broken.
    $back = (& cmd /c "reg query $regApp /v InstallDir 2>&1") -join ' '
    "restored desktop_lnk=$(Test-Path $lnkDesk) startmenu_lnks=$((Get-ChildItem $lnkDir -ErrorAction SilentlyContinue).Count)"
    "restored $back"
}

'PASS'
