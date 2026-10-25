#!/usr/bin/env python3
"""Run the Flutter tool with its temporary and pub directories pointed inside
the repository.

Why the wrapper: on machines where %APPDATA% / %PUB_CACHE% are not writable the
flutter tool dies immediately with

    Error: Flutter failed to write to a file at "...\\.flutter_tool_state"

and `flutter analyze` additionally needs %LOCALAPPDATA%\\.dartServer
(PathAccessException: Creation failed ... .dartServer).  Redirecting TMP, TEMP,
APPDATA, LOCALAPPDATA and PUB_CACHE into .tools/ makes the tool usable without
touching the real profile.

    python scripts/run_flutter_tests.py
    python scripts/run_flutter_tests.py analyze
    python scripts/run_flutter_tests.py test test/widget_test.dart
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402


def flutter_bin(tools: Path) -> Path:
    if sys.platform == "win32":
        return tools / "flutter-sdk" / "bin" / "flutter.bat"
    return tools / "flutter-sdk" / "bin" / "flutter"


def main() -> int:
    argv = sys.argv[1:]
    tools = lp.TOOLS
    for name in ("tmp", "appdata", "pubcache"):
        (tools / name).mkdir(parents=True, exist_ok=True)

    env = lp.isolated_env()
    env["PUB_CACHE"] = str(tools / "pubcache")
    env["LOCALAPPDATA"] = str(tools / "appdata")

    flutter = flutter_bin(tools)
    if not flutter.exists():
        raise lp.ScriptError("Flutter SDK missing - run: python tool/fetch_deps.py flutter")

    args = list(argv) or ["test"]
    result = lp.run([str(flutter), *args], cwd=lp.ROOT / "app", env=env, check=False)
    return result.returncode


if __name__ == "__main__":
    sys.exit(lp.main(main))
