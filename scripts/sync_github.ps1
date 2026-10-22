# Sync the working tree to GitHub in one step.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sync_github.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sync_github.ps1 -Message "fix: ..."
#
# What it does:
#   1. git add -A            (honours .gitignore; build output and .tools/ never go up)
#   2. git commit            (only when something is actually staged)
#   3. git push              (no-op when the branch is already up to date)
#
# Exit codes: 0 = pushed or already in sync, 1 = git error, 2 = not a git repo.
#
# This file must stay pure ASCII: PowerShell 5.1 reads .ps1 files using the
# ANSI code page, so a multi-byte character here breaks the parser on a
# Chinese Windows install.

param(
    [string]$Message = "",
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $root
try {
    if (-not (Test-Path (Join-Path $root '.git'))) {
        Write-Host "sync: $root is not a git repository" -ForegroundColor Red
        exit 2
    }

    # Make sure we never block on an interactive credential prompt. The
    # Windows credential manager already holds a GitHub token for this
    # machine, so a prompt here would mean the token was revoked.
    $env:GIT_TERMINAL_PROMPT = '0'

    # Prefer Git for Windows when present. The git bundled with the Flutter SDK
    # (mingit) ships an OpenSSL CA bundle that does not validate github.com and
    # has no credential helper, so push from it dies with
    # "SSL certificate problem: unable to get local issuer certificate".
    $systemGit = 'C:\Program Files\Git\cmd\git.exe'
    $git = if (Test-Path $systemGit) { $systemGit } else { 'git' }
    if (-not $Quiet) { Write-Host "sync: using $git" }

    & $git add -A 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "sync: git add failed" -ForegroundColor Red
        exit 1
    }

    $staged = & $git diff --cached --name-only
    if ($staged) {
        if (-not $Message) {
            $Message = "auto: sync working tree ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
        }
        if (-not $Quiet) {
            Write-Host "sync: committing $($staged.Count) file(s)"
            $staged | ForEach-Object { Write-Host "  $_" }
        }
        # A Chinese commit message must survive the console code page, so pass
        # it through a UTF-8 file instead of an argv string.
        $msgFile = Join-Path $root '.git\SYNC_COMMIT_MSG.txt'
        [System.IO.File]::WriteAllText($msgFile, $Message, (New-Object System.Text.UTF8Encoding($false)))
        & $git -c core.autocrlf=false commit -F $msgFile 2>&1 | Out-Null
        $commitExit = $LASTEXITCODE
        Remove-Item $msgFile -Force -ErrorAction SilentlyContinue
        if ($commitExit -ne 0) {
            Write-Host "sync: git commit failed" -ForegroundColor Red
            exit 1
        }
    } else {
        if (-not $Quiet) { Write-Host "sync: nothing to commit" }
    }

    # Push whatever the branch now has. "Everything up-to-date" is success.
    #
    # Two attempts. The direct one is normal; when it fails it is almost always
    # because DNS handed us a github.com address that this network cannot reach
    # (see tool/github_tunnel.py). The fallback starts that local CONNECT tunnel
    # and retries through it, without persisting any proxy in the git config.
    $pushOutput = & $git push origin HEAD 2>&1
    if ($LASTEXITCODE -ne 0) {
        if (-not $Quiet) { Write-Host 'sync: direct push failed, trying the local tunnel' }
        $tunnel = Join-Path $PSScriptRoot 'ensure_github_tunnel.ps1'
        if (Test-Path $tunnel) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tunnel | ForEach-Object {
                if (-not $Quiet) { Write-Host "  $_" }
            }
            if ($LASTEXITCODE -eq 0) {
                $pushOutput = & $git -c http.proxy=http://127.0.0.1:8899 `
                    -c https.proxy=http://127.0.0.1:8899 push origin HEAD 2>&1
            }
        }
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "sync: git push failed" -ForegroundColor Red
        $pushOutput | ForEach-Object { Write-Host "  $_" }
        exit 1
    }
    if (-not $Quiet) {
        $head = & $git --no-pager log --oneline -1
        Write-Host "sync: pushed -> origin $head" -ForegroundColor Green
    }
    exit 0
}
finally {
    Pop-Location
}
