# Windows runtime evidence that the volume stored in settings.json reaches the
# kernel and is clamped to 0..2 there.
#
# Why: the volume sheet only shows a percentage, so a screenshot cannot prove
# the gain was applied. The kernel prints one line on open --
#   [LanPlayer I audio] volume 0.35 (35%) from settings
# -- and this script asserts that line for several values.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify_windows_volume.ps1
param(
    [string]$Exe = '',
    [string]$Media = ''
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Exe) {
    $Exe = Join-Path $root 'app\windows\out\build\x64-VisualStudio182026\runner\Release\lanplayer.exe'
}
if (-not $Media) {
    $Media = Join-Path $root 'build\media\clip.mp4'
}

if (-not (Test-Path $Exe)) { Write-Host "missing exe: $Exe"; exit 2 }
if (-not (Test-Path $Media)) { Write-Host "missing media: $Media"; exit 2 }

$scratch = Join-Path $root '.tools\tmp\volcheck'
$state = Join-Path $scratch 'state'
$fail = 0

function Probe([string]$value) {
    Remove-Item -Recurse -Force $state -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $state | Out-Null
    $json = '{"version":1,"volume":' + $value + '}'
    Set-Content -Path (Join-Path $state 'settings.json') -Value $json -Encoding UTF8 -NoNewline
    # The core logs to stderr (lp_log.c uses fprintf(stderr)), the Flutter side
    # to stdout, so both streams have to be scanned.
    $log = Join-Path $scratch 'out.log'
    $err = Join-Path $scratch 'err.log'
    Remove-Item -Force $log, $err -ErrorAction SilentlyContinue
    $env:LANPLAYER_STATE_DIR = $state
    $env:LANPLAYER_OPEN = $Media
    $env:LANPLAYER_NO_TEXTURE = '1'
    $p = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError $err
    Start-Sleep -Seconds 6
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 400
    $line = ''
    foreach ($f in @($err, $log)) {
        if ($line) { break }
        if (-not (Test-Path $f)) { continue }
        $hit = Select-String -Path $f -Pattern 'volume [0-9.]+ \([0-9]+%\) from settings' |
            Select-Object -First 1
        if ($hit) { $line = $hit.Matches[0].Value }
    }
    if ($line) {
        Write-Host ("volume={0,-5} -> {1}" -f $value, $line)
    } else {
        Write-Host ("volume={0,-5} -> NO LOG LINE" -f $value)
        $script:fail = 1
    }
    return $line
}

New-Item -ItemType Directory -Force -Path $scratch | Out-Null

$expect = @(
    @{ v = '0.35'; text = 'volume 0.35 (35%) from settings' },
    @{ v = '1';    text = 'volume 1.00 (100%) from settings' },
    @{ v = '0';    text = 'volume 0.00 (0%) from settings' },
    @{ v = '5';    text = 'volume 2.00 (200%) from settings' },
    @{ v = '-3';   text = 'volume 0.00 (0%) from settings' }
)

foreach ($case in $expect) {
    $got = Probe $case.v
    if ($got -ne $case.text) {
        Write-Host ("  expected: {0}" -f $case.text)
        $fail = 1
    }
}

Remove-Item Env:\LANPLAYER_STATE_DIR -ErrorAction SilentlyContinue
Remove-Item Env:\LANPLAYER_OPEN -ErrorAction SilentlyContinue
Remove-Item Env:\LANPLAYER_NO_TEXTURE -ErrorAction SilentlyContinue
Get-Process -Name lanplayer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

if ($fail -ne 0) {
    Write-Host 'volume-from-settings FAILED'
    exit 1
}
Write-Host 'PASS: settings volume reaches the kernel and is clamped to 0..2'
exit 0
