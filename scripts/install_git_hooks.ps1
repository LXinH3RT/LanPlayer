# Install the local git hooks that auto-push every commit to GitHub.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install_git_hooks.ps1
#
# Hooks live in .git/hooks/ and are NOT tracked by git, so they have to be
# reinstalled after a fresh clone. Run this once per clone.
#
# This file must stay pure ASCII: PowerShell 5.1 parses .ps1
# with the ANSI code page, so a non-ASCII character breaks it.

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$hooks = Join-Path $root '.git\hooks'
if (-not (Test-Path $hooks)) {
    Write-Host "install-git-hooks: $root is not a git repository" -ForegroundColor Red
    exit 2
}

$hookPath = Join-Path $hooks 'post-commit'

# The hook body is written with LF endings on purpose: a CRLF sh script fails
# with "bad interpreter: /bin/sh^M" on some shells.
$body = @'
#!/bin/sh
# Auto-push every commit to GitHub.
#
# Installed by scripts/install_git_hooks.ps1. Lives in .git/hooks
# so it is local to this clone and never committed.
#
# Runs AFTER the commit exists, so a failed push never loses work: the commit
# stays local and the next push picks it up. Failures print a hint but do not
# abort anything, because push problems (offline, token expired) must not make
# an otherwise good commit look broken.

remote=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
if [ -z "$remote" ]; then
    echo "[auto-push] no upstream branch, skipping"
    exit 0
fi

# Never block on a credential prompt from a hook (there is no terminal).
# Two-step push: this clone may be driven by the git that ships inside the
# Flutter SDK (mingit). That one has no Windows credential-manager helper, and
# its bundled CA store does not validate github.com, so it fails with
# "SSL certificate problem: unable to get local issuer certificate". The
# machine-wide Git for Windows install has both, so retry with it.
export GIT_TERMINAL_PROMPT=0

push_with() {
    if [ "$1" = "tunnel" ]; then
        "$2" -c http.proxy=http://127.0.0.1:8899 \
             -c https.proxy=http://127.0.0.1:8899 push origin HEAD >/dev/null 2>&1
    else
        "$2" push origin HEAD >/dev/null 2>&1
    fi
}

git_bin=git
if [ -x "/c/Program Files/Git/cmd/git.exe" ]; then
    git_bin="/c/Program Files/Git/cmd/git.exe"
fi

if push_with direct "$git_bin"; then
    echo "[auto-push] pushed $(git rev-parse --short HEAD) to $remote"
    exit 0
fi

# Second chance through the local CONNECT tunnel. On this network DNS often
# returns a github.com address that is unreachable; tool/github_tunnel.py
# rewrites only the TCP destination so TLS still matches the certificate.
root=$(git rev-parse --show-toplevel 2>/dev/null)
ensure="$root/scripts/ensure_github_tunnel.ps1"
if [ -f "$ensure" ]; then
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$ensure" 2>/dev/null || echo "$ensure")" >/dev/null 2>&1
    if push_with tunnel "$git_bin"; then
        echo "[auto-push] pushed $(git rev-parse --short HEAD) to $remote (tunnel)"
        exit 0
    fi
fi

echo "[auto-push] push failed; run scripts/sync_github.ps1 manually"
exit 0
'@

$text = $body -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($hookPath, ($text.TrimEnd("`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "install-git-hooks: wrote .git/hooks/post-commit"

# On Windows git ships its own sh, so the hook runs without Git Bash on PATH.
Write-Host "install-git-hooks: every 'git commit' now pushes to origin automatically"
exit 0
