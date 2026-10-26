#!/usr/bin/env python3
"""Sync the working tree to GitHub in one step.

    python scripts/sync_github.py
    python scripts/sync_github.py --message "fix: ..."
    python scripts/sync_github.py --quiet

What it does:

  1. ``git add -A``   (honours .gitignore; build output and .tools/ never go up)
  2. ``git commit``   (only when something is actually staged)
  3. ``git push``     (a no-op when the branch is already up to date)

Exit codes: 0 = pushed or already in sync, 1 = git error, 2 = not a git repo.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402


def pick_git() -> str:
    """Prefer Git for Windows over the mingit that ships with the Flutter SDK.

    mingit has no credential helper and its CA bundle does not validate
    github.com, so a push from it dies with "unable to get local issuer
    certificate".
    """
    system_git = Path(r"C:\Program Files\Git\cmd\git.exe")
    return str(system_git) if system_git.exists() else "git"


def sync(message: str, quiet: bool) -> int:
    lp.QUIET = quiet
    if not (lp.ROOT / ".git").exists():
        lp.warn(f"sync: {lp.ROOT} is not a git repository")
        return 2

    git = pick_git()
    env = lp.isolated_env(home=False)
    lp.say(f"sync: using {git}")

    if lp.run([git, "add", "-A"], cwd=lp.ROOT, env=env, check=False, capture=True).returncode != 0:
        lp.warn("sync: git add failed")
        return 1

    staged = lp.output([git, "diff", "--cached", "--name-only"], cwd=lp.ROOT, env=env)
    if staged:
        files = staged.splitlines()
        if not message:
            from datetime import datetime

            message = f"auto: sync working tree ({datetime.now():%Y-%m-%d %H:%M})"
        lp.say(f"sync: committing {len(files)} file(s)")
        for name in files:
            lp.say(f"  {name}")
        # A non-ASCII commit message has to survive the console code page, so
        # it goes through a UTF-8 file rather than an argv string.
        msg_file = lp.ROOT / ".git" / "SYNC_COMMIT_MSG.txt"
        lp.write_text(msg_file, message + "\n", newline="\n")
        try:
            commit = lp.run([git, "-c", "core.autocrlf=false", "commit", "-F", msg_file],
                            cwd=lp.ROOT, env=env, check=False, capture=True)
        finally:
            msg_file.unlink(missing_ok=True)
        if commit.returncode != 0:
            lp.warn("sync: git commit failed")
            if commit.stdout:
                print(commit.stdout, file=sys.stderr)
            return 1
    else:
        lp.say("sync: nothing to commit")

    # Push whatever the branch now has. "Everything up-to-date" is success.
    # Two attempts: the direct one is normal, and when it fails it is almost
    # always a github.com address this network cannot reach. The fallback
    # starts the local CONNECT tunnel (tool/github_tunnel.py) and retries
    # through it without persisting any proxy in the git config.
    pushed = lp.run([git, "push", "origin", "HEAD"], cwd=lp.ROOT, env=env,
                    check=False, capture=True)
    if pushed.returncode != 0:
        lp.say("sync: direct push failed, trying the local tunnel")
        tunnel = lp.SCRIPTS / "ensure_github_tunnel.py"
        if tunnel.exists():
            started = lp.run([sys.executable, tunnel], cwd=lp.ROOT, env=env,
                             check=False, capture=True)
            if not quiet and started.stdout:
                for line in started.stdout.splitlines():
                    lp.say(f"  {line}")
            if started.returncode == 0:
                pushed = lp.run(
                    [git, "-c", "http.proxy=http://127.0.0.1:8899",
                     "-c", "https.proxy=http://127.0.0.1:8899", "push", "origin", "HEAD"],
                    cwd=lp.ROOT, env=env, check=False, capture=True)
    if pushed.returncode != 0:
        lp.warn("sync: git push failed")
        for line in ((pushed.stdout or "") + (pushed.stderr or "")).splitlines():
            print(f"  {line}", file=sys.stderr)
        return 1

    head = lp.output([git, "--no-pager", "log", "--oneline", "-1"], cwd=lp.ROOT, env=env)
    lp.say(f"sync: pushed -> origin {head}")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Commit and push the working tree.")
    parser.add_argument("--message", "-m", default="", help="commit message")
    parser.add_argument("--quiet", "-q", action="store_true", help="only report problems")
    args = parser.parse_args()
    sys.exit(sync(args.message, args.quiet))


if __name__ == "__main__":
    main()
