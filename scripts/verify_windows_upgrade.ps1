param(
    [string]$OldSetup = 'D:\repo\LanPlayer\dist\LanPlayer-0.1.1-windows-x64-setup.exe',
    [string]$NewSetup = 'D:\repo\LanPlayer\dist\LanPlayer-0.1.2-windows-x64-setup.exe',
    [string]$Scratch  = 'D:\lp-upgrade-test'
)

# Verify that the installer upgrades over a *running* old version without asking
# the user to uninstall first -- the bug this script exists to catch.
#
# The test installs into a scratch directory, not into the real install
# location: it deletes a DLL and appends marker bytes to the exe, which is fine
# on a copy and rude on the user's own installation. HKCU\Software\LanPlayer is
# pointed at the scratch dir first (that value is exactly how the installer
# decides where to go) and everything the install touches is restored in the
# finally block: both registry keys, the desktop shortcut and the Start Menu
# folder. Installing into a scratch dir also leaves a desktop shortcut pointing
# at the scratch dir, so skipping that restore quietly breaks the real install.
#
# Six traps, all learned the hard way:
#
#  1. Integrity label. Files this shell creates carry a Low integrity
#     label, and a Low-label exe cannot write to a Medium-label directory: the
#     installer then exits 0 having done nothing -- a silent false negative.
#     So both setups are copied into %TEMP% (Medium) and the copies are run.
#  2. The launcher exe is byte-identical between 0.1.1 and 0.1.2 (same size,
#     same sha256), so its size proves nothing on its own. Append marker bytes
#     first; if the installer overwrites the file the size drops back to 90624.
#     The deleted DLL is the second, independent signal.
#  3. Start-Process -PassThru + $p.HasExited hangs forever under this environment,
#     and `cmd /c "..." &` from a sandboxed shell leaves tasklist without a
#     usable stdin. Run `cmd /c "<setup>" /S` synchronously instead, and poll
#     with Get-Process.
#  4. The NSIS uninstaller copies itself to %TEMP% and returns immediately, so
#     its exit code says nothing about completion; wait for the directory to
#     disappear. The installer does not do this, but the same wait is harmless.
#  5. Get-ItemProperty right after Set-ItemProperty can read back the old value
#     even though the write landed; verify registry edits with reg.exe query.
#  6. Do not seed the scratch directory from dist\stage\windows: the installer
#     deletes everything already in $INSTDIR, so a pre-seeded tree vanishes and
#     "was the exe replaced" turns into a comparison against a missing file.
#     Install 0.1.1 properly instead -- that also produces uninstall.exe.
#
# ASCII only: Windows PowerShell 5.1 decodes a BOM-less .ps1 as cp936, and a
# Chinese comment then becomes a garbled string literal that eats the next line.

$ErrorActionPreference = 'Stop'

$oldTmp = Join-Path $env:TEMP 'lp-verify-011.exe'
$newTmp = Join-Path $env:TEMP 'lp-verify-012.exe'
$exe    = Join-Path $Scratch 'lanplayer.exe'
$dll    = Join-Path $Scratch 'swscale-10.dll'
$regApp = 'HKCU\Software\LanPlayer'
$regUn  = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\LanPlayer'
$bakApp = Join-Path $env:TEMP 'lp-reg-app.reg'
$bakUn  = Join-Path $env:TEMP 'lp-reg-un.reg'
$lnkDir  = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\LanPlayer"
$lnkDesk = "$env:USERPROFILE\Desktop\LanPlayer.lnk"
$lnkBox  = Join-Path $env:TEMP 'lp-shortcut-backup'

foreach ($p in @($OldSetup, $NewSetup)) {
    if (-not (Test-Path $p)) { throw "missing input: $p" }
}

Copy-Item $OldSetup $oldTmp -Force
Copy-Item $NewSetup $newTmp -Force

function Stop-App {
    Get-Process lanplayer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}

