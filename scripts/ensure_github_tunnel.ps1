# Make sure the local GitHub CONNECT tunnel is listening.
#
# Why this exists: on this machine DNS resolves github.com to one address that
# is frequently unreachable (TCP 443 times out) while other GitHub addresses
# answer normally. tool/github_tunnel.py listens on 127.0.0.1 and rewrites only
# the TCP destination, so TLS stays end to end and the certificate still
# matches github.com. git just needs http.proxy pointing at it.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\ensure_github_tunnel.ps1
#   ... -Port 8899 -Ip 140.82.112.3 -TimeoutSec 20
#
# Exit codes: 0 = tunnel is listening, 1 = could not start it.
#
# This file must stay pure ASCII (PowerShell 5.1 reads .ps1 with the ANSI code
# page on a Chinese Windows install).

param(
    [int]$Port = 8899,
    [string]$Ip = '140.82.112.3',
    [int]$TimeoutSec = 20
)

$ErrorActionPreference = 'Continue'

function Test-PortOpen {
    param([int]$P)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        return $client.ConnectAsync('127.0.0.1', $P).Wait(400)
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

if (Test-PortOpen -P $Port) {
    Write-Host "tunnel: already listening on 127.0.0.1:$Port"
    exit 0
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script = Join-Path $root 'tool\github_tunnel.py'
if (-not (Test-Path $script)) {
    Write-Host "tunnel: $script is missing" -ForegroundColor Red
    exit 1
}

$candidates = @(
    (Join-Path $root '.tools\python\python.exe'),
    'python.exe',
    'python3.exe'
)
$python = $null
foreach ($c in $candidates) {
    if (Test-Path $c) { $python = $c; break }
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if ($cmd) { $python = $cmd.Source; break }
}
if (-not $python) {
    Write-Host 'tunnel: no python found (expected .tools\python\python.exe)' -ForegroundColor Red
    exit 1
}

$logDir = Join-Path $root '.tools\tmp'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$outLog = Join-Path $logDir 'github-tunnel.log'
$errLog = Join-Path $logDir 'github-tunnel.err.log'

$proc = Start-Process -FilePath $python `
    -ArgumentList @($script, '--port', $Port, '--ip', $Ip) `
    -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog
if (-not $proc) {
    Write-Host 'tunnel: failed to spawn python' -ForegroundColor Red
    exit 1
}

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    if (Test-PortOpen -P $Port) {
        Write-Host "tunnel: started on 127.0.0.1:$Port (pid $($proc.Id), github.com -> $Ip)"
        exit 0
    }
    if ($proc.HasExited) {
        Write-Host "tunnel: python exited with code $($proc.ExitCode)" -ForegroundColor Red
        if (Test-Path $errLog) { Get-Content $errLog -Tail 5 | ForEach-Object { Write-Host "  $_" } }
        exit 1
    }
}

Write-Host "tunnel: did not come up within $TimeoutSec s" -ForegroundColor Red
exit 1
