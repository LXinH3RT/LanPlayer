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

MAP_RE = re.compile(r"^\s*(lp_[a-z0-9_]*(?:\*)?|Java_[A-Za-z0-9_]*(?:\*)?)\s*;", re.M)


def collect_exports() -> dict[str, Path]:
    """Every function the public headers mark `LP_EXPORT`.

    Those are the only ones a host outside the library can call, so they are
    also the only ones that must survive the version script.
    """
    exports: dict[str, Path] = {}
    for path in INC.rglob("*.h"):
        text = path.read_text(encoding="utf-8")
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        # The two `#define LP_EXPORT ...` lines would otherwise look like
        # declarations of a function called nothing at all.
        text = re.sub(r"^\s*#define[^\n]*$", "", text, flags=re.M)
        for m in re.finditer(r"LP_EXPORT\b[^;()]*?\b(lp_[a-z0-9_]+)\s*\(", text):
            exports.setdefault(m.group(1), path)
    return exports


def collect_map(varname: str) -> list[str]:
    """The `global:` entries of a linker version script."""
    path = ROOT / varname
    if not path.exists():
        return []
    text = re.sub(r"/\*.*?\*/", "", path.read_text(encoding="utf-8"), flags=re.S)
    head = text.split("local:", 1)[0]
    return [m.group(1) for m in MAP_RE.finditer(head)]


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

    # Linux / Android build with `C_VISIBILITY_PRESET hidden` and get their
    # exported surface back from a version script alone. A symbol that is
    # `LP_EXPORT` in the header but missing from that script compiles fine and
    # then fails at lookup time on the device — which is exactly how Android
    # lost its thumbnails for a while.
    exports = collect_exports()
    map_path = ROOT / "lp_map.txt"
    if map_path.exists():
        # An empty `global:` list means nothing is exported at all, which is a
        # different bug with the same symptom; do not skip the check for it.
        gl_map = collect_map(Path("lp_map.txt"))
        patterns = [p for p in gl_map if p.endswith("*")]
        listed = set(p for p in gl_map if not p.endswith("*"))
        for name in sorted(exports):
            if name in listed or any(name.startswith(p[:-1]) for p in patterns):
                continue
            problems.append(
                f"LP_EXPORT but missing from native/lp_map.txt: {name}"
                f"  ({exports[name].relative_to(ROOT)})")
    else:
        problems.append("native/lp_map.txt is gone; the Linux/Android builds "
                        "would export nothing")

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
