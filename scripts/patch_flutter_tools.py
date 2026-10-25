#!/usr/bin/env python3
"""Patch the bundled Flutter SDK so ``flutter build windows`` works with Visual
Studio 2026 (major version 18).

Why this is needed
------------------
flutter_tools decides the CMake generator itself:

    .tools/flutter-sdk/packages/flutter_tools/lib/src/windows/visual_studio.dart
      String? get cmakeGenerator {
        return switch (_majorVersion) {
          17 => 'Visual Studio 17 2022',
          _  => 'Visual Studio 16 2019',
        };
      }

Visual Studio 18 therefore falls into the ``_`` arm and CMake is asked for a
"Visual Studio 16 2019" generator, which does not exist on the machine:

    CMake Error: Generator Visual Studio 16 2019 could not find any instance
    of Visual Studio.

Flutter 3.27.4 predates VS 2026, so there is no upstream support to rely on.
The SDK lives under the git-ignored .tools/ directory, so patching it is a
local tool cache change rather than a modification of tracked sources; the
patch is idempotent and re-applied by scripts/build_windows_desktop.py.

The generator name is discovered from ``cmake --help`` (which always lists the
generators the installed CMake knows) and injected as an explicit case, so a
future VS 19 / VS 20 would only need ``--major-version 19``.

    python scripts/patch_flutter_tools.py
    python scripts/patch_flutter_tools.py --major-version 18
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402

OLD = """  String? get cmakeGenerator {
    // From https://cmake.org/cmake/help/v3.22/manual/cmake-generators.7.html#visual-studio-generators
    return switch (_majorVersion) {
      17 => 'Visual Studio 17 2022',
      _  => 'Visual Studio 16 2019',
    };
  }
"""


def find_cmake() -> str | None:
    """The cmake that ships with Visual Studio, else whatever is on PATH."""
    for base_var in ("ProgramFiles", "ProgramFiles(x86)"):
        base = lp.os.environ.get(base_var)
        if not base:
            continue
        vs_root = Path(base) / "Microsoft Visual Studio"
        if not vs_root.is_dir():
            continue
        for major in sorted(vs_root.iterdir()):
            if not major.is_dir():
                continue
            for edition in sorted(major.iterdir()):
                candidate = edition / "Common7" / "IDE" / "CommonExtensions" / \
                    "Microsoft" / "CMake" / "CMake" / "bin" / "cmake.exe"
                if candidate.exists():
                    return str(candidate)
    return lp.shutil.which("cmake")


def discover_generator(cmake: str, major: int) -> str | None:
    """The ``Visual Studio <major> <year>`` line from ``cmake --help``.

    Matching on the major number followed by a four digit year keeps
    "16 2019" from being taken for "18 2026".
    """
    help_text = lp.output([cmake, "--help"])
    pattern = re.compile(rf"^\s*\*?\s*(Visual Studio {major}\s+\d{{4}})(?!\d)")
    for line in help_text.splitlines():
        match = pattern.match(line)
        if match:
            return match.group(1).strip()
    return None


def patch(major: int, flutter_root: Path) -> int:
    source = flutter_root / "packages" / "flutter_tools" / "lib" / "src" / \
        "windows" / "visual_studio.dart"
    if not source.exists():
        lp.warn(f"no flutter_tools sources at {source} (SDK not downloaded?)")
        return 1

    cmake = find_cmake()
    if not cmake:
        lp.warn("cmake.exe not found; cannot discover the generator name")
        return 1
    generator = discover_generator(cmake, major)
    if not generator:
        lp.warn(f"cmake does not offer a 'Visual Studio {major}' generator")
        return 1

    text = source.read_text(encoding="utf-8")
    marker = (f"// [lanplayer] Visual Studio {major} support "
              f"(scripts/patch_flutter_tools.py)")
    new = f"""  String? get cmakeGenerator {{
    // From https://cmake.org/cmake/help/v3.22/manual/cmake-generators.7.html#visual-studio-generators
    {marker}
    return switch (_majorVersion) {{
      {major} => '{generator}',
      17 => 'Visual Studio 17 2022',
      _  => 'Visual Studio 16 2019',
    }};
  }}
"""

    # Replace the whole getter rather than one exact spelling of the original:
    # an SDK patched by the earlier PowerShell script carries a slightly
    # different comment ("// // [lanplayer] ... (scripts/patch_flutter_tools.py)"),
    # and rewriting the block is both idempotent and how that artefact gets
    # cleaned up on the next run.
    block = re.compile(r"  String\? get cmakeGenerator\s*\{.*?\n  \}", re.S)
    match = block.search(text)
    if not match:
        lp.warn("cmakeGenerator getter does not match the expected shape")
        lp.warn("the SDK may already be newer; remove this patch if upstream "
                "supports VS 2026")
        return 1

    if match.group(0) == new.rstrip("\n"):
        lp.note(f"flutter_tools: already patched for {generator}")
        return 0

    source.write_text(text[:match.start()] + new + text[match.end():],
                      encoding="utf-8", newline="")
    lp.note(f"flutter_tools: patched cmakeGenerator -> '{generator}' "
            f"(VS major {major})")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Patch flutter_tools for a newer Visual Studio.")
    parser.add_argument("--major-version", type=int, default=18,
                        help="Visual Studio major version to support (18 = VS 2026)")
    parser.add_argument("--flutter-root", default="",
                        help="Flutter SDK root; defaults to .tools/flutter-sdk")
    args = parser.parse_args()
    root = Path(args.flutter_root) if args.flutter_root else lp.TOOLS / "flutter-sdk"
    sys.exit(patch(args.major_version, root))


if __name__ == "__main__":
    main()
