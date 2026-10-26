#!/usr/bin/env python3
"""Install the local git hooks that auto-push every commit to GitHub.

    python scripts/install_git_hooks.py

Hooks live in .git/hooks and are not tracked by git, so they have to be
reinstalled after a fresh clone.  Run this once per clone.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402

HOOK_BODY = """#!/bin/sh
# Auto-push every commit to GitHub.
#
# Installed by scripts/install_git_hooks.py.  Lives in .git/hooks so it is
# local to this clone and never committed.  The logic is in
# tool/git_autopush.py: keeping it there means the retry ladder (direct ->
# certificate check off -> local tunnel) is written once, in a language with
# error handling, instead of inside a shell hook nobody can debug.

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

python_bin="$root/.tools/python/python.exe"
if [ ! -x "$python_bin" ]; then
    python_bin=$(command -v python3 || command -v python || true)
fi
if [ -z "$python_bin" ]; then
    echo "[auto-push] no python found; run scripts/sync_github.py manually"
    exit 0
fi

"$python_bin" "$root/tool/git_autopush.py" "$root"
exit 0
"""


def install() -> int:
    root = lp.ROOT
    hooks = root / ".git" / "hooks"
    if not hooks.is_dir():
        lp.warn(f"install-git-hooks: {root} is not a git repository")
        return 2

    hook = hooks / "post-commit"
    # LF endings on purpose: a CRLF shell script fails on some shells with
    # "bad interpreter: /bin/sh^M".
    lp.write_text(hook, HOOK_BODY, newline="\n")
    hook.chmod(0o755)
    lp.note("install-git-hooks: wrote .git/hooks/post-commit")
    lp.note("install-git-hooks: every 'git commit' now pushes to origin automatically")
    return 0


def main() -> None:
    sys.exit(install())


if __name__ == "__main__":
    main()
