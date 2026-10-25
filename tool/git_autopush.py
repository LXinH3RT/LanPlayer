#!/usr/bin/env python3
"""Push the current branch to GitHub; installed as the post-commit hook body.

Runs AFTER the commit exists, so a failed push never loses work: the commit
stays local and the next push picks it up.  Failures print a hint but exit 0,
because push problems (offline, token expired) must not make an otherwise good
commit look broken.

The hook is installed by ``scripts/install_git_hooks.py``; this file holds the
logic so the hook itself can stay a two-line launcher.

    python tool/git_autopush.py [repo-root]
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lpscript as lp  # noqa: E402


def pick_git(root: Path) -> str:
    """Git for Windows has the credential helper and a CA bundle that validates
    github.com; the mingit inside the Flutter SDK has neither."""
    for candidate in (
        Path(r"C:\Program Files\Git\cmd\git.exe"),
        Path("/usr/bin/git"),
    ):
        if candidate.exists():
            return str(candidate)
    return "git"


def push_with(git: str, root: Path, env: dict[str, str], tunnel: bool, insecure: bool) -> bool:
    cmd = [git]
    if insecure:
        # Windows schannel fails the revocation check against github.com
        # (CRYPT_E_NO_REVOCATION_CHECK) and git exposes no finer switch than
        # sslVerify.  Traffic is still TLS; only the chain check is skipped.
        cmd += ["-c", "http.sslVerify=false"]
    if tunnel:
        cmd += ["-c", "http.proxy=http://127.0.0.1:8899",
                "-c", "https.proxy=http://127.0.0.1:8899"]
    cmd += ["push", "origin", "HEAD"]
    return lp.run(cmd, cwd=root, env=env, check=False, capture=True).returncode == 0


def autopush(root: Path) -> int:
    env = lp.isolated_env(home=False)
    git = pick_git(root)

    upstream = lp.output([git, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
                         cwd=root, env=env)
    if not upstream:
        lp.note("[auto-push] no upstream branch, skipping")
        return 0

    short = lp.output([git, "rev-parse", "--short", "HEAD"], cwd=root, env=env)

    if push_with(git, root, env, tunnel=False, insecure=False):
        lp.note(f"[auto-push] pushed {short} to {upstream}")
        return 0
    if push_with(git, root, env, tunnel=False, insecure=True):
        lp.note(f"[auto-push] pushed {short} to {upstream} (cert check off)")
        return 0

    # Last chance through the local CONNECT tunnel: on this network DNS often
    # returns a github.com address that is unreachable, and the tunnel rewrites
    # only the TCP destination so TLS still matches the certificate.
    ensure = root / "scripts" / "ensure_github_tunnel.py"
    if ensure.exists():
        lp.run([lp.find_python(), ensure], cwd=root, env=env, check=False, capture=True)
        if push_with(git, root, env, tunnel=True, insecure=False):
            lp.note(f"[auto-push] pushed {short} to {upstream} (tunnel)")
            return 0
        if push_with(git, root, env, tunnel=True, insecure=True):
            lp.note(f"[auto-push] pushed {short} to {upstream} (tunnel, cert check off)")
            return 0

    lp.note("[auto-push] push failed; run scripts/sync_github.py manually")
    return 0


def main() -> None:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else lp.ROOT
    sys.exit(autopush(root))


if __name__ == "__main__":
    main()
