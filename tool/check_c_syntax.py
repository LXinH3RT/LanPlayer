#!/usr/bin/env python3
"""Cheap syntactic sanity checks for the C sources (no compiler available).

  * balanced braces / parentheses / brackets, ignoring comments and literals
  * balanced #if / #ifdef / #ifndef against #endif
  * local #include "..." targets resolve through the project include paths
  * files are UTF-8 without BOM and end with a newline
"""
from __future__ import annotations

import sys
from pathlib import Path

# The Windows console defaults to a legacy code page that cannot represent
# the marks printed below; force UTF-8 so the report is readable everywhere.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parent.parent / "native"
INCLUDES = [
    ROOT / "include",
    ROOT / "src",
    ROOT / "src" / "source",
    ROOT.parent / "packages" / "lanplayer_video" / "windows" / "include",
]
OPENERS = {"{": "}", "(": ")", "[": "]"}
CLOSERS = {v: k for k, v in OPENERS.items()}

def strip_comments_and_literals(text: str) -> str:
    out: list[str] = []
    i = 0
    n = len(text)
    state = "code"
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if state == "code":
            if c == "/" and nxt == "/":
                state = "line"
                i += 2
                continue
            if c == "/" and nxt == "*":
                state = "block"
                i += 2
                continue
            if c == '"':
                state = "str"
                out.append(" ")
                i += 1
                continue
            if c == "'":
                state = "chr"
                out.append(" ")
                i += 1
                continue
            out.append(c)
            i += 1
            continue
        if state == "line":
            if c == "\n":
                state = "code"
                out.append(c)
            i += 1
            continue
        if state == "block":
            if c == "*" and nxt == "/":
                state = "code"
                i += 2
                continue
            i += 1
            continue
        if state == "str" or state == "chr":
            if c == "\\":
                i += 2
                continue
            if (state == "str" and c == '"') or (state == "chr" and c == "'"):
                state = "code"
            i += 1
            continue
    return "".join(out)

def check_balance(path: Path, text: str) -> list[str]:
    problems: list[str] = []
    code = strip_comments_and_literals(text)
    stack: list[tuple[str, int]] = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
            continue
        if ch in OPENERS:
            stack.append((ch, line))
        elif ch in CLOSERS:
            if not stack:
                problems.append(f"{path.name}:{line}: unmatched '{ch}'")
                continue
            opener, oline = stack.pop()
            if OPENERS[opener] != ch:
                problems.append(
                    f"{path.name}:{line}: '{ch}' closes '{opener}' opened at line {oline}")
    for opener, oline in stack:
        problems.append(f"{path.name}: unbalanced '{opener}' opened at line {oline}")

    # Preprocessor nesting.
    depth = 0
    for idx, raw in enumerate(text.splitlines(), start=1):
        s = raw.strip()
        if s.startswith(("#if", "#ifdef", "#ifndef")):
            depth += 1
        elif s.startswith("#endif"):
            depth -= 1
            if depth < 0:
                problems.append(f"{path.name}:{idx}: stray #endif")
                depth = 0
    if depth != 0:
        problems.append(f"{path.name}: {depth} unterminated #if block(s)")
    return problems

def check_includes(path: Path, text: str) -> list[str]:
    problems: list[str] = []
    for raw in text.splitlines():
        s = raw.strip()
        if not s.startswith('#include "'):
            continue
        target = s.split('"')[1]
        candidates = [path.parent / target] + [inc / target for inc in INCLUDES]
        if not any(c.exists() for c in candidates):
            problems.append(f"{path.name}: local include not found: {target}")
    return problems

def main() -> int:
    problems: list[str] = []
    files = sorted(list((ROOT / "src").rglob("*.c")) + list((ROOT / "tests").rglob("*.c")) +
                   list((ROOT / "include").rglob("*.h")) + [ROOT / "src" / "player_internal.h",
                                                           ROOT / "src" / "source" / "source_internal.h"])
    for path in files:
        data = path.read_bytes()
        if data.startswith(b"\xef\xbb\xbf"):
            problems.append(f"{path.name}: UTF-8 BOM")
        if not data.endswith(b"\n"):
            problems.append(f"{path.name}: missing trailing newline")
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as exc:
            problems.append(f"{path.name}: not valid UTF-8 ({exc})")
            continue
        problems += check_balance(path, text)
        problems += check_includes(path, text)

    print(f"files checked: {len(files)}")
    if problems:
        for p in problems:
            print(f"✗ {p}")
        return 1
    print("✓ braces, preprocessor nesting, includes and encoding look sane")
    return 0

if __name__ == "__main__":
    sys.exit(main())
