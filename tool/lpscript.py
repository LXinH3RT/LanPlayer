#!/usr/bin/env python3
"""Shared helpers for the build and maintenance scripts in this repository.

Every script that used to be a shell script imports this module instead of
repeating the same twenty lines of environment juggling.  The rules it encodes
are the ones that kept costing time when the scripts were PowerShell or bash:

  * a command's failure has to stop the script, with its output shown;
  * child processes inherit an environment that does not leak the developer's
    personal profile directories (Flutter and Gradle both write there);
  * paths are handled with pathlib, never by string concatenation, because the
    same scripts run on Windows, macOS and Linux;
  * reports go to stdout as UTF-8 whatever the console code page is.

Import it as::

    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
    import lpscript as lp
"""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# The Windows console defaults to a legacy code page that cannot represent
# every character these reports print; force UTF-8 so they are readable.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
TOOLS = ROOT / ".tools"
DIST = ROOT / "dist"

QUIET = False


class ScriptError(RuntimeError):
    """A step failed.  main() turns it into exit code 1 and one clear line."""


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------
def say(*parts: object) -> None:
    """Print one progress line (suppressed by --quiet)."""
    if not QUIET:
        print(*parts, flush=True)


def note(*parts: object) -> None:
    """Print a line that must appear even in quiet mode."""
    print(*parts, flush=True)


def warn(*parts: object) -> None:
    print("!!", *parts, file=sys.stderr, flush=True)


def step(title: str) -> None:
    say(f"== {title}")


