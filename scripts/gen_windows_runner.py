#!/usr/bin/env python3
"""Generate app/windows/ from the Flutter SDK's own Windows runner templates.

``flutter create --platforms=windows .`` does exactly this; reproducing it here
means the desktop runner can be generated on machines where the flutter tool
cannot run (no git, no interactive console) and the generated tree stays
reviewable in the repository.

    python scripts/gen_windows_runner.py
    python scripts/gen_windows_runner.py --project-name lanplayer --organization dev.lanplayer
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402

BINARY_SUFFIXES = {".ico", ".png", ".jpg"}

# Sections of the template that only apply to plugin projects.
DROP_SECTION = re.compile(
    r"(?s)\{\{#withPlatformChannelPluginHook\}\}.*?\{\{/withPlatformChannelPluginHook\}\}")


def expand(text: str, project: str, organization: str) -> str:
    text = DROP_SECTION.sub("", text)
    replacements = {
        "{{projectName}}": project,
        "{{pluginProjectName}}": project,
        "{{organization}}": organization,
        "{{year}}": str(datetime.now().year),
        "{{description}}": "LanPlayer",
        "{{windowsIdentifier}}": organization,
    }
    for needle, value in replacements.items():
        text = text.replace(needle, value)
    return text


def generate(template_root: Path, dest: Path, project: str, organization: str) -> int:
    if not template_root.is_dir():
        raise lp.ScriptError("Flutter SDK templates not found - run: "
                             "python tool/fetch_deps.py flutter")

    created = 0
    for source in sorted(template_root.rglob("*")):
        if not source.is_file():
            continue
        relative = source.relative_to(template_root).as_posix()
        # Two sequential suffixes, in this order: "app_icon.ico.img.tmpl" has
        # to lose both, and stripping them in one step would leave ".img".
        name = relative[:-len(".tmpl")] if relative.endswith(".tmpl") else relative
        name = name[:-len(".img")] if name.endswith(".img") else name
        target = dest / name
        target.parent.mkdir(parents=True, exist_ok=True)

        if target.suffix.lower() in BINARY_SUFFIXES:
            shutil.copy2(source, target)
        else:
            target.write_text(expand(source.read_text(encoding="utf-8"),
                                      project, organization),
                              encoding="utf-8", newline="")
        lp.note(f"   {name}")
        created += 1

    lp.note(f"\ngenerated {created} files in {dest}")
    lp.note("next: flutter pub get regenerates windows/flutter/generated_plugins.cmake")
    return created


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate the Windows runner from the SDK templates.")
    parser.add_argument("--project-name", default="lanplayer")
    parser.add_argument("--organization", default="dev.lanplayer")
    args = parser.parse_args()
    template = lp.TOOLS / "flutter-sdk" / "packages" / "flutter_tools" / \
        "templates" / "app_shared" / "windows.tmpl"
    generate(template, lp.ROOT / "app" / "windows", args.project_name, args.organization)


if __name__ == "__main__":
    main()
