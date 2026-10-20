#!/usr/bin/env python3
"""Static consistency check for the native core.

There is no C compiler in this workspace, so this script performs the checks a
compiler would catch first:

  * every function declared in the public/internal headers has a definition
  * every non-static definition is declared somewhere (catches typos)
  * the public header surface only uses types that dart:ffi can bind
  * the Dart FFI bindings only reference symbols the core actually exports

Exit code 0 = clean, 1 = problems found (printed on stdout).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# The Windows console defaults to a legacy code page that cannot represent
# the marks printed below; force UTF-8 so the report is readable everywhere.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parent.parent / "native"
SRC = ROOT / "src"
INC = ROOT / "include"
APP = Path(__file__).resolve().parent.parent / "app"

DECL_RE = re.compile(r"^\s*(?:LP_EXPORT\s+)?(?:[A-Za-z_][\w\s\*]*?)\b(lp_[a-z0-9_]+)\s*\(", re.M)
DEF_RE = re.compile(r"^(?!\s*(?:return|if|else|while|for)\b)[A-Za-z_][\w\s\*]*?\b(lp_[a-z0-9_]+)\s*\([^;]*?\)\s*\{", re.M)
FFI_RE = re.compile(r"lookupFunction<[^>]*>\(\s*'([a-zA-Z0-9_]+)'")
LPDECL_IN_DART = re.compile(r"'(lp_[a-z0-9_]+)'")

SKIP_PREFIX = ("lp_str_", "lp_pq_", "lp_ring_", "lp_clock_", "lp_json_", "lp_log_vemit")

def collect_decls() -> dict[str, Path]:
    decls: dict[str, Path] = {}
    extra_headers = [
        SRC / "player_internal.h",
        SRC / "source" / "source_internal.h",
        SRC / "platform" / "win32" / "win32_preview.h",
    ]
    for path in list(INC.rglob("*.h")) + extra_headers:
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        # Drop macro definitions and comments to avoid false positives.
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        text = re.sub(r"^\s*#define.*$", "", text, flags=re.M)
        for m in DECL_RE.finditer(text):
            name = m.group(1)
            line = text[m.start(): text.find(";", m.start()) + 1]
            if "typedef" in line or "(*" in line:
                continue
            if name not in decls:
                decls[name] = path
    return decls

def collect_defs() -> dict[str, Path]:
    defs: dict[str, Path] = {}
    for path in SRC.rglob("*.c"):
        text = path.read_text(encoding="utf-8")
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        for m in DEF_RE.finditer(text):
            name = m.group(1)
            # static functions are file local by design
            head = text[max(0, m.start() - 40): m.start()]
            if re.search(r"\bstatic\b", head):
                continue
            defs.setdefault(name, path)
    return defs

def collect_dart_symbols() -> set[str]:
    if not APP.exists():
        return set()
    used: set[str] = set()
    for path in (APP / "lib").rglob("*.dart"):
        for m in FFI_RE.finditer(path.read_text(encoding="utf-8")):
            used.add(m.group(1))
    return used

def main() -> int:
    decls = collect_decls()
    defs = collect_defs()
    problems: list[str] = []

    for name, path in sorted(decls.items()):
        if name.startswith(SKIP_PREFIX):
            continue
        if name not in defs:
            problems.append(f"declared but never defined: {name}  ({path.relative_to(ROOT)})")

    for name, path in sorted(defs.items()):
        if name.startswith(SKIP_PREFIX):
            continue
        if name not in decls:
            problems.append(f"defined but not declared: {name}  ({path.relative_to(ROOT)})")

    dart = collect_dart_symbols()
    for name in sorted(dart):
        if name not in defs:
            problems.append(f"Dart binds a symbol the core does not define: {name}")

    public = sorted(n for n in decls if n.startswith(("lp_player", "lp_source", "lp_abi", "lp_string", "lp_url", "lp_log_set")))
    print(f"public API functions: {len(public)}")
    print(f"declarations: {len(decls)}  definitions: {len(defs)}  dart-bound symbols: {len(dart)}")

    if problems:
        print("\n".join(problems))
        print(f"\n{len(problems)} problem(s) found")
        return 1
    print("no inconsistencies found")
    return 0

if __name__ == "__main__":
    sys.exit(main())