# --------------------------------------------------------------------------
# processes
# --------------------------------------------------------------------------
def run(
    cmd: list[object],
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    capture: bool = False,
    check: bool = True,
    show: bool = True,
    stdin_text: str | None = None,
) -> subprocess.CompletedProcess:
    """Run one command and wait for it.

    Output goes straight to the console unless ``capture`` is set: build tools
    detect a terminal and colour or reformat their output accordingly, and
    hiding a long compile behind a pipe makes a hang indistinguishable from
    work in progress.
    """
    argv = [str(c) for c in cmd]
    if show:
        say("+", " ".join(argv))
    proc = subprocess.run(
        argv,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        input=stdin_text,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and proc.returncode != 0:
        detail = ""
        if capture:
            out = (proc.stdout or "") + (proc.stderr or "")
            tail = "\n".join(out.strip().splitlines()[-25:])
            detail = f"\n{tail}" if tail else ""
        raise ScriptError(f"{argv[0]} exited with {proc.returncode}{detail}")
    return proc


def output(cmd: list[object], cwd: Path | None = None, env: dict[str, str] | None = None) -> str:
    """Run a command and return its stripped stdout; empty string if it fails."""
    argv = [str(c) for c in cmd]
    proc = subprocess.run(
        argv,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return proc.stdout.strip() if proc.returncode == 0 else ""


def background(cmd: list[object], cwd: Path | None = None, env: dict[str, str] | None = None,
               stdout=None, stderr=None) -> subprocess.Popen:
    argv = [str(c) for c in cmd]
    say("+", " ".join(argv), "(background)")
    return subprocess.Popen(argv, cwd=str(cwd) if cwd else None, env=env,
                            stdout=stdout, stderr=stderr, text=True)


def wait_port(port: int, timeout: float, host: str = "127.0.0.1") -> bool:
    """True once a TCP connection to host:port succeeds."""
    import socket

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket() as sock:
            sock.settimeout(0.4)
            try:
                sock.connect((host, port))
                return True
            except OSError:
                time.sleep(0.25)
    return False


# --------------------------------------------------------------------------
# processes that stay alive (GUI automation, servers)
# --------------------------------------------------------------------------
def kill_tree(proc: subprocess.Popen, grace: float = 1.0) -> None:
    """Stop a child and everything it spawned.

    Flutter desktop apps spawn worker threads but no child processes, while
    Gradle and CMake spawn grandchildren; terminate then kill covers both.
    """
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        proc.kill()
        try:
            proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            pass


# --------------------------------------------------------------------------
# environment
# --------------------------------------------------------------------------
def find_python() -> str:
    """A python that works on this machine.

    ``python`` on PATH can be the Microsoft Store redirector, which exits
    without running anything, so the bundled interpreter wins when present.
    """
    for candidate in (TOOLS / "python" / "python.exe", TOOLS / "python" / "bin" / "python3"):
        if candidate.exists():
            return str(candidate)
    if sys.executable:
        return sys.executable
    return "python3"


def isolated_env(extra: dict[str, str] | None = None, home: bool = True) -> dict[str, str]:
    """A copy of os.environ with the personal profile directories redirected.

    Flutter, the Dart pub cache and Gradle all write into %APPDATA%,
    %LOCALAPPDATA%, %PUB_CACHE% and the home directory.  Pointing those at
    .tools/ keeps a build from touching whatever the developer has installed,
    and makes a failure reproducible by deleting one directory.
    """
    env = dict(os.environ)
    if home:
        env["HOME"] = str(TOOLS / "home")
        env["TMP"] = str(TOOLS / "tmp")
        env["TEMP"] = str(TOOLS / "tmp")
        env["APPDATA"] = str(TOOLS / "appdata")
        env["LOCALAPPDATA"] = str(TOOLS / "localappdata")
        env["PUB_CACHE"] = str(TOOLS / "pub-cache")
        for key in ("HOME", "TMP", "TEMP", "APPDATA", "LOCALAPPDATA", "PUB_CACHE"):
            Path(env[key]).mkdir(parents=True, exist_ok=True)
    # Never let a git or ssh call wait for a password nobody can type.
    env.setdefault("GIT_TERMINAL_PROMPT", "0")
    env.setdefault("GCM_INTERACTIVE", "never")
    if extra:
        env.update(extra)
    return env


def prepend_path(env: dict[str, str], *dirs: Path) -> dict[str, str]:
    sep = os.pathsep
    head = sep.join(str(d) for d in dirs if d and Path(d).exists())
    env["PATH"] = head + sep + env.get("PATH", "") if head else env.get("PATH", "")
    return env


def need(name: str, why: str = "") -> str:
    """Resolve an executable or raise with an actionable message."""
    found = shutil.which(name)
    if found:
        return found
    suffix = f" ({why})" if why else ""
    raise ScriptError(f"{name} was not found on PATH{suffix}")


# --------------------------------------------------------------------------
# files
# --------------------------------------------------------------------------
def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def size_mb(path: Path) -> float:
    return round(path.stat().st_size / (1024 * 1024), 1)


def ensure_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def pubspec_version(path: Path | None = None) -> str:
    """The x.y.z part of app/pubspec.yaml's version line.

    Every package name and the executables' file version come from this one
    line, so a script that hard-codes a version silently ships a stale build.
    """
    import re

    spec = path or (ROOT / "app" / "pubspec.yaml")
    text = spec.read_text(encoding="utf-8")
    match = re.search(r"^\s*version:\s*(\d+\.\d+\.\d+)", text, re.M)
    if not match:
        raise ScriptError(f"cannot read the version from {spec}")
    return match.group(1)


def copy_tree_files(src: Path, dst: Path, names: list[str]) -> list[Path]:
    """Copy the named files, failing loudly when one is missing."""
    copied: list[Path] = []
    for name in names:
        source = src / name
        if not source.exists():
            raise ScriptError(f"{source} is missing; build it first")
        ensure_dir(dst)
        shutil.copy2(source, dst / name)
        copied.append(dst / name)
    return copied


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------
def main(wrapper) -> None:
    """Run ``wrapper()`` and turn ScriptError into exit code 1."""
    global QUIET
    try:
        code = wrapper()
    except ScriptError as exc:
        print(f"!! {exc}", file=sys.stderr, flush=True)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print("!! interrupted", file=sys.stderr, flush=True)
        raise SystemExit(130)
    raise SystemExit(code or 0)