function Run-Setup([string]$path, [string]$args_) {
    & cmd /c "`"$path`" $args_"
    return $LASTEXITCODE
}

function Wait-Gone([string]$dir, [int]$timeoutSec = 40) {
    for ($i = 0; $i -lt $timeoutSec * 4; $i++) {
        if (-not (Test-Path $dir)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return -not (Test-Path $dir)
}

function Show-State([string]$tag) {
    $reg = Get-ItemProperty 'HKCU:\Software\LanPlayer' -ErrorAction SilentlyContinue
    $f   = Get-Item $exe -ErrorAction SilentlyContinue
    $procs = @(Get-Process lanplayer -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    '{0}: reg_version={1} swscale={2} exe_bytes={3} procs=[{4}]' -f `
        $tag, $reg.Version, (Test-Path $dll), `
        $(if ($f) { $f.Length } else { 'missing' }), ($procs -join ',')
}

& cmd /c "reg export $regApp `"$bakApp`" /y >nul 2>&1"
& cmd /c "reg export $regUn `"$bakUn`" /y >nul 2>&1"
if (-not (Test-Path $bakApp)) { throw 'registry backup failed' }
Remove-Item $lnkBox -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $lnkBox -Force | Out-Null
if (Test-Path $lnkDir)  { Copy-Item $lnkDir $lnkBox -Recurse -Force }
if (Test-Path $lnkDesk) { Copy-Item $lnkDesk $lnkBox -Force }

try {
    Stop-App
    if (Test-Path $Scratch) { Remove-Item $Scratch -Recurse -Force }

    # Point the registry at the scratch dir and let both installs find it the
    # way a double-clicking user would -- no /D. That also covers the real
    # upgrade path: the 0.1.2 installer must honour the InstallDir left behind
    # by 0.1.1 instead of falling back to the default location.
    & cmd /c "reg add $regApp /v InstallDir /t REG_SZ /d `"$Scratch`" /f >nul 2>&1"
    $seen = (& cmd /c "reg query $regApp /v InstallDir 2>&1") -join ' '
    if ($seen -notlike "*$Scratch*") { throw "could not point InstallDir at scratch: $seen" }

    if ((Run-Setup $oldTmp "/S") -ne 0) { throw 'baseline 0.1.1 install failed' }
    Show-State 'baseline-0.1.1'
    if (-not (Test-Path $exe)) { throw 'baseline install did not land in the scratch dir' }

    # Append marker bytes so "was the exe replaced" is byte-exact, then remove a
    # DLL as a second, fully independent signal.
    Add-Content -Path $exe -Value 'MARKER-PRE-UPGRADE' -NoNewline -Encoding ASCII
    $sizeBefore = ((Get-Item $exe).Length)
    Remove-Item $dll -Force -ErrorAction SilentlyContinue

    Start-Process $exe
    Start-Sleep -Seconds 5
    Show-State 'old-version-running'

    # The whole test: an old build is running, nobody uninstalled anything.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $code = Run-Setup $newTmp '/S'
    $sw.Stop()
    Start-Sleep -Seconds 2
    Show-State 'after-upgrade'

    $sizeAfter  = (Get-Item $exe -ErrorAction SilentlyContinue).Length
    $replaced   = $sizeAfter -ne $sizeBefore
    $dllBack    = Test-Path $dll
    $stillAlive = @(Get-Process lanplayer -ErrorAction SilentlyContinue).Count -gt 0
    "setup_exit=$code elapsed_ms=$($sw.ElapsedMilliseconds)"
    "verdict: exe_replaced=$replaced dll_restored=$dllBack old_still_alive=$stillAlive"
    if (-not $replaced -or -not $dllBack -or $stillAlive -or $code -ne 0) {
        throw 'upgrade-over-running-app FAILED'
    }

    # Launch the upgraded copy once: proves the new binaries are not corrupt.
    Start-Process $exe
    Start-Sleep -Seconds 4
    $alive = @(Get-Process lanplayer -ErrorAction SilentlyContinue)
    "new_build_launch: procs=[$($alive.Id -join ',')] title=[$($alive | ForEach-Object { $_.MainWindowTitle } | Where-Object { $_ })]"
    if ($alive.Count -eq 0) { throw 'upgraded build did not start' }
}
finally {
    Stop-App
    # Run the scratch copy's uninstaller so the fake install does not linger;
    # it is allowed to fail, the directory is removed anyway.
    $un = Join-Path $Scratch 'uninstall.exe'
    if (Test-Path $un) { & cmd /c "`"$un`" /S >nul 2>&1" }
    [void](Wait-Gone $Scratch 20)
    Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue

    & cmd /c "reg import `"$bakApp`" >nul 2>&1"
    & cmd /c "reg import `"$bakUn`" >nul 2>&1"
    if (Test-Path (Join-Path $lnkBox 'LanPlayer')) {
        New-Item -ItemType Directory -Path $lnkDir -Force | Out-Null
        Copy-Item (Join-Path $lnkBox 'LanPlayer\*') $lnkDir -Force
    }
    $deskBak = Join-Path $lnkBox 'LanPlayer.lnk'
    if (Test-Path $deskBak) { Copy-Item $deskBak $lnkDesk -Force }
    Remove-Item $lnkBox -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $oldTmp, $newTmp, $bakApp, $bakUn -Force -ErrorAction SilentlyContinue

    $back = (& cmd /c "reg query $regApp /v InstallDir 2>&1") -join ' '
    "restored desktop_lnk=$(Test-Path $lnkDesk) startmenu_lnks=$((Get-ChildItem $lnkDir -ErrorAction SilentlyContinue).Count)"
    "restored $back"
}

'PASS'
