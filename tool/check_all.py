#!/usr/bin/env python3
"""Project-wide static checks that do not need a compiler or the Flutter SDK.

Runs on the bundled Python.  Catches the class of mistakes that would otherwise
only surface after `flutter analyze` / a native build:

  1. every relative Dart import resolves to a file
  2. no duplicated top-level Dart declaration (a classic copy/paste bug)
  3. every Dart FFI symbol exists in the native core (delegated to
     check_symbols.py)
  4. the repository has every file the docs promise
  5. the Apple wiring stays consistent (podspec links liblanplayer.a, the two
     Podfiles exist and declare the same deployment targets as
     scripts/build_apple_deps.sh)

Usage:  python tool/check_all.py
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

# The Windows console defaults to a legacy code page that cannot represent
# the marks printed below; force UTF-8 so the report is readable everywhere.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"
LIB = APP / "lib"

problems: list[str] = []
notes: list[str] = []

def check_dart_imports() -> None:
    if not LIB.exists():
        problems.append("app/lib is missing")
        return
    count = 0
    for path in LIB.rglob("*.dart"):
        text = path.read_text(encoding="utf-8")
        for m in re.finditer(r"^\s*(?:import|export)\s+'([^']+)'", text, flags=re.M):
            target = m.group(1)
            if target.startswith(("dart:", "package:")):
                continue
            resolved = (path.parent / target).resolve()
            if not resolved.exists():
                problems.append(f"{path.relative_to(ROOT)}: unresolved import '{target}'")
            count += 1
    notes.append(f"dart imports checked: {count}")

TOP_LEVEL = re.compile(
    r"^(?:Future<[^>]*>|void|String|int|double|bool|Widget|Map<[^>]*>|List<[^>]*>|"
    r"PlayerState|[A-Z][A-Za-z0-9_]*\??)\s+([a-z][A-Za-z0-9_]*)\s*\(",
    re.M,
)

def check_dart_duplicates() -> None:
    seen: dict[str, list[str]] = defaultdict(list)
    for path in LIB.rglob("*.dart"):
        text = path.read_text(encoding="utf-8")
        for m in TOP_LEVEL.finditer(text):
            seen[m.group(1)].append(str(path.relative_to(ROOT)))
    dupes = {name: files for name, files in seen.items() if len(files) > 1}
    for name, files in sorted(dupes.items()):
        # Methods live inside classes and are indented, so a column-0 hit in more
        # than one file is a real duplicate global.
        problems.append(f"duplicate top-level function '{name}': {', '.join(files)}")
    notes.append(f"top-level dart declarations: {len(seen)}")

REQUIRED = [
    "README.md",
    "docs/architecture.md",
    "docs/build.md",
    "docs/media-source.md",
    "docs/roadmap.md",
    "docs/security.md",
    "native/CMakeLists.txt",
    "native/include/lanplayer/lp_player.h",
    "native/include/lanplayer/lp_source.h",
    "native/include/lanplayer/lp_types.h",
    "native/src/core/player.c",
    "native/src/core/demux.c",
    "native/src/core/video.c",
    "native/src/core/audio.c",
    "native/src/core/subtitle.c",
    "native/src/core/queue.c",
    "native/src/core/audio_ring.c",
    "native/src/source/smb.c",
    "native/src/source/file.c",
    "native/src/source/io.c",
    "native/src/platform/android/media_codec_decoder.c",
    "native/src/platform/android/egl_renderer.c",
    "native/src/platform/android/aaudio_sink.c",
    "native/src/platform/android/jni_bridge.c",
    "native/src/platform/apple/videotoolbox_decoder.c",
    "native/src/platform/apple/coreaudio_sink.c",
    "native/src/platform/apple/apple_texture.c",
    "native/src/platform/stub/stub_platform.c",
    "app/pubspec.yaml",
    "app/lib/core/bindings.dart",
    "app/lib/core/player_controller.dart",
    "app/lib/data/stores.dart",
    "app/lib/ui/home_screen.dart",
    "app/lib/ui/browser_screen.dart",
    "app/lib/ui/player_screen.dart",
    "app/android/app/src/main/kotlin/dev/lanplayer/app/MainActivity.kt",
    # A Gradle project needs these to build at all.  They are the stock Flutter
    # 3.27 templates (settings.gradle / build.gradle / gradle.properties /
    # wrapper), plus the res/ tree AndroidManifest.xml references via
    # @mipmap/ic_launcher and @style/LaunchTheme.
    "app/android/settings.gradle",
    "app/android/build.gradle",
    "app/android/gradle.properties",
    "app/android/gradle/wrapper/gradle-wrapper.properties",
    "app/android/app/src/debug/AndroidManifest.xml",
    "app/android/app/src/main/res/values/styles.xml",
    "app/android/app/src/main/res/mipmap-hdpi/ic_launcher.png",
    "app/ios/Runner/AppDelegate.swift",
    "app/ios/Runner/Info.plist",
    "app/windows/CMakeLists.txt",
    "app/windows/runner/main.cpp",
    "app/windows/runner/win32_window.cpp",
    "app/windows/flutter/generated_plugin_registrant.cc",
    "packages/lanplayer_video/pubspec.yaml",
    "packages/lanplayer_video/windows/CMakeLists.txt",
    "packages/lanplayer_video/windows/lanplayer_video_plugin.cpp",
    "packages/lanplayer_video/windows/include/lanplayer_video/lan_player_video_plugin.h",
    "packages/lanplayer_core/pubspec.yaml",
    "packages/lanplayer_core/ios/lanplayer_core.podspec",
    "packages/lanplayer_core/macos/lanplayer_core.podspec",
    "packages/lanplayer_core/ios/Classes/lanplayer_core_anchor.m",
    "packages/lanplayer_core/macos/Classes/lanplayer_core_anchor.m",
    "app/ios/Podfile",
    "app/macos/Podfile",
    "app/macos/Runner/MainFlutterWindow.swift",
    "app/macos/Runner/Runner-Bridging-Header.h",
    "app/macos/Runner/Configs/AppInfo.xcconfig",
    "scripts/build_apple_deps.sh",
    "scripts/gen_windows_runner.ps1",
    "scripts/patch_flutter_tools.ps1",
    "native/tests/lp_win32_texture_test.c",
    "native/tests/lp_hw_decode_test.c",
    "native/tests/lp_hw_probe.c",
    "native/tests/lp_thumb_test.c",
    "native/tests/lp_junk_test.c",
    "native/src/platform/win32/d3d11va_decoder.c",
    "packages/lanplayer_video/windows/include/lanplayer_video/pixel_swizzle.h",
    "app/lib/ui/widgets/subtitle_overlay.dart",
    "app/lib/data/models.dart",
    "app/test/subtitle_overlay_test.dart",
    "app/test/settings_test.dart",
    "scripts/build_windows_app.ps1",
    "scripts/build_windows_desktop.ps1",
    "scripts/build_windows_installer.ps1",
    "scripts/build_macos_dmg.sh",
    "scripts/ios_device_install.sh",
    "scripts/windows/installer.nsi",
    "LICENSE",
    "scripts/fix_plugin_links.ps1",
    "scripts/msvc_chain.bat",
    "scripts/capture_window.ps1",
    "scripts/capture_app.ps1",
    "scripts/capture_screen.ps1",
    "scripts/send_keys.ps1",
    "scripts/capture_playback_ui.ps1",
    "scripts/hover_probe.ps1",
    "scripts/click_window.ps1",
    "scripts/capture_lanscan.ps1",
    "tool/image_stats.ps1",
    "tool/make_pgs_fixture.py",
    "tool/pgs_probe.c",
    "app/lib/data/progress.dart",
    "app/lib/data/lan_scan.dart",
    "app/lib/data/thumbs.dart",
    "app/lib/ui/widgets/thumbnail_tile.dart",
    "app/tool/lan_scan_probe.dart",
    "app/tool/browse_smoke.dart",
    "app/test/lan_scan_test.dart",
    "app/test/server_edit_screen_test.dart",
    "app/test/thumbnail_cache_test.dart",
    "app/test/thumbnail_tile_test.dart",
    "native/src/core/thumb.c",
    "tool/thumb_probe.py",
    "tool/smb_ls_probe.py",
    "tool/win_smb_thumb_probe.py",
    "docs/images/desktop-home.png",
    "docs/images/desktop-player.png",
    "docs/images/desktop-browse.png",
    "docs/images/desktop-smb-play.png",
    "docs/images/desktop-stats.png",
    "docs/images/desktop-color-red.png",
    "docs/images/desktop-d3d11va.png",
    "docs/images/ipad-player.png",
]

def check_texture_colors() -> None:
    """Guard the BGRA->RGBA contract that fixes the "picture is blue" bug.

    The engine always reads a pixel-buffer texture as RGBA8888 while the core
    emits BGRA, so the plugin must swap the channels.  Two static facts are
    enough to catch a regression without a build: the header must actually swap
    R and B, and the plugin must call it from Copy().
    """
    header = ROOT / "packages" / "lanplayer_video" / "windows" / "include" / \
        "lanplayer_video" / "pixel_swizzle.h"
    plugin = ROOT / "packages" / "lanplayer_video" / "windows" / "lanplayer_video_plugin.cpp"
    test = ROOT / "native" / "tests" / "lp_win32_texture_test.c"
    if not header.exists():
        problems.append("pixel_swizzle.h missing (BGRA->RGBA conversion)")
        return
    text = header.read_text(encoding="utf-8")
    if "row[0] = row[2]" not in text or "row[2] = b" not in text:
        problems.append("pixel_swizzle.h no longer swaps R and B")
    if "row[3] = 0xFF" not in text:
        problems.append("pixel_swizzle.h no longer forces opaque alpha")
    if plugin.exists() and "lp_bgra_to_rgba(" not in plugin.read_text(encoding="utf-8"):
        problems.append("plugin does not call lp_bgra_to_rgba() from Copy()")
    if test.exists() and "--expect-red" not in test.read_text(encoding="utf-8"):
        problems.append("texture test lost its --expect-red assertion")

    cap = ROOT / "scripts" / "capture_screen.ps1"
    if cap.exists():
        ctext = cap.read_text(encoding="utf-8")
        # A capture that silently grabs the desktop instead of the app produced
        # an all-white "proof" twice; the colour assertion is what catches it.
        for needle, why in (
            ("-ExpectColor", "capture script lost its expected-colour option"),
            ("Get-ColorMatch", "capture script no longer measures the expected colour"),
            ("exit 3", "capture script no longer fails on invalid evidence"),
        ):
            if needle not in ctext:
                problems.append(why)
        if "$ecR = [int]$parts[0]" not in ctext:
            problems.append("capture script assigns the colour array back to the [string] "
                            "parameter (PowerShell coerces it, comparisons silently fail)")

    media = ROOT / "scripts" / "make_test_media.ps1"
    if media.exists() and "duration=60" not in media.read_text(encoding="utf-8"):
        problems.append("colour probe clip is short again; capturing it becomes a race "
                        "against playback ending (see docs/verification.md 3.14)")
    notes.append("texture colour order: R<->B swapped once, alpha forced opaque")

def check_required_files() -> None:
    for rel in REQUIRED:
        if not (ROOT / rel).exists():
            problems.append(f"missing required file: {rel}")
    notes.append(f"required files: {len(REQUIRED)}")

def check_lan_scan() -> None:
    """Guard the LAN discovery contract.

    Two things must stay true or the feature silently degrades:
      * it probes TCP 445 (the only port that tells us "SMB lives here");
      * the UI offers it as an optional button and does not pretend to know
        the share name (share enumeration was deliberately dropped).
    Bounding the concurrency matters too: a naive 254-way connect at once is
    what makes the scan fast, but removing the cap would open a socket per
    address on every interface and can trip the OS.
    """
    scan = ROOT / "app" / "lib" / "data" / "lan_scan.dart"
    ui = ROOT / "app" / "lib" / "ui" / "server_edit_screen.dart"
    if not scan.exists():
        problems.append("missing app/lib/data/lan_scan.dart (LAN discovery)")
        return
    code = scan.read_text(encoding="utf-8")
    body = "\n".join(l for l in code.splitlines()
                     if not l.strip().startswith("//"))
    if "445" not in body:
        problems.append("lan_scan.dart must probe TCP 445, not another port")
    if "Socket.connect" not in body:
        problems.append("lan_scan.dart must use Socket.connect for the probe")
    if "169.254" not in body:
        problems.append("lan_scan.dart must skip 169.254.0.0/16 link-local "
                        "(virtual adapters report those and would be scanned)")
    m = re.search(r"int\s+concurrency\s*=\s*(\d+)", body)
    if not m:
        problems.append("lan_scan.dart must cap concurrency "
                        "(scanSubnet(concurrency: N))")
    elif not (8 <= int(m.group(1)) <= 512):
        problems.append(f"scanSubnet concurrency = {m.group(1)} is "
                        "unreasonable (8..512)")
    if "shouldStop" not in body:
        problems.append("scanSubnet must accept shouldStop so a page can "
                        "abort a scan it no longer needs")

    if not ui.exists():
        problems.append("missing app/lib/ui/server_edit_screen.dart")
        return
    ui_code = "\n".join(l for l in ui.read_text(encoding="utf-8").splitlines()
                        if not l.strip().startswith("//"))
    if "扫描局域网" not in ui_code:
        problems.append("the add-server screen lost its 扫描局域网 button")
    if "LanHostPicker" not in ui_code:
        problems.append("the add-server screen must render LanHostPicker")
    # The page must not open the native core while building: a missing
    # lanplayer.dll used to make the whole screen unrenderable.
    eager = [l for l in ui_code.splitlines()
             if re.search(r"\bfinal\b", l) and re.search(r"\b_repo\s*=", l)
             and "late" not in l]
    if eager:
        problems.append("ServerEditScreen must lazily create MediaRepository "
                        "(late final), otherwise a missing lanplayer.dll "
                        f"breaks the whole page: {eager[0].strip()}")
    notes.append("lan scan: probes TCP 445 with capped concurrency, "
                 "optional UI step, share name still user-supplied")


def check_thumbnails() -> None:
    """Guard the cover-art contract.

    Three failure modes are cheap to reintroduce and expensive to notice,
    because the UI just shows a placeholder icon and the log stays quiet:
      * the cache file layout and the reader drift apart (a v1 file wrote only
        the width, so every read threw and covers never appeared);
      * the key stops being a plain hex name, producing unwritable filenames;
      * the list renders covers for audio files too, paying a network round
        trip for a frame nobody wants.
    """
    thumbs = ROOT / "app" / "lib" / "data" / "thumbs.dart"
    tile = ROOT / "app" / "lib" / "ui" / "widgets" / "thumbnail_tile.dart"
    browser = ROOT / "app" / "lib" / "ui" / "browser_screen.dart"
    for path, what in ((thumbs, "cover cache"), (tile, "cover tile"),
                       (browser, "browser list")):
        if not path.exists():
            problems.append(f"missing {path.relative_to(ROOT).as_posix()} ({what})")
            return

    code = "\n".join(l for l in thumbs.read_text(encoding="utf-8").splitlines()
                     if not l.strip().startswith("//"))
    # The header must carry both dimensions: 4 magic + 4 width + 4 height.
    if "0x4C, 0x50, 0x54, 0x32" not in code:
        problems.append("thumbs.dart magic must be LPT2 (LPT1 wrote no height "
                        "and every read threw RangeError)")
    if "12 + w * h * 4" not in code:
        problems.append("thumbs.dart must validate the 12-byte header against "
                        "the pixel payload length")
    if "bytes.length < 12" not in code:
        problems.append("decodeThumb must reject short bytes before "
                        "ByteData.sublistView (otherwise RangeError escapes)")
    if "toUnsigned(64)" in code or "toRadixString(16).padLeft(16" in code:
        problems.append("keyFor must not rely on a signed 64-bit toRadixString "
                        "(negative hashes produce a leading '-' in the filename)")
    if "hi.toRadixString(16)" not in code:
        problems.append("keyFor must split the hash into two 32-bit halves so "
                        "the cache name is always plain hex")

    tile_code = "\n".join(l for l in tile.read_text(encoding="utf-8").splitlines()
                          if not l.strip().startswith("//"))
    if "didUpdateWidget" not in tile_code:
        problems.append("ThumbnailTile must refetch in didUpdateWidget, "
                        "otherwise list recycling shows the previous cover")
    if "dispose()" in tile_code and "_image?.dispose" in tile_code:
        problems.append("ThumbnailTile must not dispose the ui.Image: the "
                        "cache owns it and would hand out a dead handle")

    browser_code = "\n".join(
        l for l in browser.read_text(encoding="utf-8").splitlines()
        if not l.strip().startswith("//"))
    if "e.isVideo" not in browser_code:
        problems.append("the browser list must only request covers for videos")

    # Regression guards for the "opening a folder full of .flv hangs" bug.
    # Each of these was a real defect (see docs/verification.md 3.28):
    #   * lp_io_read spinning at the cache boundary,
    #   * avio_read_cb handing 0 back to FFmpeg instead of AVERROR_EOF,
    #   * av_seek_frame given microseconds instead of stream ticks,
    #   * one Isolate.run per list row hammering the NAS.
    io_c = ROOT / "native" / "src" / "source" / "io.c"
    thumb_c = ROOT / "native" / "src" / "core" / "thumb.c"
    if not io_c.exists() or not thumb_c.exists():
        problems.append("missing source/source io.c or core/thumb.c")
    else:
        io_code = io_c.read_text(encoding="utf-8")
        if "if (r == 0) {\n        return AVERROR_EOF;\n    }" not in io_code:
            problems.append("avio_read_cb must map a 0-byte read to "
                            "AVERROR_EOF, otherwise the demuxer retries forever")
        if "chunk <= 0" not in io_code:
            problems.append("lp_io_read must handle chunk <= 0 at the cache "
                            "boundary, otherwise it spins without progress")

        thumb_code = thumb_c.read_text(encoding="utf-8")
        if "av_rescale_q(target_us" not in thumb_code:
            problems.append("thumb seek must rescale microseconds into the "
                            "stream time base (a raw use seeks to EOF)")
        if "LP_THUMB_BUDGET_MS" not in thumb_code:
            problems.append("thumb must carry a wall-clock budget so a slow "
                            "container cannot hang the caller forever")

    if "maxConcurrent" not in code or "ConcurrencyGate" not in code:
        problems.append("thumbs.dart must throttle cover decoding; without a "
                        "gate every visible row decodes concurrently")
    if "_seq" not in tile_code:
        problems.append("ThumbnailTile must guard against stale results after "
                        "the row is recycled")

    # OS metadata must never be listed. Both transports have to apply the same
    # filter, otherwise .DS_Store shows up over SMB but not locally (or worse,
    # users conclude the app is writing to their server - it never does:
    # smb.c only opens with O_RDONLY).
    smb_c = ROOT / "native" / "src" / "source" / "smb.c"
    file_c = ROOT / "native" / "src" / "source" / "file.c"
    url_c = ROOT / "native" / "src" / "source" / "url.c"
    for path in (smb_c, file_c, url_c):
        if not path.exists():
            problems.append(f"missing {path.relative_to(ROOT).as_posix()}")
    if smb_c.exists() and "lp_is_os_junk_name" not in smb_c.read_text(encoding="utf-8"):
        problems.append("smb listing must skip .DS_Store / ._* / desktop.ini")
    if file_c.exists() and "lp_is_os_junk_name" not in file_c.read_text(encoding="utf-8"):
        problems.append("local listing must skip .DS_Store / ._* / desktop.ini")
    if url_c.exists():
        url_code = url_c.read_text(encoding="utf-8")
        if "lp_is_os_junk_name" not in url_code:
            problems.append("lp_is_os_junk_name must live in url.c")
        if "lp_is_listable_media" not in url_code:
            problems.append("lp_is_listable_media must live in url.c")
        if "O_RDWR" in (smb_c.read_text(encoding="utf-8") if smb_c.exists() else ""):
            problems.append("smb.c must never open a share read-write")

    # The browser must show media only: .txt/.docx used to be listed as
    # unplayable rows. Both transports filter files (directories must survive),
    # and the Flutter side keeps a second guard plus subtitle grouping.
    for path, label in ((smb_c, "SMB"), (file_c, "local")):
        if path.exists() and "lp_is_listable_media" not in path.read_text(encoding="utf-8"):
            problems.append(f"{label} listing must keep only video/subtitle/audio "
                            f"(lp_is_listable_media)")
    models = ROOT / "app" / "lib" / "data" / "models.dart"
    browser = ROOT / "app" / "lib" / "ui" / "browser_screen.dart"
    if models.exists():
        mc = models.read_text(encoding="utf-8")
        if "browsable" not in mc:
            problems.append("DirectoryListing.browsable missing; the browser "
                            "would fall back to listing every file")
        if "subtitlesFor" not in mc:
            problems.append("DirectoryListing.subtitlesFor missing; sidecar "
                            "subtitles would not be linked to their video")
    else:
        problems.append("app/lib/data/models.dart missing")
    if browser.exists():
        bc = browser.read_text(encoding="utf-8")
        if "_listing.browsable" not in bc:
            problems.append("browser_screen must iterate browsable, not entries")
        if "subtitlesFor" not in bc:
            problems.append("browser_screen must group subtitles per video")

    notes.append("thumbnails: LPT2 header round-trips, hex cache key, "
                 "covers only for video rows, decoding is throttled and "
                 "cannot spin or seek past the end")
    notes.append("browser: only video/subtitle/audio rows, subtitles grouped "
                 "under their own video")
    notes.append("source: listing hides OS metadata (.DS_Store/._*/desktop.ini), "
                 "SMB transport is read-only")

def check_installers() -> None:
    """Guard the two release installers.

    Both were written once and then only lightly touched, so the cheap checks
    are about the invariants that would silently produce a broken package:
      * the NSIS script needs a BOM (makensis refuses UTF-8 without one) and
        must stay a per-user install, because a machine-wide one needs UAC and
        would write into Program Files;
      * the staging list in the PowerShell driver and the File list in the .nsi
        must agree, otherwise the package is missing a DLL at runtime;
      * the dmg script must use ditto (cp -R drops the code signature) and must
        not build a lower-case alias next to LanPlayer.app (APFS is
        case-insensitive, so the cleanup would delete the app it just copied).
    """
    nsi = ROOT / "scripts" / "windows" / "installer.nsi"
    ps1 = ROOT / "scripts" / "build_windows_installer.ps1"
    sh = ROOT / "scripts" / "build_macos_dmg.sh"
    for path, what in ((nsi, "NSIS script"), (ps1, "Windows installer driver"),
                       (sh, "macOS dmg script")):
        if not path.exists():
            problems.append(f"missing {path.relative_to(ROOT).as_posix()} ({what})")
            return

    raw = nsi.read_bytes()
    if not raw.startswith(b"\xef\xbb\xbf"):
        problems.append("scripts/windows/installer.nsi must be UTF-8 with BOM, "
                        "otherwise makensis fails with 'Bad text encoding'")
    nsi_text = raw.decode("utf-8-sig")
    nsi_code = "\n".join(l for l in nsi_text.splitlines()
                         if not l.strip().startswith(";"))
    if "RequestExecutionLevel user" not in nsi_code:
        problems.append("installer.nsi must keep RequestExecutionLevel user "
                        "(a machine-wide install would need UAC)")
    if "$LOCALAPPDATA\\Programs\\" not in nsi_code:
        problems.append("installer.nsi must install under "
                        "$LOCALAPPDATA\\Programs\\, not Program Files")
    if "ifndef APP_ICON" not in nsi_code:
        problems.append("installer.nsi lost its APP_ICON default")
    for macro in ("APP_VERSION", "STAGE", "OUTFILE", "APP_ICON"):
        if "/D" + macro + "=" not in ps1.read_text(encoding="utf-8"):
            problems.append(f"build_windows_installer.ps1 does not pass /D{macro} "
                            "to makensis")

    # Every staged runtime file must also be packaged; a drift here ships a
    # package that throws on startup when it cannot find a DLL.
    driver = ps1.read_text(encoding="utf-8")
    staged = re.findall(r"^\s*'([\w.-]+\.dll|[\w.-]+\.exe)',?\s*$", driver, re.M)
    for name in staged:
        if f'"{name}"' not in nsi_code and f"\\{name}" not in nsi_code:
            problems.append(f"installer.nsi does not package {name} "
                            "although the driver stages it")

    dmg = sh.read_text(encoding="utf-8")
    body = "\n".join(l for l in dmg.splitlines()
                     if not l.strip().startswith("#"))
    if "ditto" not in body:
        problems.append("build_macos_dmg.sh must copy the app with ditto "
                        "(cp -R drops extended attributes and the signature)")
    if "cp -R" in body:
        problems.append("build_macos_dmg.sh must not use cp -R for the .app")
    if "hdiutil create" not in body or "UDZO" not in body:
        problems.append("build_macos_dmg.sh must create a compressed (UDZO) dmg")
    if "codesign --verify" not in body:
        problems.append("build_macos_dmg.sh must verify the signature before "
                        "packing")

    # The iOS device installer is the only path that runs on a real iPad.
    # Guard the two things that make it work: an explicit team id (Xcode
    # refuses to sign without one) and devicectl (flutter install needs the
    # legacy MobileDevice stack, which Xcode 27 dropped for devices).
    dev = ROOT / "scripts" / "ios_device_install.sh"
    if not dev.exists():
        problems.append("missing scripts/ios_device_install.sh")
    else:
        dev_body = "\n".join(l for l in dev.read_text(encoding="utf-8").splitlines()
                             if not l.strip().startswith("#"))
        if "DEVELOPMENT_TEAM" not in dev_body:
            problems.append("ios_device_install.sh must write DEVELOPMENT_TEAM "
                            "into the Xcode project")
        if "devicectl device install app" not in dev_body:
            problems.append("ios_device_install.sh must install with "
                            "'devicectl device install app'")
        if "flutter build ios" not in dev_body:
            problems.append("ios_device_install.sh must build with "
                            "'flutter build ios'")

    notes.append("installers: NSIS per-user with BOM + matching file list, "
                 "dmg uses ditto + UDZO")
    notes.append("iOS device: team id injected, devicectl install")

def run(cmd: list[str], env: dict[str, str] | None = None,
        cwd: Path | None = None) -> tuple[int, str]:
    proc = subprocess.run(cmd, cwd=cwd or ROOT, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", env=env)
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")

def dart_env() -> dict[str, str]:
    """The Dart CLI wants a writable config dir; keep it inside .tools/."""
    env = dict(os.environ)
    cfg = ROOT / ".tools" / "dart-cfg"
    cfg.mkdir(parents=True, exist_ok=True)
    env["APPDATA"] = str(cfg)
    env["LOCALAPPDATA"] = str(cfg)
    env["PUB_CACHE"] = str(ROOT / ".tools" / "pub-cache")
    # `dart format` and the engine frontend server both write temp files; the
    # sandbox denies the default %LOCALAPPDATA%\Temp location.
    tmp = ROOT / ".tools" / "tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    env["TMP"] = str(tmp)
    env["TEMP"] = str(tmp)
    return env

def check_native_runtime() -> None:
    """Runs the compiled smoke test when scripts/build_windows.ps1 has run."""
    out_dir = ROOT / "build" / "win-x64"
    exe = out_dir / "lp_smoke_test.exe"
    if not exe.exists():
        notes.append("native runtime: not built (scripts/build_windows.ps1)")
        return
    env = dict(os.environ)
    env["PATH"] = str(out_dir) + os.pathsep + env.get("PATH", "")
    code, out = run([str(exe)], env=env)
    if code != 0 or "smoke test passed" not in out:
        problems.append("native smoke test failed:\n" + out.strip()[-1500:])
    else:
        notes.append("native runtime: ABI + schemes OK")

def check_hw_decode() -> None:
    """Runs the D3D11VA end-to-end test when the native build exists.

    A software fallback still decodes a perfect picture, so a picture alone
    cannot prove the hardware path works: the test asserts the reported decoder
    name, the colour order and the match against a software reference run.
    """
    out_dir = ROOT / "build" / "win-x64"
    exe = out_dir / "lp_hw_decode_test.exe"
    red = ROOT / "build" / "media" / "colortest" / "red.mp4"
    if not exe.exists():
        notes.append("hw decode: not built (scripts/build_windows.ps1)")
        return
    if not red.exists():
        notes.append("hw decode: skipped (no colour probe clip; make_test_media.ps1)")
        return
    env = dict(os.environ)
    env["PATH"] = str(out_dir) + os.pathsep + env.get("PATH", "")
    code, out = run([str(exe), str(red), "--expect-red"], env=env, cwd=str(out_dir))
    if code == 3 or "no hardware device" in out:
        # A runner/VM without a GPU has no D3D11 device at all: the core says so
        # on stderr and falls back to software.  That is not a code problem, so
        # do not fail the suite here - but say it out loud, because "software" in
        # a job that is supposed to exercise d3d11va is otherwise misleading.
        notes.append("hw decode: no D3D11 device here, software path only")
        return
    if code != 0 or "hw decode OK" not in out:
        problems.append("hw decode failed:\n" + out.strip()[-1500:])
        return
    mid = [ln for ln in out.splitlines() if ln.startswith("mid_pixel=")]
    notes.append("hw decode: d3d11va matches software reference, " +
                 (mid[-1] if mid else "no pixel"))

def dart_exe() -> Path | None:
    """Prefer the standalone SDK, fall back to the one bundled with Flutter.

    `.tools/dart` is an optional download: the Flutter SDK ships its own Dart and
    that copy formats identically, so a project kept lean with only Flutter must
    still pass the Dart checks.
    """
    for candidate in (ROOT / ".tools" / "dart" / "bin" / "dart.exe",
                      ROOT / ".tools" / "flutter-sdk" / "bin" / "cache" /
                      "dart-sdk" / "bin" / "dart.exe"):
        if candidate.exists():
            return candidate
    return None

def check_dart_syntax() -> None:
    dart = dart_exe()
    if dart is None:
        notes.append("dart syntax: no Dart SDK (tool/fetch_deps.py dart)")
        return
    code, out = run([str(dart), "format", "--output=none",
                     str(APP / "lib"), str(APP / "test"), str(APP / "tool")],
                    env=dart_env())
    if code != 0 or "Could not format" in out:
        problems.append("dart parse failed:\n" + out.strip()[-1500:])
    else:
        last = [ln for ln in out.strip().splitlines() if ln.startswith("Formatted")]
        notes.append("dart syntax: " + (last[-1] if last else "ok"))

def check_dart_compile() -> None:
    """Compile lib/main.dart to kernel with the engine's frontend server.

    This is the closest thing to `dart analyze` that works without the flutter
    tool: it resolves every import and reports real type errors.
    """
    fs = ROOT / ".tools" / "flutter-sdk"
    dart_sdk = fs / "bin" / "cache" / "dart-sdk"
    frontend = dart_sdk / "bin" / "snapshots" / "frontend_server_aot.dart.snapshot"
    runtime = dart_sdk / "bin" / "dartaotruntime.exe"
    patched = fs / "bin" / "cache" / "artifacts" / "engine" / "common" / "flutter_patched_sdk"
    cfg = APP / ".dart_tool" / "package_config.json"
    if not (runtime.exists() and frontend.exists() and patched.exists() and cfg.exists()):
        notes.append("dart compile: skipped (needs flutter sdk + dart pub get)")
        return
    out_dir = ROOT / "build" / "dart-check"
    out_dir.mkdir(parents=True, exist_ok=True)
    dill = out_dir / "app.dill"
    code, out = run([str(runtime), str(frontend), "--sdk-root", str(patched),
                     "--target=flutter", "--packages", str(cfg),
                     "--output-dill", str(dill), str(APP / "lib" / "main.dart")],
                    env=dart_env())
    errors = [ln.strip() for ln in out.splitlines() if ": Error:" in ln]
    if code != 0 or errors:
        problems.append("dart compile failed (%d error(s)):\n%s"
                        % (len(errors), "\n".join(errors[:15])))
    else:
        notes.append("dart compile: kernel ok (%.1f MB)" % (dill.stat().st_size / 1e6))

def check_windows_plugin() -> None:
    """The desktop plugin resolves lp_* at runtime; names must exist in headers."""
    plugin = ROOT / "packages" / "lanplayer_video" / "windows" / "lanplayer_video_plugin.cpp"
    if not plugin.exists():
        problems.append("windows plugin missing")
        return
    headers = list((ROOT / "native" / "include").rglob("*.h")) + [
        ROOT / "native" / "src" / "platform" / "win32" / "win32_preview.h"]
    declared: set[str] = set()
    for header in headers:
        declared |= set(re.findall(r"\b(lp_[a-z0-9_]+)\s*\(", header.read_text(encoding="utf-8")))
    text = plugin.read_text(encoding="utf-8")
    used = set(re.findall(r'GetProcAddress\([^,]+,\s*"(lp_[a-z0-9_]+)"\)', text))
    used |= set(re.findall(r'get\("(lp_[a-z0-9_]+)"\)', text))
    for name in sorted(used):
        if name not in declared:
            problems.append(f"windows plugin resolves unknown symbol: {name}")
    notes.append(f"windows plugin: {len(used)} lp_* symbols, all declared")

def check_c_syntax() -> None:
    code, out = run([sys.executable, str(ROOT / "tool" / "check_c_syntax.py")])
    if code != 0:
        problems.append("check_c_syntax.py failed:\n" + out.strip())
    else:
        notes.append(out.strip().splitlines()[-1])

def check_symbols() -> None:
    code, out = run([sys.executable, str(ROOT / "tool" / "check_symbols.py")])
    if code != 0:
        problems.append("check_symbols.py failed:\n" + out.strip())
    else:
        notes.append(out.strip().splitlines()[-1])

def check_dart_tests() -> None:
    """Run the Dart test suite (share key + subtitle rendering).

    The Flutter SDK is required; without it the suite is skipped so the static
    checks still work on a machine that only has the native toolchain.
    """
    flutter = ROOT / ".tools" / "flutter-sdk" / "bin" / "flutter.bat"
    if not flutter.exists():
        notes.append("dart tests: skipped (needs .tools/flutter-sdk)")
        return
    env = dart_env()
    env["HOME"] = str(ROOT / ".tools" / "home")
    env["TMP"] = str(ROOT / ".tools" / "tmp")
    env["TEMP"] = str(ROOT / ".tools" / "tmp")
    env["FLUTTER_ROOT"] = str(ROOT / ".tools" / "flutter-sdk")
    code, out = run([str(flutter), "--no-version-check", "test"], env=env, cwd=APP)
    if code != 0:
        problems.append("dart tests failed:\n" + out.strip()[-2000:])
    else:
        last = [ln for ln in out.strip().splitlines() if "All tests passed" in ln]
        notes.append("dart tests: " + (last[-1].strip() if last else "ok"))

def check_player_layout() -> None:
    """Guard the two layout bugs the user reported on the player page.

    1. The back button sat at the vertical centre of the left edge.  The cause was
       not the Align: the Column inside _topBar()'s Row defaulted to
       mainAxisSize.max, so it claimed the full screen height and the Row's
       crossAxisAlignment centred the button.  Dropping that parameter silently
       reintroduces the bug, and no screenshot can catch it reliably here.
    2. The picture controls lived behind a "more" button in the top-right corner.
       They belong in the bottom transport row next to speed/subtitle/audio.
    """
    screen = ROOT / "app" / "lib" / "ui" / "player_screen.dart"
    if not screen.exists():
        problems.append("player_screen.dart missing")
        return
    text = screen.read_text(encoding="utf-8")

    # mainAxisSize.min must appear inside _topBar().  Slice from the method header
    # to the next top-level method so an unrelated Column cannot satisfy the check.
    start = text.find("Widget _topBar()")
    if start < 0:
        problems.append("player_screen.dart: _topBar() not found")
        return
    end = text.find("Widget _bottomBar(", start)
    top = text[start:end if end > 0 else start + 4000]
    if "mainAxisSize: MainAxisSize.min" not in top:
        problems.append("_topBar() lost mainAxisSize.min; the back button will "
                        "return to the vertical centre (see docs/verification.md)")
    if "_backKey" not in top:
        problems.append("_topBar() lost the _backKey hook used by the layout probe")

    bottom_start = text.find("Widget _bottomBar(")
    bottom = text[bottom_start:] if bottom_start > 0 else ""
    if "_pictureKey" not in bottom or "_openPictureSheet" not in bottom:
        problems.append("the picture controls are no longer in the bottom transport row")
    if "Icons.more_vert" in text:
        problems.append("the top-right 'more' button is back; picture controls should "
                        "live in the bottom row")

    # Volume must be adjustable, not just mute (user report: "音量设置按钮只能
    # 设置是否静音，不能调节音量大小"). Guard both layers: the transport row has to
    # open the volume sheet, and that sheet has to carry a real slider.
    if "_openVolumeSheet" not in bottom:
        problems.append("the volume button no longer opens the volume sheet; "
                        "toggling mute alone cannot change the level")
    if "_volumeKey" not in bottom:
        problems.append("the volume button lost its layout-probe key")
    sheet = ROOT / "app" / "lib" / "ui" / "widgets" / "volume_sheet.dart"
    if not sheet.exists():
        problems.append("widgets/volume_sheet.dart missing")
    else:
        sc = sheet.read_text(encoding="utf-8")
        if "Slider(" not in sc:
            problems.append("VolumeSheet must have a Slider; mute alone is not "
                            "enough to set the volume")
        if "maxVolume = 2.0" not in sc:
            problems.append("VolumeSheet.maxVolume must stay 2.0 (the core gain "
                            "range); clamping it to 1.0 loses the boost range")
        if "divisions" not in sc:
            problems.append("VolumeSheet slider must stay discrete so a drag "
                            "lands on a stable 5% step")

    notes.append("player layout: back button pinned top-left, picture controls in the "
                 "bottom row")


def _ver_tuple(text: str) -> tuple[int, ...]:
    """Turn "12.0" / "10.14" into a comparable tuple.

    Deployment targets are dotted numbers; comparing them as strings puts
    "10.14" above "9.0" but below "12.0" only by accident. Tuples compare
    element-wise, which is what Xcode does.
    """
    return tuple(int(part) for part in text.split(".") if part.isdigit())


# Every LP_EXPORT function in the public headers. The Apple podspecs must list
# all of them with -Wl,-u,_<name>: Dart reaches the core through dlsym, which
# ld cannot see, and Runner's pbxproj hard-codes DEAD_CODE_STRIPPING=YES at
# target level (a podspec xcconfig cannot override it), so anything not
# explicitly referenced gets stripped out of the release binary.
_LP_EXPORT_RE = re.compile(r"LP_EXPORT\b[^;()]*?\b(lp_[a-z0-9_]+)\s*\(")


def _lp_exported_symbols() -> set[str]:
    names: set[str] = set()
    for header in sorted((ROOT / "native" / "include" / "lanplayer").glob("*.h")):
        names.update(_LP_EXPORT_RE.findall(header.read_text(encoding="utf-8")))
    return names


def _lp_exported_in_spec(code: str) -> set[str]:
    """Read the LP_EXPORTED_SYMBOLS = %w[...] list out of a podspec."""
    match = re.search(r"LP_EXPORTED_SYMBOLS\s*=\s*%w\[(.*?)\]", code, re.S)
    if not match:
        return set()
    return {tok for tok in match.group(1).split() if tok.startswith("lp_")}


def check_apple_wiring() -> None:
    """Guard the iOS / macOS wiring.

    Apple builds cannot be run on this machine at all (no Xcode, no macOS), so
    the only protection against a silently-broken desktop chain is static: the
    podspecs must still link liblanplayer.a, the Podfiles must exist, and the
    deployment targets must match what scripts/build_apple_deps.sh produces.
    A mismatch there does not fail pod install — it fails the link minutes
    later with "building for iOS 13.0, but linking in object file built for
    iOS 14.0", which is exactly the sort of thing nobody can debug on Windows.
    """
    core = ROOT / "packages" / "lanplayer_core"
    for name in ("ios", "macos"):
        spec = core / name / "lanplayer_core.podspec"
        if not spec.exists():
            problems.append(f"missing {spec.relative_to(ROOT)}")
            continue
        text = spec.read_text(encoding="utf-8")
        for needle, why in (
            ("third_party", "the podspec no longer points at native/third_party"),
            ("OTHER_LDFLAGS", "the podspec no longer passes link flags to Runner"),
            ("liblanplayer.a", "the podspec no longer references the C core archive"),
        ):
            if needle not in text:
                problems.append(f"{spec.relative_to(ROOT)}: {why}")
        # The C archive must enter the link unconditionally. Dart reaches the
        # core through DynamicLibrary.process() + dlsym, which the static linker
        # cannot see, so with a plain -llanplayer it keeps only the object files
        # some Swift code literally calls and drops the rest; the app then dies
        # at runtime with "Failed to lookup symbol 'lp_player_create'".
        #
        # Only code lines count: the comment above the flag explains the whole
        # story and therefore contains both "-force_load" and "-llanplayer".
        code_lines = [ln for ln in text.splitlines()
                      if not ln.strip().startswith("#")]
        code = "\n".join(code_lines)
        if "force_load" not in code:
            problems.append(f"{spec.relative_to(ROOT)}: the podspec must link "
                            f"liblanplayer.a with -force_load (plain -llanplayer "
                            f"lets ld drop the dlsym-only symbols)")
        # -force_load alone is not enough. The archive does get pulled in whole,
        # but ld's dead-strip pass still deletes every function nothing refers
        # to statically, and Swift only calls two of the forty lp_* functions.
        # Measured on macOS 27 / Xcode 27.1 / ld 1115.7.2: with force_load but
        # DEAD_CODE_STRIPPING=YES (which Runner's pbxproj hard-codes at target
        # level, so a podspec xcconfig cannot override it) the binary still
        # exported exactly 2 T _lp_ symbols and the app died on lp_player_create.
        # The fix is to mark each export as an external reference with -u.
        # The podspec builds those flags from LP_EXPORTED_SYMBOLS, so the check
        # is on the list plus the flag construction, not on 39 literal flags.
        if "-Wl,-u,_" not in code:
            problems.append(f"{spec.relative_to(ROOT)}: -force_load needs "
                            f"-Wl,-u,_<symbol> for each export as well, otherwise "
                            f"ld dead-strips the dlsym-only lp_* symbols")
        # The list must match the headers exactly: a function added to
        # native/include/lanplayer/*.h but forgotten here works in debug builds
        # and dies in release (dead-strip only bites at -O/-release).
        listed = _lp_exported_in_spec(code)
        if not listed:
            problems.append(f"{spec.relative_to(ROOT)}: LP_EXPORTED_SYMBOLS is empty "
                            f"or unparsable; the -u list cannot be built")
        else:
            header_symbols = _lp_exported_symbols()
            for missing in sorted(header_symbols - listed):
                problems.append(f"{spec.relative_to(ROOT)}: LP_EXPORTED_SYMBOLS is "
                                f"missing {missing} (declared LP_EXPORT, will be "
                                f"dead-stripped out of the release binary)")
            for extra in sorted(listed - header_symbols):
                problems.append(f"{spec.relative_to(ROOT)}: LP_EXPORTED_SYMBOLS lists "
                                f"{extra}, which no header declares LP_EXPORT for")
        # ... and it must be force-loading our archive, not the whole FFmpeg.
        for flag_line in code_lines:
            if "force_load" in flag_line and "liblanplayer.a" not in flag_line:
                problems.append(f"{spec.relative_to(ROOT)}: -force_load must target "
                                f"liblanplayer.a only (FFmpeg/libsmb2 stay lazy)")
            if "'-llanplayer'" in flag_line:
                problems.append(f"{spec.relative_to(ROOT)}: -llanplayer is back; it "
                                f"lets ld drop the dlsym-only lp_* symbols")
        # Each platform family must search its own archive directory.  When all
        # three families share native/third_party/*/apple/lib, whichever script
        # run happened last wins, and the next build of another family dies with
        #   ld: building for 'macOS', but linking in object file
        #       (…/lanplayer/apple/lib/liblanplayer.a[2](lp_str.o))
        #       built for 'iOS-simulator'
        # which looks like a corrupted toolchain rather than a stale artifact.
        # The podspecs therefore key the directory off $(PLATFORM_NAME) and keep
        # the flat path only as a fallback.
        if "PLATFORM_NAME" not in code:
            problems.append(f"{spec.relative_to(ROOT)}: LIBRARY_SEARCH_PATHS must "
                            f"key the archive directory off $(PLATFORM_NAME) so the "
                            f"macOS/iOS-device/iOS-simulator archives can coexist")
        if "_FLAT" not in code:
            problems.append(f"{spec.relative_to(ROOT)}: keep the flat apple/lib "
                            f"path as a fallback (_FLAT) for checkouts that only "
                            f"ever ran one family's build")
        # The pod must not try to compile native/ itself: Flutter symlinks this
        # package into ephemeral/.symlinks/plugins, and globbing sources across a
        # symlink is what we avoided on purpose.
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("s.source_files") and "native" in stripped:
                problems.append(f"{spec.relative_to(ROOT)}: source_files must not "
                                f"compile native/ (the core is a prebuilt archive)")
            # CocoaPods 1.16+ eval()s the podspec inside `module Pod`, so a
            # top-level `def lanplayer_repo_root` becomes an instance method of
            # Pod and the call fails with:
            #   undefined method 'lanplayer_repo_root' for module Pod
            # (hit for real on CocoaPods 1.17 + Ruby 4.0). Keep the root lookup
            # method-free and marker-driven instead.
            if stripped.startswith("def "):
                problems.append(f"{spec.relative_to(ROOT)}: top-level `{stripped}` is "
                                f"evaluated inside `module Pod`, so it cannot be called "
                                f"from the podspec body (use a begin/end expression)")
        if "File.exist?" not in text:
            problems.append(f"{spec.relative_to(ROOT)}: the repo root lookup no longer "
                            f"walks up to a marker file, so it breaks when Flutter "
                            f"symlinks the package into ephemeral/.symlinks/plugins")
        # It is very tempting to declare the prebuilt archive with preserve_paths,
        # but CocoaPods validates every pattern against the pod root and refuses
        # absolute ones, so `pod install` dies before the build even starts:
        #   ERROR | File Patterns: File patterns must be relative and cannot
        #   start with a slash (preserve_paths).
        # (hit for real on CocoaPods 1.17). Nothing needs preserving anyway: the
        # headers and .a live outside the pod directory, where CocoaPods never
        # deletes anything. Linking goes through user_target_xcconfig instead.
        if re.search(r'^\s*s\.preserve_paths', text, re.MULTILINE):
            problems.append(f"{spec.relative_to(ROOT)}: preserve_paths must stay removed "
                            f"(CocoaPods rejects absolute patterns); rely on "
                            f"LIBRARY_SEARCH_PATHS / HEADER_SEARCH_PATHS instead")

    # Deployment targets must agree with build_apple_deps.sh, otherwise the
    # static archives are newer than the app and the link fails.
    # The script uses shell default-expansion: MIN_IOS="${MIN_IOS:-13.0}", so
    # pull the fallback out of that form rather than the raw right-hand side.
    script = ROOT / "scripts" / "build_apple_deps.sh"
    min_ios = min_macos = None
    if script.exists():
        for line in script.read_text(encoding="utf-8").splitlines():
            m = re.match(r'\s*(MIN_IOS|MIN_MACOS)="?\$\{\w+:-([0-9.]+)\}"?', line)
            if not m:
                m = re.match(r'\s*(MIN_IOS|MIN_MACOS)="?([0-9.]+)"?', line)
            if not m:
                continue
            if m.group(1) == "MIN_IOS":
                min_ios = m.group(2)
            else:
                min_macos = m.group(2)

    ios_podfile = APP / "ios" / "Podfile"
    macos_podfile = APP / "macos" / "Podfile"
    if not ios_podfile.exists():
        problems.append("app/ios/Podfile missing; flutter build ios refuses to run")
    elif min_ios and f"platform :ios, '{min_ios}'" not in ios_podfile.read_text(encoding="utf-8"):
        problems.append(f"app/ios/Podfile does not declare platform :ios, '{min_ios}' "
                        f"(build_apple_deps.sh builds for {min_ios})")
    if not macos_podfile.exists():
        problems.append("app/macos/Podfile missing; flutter build macos refuses to run")
    elif min_macos and f"platform :osx, '{min_macos}'" not in macos_podfile.read_text(encoding="utf-8"):
        problems.append(f"app/macos/Podfile does not declare platform :osx, '{min_macos}' "
                        f"(build_apple_deps.sh builds for {min_macos})")

    # Swift cannot see lp_* without the bridging header in the build settings.
    macos_pbx = APP / "macos" / "Runner.xcodeproj" / "project.pbxproj"
    if macos_pbx.exists():
        pbx_text = macos_pbx.read_text(encoding="utf-8")
        if "SWIFT_OBJC_BRIDGING_HEADER" not in pbx_text:
            problems.append("app/macos/Runner.xcodeproj: SWIFT_OBJC_BRIDGING_HEADER is "
                            "not set, so MainFlutterWindow.swift cannot call lp_*")
        # Xcode 26 (macOS SDK 27) refuses anything below 12.0:
        #   error: The macOS deployment target 'MACOSX_DEPLOYMENT_TARGET' is set to
        #   11.0, but the range of supported deployment target versions is 12.0 to 27.0.x
        # A stale 11.0 in the pbxproj silently breaks `flutter build macos`, so pin
        # every occurrence to the same floor the shell script builds with.
        for target in re.findall(r'MACOSX_DEPLOYMENT_TARGET = "?([0-9.]+)"?;', pbx_text):
            if min_macos and _ver_tuple(target) < _ver_tuple(min_macos):
                problems.append(f"app/macos/Runner.xcodeproj: MACOSX_DEPLOYMENT_TARGET = "
                                f"{target} is below {min_macos}; Xcode 26 rejects it")
                break
    # The xcconfig is the second line of defence: a target-level setting wins over
    # an inherited project one, so keep the floor here too.
    app_info = APP / "macos" / "Runner" / "Configs" / "AppInfo.xcconfig"
    if app_info.exists() and min_macos:
        if f"MACOSX_DEPLOYMENT_TARGET = {min_macos}" not in app_info.read_text(encoding="utf-8"):
            problems.append(f"app/macos/Runner/Configs/AppInfo.xcconfig does not pin "
                            f"MACOSX_DEPLOYMENT_TARGET = {min_macos}")
    # Pods.xcodeproj is generated, so the only way to guarantee every pod ends up
    # on the floor is the post_install hook. path_provider_foundation ships 10.14
    # and flutter_macos_podfile_setup only deletes the key below 10.14, so without
    # this loop `pod install` succeeds but xcodebuild fails.
    if macos_podfile.exists() and min_macos:
        podfile_text = macos_podfile.read_text(encoding="utf-8")
        if "config.build_settings['MACOSX_DEPLOYMENT_TARGET']" not in podfile_text:
            problems.append("app/macos/Podfile post_install does not raise every pod's "
                            "MACOSX_DEPLOYMENT_TARGET; third-party pods ship 10.14 and "
                            "Xcode 26 rejects it")
    if not (APP / "macos" / "Runner" / "MainFlutterWindow.swift").exists():
        problems.append("app/macos/Runner/MainFlutterWindow.swift missing; the macOS "
                        "build would have no lanplayer/video channel")

    # iOS side of the same class of bug.  Xcode 27 (iOS SDK 27) raised its floor to
    # 15.0, so a pod or target left on 13.0 now fails with:
    #   Target Integrity (Xcode): The iOS Simulator deployment target
    #   'IPHONEOS_DEPLOYMENT_TARGET' is set to 13.0, but the range of supported
    #   deployment target versions is 15.0 to 27.1.x.
    # Every place that can carry the value has to agree with build_apple_deps.sh.
    ios_podfile_text = ios_podfile.read_text(encoding="utf-8") if ios_podfile.exists() else ""
    if min_ios and ios_podfile_text:
        if "config.build_settings['IPHONEOS_DEPLOYMENT_TARGET']" not in ios_podfile_text:
            problems.append("app/ios/Podfile post_install does not raise every pod's "
                            "IPHONEOS_DEPLOYMENT_TARGET; third-party pods ship 12.0/13.0 "
                            "and Xcode 27 rejects it")
    ios_pbx = APP / "ios" / "Runner.xcodeproj" / "project.pbxproj"
    if ios_pbx.exists() and min_ios:
        for target in re.findall(r'IPHONEOS_DEPLOYMENT_TARGET = "?([0-9.]+)"?;',
                                 ios_pbx.read_text(encoding="utf-8")):
            if _ver_tuple(target) < _ver_tuple(min_ios):
                problems.append(f"app/ios/Runner.xcodeproj: IPHONEOS_DEPLOYMENT_TARGET = "
                                f"{target} is below {min_ios}; Xcode 27 rejects it")
                break
    app_framework_info = APP / "ios" / "Flutter" / "AppFrameworkInfo.plist"
    if app_framework_info.exists() and min_ios:
        m = re.search(r'<key>MinimumOSVersion</key>\s*<string>([0-9.]+)</string>',
                      app_framework_info.read_text(encoding="utf-8"))
        if m and _ver_tuple(m.group(1)) < _ver_tuple(min_ios):
            problems.append(f"app/ios/Flutter/AppFrameworkInfo.plist: MinimumOSVersion = "
                            f"{m.group(1)} is below {min_ios}")
    for name in ("ios", "macos"):
        spec = core / name / "lanplayer_core.podspec"
        if not spec.exists():
            continue
        floor = min_ios if name == "ios" else min_macos
        if not floor:
            continue
        key = "s.ios.deployment_target" if name == "ios" else "s.osx.deployment_target"
        m = re.search(re.escape(key) + r"\s*=\s*'([0-9.]+)'",
                      spec.read_text(encoding="utf-8"))
        if m and _ver_tuple(m.group(1)) < _ver_tuple(floor):
            problems.append(f"packages/lanplayer_core/{name}/lanplayer_core.podspec: "
                            f"{key} = {m.group(1)} is below {floor}")

    if not any(p.startswith(("app/ios/Podfile", "app/macos/Podfile",
                             "app/macos/Runner.xcodeproj")) for p in problems):
        notes.append(f"apple wiring: podspecs link liblanplayer.a, Podfiles declare "
                     f"iOS {min_ios or '?'} / macOS {min_macos or '?'}")


def main() -> int:
    check_c_syntax()
    check_dart_imports()
    check_dart_duplicates()
    check_required_files()
    check_symbols()
    check_native_runtime()
    check_dart_syntax()
    check_dart_compile()
    check_dart_tests()
    check_windows_plugin()
    check_texture_colors()
    check_lan_scan()
    check_thumbnails()
    check_installers()
    check_player_layout()
    check_apple_wiring()
    check_hw_decode()

    for n in notes:
        print(f"· {n}")
    if problems:
        print()
        for p in problems:
            print(f"✗ {p}")
        print(f"\n{len(problems)} problem(s)")
        return 1
    print("\n✓ all static checks passed")
    return 0

if __name__ == "__main__":
    sys.exit(main())
