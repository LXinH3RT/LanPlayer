#!/usr/bin/env python3
"""Re-create the plugin links Flutter expects under
``app/windows/flutter/ephemeral/.plugin_symlinks/``.

Why this exists: ``flutter pub get`` / ``flutter build windows`` call Dart's
``Link.createSync`` for every plugin that has a windows/ folder.  On a machine
where the shell token has no SeCreateSymbolicLinkPrivilege (plain user, medium
integrity, developer mode irrelevant) that call throws

    FileSystemException: Cannot create link ... (OS Error: 客户端没有所需的特权。, errno = 1314)

and the tool aborts with "Building with plugins requires symlink support."

Directory junctions are created with ``mklink /J`` and need no privilege, and
Dart reports them as ``FileSystemEntityType.link`` with
``Link.existsSync() == true``.  flutter_tools' ``_createPlatformPluginSymlinks``
does ``if (link.existsSync()) continue;`` before creating the link, so a
pre-made junction is accepted as-is.

Run this once per checkout, and again after ``flutter clean`` or after adding a
plugin with a windows/ implementation:

    python scripts/fix_plugin_links.py
    python scripts/fix_plugin_links.py --app app
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402

seen: set[str] = set()


def add_junction(link_path: Path, target: Path | str, label: str) -> None:
    if label in seen:
        return
    seen.add(label)
    target = Path(target)
    if not target.exists():
        lp.note(f"   {label:<22} skipped (target missing: {target})")
        return
    if link_path.exists() or link_path.is_symlink():
        lp.note(f"   {label:<22} already linked")
        return
    # cmd is used instead of os.symlink because a real symlink needs exactly
    # the privilege this script works around, while a junction does not.
    cmd = ["cmd", "/c", "mklink", "/J", str(link_path), str(target)]
    result = lp.run(cmd, check=False, capture=True)
    if result.returncode != 0:
        raise lp.ScriptError(f"mklink /J failed for {label}\n"
                             f"{(result.stdout or '') + (result.stderr or '')}")
    lp.note(f"   {label:<22} -> {target}")


def latest_path_provider(pub_cache: Path, app: Path) -> Path | None:
    """The newest path_provider_windows package in the pub cache."""
    hosted = pub_cache / "hosted" / "pub.dev"
    if not hosted.is_dir():
        return None
    candidates = sorted(
        (p for p in hosted.iterdir() if p.name.startswith("path_provider_windows-")),
        key=lambda p: p.name,
        reverse=True,
    )
    return candidates[0] if candidates else None


def fix(app: Path) -> int:
    links = app / "windows" / "flutter" / "ephemeral" / ".plugin_symlinks"
    links.mkdir(parents=True, exist_ok=True)
    lp.note(f"== plugin links in {links}")

    # 1) Our own native plugin (has windows/CMakeLists.txt + C++ sources).
    add_junction(links / "lanplayer_video", lp.ROOT / "packages" / "lanplayer_video",
                 "lanplayer_video")

    # 2) path_provider_windows is a Dart-only implementation, but pub get still
    #    links every plugin folder it finds.  It lives in the pinned PUB_CACHE.
    pub_cache = Path(os.environ.get("PUB_CACHE", "")) if os.environ.get("PUB_CACHE") \
        else lp.TOOLS / "pub-cache"
    if not pub_cache.is_dir():
        fallback = Path(os.environ.get("LOCALAPPDATA", "")) / "Pub" / "Cache"
        pub_cache = fallback if fallback.is_dir() else lp.TOOLS / "pub-cache"
    ppw = latest_path_provider(pub_cache, app)
    if ppw:
        add_junction(links / "path_provider_windows", ppw, "path_provider_windows")
    else:
        lp.note("   path_provider_windows   skipped (run `dart pub get` in app/ first)")

    # 3) Anything else already resolved into app/.flutter-plugins-dependencies
    #    that the tool would try to link next time.
    deps = app / ".flutter-plugins-dependencies"
    if deps.exists():
        try:
            data = json.loads(deps.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            data = {}
        for plugin in (data.get("plugins") or {}).get("windows") or []:
            name, directory = plugin.get("name"), plugin.get("path")
            if name and directory:
                add_junction(links / name, directory, name)

    count = len(list(links.iterdir())) if links.is_dir() else 0
    lp.note(f"\n== done: {count} link(s)")
    lp.note("   now: cd app; flutter build windows")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Create the plugin junctions Flutter wants.")
    parser.add_argument("--app", default="", help="app directory (default: <repo>/app)")
    args = parser.parse_args()
    app = Path(args.app) if args.app else lp.ROOT / "app"
    sys.exit(fix(app))


if __name__ == "__main__":
    main()
