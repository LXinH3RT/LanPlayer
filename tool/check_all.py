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
     scripts/build_apple_deps.py)

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
    "README.en.md",
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
    "native/src/core/submatch.c",
    "native/src/core/queue.c",
    "native/src/core/audio_ring.c",
    "native/src/core/nal.c",
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
    "app/lib/ui/media_permission.dart",
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
    "scripts/build_apple_deps.py",
    "scripts/gen_windows_runner.py",
    "scripts/patch_flutter_tools.py",
    "native/tests/lp_win32_texture_test.c",
    "native/tests/lp_hw_decode_test.c",
    "native/tests/lp_hw_probe.c",
    "native/tests/lp_thumb_test.c",
    "native/tests/lp_junk_test.c",
    "native/src/platform/win32/d3d11va_decoder.c",
    "packages/lanplayer_video/windows/include/lanplayer_video/pixel_swizzle.h",
    "app/lib/ui/widgets/subtitle_overlay.dart",
    "app/test/subtitle_clip_test.dart",
    "app/lib/ui/splash_gate.dart",
    "app/test/splash_gate_test.dart",
    "app/assets/branding/splash_logo.png",
    "app/android/app/src/main/res/values-v31/styles.xml",
    "app/lib/ui/widgets/video_surface.dart",
    "app/test/video_surface_test.dart",
    "app/assets/fonts/MiSansVF.ttf",
    "app/assets/fonts/MiSans-LICENSE.txt",
    "app/assets/fonts/NOTICE.txt",
    "app/lib/data/models.dart",
    "app/lib/data/probe.dart",
    "app/lib/data/track_prefs.dart",
    "app/test/track_prefs_test.dart",
    "app/test/settings_track_lang_test.dart",
    "app/test/subtitle_overlay_test.dart",
    "app/test/settings_test.dart",
    "scripts/build_windows_app.py",
    "scripts/build_windows_desktop.py",
    "scripts/build_windows_installer.py",
    "scripts/build_macos_dmg.py",
    "scripts/build_android_apk.py",
    "scripts/release_all.py",
    "scripts/ios_device_install.py",
    "scripts/windows/installer.nsi",
    "scripts/verify_windows_upgrade.py",
    "scripts/verify_windows_uninstall.py",
    "scripts/verify_windows_locked_upgrade.py",
    "scripts/verify_windows_locked_uninstall.py",
    "scripts/install_local_windows.py",
    "LICENSE",
    "scripts/fix_plugin_links.py",
    "scripts/msvc_chain.py",
    "scripts/capture_window.py",
    "scripts/capture_app.py",
    "scripts/capture_screen.py",
    "scripts/send_keys.py",
    "scripts/capture_playback_ui.py",
    "scripts/hover_probe.py",
    "scripts/click_window.py",
    "scripts/capture_lanscan.py",
    "tool/image_stats.py",
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
    "docs/images/desktop-subtitle-fonts.jpg",
    "docs/images/desktop-subtitle-sheet.jpg",
    "docs/images/desktop-ass-advanced.png",
    "docs/images/desktop-splash.png",
    "docs/images/desktop-about.png",
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

    cap = ROOT / "scripts" / "capture_screen.py"
    if cap.exists():
        ctext = cap.read_text(encoding="utf-8")
        # A capture that silently grabs the desktop instead of the app produced
        # an all-white "proof" twice; the colour assertion is what catches it.
        for needle, why in (
            ('"--expect-color"', "capture script lost its expected-colour option"),
            ("colour_match(", "capture script no longer measures the expected colour"),
            ("return 3", "capture script no longer fails on invalid evidence"),
        ):
            if needle not in ctext:
                problems.append(why)
        # The colour has to be parsed into three separate ints, not carried
        # around as the raw "R,G,B" string.
        if "want = tuple(int(p) for p in parts)" not in ctext:
            problems.append("capture script no longer turns the colour string into "
                            "an integer triple, so comparing it silently fails")

    media = ROOT / "scripts" / "make_test_media.py"
    if media.exists() and "duration=60" not in media.read_text(encoding="utf-8"):
        problems.append("colour probe clip is short again; capturing it becomes a race "
                        "against playback ending")
    notes.append("texture colour order: R<->B swapped once, alpha forced opaque")

def check_splash() -> None:
    r"""Guard the launch animation and the native splash artwork.

    The point of the splash is that the engine shows *something* before the
    stores are read. Three things can silently undo it:

      * `main()` awaits the stores again before `runApp`, so the first frame is
        back to the system splash and the icon never appears;
      * the gate stops honouring its minimum duration, so on a warm start the
        icon flashes for one frame - which looks worse than no splash at all;
      * the native launch screens drift from the Flutter one (white backdrop,
        placeholder 1x1 image) and the user sees a white flash before the dark
        icon screen.
    """
    gate = ROOT / "app" / "lib" / "ui" / "splash_gate.dart"
    if not gate.exists():
        problems.append("app/lib/ui/splash_gate.dart missing; the launch "
                        "animation was removed")
    else:
        gs = gate.read_text(encoding="utf-8")
        for token, why in (
            ("class SplashGate", "the launch gate widget"),
            ("widget.minimum", "the minimum on-screen time"),
            ("Future<void> _bootOnly", "running init behind the animation"),
            ("AnimatedOpacity", "fading the icon out"),
            ("assets/branding/splash_logo.png", "the splash artwork"),
        ):
            if token not in gs:
                problems.append(
                    "app/lib/ui/splash_gate.dart: missing %r (%s)"
                    % (token, why))

    main_dart = ROOT / "app" / "lib" / "main.dart"
    if not main_dart.exists():
        problems.append("app/lib/main.dart missing")
    else:
        ms = main_dart.read_text(encoding="utf-8")
        # runApp 必须出现在 main() 里、而且要在任何 store.load() 之前，
        # 否则第一帧仍然是系统那张空白图，图标动画根本不会出现。
        body_start = ms.find("Future<void> main()")
        body_end = ms.find("runApp(", body_start + 1) if body_start >= 0 else -1
        if body_start < 0:
            problems.append("app/lib/main.dart: no main()")
        elif body_end < 0:
            problems.append(
                "app/lib/main.dart: main() never calls runApp(); nothing "
                "would be drawn")
        else:
            head = ms[body_start:body_end]
            if ".load()" in head or "_boot()" in head:
                problems.append(
                    "app/lib/main.dart: main() awaits the stores before "
                    "runApp(); the first frame would still be the blank "
                    "system splash")
        if "home: SplashGate(" not in ms:
            problems.append(
                "app/lib/main.dart: home is not wrapped in SplashGate; "
                "nothing would mask the load")

        # 启动动画的代价：runApp 早于 store 读取，首页第一帧必然拿到空列表。
        # 若两个 store 不是可监听的，读完也没有人通知界面 —— 0.1.6 就是这样
        # 发布的，首页永远停在「还没有内容」，而磁盘上的服务器好好的。
        for rel, cls in (("app/lib/data/stores.dart", "ServerStore"),
                         ("app/lib/data/folders.dart", "LocalFolderStore")):
            path = ROOT / rel
            if not path.exists():
                problems.append("%s missing" % rel)
                continue
            src = path.read_text(encoding="utf-8")
            head = "class %s extends ChangeNotifier" % cls
            if head not in src:
                problems.append(
                    "%s: %s no longer extends ChangeNotifier; the home screen "
                    "would stay empty after the stores finish loading"
                    % (rel, cls))
            if "bool get loaded => _loaded;" not in src:
                problems.append(
                    "%s: %s lost the `loaded` flag; the home screen could not "
                    "tell 'nothing saved' from 'not read yet'" % (rel, cls))
            if "notifyListeners();" not in src:
                problems.append(
                    "%s: %s never calls notifyListeners(); loading would not "
                    "redraw the home screen" % (rel, cls))

        home = ROOT / "app" / "lib" / "ui" / "home_screen.dart"
        if not home.exists():
            problems.append("app/lib/ui/home_screen.dart missing")
        else:
            hs = home.read_text(encoding="utf-8")
            for token, why in (
                ("addListener(_onStoreChanged)",
                 "subscribing to the stores"),
                ("removeListener(_onStoreChanged)",
                 "unsubscribing when the screen goes away"),
                ("_storesReady", "holding the empty state until the read ends"),
            ):
                if token not in hs:
                    problems.append(
                        "app/lib/ui/home_screen.dart: missing %r (%s)"
                        % (token, why))

    ios = (ROOT / "app" / "ios" / "Runner" / "Base.lproj"
           / "LaunchScreen.storyboard")
    if not ios.exists():
        problems.append("app/ios/Runner/Base.lproj/LaunchScreen.storyboard "
                        "missing")
    else:
        st = ios.read_text(encoding="utf-8")
        if 'red="1" green="1" blue="1"' in st:
            problems.append(
                "LaunchScreen.storyboard still uses a white backdrop; the "
                "splash screen is dark, so the launch would flash white")
        if 'image="LaunchImage"' not in st:
            problems.append(
                "LaunchScreen.storyboard lost the LaunchImage reference")

    android_bg = (ROOT / "app" / "android" / "app" / "src" / "main" / "res"
                  / "drawable" / "launch_background.xml")
    if not android_bg.exists():
        problems.append("Android launch_background.xml missing")
    else:
        bg = android_bg.read_text(encoding="utf-8")
        if "@android:color/white" in bg:
            problems.append("Android launch_background.xml is still white; "
                            "the app is dark, so launch would flash white")
        if "@mipmap/launch_logo" not in bg:
            problems.append("Android launch_background.xml no longer draws "
                            "the launch logo")

    v31 = (ROOT / "app" / "android" / "app" / "src" / "main" / "res"
           / "values-v31" / "styles.xml")
    if not v31.exists():
        problems.append(
            "app/android/.../values-v31/styles.xml missing; Android 12+ would "
            "draw its own white splash instead of ours")
    else:
        vt = v31.read_text(encoding="utf-8")
        for token in ("windowSplashScreenBackground",
                      "windowSplashScreenAnimatedIcon"):
            if token not in vt:
                problems.append(
                    "values-v31/styles.xml: missing %s; Android 12+ would "
                    "fall back to the default splash" % token)

    for scale in ("", "@2x", "@3x"):
        p = (ROOT / "app" / "ios" / "Runner" / "Assets.xcassets"
             / "LaunchImage.imageset" / ("LaunchImage%s.png" % scale))
        if not p.exists():
            problems.append("iOS LaunchImage%s.png missing" % scale)
        elif p.stat().st_size < 400:
            problems.append(
                "iOS LaunchImage%s.png is a placeholder (%d bytes); the "
                "launch screen would show a blank square"
                % (scale, p.stat().st_size))

    doc_image = ROOT / "docs" / "images" / "desktop-splash.png"
    if not doc_image.exists():
        problems.append("docs/images/desktop-splash.png missing; the README "
                        "screenshot of the launch animation would be broken")

    about_image = ROOT / "docs" / "images" / "desktop-about.png"
    if not about_image.exists():
        problems.append("docs/images/desktop-about.png missing; the README "
                        "screenshot of the version line would be broken")
    notes.append("splash: a logo animation covers the first frame while the "
                 "stores load, native launch screens share its backdrop")



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
    # The display-name box was dropped on purpose: two fields (name + share)
    # for one thing made every add-server visit show an empty optional box that
    # almost nobody filled, and leaving it blank already fell back to the share
    # name. Guard the decision so a later edit does not quietly restore it.
    if "显示名称" in ui_code:
        problems.append("the add-server screen must not ask for 显示名称 any "
                        "more; the card title is the share name "
                        "(ServerProfile.displayName)")
    if ui_code.count("TextFormField(") != 5:
        problems.append(
            f"the add-server screen should have 5 inputs (host/port/share/"
            f"user/password), found {ui_code.count('TextFormField(')}")
    models = ROOT / "app" / "lib" / "data" / "models.dart"
    if models.exists() and "displayName" not in models.read_text(encoding="utf-8"):
        problems.append("ServerProfile must expose displayName (falls back to "
                        "share) so cards stay readable when name is empty")


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

    # A cover keyed only by the URL never expires: replacing a file under the
    # same name kept showing the old frame until the user wiped the cache by
    # hand.  The key now carries the entry's version (mtime + size).
    if "keyForVersion(url, version)" not in code:
        problems.append("thumbs.dart must key covers by keyForVersion(url, "
                        "version); a URL-only key never expires when a file is "
                        "replaced in place")
    if "version: widget.version" not in tile_code:
        problems.append("ThumbnailTile must hand its version to the cache, "
                        "or a replaced file keeps its old cover")
    if "oldWidget.version" not in tile_code:
        problems.append("ThumbnailTile must refetch when the version changes "
                        "too, not just when the URL does")
    row = ROOT / "app" / "lib" / "ui" / "widgets" / "media_row.dart"
    if not row.exists() or "version: entry.version" not in row.read_text(
            encoding="utf-8"):
        problems.append("media_row must pass entry.version to the cover tile")

    browser_code = "\n".join(
        l for l in browser.read_text(encoding="utf-8").splitlines()
        if not l.strip().startswith("//"))
    if "e.isVideo" not in browser_code:
        problems.append("the browser list must only request covers for videos")

    # Going back re-used the listing snapshot taken on the way in, so a rename
    # on the server stayed invisible until the user pressed refresh.  The back
    # button has to refetch, and refresh has to show progress and not swallow
    # a second click.
    if "unawaited(_reload())" not in browser_code:
        problems.append("browser _up() must reload the parent listing; the "
                        "stack holds a snapshot and renames never show up")
    if "Future<void> _reload() async" not in browser_code:
        problems.append("browser lost _reload(); the refresh button needs one")
    else:
        body = browser_code.split("Future<void> _reload() async", 1)[1]
        body = body.split("Future<void> ", 1)[0]
        if "_loading = true" not in body:
            problems.append("browser _reload() must raise _loading; a slow "
                            "share then looks like a dead refresh button")
        if "if (_loading) return" in body or "if (_loads[s.id]?.loading == true)" in body:
            problems.append("browser _reload() must not drop a second click; "
                            "ignoring it makes the button feel broken")

    # Regression guards for the "opening a folder full of .flv hangs" bug.
    # Each of these was a real defect:
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
        if "subtitleBelongsTo" not in mc:
            problems.append("models.dart must group sidecars through "
                            "data/subtitle_match.dart; the loose rules it used "
                            "to carry could not pair a tagged release with its "
                            "own subtitle")
    else:
        problems.append("app/lib/data/models.dart missing")
    # 配对规则是跨语言产物：列表分组（Dart）和自动挂载（C）必须用同一套判定，
    # 否则同一个文件在列表里有字幕、点开却没加载。
    match = ROOT / "app" / "lib" / "data" / "subtitle_match.dart"
    if not match.exists():
        problems.append("app/lib/data/subtitle_match.dart missing")
    else:
        mt = match.read_text(encoding="utf-8")
        if "subtitleBelongsTo" not in mt:
            problems.append("subtitle_match.dart must expose "
                            "subtitleBelongsTo(videoName, subName)")
        if "_episodeKey" not in mt:
            problems.append(
                "subtitle_match.dart must compare episode numbers; without it a "
                "whole season's subtitles collapse onto the first episode")
    cmatch = ROOT / "native" / "src" / "core" / "submatch.c"
    if not cmatch.exists():
        problems.append("native/src/core/submatch.c missing; the core would "
                        "pair sidecars by a bare name prefix again")
    else:
        cm = cmatch.read_text(encoding="utf-8")
        if "lp_sub_match_related" not in cm:
            problems.append("submatch.c must expose lp_sub_match_related")
        demux = ROOT / "native" / "src" / "core" / "demux.c"
        if demux.exists() and "lp_sub_match_related" not in demux.read_text(encoding="utf-8"):
            problems.append("demux.c must pair sidecars through "
                            "lp_sub_match_related, not a bare prefix compare")
    # The row itself lives in a shared widget now, because the home screen
    # spreads every source's root out with the very same rows. The guard follows
    # the code: the widget must group subtitles under their video, and both
    # screens must render through that widget instead of hand-rolling rows.
    row = ROOT / "app" / "lib" / "ui" / "widgets" / "media_row.dart"
    home = ROOT / "app" / "lib" / "ui" / "home_screen.dart"
    if browser.exists():
        bc = browser.read_text(encoding="utf-8")
        if "_listing.browsable" not in bc:
            problems.append("browser_screen must iterate browsable, not entries")
        if "MediaRow(" not in bc:
            problems.append("browser_screen must render rows through "
                            "widgets/media_row.dart, not its own ListTile")
    else:
        problems.append("app/lib/ui/browser_screen.dart missing")
    if row.exists():
        rc = row.read_text(encoding="utf-8")
        if "subtitlesFor" not in rc:
            problems.append("media_row must group subtitles per video; "
                            "sidecar files would show up as loose rows")
        if "resumablePosition" not in rc:
            problems.append("media_row must draw the resume bar; playback "
                            "position would be invisible on both screens")
    else:
        problems.append("app/lib/ui/widgets/media_row.dart missing")
    if home.exists() and "MediaRow(" not in home.read_text(encoding="utf-8"):
        problems.append("home_screen must render rows through "
                        "widgets/media_row.dart so both lists stay identical")

    # 首页是「直接摊开根目录」，不是「卡片列表」：它必须自己去列每个来源的根，
    # 源头是两类存储（服务器 + 本机文件夹）。
    sources = ROOT / "app" / "lib" / "data" / "home_sources.dart"
    folders = ROOT / "app" / "lib" / "data" / "folders.dart"
    for path, label in ((sources, "home_sources.dart"), (folders, "folders.dart")):
        if not path.exists():
            problems.append(f"app/lib/data/{label} missing; the home screen "
                            f"would only show server cards again")
    if sources.exists():
        sc = sources.read_text(encoding="utf-8")
        if "buildHomeSources(" not in sc:
            problems.append("home_sources must keep buildHomeSources(); the "
                            "home screen would have to merge the two stores "
                            "itself and the order would drift")
    if home.exists():
        hc = home.read_text(encoding="utf-8")
        if "location.rootUrl" not in hc:
            problems.append("home_screen must list each source's root itself; "
                            "requiring a tap on a card first is what users "
                            "asked to remove")
        if "showSourceFilter(" not in hc:
            problems.append("home_screen must offer the source filter when "
                            "several sources are on the page")
        # 首页有来源时不再挂一个右下的浮动按钮，添加入口收进顶栏，紧挨设置。
        # 反过来的写法（FloatingActionButton 又冒出来）会让列表底部永远空出
        # 一条挡板的空白，也和「空状态页已经有两颗按钮」重复。
        if "FloatingActionButton" in hc:
            problems.append("home_screen must not float an add button over the "
                            "list; the add entry belongs in the app bar")
        if "tooltip: '添加'" not in hc:
            problems.append("home_screen lost the add entry in the app bar")
        # 添加菜单收起之后才能压新页面。showModalBottomSheet 返回的是路由的
        # `popped`，在退场动画开始时就完成了；iOS 上紧接着 push 会被 UIKit
        # 丢掉，用户看到「点加号弹出的二级页面自己收回」。所以首页必须自己
        # push 路由并等 `completed`。
        if "ModalBottomSheetRoute<" not in hc:
            problems.append("home_screen must push the add sheet itself; "
                            "showModalBottomSheet resolves before the sheet "
                            "is off screen and the next push gets dropped")
        if "route.completed" not in hc:
            problems.append("home_screen must await route.completed before "
                            "opening the next page; otherwise the sheet's exit "
                            "animation races the push and iOS drops it")
        # 首页单块加载曾经用「正在加载就跳过」做去重，结果从子目录返回时那次
        # 回填被悄悄丢掉，看上去就是刷新没生效。过期结果由 _loadGen 丢弃，
        # 不需要入口守卫。
        if "if (_loads[s.id]?.loading == true) return;" in hc:
            problems.append("home_screen _load must not swallow a reload while "
                            "one is in flight; the stale result is already "
                            "dropped by _loadGen")

    notes.append("thumbnails: LPT2 header round-trips, hex cache key keyed by "
                 "mtime+size so a replaced file gets a fresh cover, covers only "
                 "for video rows, decoding is throttled and cannot spin or seek "
                 "past the end")
    notes.append("browser: only video/subtitle/audio rows, subtitles grouped "
                 "under their own video, back and refresh both refetch "
                 "(the back stack only holds a snapshot)")
    notes.append("subtitle match: same stem, same episode, or release/language "
                 "tags stripped — and the same rules in Dart and in the core")
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
    ps1 = ROOT / "scripts" / "build_windows_installer.py"
    sh = ROOT / "scripts" / "build_macos_dmg.py"
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
            problems.append(f"build_windows_installer.py does not pass /D{macro} "
                            "to makensis")

    # Every staged runtime file must also be packaged; a drift here ships a
    # package that throws on startup when it cannot find a DLL.
    driver = ps1.read_text(encoding="utf-8")
    staged = re.findall(r'^\s*"([\w.-]+\.dll|[\w.-]+\.exe)",?\s*$', driver, re.M)
    for name in staged:
        if f'"{name}"' not in nsi_code and f"\\{name}" not in nsi_code:
            problems.append(f"installer.nsi does not package {name} "
                            "although the driver stages it")

    dmg = sh.read_text(encoding="utf-8")
    body = "\n".join(l for l in dmg.splitlines()
                     if not l.strip().startswith("#"))
    if "DITTO" not in body:
        problems.append("build_macos_dmg.py must copy the app with ditto "
                        "(cp -R drops extended attributes and the signature)")
    if "shutil.copytree" in body:
        problems.append("build_macos_dmg.py must not copy the .app with shutil "
                        "(that drops the code signature)")
    if "HDIUTIL" not in body or "UDZO" not in body:
        problems.append("build_macos_dmg.py must create a compressed (UDZO) dmg")
    if "CODESIGN" not in body or "--verify" not in body:
        problems.append("build_macos_dmg.py must verify the signature before "
                        "packing")

    # A file inherits the integrity label of the directory it is created in, so
    # an installer built under a Low-labelled tree comes out labelled Low.  That
    # is *hygiene*, not the install blocker it was once assumed to be: the level
    # of a process comes from the launching token, and a Low-labelled setup.exe
    # installs fine from an ordinary shell (measured).  What does break an
    # install is the build shell itself running at Low - then everything it
    # launches inherits that token and cannot write to the install directory.
    # The build has to check both: strip the label when it can, and refuse to
    # pretend everything is fine when the shell is restricted.
    if "low_integrity_label" not in driver:
        problems.append("build_windows_installer.py no longer checks whether the "
                        "installer inherited a Low integrity label; the label "
                        "would be passed on to whatever the package unpacks")
    if "current_integrity" not in driver:
        problems.append("build_windows_installer.py no longer reports the build "
                        "shell's own integrity level; a Low shell produces "
                        "artefacts that cannot be installed while claiming "
                        "success")

    # The iOS device installer is the only path that runs on a real iPad.
    # Guard the two things that make it work: an explicit team id (Xcode
    # refuses to sign without one) and devicectl (flutter install needs the
    # legacy MobileDevice stack, which Xcode 27 dropped for devices).
    dev = ROOT / "scripts" / "ios_device_install.py"
    if not dev.exists():
        problems.append("missing scripts/ios_device_install.py")
    else:
        dev_body = "\n".join(l for l in dev.read_text(encoding="utf-8").splitlines()
                             if not l.strip().startswith("#"))
        if "DEVELOPMENT_TEAM" not in dev_body:
            problems.append("ios_device_install.py must write DEVELOPMENT_TEAM "
                            "into the Xcode project")
        if '"devicectl", "device", "install", "app"' not in dev_body:
            problems.append("ios_device_install.py must install with "
                            "'devicectl device install app'")
        if "build ios" not in dev_body:
            problems.append("ios_device_install.py must build with "
                            "'flutter build ios'")

    # Covering upgrade: without asking the running copy to quit, File/Delete hit
    # mapped images and the user has to uninstall by hand first. The macro must
    # be inserted in *both* sections -- dropping it from either one only breaks
    # half the flow, and a negative control proved it: with the uninstall insert
    # removed, an uninstall over a running app left 13 of 17 files behind.
    if "!macro StopRunningApp" not in nsi_code:
        problems.append("installer.nsi lost the StopRunningApp macro; a running "
                        "old version would block the upgrade again")
    else:
        core_start = nsi_code.find('Section "LanPlayer')
        core_end = nsi_code.find('SectionEnd', core_start)
        un_start = nsi_code.find('Section "Uninstall"')
        for name, start, end in (("install", core_start, core_end),
                                 ("uninstall", un_start, len(nsi_code))):
            if start < 0 or "!insertmacro StopRunningApp" not in nsi_code[start:end]:
                problems.append(f"installer.nsi does not call StopRunningApp from "
                                f"the {name} section")

        # The macro asks cmd to pipe tasklist into a text filter and takes the
        # filter's exit code as "is it still running". `find` is a trap: Git
        # Bash puts /usr/bin ahead of System32, so cmd resolves to GNU find,
        # which rejects /FI and /I and exits non-zero -- the macro then thinks
        # nothing is running, skips the taskkill, and the upgrade silently
        # fails with "file in use" again. findstr ships with Windows only.
        if "| findstr" not in nsi_code:
            problems.append("installer.nsi no longer filters tasklist with "
                            "findstr; `find` resolves to GNU find under Git "
                            "Bash and breaks the running-app check")
        if "| find /I" in nsi_code:
            problems.append("installer.nsi pipes tasklist into `find /I`; that "
                            "is GNU find under Git Bash and always fails")

        # Matching on the image name alone is not enough: copy the exe under a
        # different name, run that copy, and tasklist /FI "IMAGENAME eq
        # lanplayer.exe" finds nothing -- the process keeps the DLL mapped, the
        # installer's File silently skips it and the package ends up with a new
        # exe next to an old lanplayer.dll. Reproduced end to end: exit code 0,
        # same DLL hash before and after.
        #
        # The obvious fix -- ask who maps lanplayer.dll -- does not work here.
        # `tasklist /M` and `taskkill /FI "MODULES eq ..."` both have to walk a
        # 64-bit module list, and the installer engine is 32-bit: inside
        # nsExec they never return, so the upgrade hangs instead of failing.
        # Measured: the same command finishes in 0.3 s from cmd.exe and never
        # returns from the installer. Do not reintroduce them.
        if "tasklist /M" in nsi_code or "MODULES eq" in nsi_code.split(
                "; tasklist /M 与 taskkill")[0]:
            problems.append("installer.nsi queries module holders again "
                            "(tasklist /M or MODULES eq); those hang forever "
                            "inside the 32-bit installer engine")
        # What it does instead: if the DLL cannot be opened for append, the
        # image is still mapped, so force-kill every exe living in $INSTDIR.
        # That covers renamed copies, which the image-name check misses.
        if r'FileOpen $R4 "$INSTDIR\${APP_DLL}" a' not in nsi_code:
            problems.append("installer.nsi lost the writability probe on "
                            "lanplayer.dll; it can no longer tell whether the "
                            "DLL is still mapped")
        if r'FindFirst $0 $1 "$INSTDIR\*.exe"' not in nsi_code:
            problems.append("installer.nsi no longer force-kills the exes in "
                            "$INSTDIR when lanplayer.dll is locked; a renamed "
                            "copy would keep the DLL mapped and the upgrade "
                            "would silently skip it")
        if 'taskkill /F /IM' not in nsi_code:
            problems.append("installer.nsi no longer force-kills by image name")
        # Killing is not enough: whoever maps the DLL may survive (a copy started
        # from outside $INSTDIR, an antivirus scanner, a process the user cannot
        # close). Windows refuses to delete or overwrite a mapped image, but it
        # does allow renaming it -- so the last step moves the old file aside and
        # lets File write the new one under the original name. Without this the
        # installer either aborts with "cannot open file for writing" (interactive)
        # or silently keeps the old DLL (silent). Both were reproduced.
        if "!macro MoveAsideLocked" not in nsi_code:
            problems.append("installer.nsi lost the MoveAsideLocked macro; a "
                            "DLL that cannot be unlocked would never be replaced")
        else:
            body = nsi_code[nsi_code.find("!macro MoveAsideLocked"):]
            body = body[:body.find("!macroend")]
            if "Rename " not in body:
                problems.append("MoveAsideLocked no longer renames the locked "
                                "file; a mapped image cannot be deleted in place")
        for call in ('!insertmacro MoveAsideLocked "$INSTDIR\\${APP_DLL}"',
                     '!insertmacro MoveAsideLocked "$INSTDIR\\${APP_EXE}"'):
            if call not in nsi_code:
                problems.append(f"installer.nsi no longer calls {call}; without "
                                "it the mapped file is never moved aside")
        if "!insertmacro MoveAsideLocked" not in nsi_code[nsi_code.find('Section "Uninstall"'):]:
            problems.append("the uninstaller does not move a locked DLL aside; "
                            "Delete fails silently on mapped files, so the "
                            "uninstall would report success and leave them behind")
        # The moved-aside copies have to be cleaned up, otherwise every upgrade
        # leaves a lanplayer.dll.old behind. The install section tries once at the
        # end (by then the old process is usually gone) and the uninstall deletes
        # them unconditionally.
        if "!macro DeleteMovedAside" not in nsi_code:
            problems.append("installer.nsi lost the DeleteMovedAside macro; each "
                            "upgrade would leave a lanplayer.dll.old behind")
        elif "!insertmacro DeleteMovedAside" not in nsi_code[
                nsi_code.find('Section "LanPlayer'):nsi_code.find('SectionEnd',
                                                                 nsi_code.find('Section "LanPlayer'))]:
            problems.append("the install section no longer cleans up the .old "
                            "copies it moved aside")
        if '"$INSTDIR\\${APP_DLL}.old"' not in nsi_code:
            problems.append("the uninstaller no longer deletes lanplayer.dll.old")
        # A .old whose image is still mapped cannot be deleted now, and Delete
        # without /REBOOTOK drops it silently -- the directory would then survive
        # the uninstall with exactly one stale file in it. NSIS can register the
        # file (and the directory) for deletion on the next reboot.
        for call in ('Delete /REBOOTOK "$INSTDIR\\${APP_DLL}.old"',
                     'Delete /REBOOTOK "$INSTDIR\\${APP_EXE}.old"',
                     'RMDir /REBOOTOK "$INSTDIR"'):
            if call not in nsi_code:
                problems.append(f"installer.nsi stopped using {call}; without it a "
                                "leftover .old survives the uninstall with nothing "
                                "to remove it")

    notes.append("installers: NSIS per-user with BOM + matching file list, "
                 "dmg uses ditto + UDZO")
    notes.append("upgrade: installer and uninstaller both stop a running copy "
                 "first, by image name and then by the exes in $INSTDIR, and "
                 "rename a file that stays mapped out of the way")
    notes.append("iOS device: team id injected, devicectl install")

    # Uninstalling used to leave the saved servers and settings behind (user
    # report: a fresh install reconnected to the old share on its own), and the
    # path it tried to clear was wrong anyway -- %APPDATA%\lanplayer does not
    # exist, because path_provider puts the support directory under
    # %APPDATA%\<CompanyName>\<ProductName>. Two independent things have to stay
    # right: the option must exist, and it must cover every directory the app
    # can actually write to.
    if "!macro PurgeUserData" not in nsi_code:
        problems.append("installer.nsi has no PurgeUserData macro; uninstalling "
                        "would keep the saved servers and settings on disk")
    else:
        purge = nsi_code[nsi_code.find("!macro PurgeUserData"):]
        purge = purge[:purge.find("!macroend")]
        for target, why in (
            ("$APPDATA\\${APP_COMPANY}\\${APP_PRODUCT}\\lanplayer",
             "the real state directory (path_provider appends the company and "
             "product name)"),
            ("$LOCALAPPDATA\\lanplayer", "the local-appdata fallback"),
            ("$INSTDIR\\state", "the portable-install fallback"),
            ("$TEMP\\lanplayer", "the temporary fallback"),
        ):
            if target not in purge:
                problems.append(f"PurgeUserData no longer clears {target}; the "
                                f"state the app left there would survive an "
                                f"uninstall that promised to remove it ({why})")
        if "RMDir /r \"$APPDATA\\${APP_COMPANY}\"" in purge:
            problems.append("PurgeUserData deletes the whole "
                            "$APPDATA\\${APP_COMPANY} tree recursively; another "
                            "product of the same vendor would be wiped too")
    if "UninstPage custom" not in nsi_code:
        problems.append("installer.nsi lost the uninstall options page; there "
                        "would be no way to ask for the saved data to be removed")
    if "/PURGE" not in nsi_code:
        problems.append("installer.nsi no longer recognises /PURGE, so a silent "
                        "uninstall could not delete the saved data")
    if "$purgeWanted" not in nsi_code:
        problems.append("installer.nsi lost the purge decision variable")
    notes.append("uninstall: saved servers/settings/caches removable from the "
                 "options page or with /PURGE, every candidate directory covered")


def check_release_policy() -> None:
    """Every release ships three platforms, and local-only notes never ship.

    Two rules that are easy to violate silently:

      * A release must carry Windows, macOS *and* Android. Publishing two of
        the three leaves the download page lying about what the version
        supports, and nothing about the repository shows it happened. The
        release script therefore has to name all three packages and has to
        fail before uploading when one is missing. Narrowing a single release
        to a subset is allowed only by passing --platforms explicitly; the
        default path must keep shipping all three, which is what the
        assertion below pins down.
      * Notes that only apply to one checkout must stay off to the side.
        They describe the machine the code happens to sit on, not the
        product; publishing them is noise at best. They belong in the
        repository's local exclude file, not in a tracked ignore list, and no
        tracked file may point at them by name either — a dangling link in a
        README is how such a note ends up shipped.
    """
    release = ROOT / "scripts" / "release_all.py"
    if not release.is_file():
        problems.append("scripts/release_all.py is missing; one release must "
                        "upload the Windows, macOS and Android packages together")
        return

    text = release.read_text(encoding="utf-8", errors="replace")
    # Match the suffixes in the asset table, not the plain names in the header
    # comment: a comment can keep saying "android" while the list that is
    # actually uploaded has lost it.
    for pattern, what in (
        ('"windows-x64-setup.exe"', "Windows installer"),
        ('"macos-arm64.dmg"', "macOS dmg"),
        ('"android-arm64.apk"', "Android apk"),
    ):
        if pattern not in text:
            problems.append(f"scripts/release_all.py no longer uploads the "
                            f"{what} ({pattern}); a release must ship all "
                            f"three platforms")
    if "if missing:" not in text or "return 1" not in text:
        problems.append("scripts/release_all.py no longer refuses to upload "
                        "when a platform package is missing")
    # --platforms may narrow one release, but the default has to stay "all
    # three": asset_names() with no platforms must not silently drop a suffix.
    if 'wanted = set(platforms) if platforms else' not in text:
        problems.append("scripts/release_all.py lost the all-three-platform "
                        "default; --platforms must be an explicit opt-out, not "
                        "the normal path")
    for builder in ("build_windows_installer.py", "build_macos_dmg.py",
                    "build_android_apk.py"):
        if not (ROOT / "scripts" / builder).is_file():
            problems.append(f"scripts/{builder} is missing; the release needs a "
                            f"way to produce every platform package")

    # All three builders must take the version from pubspec so the three
    # packages of one release cannot disagree.
    for builder in ("build_android_apk.py", "build_macos_dmg.py",
                    "build_windows_installer.py"):
        path = ROOT / "scripts" / builder
        if not path.is_file():
            continue
        body = path.read_text(encoding="utf-8", errors="replace")
        if "pubspec_version(" not in body:
            problems.append(f"scripts/{builder} no longer reads the version "
                            f"from app/pubspec.yaml; its packages would be "
                            f"named with a stale version")

    # Checkout-only rules live in .git/info/exclude rather than a tracked
    # ignore list: naming such files in a published file would announce what
    # this machine runs, which is exactly what we are trying not to publish.
    # The names therefore stay local, and this check reads them from there so
    # the guard still works without repeating them here.
    exclude = ROOT / ".git" / "info" / "exclude"
    rules = []
    if exclude.is_file():
        rules = [line.strip() for line in
                 exclude.read_text(encoding="utf-8", errors="replace").splitlines()
                 if line.strip() and not line.strip().startswith("#")]
    code, out = run(["git", "ls-files"])
    if code == 0:
        tracked = [line.strip() for line in out.splitlines() if line.strip()]
        # A trailing slash in the rule means "this directory"; anything under
        # it must be out of the index too.
        for rule in rules:
            if rule.endswith("/"):
                if any(path.startswith(rule) for path in tracked):
                    problems.append(f"{rule} is tracked even though the local "
                                    f"exclude file says it must not be; a "
                                    f"checkout-only file reached the repository")
            elif rule in tracked:
                problems.append(f"{rule} is tracked even though the local "
                                f"exclude file says it must not be; a "
                                f"checkout-only file reached the repository")

    # Published prose is read by strangers: it may describe how to build and
    # use the product, not how this particular checkout was published. Token
    # endpoints and upload hostnames in a Markdown file are a copy-paste
    # invitation to attach credentials to them, and a reference to a note
    # that is not in the repository is a dead link for everyone else.
    forbidden_doc_strings = (
        "api.github.com",
        "uploads.github.com",
        "Authorization: token",
        "ghp_",
        "docs/verification.md",
    )
    for rel in [p for p in tracked if p.endswith(".md")]:
        path = ROOT / rel
        if not path.is_file():
            continue
        try:
            body = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for needle in forbidden_doc_strings:
            if needle in body:
                problems.append(f"{rel} mentions {needle!r}; published prose "
                                f"must not carry publishing endpoints or point "
                                f"at notes that are not in the repository")

    # The two READMEs are translations of each other, so each has to point at
    # the other one; a language switcher that only works one way strands half
    # the readers.  Both also have to name the same screenshot, otherwise a
    # translated page keeps showing a picture that no longer exists.
    for name, other in (("README.md", "README.en.md"),
                        ("README.en.md", "README.md")):
        path = ROOT / name
        if not path.is_file():
            problems.append(f"{name} is missing; the repository is published "
                            f"in two languages")
            continue
        body = path.read_text(encoding="utf-8", errors="replace")
        if other not in body:
            problems.append(f"{name} no longer links {other}; the language "
                            f"switch would only work in one direction")

    notes.append("release: one release uploads Windows + macOS + Android, "
                 "checkout-only notes stay out of the repository")

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
    """Runs the compiled smoke test when scripts/build_windows.py has run."""
    out_dir = ROOT / "build" / "win-x64"
    exe = out_dir / "lp_smoke_test.exe"
    if not exe.exists():
        notes.append("native runtime: not built (scripts/build_windows.py)")
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
        notes.append("hw decode: not built (scripts/build_windows.py)")
        return
    if not red.exists():
        notes.append("hw decode: skipped (no colour probe clip; make_test_media.py)")
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
                        "return to the vertical centre")
    if "_backKey" not in top:
        problems.append("_topBar() lost the _backKey hook used by the layout probe")

    bottom_start = text.find("Widget _bottomBar(")
    bottom = text[bottom_start:] if bottom_start > 0 else ""
    if "_pictureKey" not in bottom or "_openPictureSheet" not in bottom:
        problems.append("the picture controls are no longer in the bottom transport row")
    # 用户按图指定：「画面」这颗按钮单击进/退全屏，长按才打开画面设置。
    # 两种手势必须挂在同一个 widget 上，拆成两个按钮就回到「多一颗全屏图标」。
    if "onLongPress: _openPictureSheet" not in bottom:
        problems.append("the picture sheet lost its entry point; put it on "
                        "long-press of the 画面 button")
    if "onTap: _toggleFullscreen" not in bottom:
        problems.append("tapping 画面 must toggle fullscreen (user asked for it)")
    if "Icons.more_vert" in text:
        problems.append("the top-right 'more' button is back; picture controls should "
                        "live in the bottom row")

    # Volume needs three things at once, and each of them has been reported
    # missing at some point:
    #   a) 点一下音量按钮 = 静音/解除静音（用户 2026-10-27 明确要求）
    #   b) 按钮旁边直接显示当前音量数值
    #   c) 音量条显示 0–100，内部增益 0–2.0（用户：「实际最大值为 200」）
    # 面板仍然要能打开，否则没有把音量调小调大的入口 —— 现在挂在长按上。
    if "_openVolumeSheet" not in bottom:
        problems.append("the volume button no longer reaches the volume sheet; "
                        "mute alone cannot change the level")
    if "_toggleMute" not in bottom:
        problems.append("tapping the volume button must toggle mute "
                        "(user asked for click-to-mute)")
    if "onLongPress: _openVolumeSheet" not in bottom:
        problems.append("the volume sheet lost its remaining entry point; put it "
                        "on long-press of the volume button")
    if "_volumeKey" not in bottom:
        problems.append("the volume button lost its layout-probe key")
    if "_volumeValueKey" not in bottom:
        problems.append("the volume button must show the current level next to "
                        "the icon (user asked for it)")
    if "VolumeSheet.displayOf(_player.volume)" not in bottom:
        problems.append("the volume readout must go through VolumeSheet.displayOf "
                        "so 2.0 gain reads as 100")
    value_at = bottom.find("key: _volumeValueKey")
    if value_at > 0 and "VolumeSheet.displayOf(" not in bottom[max(0, value_at - 240):value_at]:
        problems.append("the number next to the volume icon must be "
                        "VolumeSheet.displayOf(...); printing the raw gain shows "
                        "200 at the top of the range")
    # 用户按图指出「没有音量条」：底栏原来只有图标 + 数字，看不出自己在量程的
    # 哪个位置。常驻滑杆挂在 _volumeBarKey 上，且必须走显示值 0–100。
    if "_volumeBarKey" not in bottom:
        problems.append("the bottom row lost the always-on volume bar (user asked "
                        "for a visible slider, not just the number)")
    if "onChanged: _setVolumeFromBar" not in bottom:
        problems.append("the volume bar does not reach the player; dragging it "
                        "would be a no-op")
    if "onChangeEnd: _commitVolume" not in bottom:
        problems.append("the volume bar must persist the level on release; "
                        "otherwise a restart forgets it")
    if "void _setVolumeFromBar(double" not in text:
        problems.append("_setVolumeFromBar is gone; the bar and the wheel would "
                        "drift apart on the 0-100/0-2.0 mapping")
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
        if "displayMax = 100" not in sc:
            problems.append("VolumeSheet.displayMax must stay 100; the slider "
                            "shows 0-100 while the gain runs 0-2.0")
        if "static int displayOf(" not in sc or "static double volumeOf(" not in sc:
            problems.append("VolumeSheet must keep the display<->gain mapping "
                            "helpers; inlining one side drifts the two apart")
        if "divisions" not in sc:
            problems.append("VolumeSheet slider must stay discrete so a drag "
                            "lands on a stable step")
        if "max: VolumeSheet.maxVolume" in sc:
            problems.append("the slider max must be VolumeSheet.displayMax, not "
                            "maxVolume; otherwise the readout goes to 200")

    # 用户 2026-10-27 要求「鼠标滚轮控制音量」。接线在播放页的 Listener 上，
    # 换算在 VolumeSheet.wheelVolume 里 —— 两边断一头都是「滚了没反应」，
    # 而这种失效在截图里完全看不出来，只能用静态断言钉住。
    if "onPointerSignal: _onPointerSignal" not in text:
        problems.append("player_screen.dart: the wheel no longer reaches the "
                        "volume; hook onPointerSignal on the surface Listener")
    if "void _onPointerSignal(PointerSignalEvent" not in text:
        problems.append("player_screen.dart: _onPointerSignal is gone; the "
                        "mouse wheel cannot change the volume")
    if "wheelVolume(" not in text:
        problems.append("player_screen.dart: the wheel must go through "
                        "VolumeSheet.wheelVolume so the step size stays in one place")
    if sheet.exists() and "static double wheelVolume(" not in sc:
        problems.append("VolumeSheet.wheelVolume is gone; the wheel step and the "
                        "0-100/0-2.0 mapping would drift apart")

    notes.append("player layout: back button pinned top-left, picture controls in the "
                 "bottom row")

    # 用户报过：「画面设置里的三个缩放按钮不起作用」。内核的 scale_mode 只有
    # Android EGL 会读，桌面与 iOS 走 Flutter 外部纹理，没人消费它，所以缩放
    # 必须在 Dart 层做。这条护栏钉住三件事：视频区真的包了 VideoSurface、
    # 三个模式映射到三种不同的 BoxFit、全屏按钮还挂在底栏上。
    surface = ROOT / "app" / "lib" / "ui" / "widgets" / "video_surface.dart"
    if not surface.exists():
        problems.append("widgets/video_surface.dart missing; the three scale modes "
                        "would go back to being no-ops on desktop")
    else:
        vs = surface.read_text(encoding="utf-8")
        for needle, msg in (
            ("BoxFit.cover",
             "VideoSurface must map scaleModeFill to BoxFit.cover"),
            ("BoxFit.fill",
             "VideoSurface must map scaleModeStretch to BoxFit.fill"),
            ("BoxFit.contain",
             "VideoSurface must map scaleModeFit to BoxFit.contain"),
            ("clipBehavior: Clip.hardEdge",
             "VideoSurface must clip; cover overflow must not paint over the HUD"),
        ):
            if needle not in vs:
                problems.append(msg)
    if "VideoSurface(" not in text:
        problems.append("player_screen.dart no longer uses VideoSurface; the picture "
                        "scale buttons would stop having any effect")
    # 全屏不再是独立图标（用户按图指定：那个位置删掉），入口挪到「画面」
    # 按钮的单击上；这里只钉「还能触发」与「按钮会跟着换图标」。
    if "_toggleFullscreen" not in bottom:
        problems.append("the picture button no longer toggles fullscreen; the "
                        "entry disappeared with the standalone icon")
    if "Icons.fullscreen_exit" not in bottom:
        problems.append("the picture button must swap its icon while fullscreen "
                        "so the state is visible")

    # 界面统一用 MiSans：字体族没配好时，中文会落到系统 fallback 上，同一句里
    # 「音轨」「关闭」这类中文和数字来自两套字，看起来像字体坏了（用户报的）。
    pubspec = ROOT / "app" / "pubspec.yaml"
    if not pubspec.exists():
        problems.append("app/pubspec.yaml missing")
    else:
        ps = pubspec.read_text(encoding="utf-8")
        if "family: MiSans" not in ps or "assets/fonts/MiSansVF.ttf" not in ps:
            problems.append("pubspec.yaml lost the bundled MiSans font; CJK text "
                            "falls back to the system font and looks broken")
        font_file = ROOT / "app" / "assets" / "fonts" / "MiSansVF.ttf"
        if not font_file.exists():
            problems.append("app/assets/fonts/MiSansVF.ttf is missing")
    theme = ROOT / "app" / "lib" / "ui" / "theme.dart"
    if not theme.exists():
        problems.append("app/lib/ui/theme.dart missing")
    elif "fontFamily: fontFamily" not in theme.read_text(encoding="utf-8"):
        problems.append("theme.dart no longer sets fontFamily; the default UI font "
                        "would silently go back to the platform default")

    # 界面字体必须全局统一：漏一处写死的 monospace 就会在设置/统计里冒出
    # 一套完全不同的字形（用户报的是「音轨」「关闭」字体不一致）。等宽数字
    # 用 fontFeatures: tabularFigures 表达，字体仍然是 MiSans。
    for rel in ("app/lib/ui/player_screen.dart",
                "app/lib/ui/settings_screen.dart",
                "app/lib/ui/home_screen.dart",
                "app/lib/ui/browser_screen.dart"):
        f = ROOT / rel
        if not f.exists():
            continue
        ft = f.read_text(encoding="utf-8")
        if "monospace" in ft or "Courier" in ft or "'Consolas'" in ft:
            problems.append(f"{rel}: 界面字体必须统一为 MiSans；写死的等宽字体"
                            f"（monospace/Courier/Consolas）会让这一处字形和"
                            f"其它地方不一致")

    # MiSans 是 Apache License 2.0：再分发时要带着许可证与声明。仓库里放一份
    # 不够 —— 用户手上只有安装包，所以这两份还得进 assets，随包落到
    # data/flutter_assets 下。三处都要在：文件本身、pubspec 的 assets 段、
    # LICENSE 的第三方清单。
    for name in ("MiSans-LICENSE.txt", "NOTICE.txt"):
        if f"assets/fonts/{name}" not in ps:
            problems.append(f"app/pubspec.yaml no longer ships assets/fonts/{name}; "
                            f"the Apache-2.0 licence and notice would not travel "
                            f"with the installed app")
    lic = ROOT / "LICENSE"
    if not lic.exists():
        problems.append("LICENSE missing; the third-party notices live there")
    else:
        lic_text = lic.read_text(encoding="utf-8")
        # 光有「MiSans」三个字母不算数：字体文件本身就叫 MiSansVF.ttf，随便
        # 留一句路径就能蒙过去。要看的是第三方清单里那一条，所以从条目开头
        # 截一段，要求许可名与许可证文件指针都落在同一段里。
        at = lic_text.find("MiSans (")
        if at < 0:
            problems.append("LICENSE no longer lists MiSans; the bundled UI font "
                            "is Apache-2.0 and has to be credited")
        else:
            # 清单里每一条都是「名字（地址） — 许可证。」，许可名必须在标题行上；
            # 只在正文后面提一句不够，那种写法读不出这一条到底是什么许可。
            rest = lic_text[at:]
            stop = rest.find("\n\n")
            entry = rest if stop < 0 else rest[:stop]
            header = entry.split("\n", 1)[0]
            if "Apache License 2.0" not in header:
                problems.append("LICENSE mentions MiSans but its entry does not "
                                "name Apache License 2.0; readers cannot tell the "
                                "terms")
            if "MiSans-LICENSE.txt" not in entry:
                problems.append("LICENSE credits MiSans but does not point at "
                                "the licence text that ships with the app")

    # 「媒体信息」和「解码统计」原本是「画面」面板里的两个入口。用户要求
    # 并成一项：他点开看的其实是同一件事 —— 这帧是什么码流、谁在解、现在
    # 跑得好不好。护栏钉三件事：面板里只剩一行入口；统计数字由面板自己的
    # AnimatedBuilder 驱动；打开期间把 wantsStats 拉起来，否则控制器根本
    # 不发通知，数字是死的。
    dialog = ROOT / "app" / "lib" / "ui" / "widgets" / "media_info_dialog.dart"
    if not dialog.exists():
        problems.append("widgets/media_info_dialog.dart missing; media info and "
                        "decode stats would drift back into two separate entries")
    else:
        dlg = dialog.read_text(encoding="utf-8")
        for needle, msg in (
            ("AnimatedBuilder(",
             "media_info_dialog must rebuild from the player; otherwise the "
             "decode counters stay at the value read when it opened"),
            ("'媒体信息'", "media_info_dialog lost its title"),
            ("'解码'", "media_info_dialog lost the decode section"),
        ):
            if needle not in dlg:
                problems.append(msg)
    if "MediaInfoDialog(" not in text:
        problems.append("player_screen.dart no longer opens MediaInfoDialog")
    code = "\n".join(line for line in text.splitlines()
                     if not line.lstrip().startswith("//"))
    if "解码统计" in code:
        problems.append("player_screen.dart still has a separate 解码统计 entry; it "
                        "was merged into 媒体信息 and must not come back")
    if "wasWantsStats" not in text:
        problems.append("opening 媒体信息 must turn wantsStats on for the duration "
                        "and restore it afterwards; otherwise the panel would "
                        "show frozen numbers")


def check_script_encoding() -> None:
    """Every script under scripts/ and tool/ must be valid UTF-8.

    The build and capture scripts all run under one interpreter now, so the
    pure-ASCII rule that PowerShell forced on us is gone -- but a file saved in
    GBK still blows up at parse time on any machine whose locale differs, and
    that failure mode is a syntax error pointing at a line that looks fine.
    Decoding every script here turns it into a message that names the file.
    """
    bad: list[str] = []
    for folder in (ROOT / "scripts", ROOT / "tool"):
        if not folder.is_dir():
            continue
        for path in sorted(folder.rglob("*.py")):
            try:
                path.read_bytes().decode("utf-8")
            except UnicodeDecodeError as exc:
                bad.append(f"{path.relative_to(ROOT).as_posix()}: not valid UTF-8 "
                           f"({exc.reason} at byte {exc.start}); Python would fail "
                           f"to import it")

    # One interpreter for every build and capture step.  The old .ps1 / .sh
    # versions are gone; letting a new one back in reintroduces the two failure
    # modes the migration removed: PowerShell 5.1 decoding UTF-8 as the ANSI
    # code page (a Chinese comment can swallow the following line), and shell
    # pipelines resolving `find` to the MSYS build under ops_bash.  Keep the
    # guarded directories to the two the repository owns -- app/android's
    # gradlew.bat ships with Flutter and is not ours to rewrite.
    for folder in (ROOT / "scripts", ROOT / "tool"):
        if not folder.is_dir():
            continue
        for path in sorted(folder.rglob("*")):
            if path.suffix.lower() in (".ps1", ".sh", ".bat", ".cmd"):
                bad.append(f"{path.relative_to(ROOT).as_posix()}: shell script under a "
                           f"Python-only directory; rewrite it in Python")

    if bad:
        problems.extend(bad)
    else:
        notes.append("scripts: Python only under scripts/ and tool/, all UTF-8")


def check_track_selection() -> None:
    """Guard the audio/subtitle track picker.

    Three user-visible contracts have to hold together; dropping any one of them
    silently brings back the bug it fixed:

    1. "音轨" and "字幕" used to share one sheet, so opening the audio panel
       showed a header literally reading 字幕 (user report: "音频设置打开后
       标题居然写的是字幕"). They must stay two entry points.
    2. The default track must not be "whatever FFmpeg's av_find_best_stream
       returns". Multi-audio releases put the English commentary first, and that
       is exactly what the user hit. The preference model has to exist.
    3. The core does not hand the disposition flag up, so pickTrack() has to be
       reachable from player_screen.dart for the preference to have any effect.
    """
    screen = ROOT / "app" / "lib" / "ui" / "player_screen.dart"
    prefs = ROOT / "app" / "lib" / "data" / "track_prefs.dart"
    settings = ROOT / "app" / "lib" / "ui" / "settings_screen.dart"

    if not screen.exists():
        problems.append("player_screen.dart missing")
        return
    text = screen.read_text(encoding="utf-8")

    if "_openAudioSheet" not in text:
        problems.append("the audio panel is gone; 音轨 and 字幕 must be separate "
                        "sheets or the audio one shows a 字幕 header again")
    if "_SheetHeader('音轨" not in text:
        problems.append("the audio sheet lost its 音轨 header")
    if "pickTrack(" not in text:
        problems.append("player_screen.dart no longer calls pickTrack(); the "
                        "language preference would have no effect")
    if "applyTrackPreference" not in text and "_applyTrackPreferences" not in text:
        problems.append("player_screen.dart no longer applies the track preference "
                        "after opening a file")

    if not prefs.exists():
        problems.append("data/track_prefs.dart missing (language preference model)")
    else:
        pt = prefs.read_text(encoding="utf-8")
        for needle, why in (
            ("kLanguageOptions", "the settings dropdown lost its language table"),
            ("String normalizeLanguage(", "language normalisation gone; zh/chi/zho "
                                          "would stop matching each other"),
            ("int? pickTrack(", "pickTrack() missing"),
        ):
            if needle not in pt:
                problems.append(f"track_prefs.dart: {why}")

    if settings.exists():
        st = settings.read_text(encoding="utf-8")
        for title in ('首选音轨语言', '次选音轨语言', '首选字幕语言', '次选字幕语言'):
            if title not in st:
                problems.append(f"settings_screen.dart lost the {title} option")
        # 「关于」里要显示当前版本号。版本号的唯一来源是 app/pubspec.yaml，
        # 而 Flutter 不会把它带进 Dart，所以构建脚本用 --dart-define 注入；
        # 界面这一侧只要把 kAppVersion 摆出来。
        if "kAppVersion" not in st:
            problems.append("settings_screen.dart no longer shows the app version; "
                            "用户要求「设置 → 关于」里能看到当前版本号。")
        ver = ROOT / "app" / "lib" / "data" / "build_info.dart"
        if not ver.exists():
            problems.append("app/lib/data/build_info.dart missing (kAppVersion)")
        elif "'LANPLAYER_VERSION'" not in ver.read_text(encoding="utf-8"):
            problems.append("build_info.dart lost the LANPLAYER_VERSION define; the "
                            "关于 page would always read dev")
    # 构建脚本都得把版本号注进去，否则打出来的包「关于」里是 dev。
    # macOS 的 `flutter build macos` 是手工一步（build_macos_dmg.py 只打包），
    # 所以它那侧的护栏是「打完包后去 App.framework 里找版本串」，找不到就警告。
    for script in ("build_windows_desktop.py", "build_android_apk.py",
                   "ios_device_install.py"):
        path = ROOT / "scripts" / script
        if path.exists() and "LANPLAYER_VERSION=" not in path.read_text(encoding="utf-8"):
            problems.append(f"scripts/{script} does not pass LANPLAYER_VERSION=; the app "
                            f"would show a version of dev in 设置 → 关于")
    mac = ROOT / "scripts" / "build_macos_dmg.py"
    if mac.exists():
        mt = mac.read_text(encoding="utf-8")
        if "App.framework" not in mt or "LANPLAYER_VERSION" not in mt:
            problems.append("scripts/build_macos_dmg.py no longer checks the bundle for "
                            "the injected version; a dmg built without the define would "
                            "ship an app showing dev")

    notes.append("about: 设置 → 关于 shows the version injected at build time, and the "
                 "UI font is MiSans everywhere except subtitles")

    # 移动端没有输入注入：devicectl 只能截图与启停进程，打不开设置页也滚不动列表。
    # 「关于」在列表最底部，所以这两个开关是真机取证的唯一途径。
    probe = ROOT / "app" / "lib" / "data" / "probe.dart"
    if not probe.exists():
        problems.append("app/lib/data/probe.dart missing; the verification switches "
                        "would be copied into every file that needs one")
    else:
        pt = probe.read_text(encoding="utf-8")
        for name in ("'LANPLAYER_UI'", "'LANPLAYER_SETTINGS_SCROLL'"):
            if name not in pt:
                problems.append(f"probe.dart lost {name}; the mobile build could no "
                                f"longer reach that page on a real device")
    if settings.exists() and "probeFlag(" not in st:
        problems.append("settings_screen.dart no longer reads the scroll switch; the "
                        "关于 section sits at the bottom and cannot be reached by "
                        "devicectl or adb input")

    # 4. The core used to announce LP_EVENT_TRACKS with an empty "{}" right after
    #    MEDIA_INFO, and the host parses both with the same code -- so the real
    #    track list was overwritten by "no tracks at all". The subtitle sheet then
    #    read 字幕（0 条内嵌）on a file that had one subtitle stream, and only a
    #    manual track switch (which re-sends real JSON) brought the list back.
    player = ROOT / "native" / "src" / "core" / "player.c"
    if player.exists():
        ptxt = player.read_text(encoding="utf-8")
        if 'LP_EVENT_TRACKS, "{}"' in ptxt:
            problems.append("player.c emits an empty TRACKS payload on open; the "
                            "host parses it as 'this file has no tracks' and the "
                            "track sheets blank out")
        if "tracks_info" not in ptxt:
            problems.append("player.c no longer emits the media JSON with "
                            "LP_EVENT_TRACKS; the sheets would show stale tracks")

    controller = ROOT / "app" / "lib" / "core" / "player_controller.dart"
    if not controller.exists():
        problems.append("core/player_controller.dart missing")
    elif "if (map.isEmpty)" not in controller.read_text(encoding="utf-8"):
        problems.append("player_controller.dart accepts an empty MEDIA_INFO/"
                        "TRACKS payload and clears the track list with it")

    notes.append("track selection: separate audio/subtitle sheets, language "
                 "preference applied once per file")


def check_subtitle_fonts() -> None:
    """Guard the ASS font plumbing, which broke in two places at once.

    An ASS file names a family in its `Style:` line (`新宋体`, `Microsoft YaHei`)
    and an inline `\\fn` can change it mid-line.  User report: subtitles came out
    in the platform default font no matter what the file asked for.  Two links
    were missing, and both have to stay:

    1. The core parsed the inline `\\fn` tag into nothing: `apply_override()`'s
       `case 'f'` only handled `\\fs` and `\\fscx/\\fscy`, so the family name was
       skipped and the run carried no font at all.
    2. The renderer never read `style.font`, so even the cue-level family (which
       the core did parse) never reached a `TextStyle`.

    `sans-serif` is the core's placeholder for "no preference" and must not be
    requested as a family: doing so defeats the platform default and can land on
    a face without CJK glyphs.
    """
    sub = ROOT / "native" / "src" / "core" / "subtitle.c"
    if not sub.exists():
        problems.append("native/src/core/subtitle.c missing")
    else:
        st = sub.read_text(encoding="utf-8")
        if "b->st.font_name[n] = '\\0';" not in st:
            problems.append("subtitle.c lost the inline \\fn parser; an ASS line "
                            "that changes family mid-sentence would be painted "
                            "in the cue style's font")
        if "lp_str_append_json_str(out, r->font_name)" not in st:
            problems.append("subtitle.c no longer emits a per-run font name; the "
                            "host would have nothing to put in fontFamily")

        # ASS 的 \1c/\2c/\3c/\4c 各改一种颜色。曾经把通道数字直接吃掉，四条
        # 通道全写进主色：{\3c&H006C3300&} 的行会整行变成描边色、描边却还是
        # 默认黑。真实素材（勇敢的心.ass）就是这么写的。
        if "channel = *p - '0';" not in st:
            problems.append("subtitle.c dropped the colour-channel digit in "
                            "apply_override; \\3c would repaint the text instead "
                            "of the outline")
        if "b->st.outline_color = parsed;" not in st:
            problems.append("subtitle.c no longer routes \\3c to "
                            "outline_color; outlines would stay default black")
        if "b->st.back_color = parsed;" not in st:
            problems.append("subtitle.c no longer routes \\4c to back_color; "
                            "BorderStyle 3/4 boxes would lose their fill")
        if "b.runs[i].outline_color ||" not in st:
            problems.append("subtitle.c drops runs whose only override is an "
                            "outline colour; such a line falls back to the cue "
                            "style and loses the \\3c entirely")
        if ",\\\"outline_color\\\":%u" not in st:
            problems.append("subtitle.c stopped emitting a per-run "
                            "outline_color; the host cannot repaint the outline")

    subcolor = ROOT / "native" / "tests" / "lp_subcolor_test.c"
    if not subcolor.exists():
        problems.append("native/tests/lp_subcolor_test.c missing; the ASS "
                        "colour-channel routing has no regression test")

    overlay = ROOT / "app" / "lib" / "ui" / "widgets" / "subtitle_overlay.dart"
    if not overlay.exists():
        problems.append("ui/widgets/subtitle_overlay.dart missing")
    else:
        ot = overlay.read_text(encoding="utf-8")
        if ot.count("fontFamily: family,") < 2:
            problems.append("subtitle_overlay.dart stopped putting the cue or run "
                            "family into both TextStyles (the stroked and the "
                            "filled one); whatever family the file asks for is "
                            "ignored and the platform default is used")
        if ot.count("fontFamilyFallback: family == null ? null : _fallback") < 2:
            problems.append("subtitle_overlay.dart dropped the CJK fallback list "
                            "from one of the two TextStyles; a family missing on "
                            "this machine would render CJK text as boxes")
        if "trimmed.toLowerCase() == 'sans-serif'" not in ot:
            problems.append("subtitle_overlay.dart no longer treats sans-serif as "
                            "the 'no preference' placeholder")

    models = ROOT / "app" / "lib" / "data" / "models.dart"
    if models.exists():
        mt = models.read_text(encoding="utf-8")
        if "final String font; // '' = inherit from the cue style" not in mt:
            problems.append("data/models.dart lost SubtitleSpan.font; the run "
                            "level \\fn would be dropped while parsing")
        if "r.font.isNotEmpty" not in mt:
            problems.append("SubtitleLine.styled ignores r.font; a line whose "
                            "only override is a family would collapse to plain "
                            "text and lose the font")
        if "r.outlineColor != 0" not in mt:
            problems.append("SubtitleLine.styled ignores r.outlineColor; a line "
                            "whose only override is an inline \\3c collapses to "
                            "plain text and the outline goes back to the cue "
                            "colour")

    # 字号与坐标必须按**画面**算，不能按窗口算。用户报「字幕字号明显过大」：
    # 旧实现取 `MediaQuery.sizeOf(context).height`（整个窗口）直接当 em 用，
    # 于是 ①窗口留黑边时画面比窗口小、②Text 层还会乘一次 textScaler 1.3 ——
    # 两层叠起来把字幕放大约 1.5 倍。
    # 另外 ASS 的 Fontsize **就是 em**，不需要再折算成「字面高度」。曾经这里
    # 乘过 1/1.26，结果整块字幕比 libass 小 20%；用同一句、同一 PlayResY、
    # 同一画面高度与 libass 逐档量墨迹高（20/288、52/480、52/1080、30/1080、
    # 90/1080）后确认系数取 1，偏差在 2% 以内。
    if overlay.exists():
        if "MediaQuery.sizeOf(context).height" in ot:
            problems.append(
                "subtitle_overlay.dart sizes text from the window height "
                "again; ASS font size is a fraction of the *picture* height, "
                "so letterboxed windows make subtitles too big")
        if "static const double scriptToEm = 1.0;" not in ot:
            problems.append(
                "subtitle_overlay.dart: scriptToEm must stay 1.0 — ASS "
                "Fontsize is already an em size, and any other factor makes "
                "subtitles disagree with libass by that amount")
        if "static Rect videoRect(" not in ot:
            problems.append(
                "subtitle_overlay.dart: the picture rectangle helper is gone; "
                "subtitles are positioned against the window again")
        if "MediaQuery.textScalerOf(context).scale(10)" not in ot:
            problems.append(
                "subtitle_overlay.dart stopped compensating for the system "
                "text scale; main.dart clamps it to 1.3, which alone inflates "
                "subtitles by 30%")

    screen = ROOT / "app" / "lib" / "ui" / "player_screen.dart"
    if screen.exists() and "videoAspectRatio: _videoAspectRatio" not in \
            screen.read_text(encoding="utf-8"):
        problems.append(
            "player_screen.dart no longer passes the picture aspect ratio to "
            "SubtitleOverlay; the overlay would fall back to 16:9 and "
            "misplace subtitles on non-16:9 video")

    if models.exists():
        if "final double playResY;" not in mt:
            problems.append(
                "data/models.dart lost SubtitleStyle.playResY; margins and "
                "outlines are in script units and cannot become pixels "
                "without it")
        if "final int borderStyle;" not in mt:
            problems.append(
                "data/models.dart lost SubtitleStyle.borderStyle; ASS "
                "BorderStyle 3 draws an opaque box instead of an outline")
        if "final SubtitleStyle? style;" not in mt:
            problems.append(
                "data/models.dart: SubtitleLine lost its own style; two "
                "dialogues on screen at once would be painted with the last "
                "hit's colour and weight")

    # 每行带自己的样式：内核按行下发 `style`，渲染层必须真的用它。旧实现
    # 一律读 `cue.style`（取最后一条命中的 cue），于是同一时刻三条不同
    # Style: 的字幕被画成一模一样（用户报的「样式渲染依然存在问题」）。
    if overlay.exists():
        if "SubtitleStyle _styleOf(SubtitleLine line)" not in ot:
            problems.append(
                "subtitle_overlay.dart: the per-line style lookup is gone; "
                "every dialogue would be painted with one shared style")
        if "line.style ?? cue.style" not in ot:
            problems.append(
                "subtitle_overlay.dart: per-line styles no longer fall back to "
                "the cue style; plain SRT cues would lose their look")
        if "class _Placement" not in ot:
            problems.append(
                "subtitle_overlay.dart: lines with different margins or "
                "\\pos are no longer grouped separately; simultaneous "
                "dialogues would be stacked on top of each other")

    core = ROOT / "native" / "src" / "core" / "subtitle.c"
    if core.exists():
        ct = core.read_text(encoding="utf-8")
        if ct.count(",\\\"style\\\":{") < 2:
            problems.append(
                "native/src/core/subtitle.c: append_runs_json() stopped "
                "emitting a per-line style; the host cannot paint two "
                "dialogues differently")
        if "play_res_y" not in ct:
            problems.append(
                "native/src/core/subtitle.c stopped reporting play_res_y; "
                "margins and outlines are script units and cannot be turned "
                "into pixels without it")
        if 'while (*nm == ' not in ct:
            problems.append(
                "native/src/core/subtitle.c: the Style: name is no longer "
                "trimmed; ' Default' never matches and every line falls back "
                "to the first style in the file")
        # ass_color() must read colours as unsigned: every value with an alpha
        # byte is above LONG_MAX on Windows, and strtol clamps it to LONG_MAX,
        # which turned &H80202020 into half-transparent white.
        if "strtoul(digits" not in ct or "strtoul(v" not in ct:
            problems.append(
                "native/src/core/subtitle.c: ass_color() must parse with "
                "strtoul; strtol overflows on 32-bit long and every colour "
                "with an alpha byte collapses to half-transparent white")

    notes.append("subtitle fonts: inline \\fn parsed, cue and run families reach "
                 "fontFamily with a CJK fallback")
    notes.append("subtitle sizing: picture-relative size, glyph->em conversion, "
                 "textScaler compensation, calibrated against libass")
    notes.append("subtitle styles: per-line style from the core, own margins "
                 "and \\pos per dialogue, BorderStyle 3 boxes")


def check_subtitle_advanced() -> None:
    r"""Guard the four ASS features that used to be parsed and then dropped.

    	 animations, \clip clipping, \p vector drawings and \k karaoke were all
    recognised by the tag scanner and then thrown away, so a file that leans on
    them looked like plain centred text.  Each feature needs a link from the
    core's parser all the way to the painter; every link can regress on its own.
    """
    core = ROOT / "native" / "src" / "core" / "subtitle.c"
    header = ROOT / "native" / "src" / "player_internal.h"
    test = ROOT / "native" / "tests" / "lp_subanim_test.c"
    if not test.exists():
        problems.append(
            "native/tests/lp_subanim_test.c is missing; nothing keeps the "
            "ASS advanced tags from being dropped again")
    if header.exists():
        ht = header.read_text(encoding="utf-8")
        for token, why in (
            ("LP_SUB_ANIM_COLOR", "the animation field mask"),
            ("typedef struct LpSubAnim", "the animation record"),
            ("typedef struct LpSubPathPoint", "the drawing point list"),
            ("int karaoke_kind;", "the karaoke slice"),
            ("double karaoke_start_ms;", "the karaoke slice start"),
            ("int clip_on;", "the clip rectangle"),
        ):
            if token not in ht:
                problems.append(
                    f"player_internal.h lost {token} ({why}); a subtitle "
                    f"using it would silently fall back to plain text")
    if core.exists():
        ct = core.read_text(encoding="utf-8")
        for token, why in (
            ("anim_window", "the animation window parser"),
            ("path_consume", "the drawing path command parser"),
            ("sub_rich_flush_drawing", "turning a drawn path into a run"),
            ("case 'k':", "the karaoke tag"),
            ("case 't':", "the animation tag"),
            ("karaoke_pending_kind", "handing a karaoke slice to the next run"),
            (',\\"anims\\":[', "emitting animations to the host"),
            (',\\"path\\":[', "emitting a drawing path to the host"),
        ):
            if token not in ct:
                problems.append(
                    f"native/src/core/subtitle.c lost {token} ({why})")
        # alpha 的字节序：单字节的 `&H80&` 曾经被当成 32 位整色右移读取，
        # 结果恒 0，所有淡入都是全不透明。
        if "raw > 0xFFul" not in ct:
            problems.append(
                "native/src/core/subtitle.c: the alpha reader no longer "
                "special-cases one-byte values; every fade-in would stay "
                "fully opaque")
        # 纯白是最常见的动画目标色（卡拉 OK 唱到的字变成白色）。曾经把
        # `\c&HFFFFFF&` 归一成「继承」，于是白色动画完全不生效。
        if "parsed == 0xFFFFFFFF" in ct:
            problems.append(
                "native/src/core/subtitle.c: a pure white colour is being "
                "folded into 'inherit' again; colour animations to white "
                "would do nothing")
        # `\p0` 之后必须把 drawing scale 清掉，否则后面的文本 run 继承
        # 绘图状态，整行被当成图形吞掉。
        if "b->st.drawing_scale = 0;" not in ct:
            problems.append(
                "native/src/core/subtitle.c: the end of a drawing no longer "
                "resets drawing_scale; the text after it would disappear")
        # 只有 `\p1` 图形、没有文字的 Dialogue 也是有效字幕（wipe 揭示、
        # 无字版式）。若判据只看文本，这类行会整条消失。
        if "has_drawing_runs" not in ct:
            problems.append(
                "native/src/core/subtitle.c: nothing checks for drawing-only "
                "cues any more; a line whose text is empty would be dropped")
        # 卡拉 OK 的「还没唱到」用的是 SecondaryColour，不是半透明的主色。
        if "secondary_color" not in ct:
            problems.append(
                "native/src/core/subtitle.c: SecondaryColour is no longer "
                "parsed; karaoke syllables would all start at the wrong "
                "colour")

    models = ROOT / "app" / "lib" / "data" / "models.dart"
    anim = ROOT / "app" / "lib" / "data" / "subtitle_anim.dart"
    overlay = ROOT / "app" / "lib" / "ui" / "widgets" / "subtitle_overlay.dart"
    if not anim.exists():
        problems.append(
            "app/lib/data/subtitle_anim.dart is missing; animations and "
            "karaoke have no evaluator")
    else:
        at = anim.read_text(encoding="utf-8")
        for token, why in (
            ("static double progress(", "the animation progress curve"),
            ("static ResolvedSpan resolve(", "applying animations to a run"),
            ("static double karaokeFill(", "the karaoke fill amount"),
            ("1.0 / accel", "the ASS acceleration exponent"),
        ):
            if token not in at:
                problems.append(
                    f"app/lib/data/subtitle_anim.dart lost {token} ({why})")
    if models.exists():
        mt = models.read_text(encoding="utf-8")
        for token, why in (
            ("class SubtitleAnim", "the animation model"),
            ("class SubtitlePathPoint", "the drawing model"),
            ("final int nowUs;", "the cue-relative clock the animations need"),
            ("bool get clipOn", "the clip rectangle accessor"),
            ("final int secondaryColor;", "the karaoke pre-sung colour"),
        ):
            if token not in mt:
                problems.append(f"data/models.dart lost {token} ({why})")
        # 只带高级特性的行也必须算「有内联样式」，否则整行退回纯文本，
        # alpha / clip / 绘图 / 卡拉 OK 全部失效。
        styled = mt.split("bool get styled", 1)[-1].split(";", 20)
        styled_txt = "".join(styled[:20])
        for token in ("r.alpha < 1.0", "r.karaokeKind != 0",
                      "r.anims.isNotEmpty", "r.clipOn", "r.drawingScale > 0"):
            if token not in styled_txt:
                problems.append(
                    f"data/models.dart: SubtitleLine.styled ignores {token}; "
                    f"a line that only carries an advanced feature would "
                    f"lose it")
    if overlay.exists():
        ot = overlay.read_text(encoding="utf-8")
        for token, why in (
            ("_karaokeColor(", "the karaoke colour ramp"),
            ("class _DrawingsPainter", "the vector drawing painter"),
            ("class _ClipRelative", "the clip rectangle"),
            ("SubtitleAnimator.resolve(", "the per-frame animation lookup"),
            ("style.secondaryColor", "the karaoke pre-sung colour"),
            ("_drawingsWithPlacement(", "drawings following their line anchor"),
            # 横向换算必须用画面实际宽度。用 PlayResX / PlayResY 乘高度推出来
            # 只在脚本分辨率恰好等于视频宽高比时才对，2.39:1 的电影会偏十几个
            # 百分点，裁剪框整体左移、该藏的字露出来。
            ("final videoWidth = video.width;",
             "the clip rectangle has to use the picture width, not a "
             "PlayResX/PlayResY guess"),
            # 裁剪矩形活在覆盖层坐标系里，块已经被摆进画面矩形，所以偏移里
            # 必须带上 video.left / video.top。少了这一项，视频上下留黑边时
            # 裁剪窗整体上移，整行字幕凭空消失（竖屏 iPad 上就是这个现象）。
            ("video.left + clip[0]",
             "the clip rectangle has to be offset into the overlay "
             "coordinates"),
            ("video.top + clip[1]",
             "the clip rectangle has to be offset into the overlay "
             "coordinates"),
        ):
            if token not in ot:
                problems.append(
                    f"subtitle_overlay.dart lost {token} ({why})")

    clip_test = ROOT / "app" / "test" / "subtitle_clip_test.dart"
    if not clip_test.exists():
        problems.append(
            "app/test/subtitle_clip_test.dart is missing; the clip rectangle "
            "would only be checked by eye")

    notes.append("subtitle advanced: animations, clip rectangles, vector "
                 "drawings and karaoke are parsed, shipped and painted")


def check_subtitle_sheet_selection() -> None:
    """Guard that picking a subtitle actually shows as picked.

    User report: tapping a sidecar subtitle loaded the file, but the sheet kept
    showing the previous selection.  Three links had to hold for the row to
    update, and each of them can regress on its own:

    1. `lp_player_add_subtitle()` has to select the track it just loaded and
       emit `LP_EVENT_TRACKS`; without the event the host never rebuilds.
    2. The sheet must rebuild from the live controller instead of a
       `_player.media` snapshot taken before it opened.
    3. The sheet must list every track the core reports (embedded *and* already
       loaded sidecar files) in the radio group, and only list not-yet-loaded
       files in the section below.  Splitting by "embedded vs external" instead
       drops auto-loaded sidecar tracks out of the radio group entirely.
    """
    player = ROOT / "native" / "src" / "core" / "player.c"
    if player.exists():
        pt = player.read_text(encoding="utf-8")
        marker = pt.find("int32_t lp_player_add_subtitle")
        if marker < 0:
            problems.append("native/src/core/player.c lost "
                            "lp_player_add_subtitle()")
        else:
            body = pt[marker:marker + 1600]
            if "lp_subtitle_select(p, index)" not in body:
                problems.append("lp_player_add_subtitle() no longer selects the "
                                "track it just loaded; a host that adds a sidecar "
                                "file would keep showing the old subtitle")
            if "LP_EVENT_TRACKS" not in body:
                problems.append("lp_player_add_subtitle() no longer emits "
                                "LP_EVENT_TRACKS; the subtitle sheet would not "
                                "see the new track until something else fires")

    screen = ROOT / "app" / "lib" / "ui" / "player_screen.dart"
    if not screen.exists():
        problems.append("app/lib/ui/player_screen.dart missing")
    else:
        st = screen.read_text(encoding="utf-8")
        if "AnimatedBuilder(\n              animation: _player," not in st:
            problems.append("player_screen.dart's track sheet stopped listening "
                            "to the controller; the selection would be frozen at "
                            "whatever it was when the sheet opened")
        if "pendingSubtitleFiles(" not in st:
            problems.append("player_screen.dart no longer filters the sidecar "
                            "section through pendingSubtitleFiles(); a file that "
                            "is already a track would show up twice")
        if "for (final s in info.subtitles)" not in st:
            problems.append("player_screen.dart's radio group no longer walks "
                            "every track the core reports; an auto-loaded sidecar "
                            "subtitle would have no row at all")

    models = ROOT / "app" / "lib" / "data" / "models.dart"
    if models.exists():
        mt = models.read_text(encoding="utf-8")
        for needle, why in (
            ("int externalSubtitleIndexOf(", "look up a loaded sidecar by name"),
            ("List<T> pendingSubtitleFiles<T>(", "list only not-yet-loaded files"),
            ("int selectedSubtitleIndex(", "read the selected track"),
        ):
            if needle not in mt:
                problems.append(f"data/models.dart lost {needle.rstrip('(')}; "
                                f"the sheet needs it to {why}")

    notes.append("subtitle sheet: adding a sidecar selects it and emits TRACKS, "
                 "one row per track, no duplicate file rows")


def check_android_playback() -> None:
    """Guard the six defects found while bringing up Android playback.

    Every one of them was invisible on Windows and macOS, and every one of them
    came back from a plausible-looking simplification, so they get static
    guards. The whole Android chain was verified on a real phone only through
    adb logs; without these assertions the next cleanup pass can silently
    reintroduce a black screen or a frozen UI and nothing on this machine would
    notice until someone plugs in a phone again.

    1. media_codec_decoder.c: MediaCodec wants Annex-B, FFmpeg hands out AVCC
       for mp4. Without the conversion the decoder accepts every packet
       (queueInputBuffer returns AMEDIA_OK) and never emits a frame.
    2. Same file: csd-0/csd-1 must be the SPS/PPS split out of the avcC record,
       not the raw record; Qualcomm's decoder drops the stream otherwise.
    3. video.c: a hardware decoder reports LP_ERR_AGAIN (-7) while FFmpeg's
       software path reports AVERROR(EAGAIN) (-11). Sharing one `again` test
       frees the packet on the hardware path -> zero frames.
    4. video.c / audio.c: after lp_pq_abort the queue still holds packets, so
       lp_pq_eof stays false; the decode thread must also exit on
       lp_pq_aborted(), otherwise pthread_join in a synchronous FFI call hangs
       the Dart UI thread (the "audio track switch freezes the app" report).
    5. demux.c: a failed lp_pq_put during a track switch is not end of file.
       Breaking out of the demux loop there leaves nobody feeding the queues.
    6. player.c: the tick thread must outlive close/open. Keying its loop off
       abort_request kills it on the first file change, and then the second
       file never reports POSITION or ENDED.
    """
    dec = ROOT / "native" / "src" / "platform" / "android" / "media_codec_decoder.c"
    vid = ROOT / "native" / "src" / "core" / "video.c"
    aud = ROOT / "native" / "src" / "core" / "audio.c"
    dem = ROOT / "native" / "src" / "core" / "demux.c"
    ply = ROOT / "native" / "src" / "core" / "player.c"

    for path in (dec, vid, aud, dem, ply):
        if not path.exists():
            problems.append(f"{path.relative_to(ROOT)} missing")
            return

    dtext = dec.read_text(encoding="utf-8")
    for needle, why in (
        ("to_annexb(", "the AVCC -> Annex-B conversion is gone; MediaCodec would "
                       "accept every packet and decode nothing (black screen)"),
        ("apply_csd(", "the csd-0/csd-1 split from the avcC record is gone; "
                       "Qualcomm drops the stream with 'The CSD is not calculated'"),
        ("needs_annexb(", "nothing decides whether a stream is AVCC any more, so "
                          "either Annex-B input gets mangled or AVCC is not converted"),
    ):
        if needle not in dtext:
            problems.append(f"media_codec_decoder.c: {why}")

    vtext = vid.read_text(encoding="utf-8")
    if "lp_pq_aborted(" not in vtext:
        problems.append("video.c no longer exits on lp_pq_aborted(); stopping the "
                        "video thread would block in pthread_join whenever the "
                        "queue still holds packets")
    if "LP_ERR_AGAIN" not in vtext:
        problems.append("video.c stopped distinguishing LP_ERR_AGAIN from "
                        "AVERROR(EAGAIN); the hardware path would free every "
                        "packet and decode nothing")

    atext = aud.read_text(encoding="utf-8")
    if "lp_pq_aborted(" not in atext:
        problems.append("audio.c no longer exits on lp_pq_aborted(); switching "
                        "tracks would hang the synchronous FFI call and freeze "
                        "the whole UI")
    # Mutex ownership: the ring's lock has to outlive open/close because the tick
    # thread reads the audio clock every 20 ms.
    ring = ROOT / "native" / "src" / "core" / "audio_ring.c"
    rtext = ring.read_text(encoding="utf-8") if ring.exists() else ""
    if "lp_ring_setup(" not in rtext or "lp_ring_teardown(" not in rtext:
        problems.append("audio_ring.c lost lp_ring_setup/lp_ring_teardown; "
                        "destroying the ring mutex on close makes the tick thread "
                        "hit a destroyed mutex (FORTIFY abort on Android)")

    demtext = dem.read_text(encoding="utf-8")
    # The original shape: hand the queue the packet, and when it refuses, set
    # pkt = NULL (the queue already freed it) and break out of the read loop.
    if "pkt = NULL; /* the queue freed it on failure" in demtext:
        problems.append("demux.c drops out of the read loop when a queue refuses "
                        "a packet; a track switch aborts that queue, so the demux "
                        "thread would exit and nobody feeds the decoders again")
    elif demtext.count("lp_pq_put(&p->") and "lp_is_abort(p)" not in demtext:
        problems.append("demux.c no longer checks lp_is_abort() after a rejected "
                        "lp_pq_put; the retry would spin forever on a real stop")

    ptext = ply.read_text(encoding="utf-8")
    if "quit_request" not in ptext:
        problems.append("player.c: the tick thread lost its quit_request flag; "
                        "keying it off abort_request kills it on the first file "
                        "change and the next file never reports ENDED")
    if "atomic_load(&p->audio.eof)" not in ptext:
        problems.append("player.c: lp_master_clock_us no longer checks audio.eof; "
                        "once the audio ring drains the clock freezes and the last "
                        "frames are never presented")

    log = ROOT / "native" / "src" / "util" / "lp_log.c"
    if log.exists():
        ltext = log.read_text(encoding="utf-8")
        # Match the call site, not the explanatory comment that quotes the old
        # shape verbatim.
        if '"LanPlayer/%s", tag ?' in ltext:
            problems.append("lp_log.c passes the module name as the __android_log_print "
                            "format string; every logcat line loses its message body")
        if '"%s: %s", tag' not in ltext:
            problems.append("lp_log.c no longer prints '<module>: <message>' on "
                            "Android; adb logcat -s LanPlayer would show no modules")

    # Android 13+ splits storage into per-type media permissions and no longer
    # grants READ_MEDIA_VIDEO on install: without a runtime request the local
    # browser lists an empty folder, which reads as a bug in the browser.
    manifest = ROOT / "app" / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
    kt = ROOT / "app" / "android" / "app" / "src" / "main" / "kotlin" / "dev" / "lanplayer" / "app" / "MainActivity.kt"
    perm = ROOT / "app" / "lib" / "ui" / "media_permission.dart"
    mtext = manifest.read_text(encoding="utf-8") if manifest.exists() else ""
    ktext = kt.read_text(encoding="utf-8") if kt.exists() else ""
    if 'android.permission.READ_MEDIA_VIDEO' not in mtext:
        problems.append("AndroidManifest.xml no longer declares READ_MEDIA_VIDEO; "
                        "the local browser cannot list Movies on Android 13+")
    if "requestPermissions(" not in ktext or "lanplayer/permissions" not in ktext:
        problems.append("MainActivity.kt lost the runtime media permission request; "
                        "the declared permission is never granted, so a fresh "
                        "install browses an empty folder")
    if "hasMediaPermission" not in ktext:
        problems.append("MainActivity.kt lost hasMediaPermission; asking again on "
                        "every browse would pop the dialog repeatedly")
    if not perm.exists():
        problems.append("app/lib/ui/media_permission.dart is missing; nothing asks "
                        "for the media permission before browsing local storage")
    else:
        ptext2 = perm.read_text(encoding="utf-8")
        # Match the wire name, not just the Dart method: renaming one side of the
        # channel leaves a silently dead permission request.
        if "'requestMedia'" not in ptext2:
            problems.append("media_permission.dart no longer calls the "
                            "'requestMedia' channel method (MainActivity exposes "
                            "that exact name)")
        if '"requestMedia" ->' not in ktext:
            problems.append("MainActivity.kt no longer handles the 'requestMedia' "
                            "channel call from media_permission.dart")

    notes.append("android playback: annex-b + csd split, queue-abort exits, demux "
                 "retries, tick outlives close, runtime media permission")


def check_playback_profiles() -> None:
    """Every hardware decoder must refuse 10-bit H.264 up front.

    None of the three shipping hwaccels implements High 10 / High 4:2:2, and a
    rejection is not how it fails: libavcodec falls back to software *inside* the
    hardware context, where thread_count is pinned to 1 because the codec still
    owns a device.  Measured on all three platforms with real SMB files, a
    1080p 10-bit H.264 then decodes at far below real time while the audio
    clock keeps running, so the picture freezes on the first frame and only
    starts again once the queue is thousands of packets deep.  The fix is the
    same profile guard in every backend; dropping it from one platform brings
    the freeze back on that platform only, which is why this is checked per file.
    """
    backends = {
        "native/src/platform/win32/d3d11va_decoder.c": "D3D11VA",
        "native/src/platform/apple/videotoolbox_decoder.c": "VideoToolbox",
        "native/src/platform/android/media_codec_decoder.c": "MediaCodec",
    }
    for rel, name in backends.items():
        path = ROOT / rel
        if not path.exists():
            problems.append(f"{rel} is gone; the {name} profile guard lives there")
            continue
        text = path.read_text(encoding="utf-8")
        if "profile_needs_software(" not in text:
            problems.append(f"{rel} lost profile_needs_software(); {name} would be "
                            "handed 10-bit H.264 and would freeze on the first frame")
        elif "AV_PROFILE_H264_HIGH_10" not in text:
            problems.append(f"{rel}: profile_needs_software() no longer names "
                            "AV_PROFILE_H264_HIGH_10, the profile that stalls")
        if "profile_needs_software(cfg->codec_id, cfg->par->profile)" not in text:
            problems.append(f"{rel} no longer calls profile_needs_software() from "
                            "lp_hw_decoder_init(); the guard would never run")

    # 10-bit HEVC is a *different* failure on each platform, so the guard is not
    # shared: VideoToolbox decodes it at 2-9 fps (audio clock runs away, the
    # picture freezes), MediaCodec accepts every input buffer and dequeues none
    # (Qin:456 DQout:0/456 Render:0 -- a black frame with a walking progress
    # bar), and D3D11VA handles it fine, so Windows must NOT refuse it.
    hevc = {
        "native/src/platform/apple/videotoolbox_decoder.c": "VideoToolbox",
        "native/src/platform/android/media_codec_decoder.c": "MediaCodec",
    }
    for rel, name in hevc.items():
        path = ROOT / rel
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        if "AV_PROFILE_HEVC_MAIN_10" not in text:
            problems.append(f"{rel}: {name} no longer refuses 10-bit HEVC; it "
                            "decodes at a few fps or not at all and the picture freezes")
    win = ROOT / "native" / "src" / "platform" / "win32" / "d3d11va_decoder.c"
    if win.exists() and "AV_PROFILE_HEVC_MAIN_10" in win.read_text(encoding="utf-8"):
        problems.append("d3d11va_decoder.c now refuses 10-bit HEVC, but D3D11VA "
                        "decodes it at full speed on this machine -- that would "
                        "silently drop hardware decoding for 51 shipping files")

    # Windows: the hwaccel can still hand back a system-memory frame mid-stream
    # (the software fallback happens after init for some bitstreams). Downloading
    # such a frame returns EINVAL and every picture is thrown away, so present()
    # must draw it directly instead.
    d3d = ROOT / "native" / "src" / "platform" / "win32" / "d3d11va_decoder.c"
    if d3d.exists() and "AV_PIX_FMT_D3D11 && !hf->hw_frames_ctx" not in d3d.read_text(encoding="utf-8"):
        problems.append("d3d11va present() no longer special-cases system-memory "
                        "frames; av_hwframe_transfer_data returns EINVAL for them "
                        "and every frame is dropped")

    # NAL framing must be decided by walking the whole length chain, not by
    # peeking at 4 bytes.  A 485-byte slice whose length field is 00 00 01 e5
    # starts with 00 00 01 and looks exactly like an Annex-B start code; the old
    # check rewrote it as Annex-B, VideoToolbox then answered
    # kVTVideoDecoderBadDataErr (-12909) for every following frame and the file
    # played at 0.00 fps with one decoded frame.
    nal = ROOT / "native" / "src" / "core" / "nal.c"
    if not nal.exists():
        problems.append("native/src/core/nal.c is gone; both hw decoders need it to "
                        "tell length-prefixed packets from Annex-B ones")
    else:
        nal_text = nal.read_text(encoding="utf-8")
        if "lp_nal_is_annexb(" not in nal_text:
            problems.append("native/src/core/nal.c lost lp_nal_is_annexb()")
        elif "chain_is_valid(" not in nal_text:
            problems.append("nal.c no longer validates the whole length chain; "
                            "peeking at the first 4 bytes mistakes 00 00 01 e5 "
                            "for a start code and corrupts every slice")
    callers = {
        "native/src/platform/apple/videotoolbox_decoder.c": "VideoToolbox to_avcc()",
        "native/src/platform/android/media_codec_decoder.c": "MediaCodec needs_annexb()",
    }
    for rel, name in callers.items():
        path = ROOT / rel
        if not path.exists():
            continue
        if "lp_nal_is_annexb(" not in path.read_text(encoding="utf-8"):
            problems.append(f"{name} in {rel} no longer calls lp_nal_is_annexb(); "
                            "length-prefixed packets that begin 00 00 01 would be "
                            "converted as if they were Annex-B and decode to nothing")
    for rel in ("native/CMakeLists.txt", "scripts/build_windows.py",
                "scripts/build_apple_deps.py"):
        path = ROOT / rel
        if path.exists() and "nal.c" not in path.read_text(encoding="utf-8"):
            problems.append(f"{rel} no longer compiles native/src/core/nal.c; "
                            "the decoders would fail to link")

    notes.append("playback profiles: hwaccel refuses 10-bit H.264 on all three "
                 "platforms, 10-bit HEVC on Apple + Android only, d3d11va draws "
                 "software frames instead of dropping them")
    notes.append("nal framing: start code vs length prefix decided by walking the "
                 "whole chain, shared by VideoToolbox and MediaCodec")

    video_c = ROOT / "native" / "src" / "core" / "video.c"
    if video_c.exists():
        text = video_c.read_text(encoding="utf-8")
        if "frames_decoded == 0" not in text:
            problems.append("native/src/core/video.c lost the start-up exemption in "
                            "wait_for_presentation(); the master clock starts before "
                            "the decoder is ready, so the first two seconds get "
                            "dropped as if they were late")
        if "-500000" not in text:
            problems.append("native/src/core/video.c drops frames later than 250 ms "
                            "again; hardware decoders legitimately run 200-300 ms "
                            "behind the clock, so that threshold throws away good frames")
    vt_c = ROOT / "native" / "src" / "platform" / "apple" / "videotoolbox_decoder.c"
    if vt_c.exists() and "LP_VT_QUEUE 32" not in vt_c.read_text(encoding="utf-8"):
        problems.append("native/src/platform/apple/videotoolbox_decoder.c shrank "
                        "LP_VT_QUEUE below 32; VideoToolbox decodes ahead of the "
                        "clock and a shallow queue makes push_frame() drop live frames")
    notes.append("late frames: a 500 ms threshold plus no drops before the first "
                 "frame keeps hardware decoder latency from looking like lag")


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
    deployment targets must match what scripts/build_apple_deps.py produces.
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

    # Deployment targets must agree with build_apple_deps.py, otherwise the
    # static archives are newer than the app and the link fails.
    # The script reads them with os.environ.get("MIN_IOS", "13.0"), so pull the
    # fallback out of that call rather than the raw right-hand side.
    script = ROOT / "scripts" / "build_apple_deps.py"
    min_ios = min_macos = None
    if script.exists():
        for line in script.read_text(encoding="utf-8").splitlines():
            m = re.search(r'os\.environ\.get\(\s*"(MIN_IOS|MIN_MACOS)"\s*,\s*"([0-9.]+)"', line)
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
                        f"(build_apple_deps.py builds for {min_ios})")
    if not macos_podfile.exists():
        problems.append("app/macos/Podfile missing; flutter build macos refuses to run")
    elif min_macos and f"platform :osx, '{min_macos}'" not in macos_podfile.read_text(encoding="utf-8"):
        problems.append(f"app/macos/Podfile does not declare platform :osx, '{min_macos}' "
                        f"(build_apple_deps.py builds for {min_macos})")

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
    # Every place that can carry the value has to agree with build_apple_deps.py.
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

    # iOS only plays sound while the ring/silent switch is on silent if the
    # audio session is left at its default `ambient` category: the system
    # mutes the app, and backgrounding stops it outright. Setting `.playback`
    # once at launch is what makes the iPad actually audible — the missing
    # call was reported as "no sound on iPad while the picture plays".
    delegate = APP / "ios" / "Runner" / "AppDelegate.swift"
    if delegate.exists():
        swift = delegate.read_text(encoding="utf-8")
        for needle, why in (
            ("import AVFoundation", "AppDelegate no longer imports AVFoundation, "
                                    "so it cannot touch the audio session"),
            ("AVAudioSession.sharedInstance()", "AppDelegate no longer reaches "
                                                "AVAudioSession; iOS then keeps the "
                                                "ambient category and silences playback"),
            (".playback", "the audio session no longer asks for the .playback "
                          "category; the ring/silent switch would mute the app"),
            ("setActive(true)", "the audio session is never activated, so audio "
                                "stays silent after a phone call or backgrounding"),
        ):
            if needle not in swift:
                problems.append(f"app/ios/Runner/AppDelegate.swift: {why}")
        if "configureAudioSession()" not in swift.split("func application(", 1)[-1] \
                .split("func configureAudioSession")[0]:
            problems.append("app/ios/Runner/AppDelegate.swift: didFinishLaunching "
                            "must call configureAudioSession() before the engine runs")

    # The audio session alone does not make sound: AudioQueue keeps its own
    # volume parameter, and switching the session category resets it to the
    # system media volume. On the iPad that came out as 0 while the queue was
    # happily consuming PCM, which reads exactly like "the decoder produces
    # nothing". Pin the floor and the first-frame evidence so a later cleanup
    # cannot quietly drop them again.
    sink = ROOT / "native" / "src" / "platform" / "apple" / "coreaudio_sink.c"
    if sink.exists():
        sc = sink.read_text(encoding="utf-8")
        if "kAudioQueueParam_Volume" not in sc:
            problems.append("native/src/platform/apple/coreaudio_sink.c no longer "
                            "raises kAudioQueueParam_Volume out of zero; the iPad "
                            "then plays with a silent queue while decoding fine")
        if "AudioQueueSetParameter" not in sc:
            problems.append("native/src/platform/apple/coreaudio_sink.c must call "
                            "AudioQueueSetParameter to lift the queue volume")
        if "first cb got" not in sc:
            problems.append("native/src/platform/apple/coreaudio_sink.c dropped the "
                            "first-callback log; without it a silent iPad cannot be "
                            "told apart from a decoder that never ran")
    else:
        problems.append("native/src/platform/apple/coreaudio_sink.c missing")

    if not any(p.startswith(("app/ios/Podfile", "app/macos/Podfile",
                             "app/macos/Runner.xcodeproj", "app/ios/Runner/AppDelegate",
                             "native/src/platform/apple/coreaudio_sink.c"))
               for p in problems):
        notes.append(f"apple wiring: podspecs link liblanplayer.a, Podfiles declare "
                     f"iOS {min_ios or '?'} / macOS {min_macos or '?'}")
        notes.append("apple audio: playback category + AudioQueue volume floor")


def check_windows_playback_paths() -> None:
    """Guard the Windows GPU surface output and the WASAPI audio sink.

    Both replaced a working-but-slow path (a CPU download plus sws_scale for
    the picture, waveOut for the sound), and both break silently when a piece
    goes missing: a decoder that stops handing over the D3D11 texture still
    plays, just at CPU speed; a sink that loses its fallback still plays on
    machines with a working WASAPI device and goes silent on the others.
    """
    out = ROOT / "native" / "src" / "platform" / "win32" / "d3d11_output.c"
    plat = ROOT / "native" / "src" / "platform" / "win32" / "win32_platform.c"
    dec = ROOT / "native" / "src" / "platform" / "win32" / "d3d11va_decoder.c"
    plugin = ROOT / "packages" / "lanplayer_video" / "windows" / "lanplayer_video_plugin.cpp"
    build = ROOT / "scripts" / "build_windows.py"

    if not out.exists():
        problems.append("native/src/platform/win32/d3d11_output.c is missing; "
                        "the D3D11 shared surface the Flutter host samples "
                        "lives there")
    else:
        oc = out.read_text(encoding="utf-8")
        for needle, why in (
            ("VideoProcessorBlt", "NV12 frames are converted on the GPU with "
                                  "the video processor, not with sws_scale"),
            ("DXGI_FORMAT_B8G8R8A8_UNORM", "the shared surface is BGRA, which "
                                           "the texture bridge reads without a "
                                           "per-pixel swizzle"),
            ("CreateTexture2D", "the shared surface still has to be created"),
            ("IDXGIResource_GetSharedHandle", "the host needs a shareable "
                                              "handle, not a bare texture"),
            ("lp_win32_gpu_surface", "the exported surface entry point is what "
                                     "the plugin calls each frame"),
        ):
            if needle not in oc:
                problems.append(f"native/src/platform/win32/d3d11_output.c no "
                                f"longer contains {needle!r}: {why}")
        if "matrix" not in oc or "full_range" not in oc:
            problems.append("native/src/platform/win32/d3d11_output.c must "
                            "apply the stream's colour matrix and range; the "
                            "video processor assumes BT.601 otherwise and "
                            "BT.709 reds come out orange")
        if "CreateVideoProcessorInputView" not in oc:
            problems.append("native/src/platform/win32/d3d11_output.c must build "
                            "the video processor input view from the decoder "
                            "texture; without it the GPU has no picture to "
                            "convert")
        if "D3D11_RESOURCE_MISC_SHARED" not in oc:
            problems.append("native/src/platform/win32/d3d11_output.c must create "
                            "the output texture with D3D11_RESOURCE_MISC_SHARED; "
                            "otherwise there is no handle for the engine")

    if not dec.exists() or "lp_render_draw_hw_ex" not in dec.read_text(encoding="utf-8"):
        problems.append("native/src/platform/win32/d3d11va_decoder.c must hand "
                        "hardware frames to lp_render_draw_hw_ex with the "
                        "stream colour description; passing NULL drops the "
                        "matrix and the colours drift")

    pc = plat.read_text(encoding="utf-8") if plat.exists() else ""
    if "lp_gpu_output_readback" not in pc:
        problems.append("native/src/platform/win32/win32_platform.c must fall "
                        "back to a GPU readback in lp_win32_copy_frame; hosts "
                        "without GPU surface support would get nothing")
    if "sws_setColorspaceDetails" not in pc:
        problems.append("native/src/platform/win32/win32_platform.c must tell "
                        "sws the stream colour space; sws defaults to BT.601 "
                        "and mis-renders BT.709 clips on the software path")
    if "kAudioQueueParam_Volume" in pc:
        pass
    for needle, why in (
        ("IMMDeviceEnumerator", "WASAPI enumeration is the point of the sink"),
        ("IAudioRenderClient", "samples have to be pushed through the render "
                               "client"),
        ("AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM", "the mixer format rarely matches "
                                               "the decoder, so the client has "
                                               "to convert"),
        ("waveOutOpen", "waveOut stays as the fallback for machines where "
                        "WASAPI cannot be opened"),
    ):
        if needle not in pc:
            problems.append(f"native/src/platform/win32/win32_platform.c no "
                            f"longer contains {needle!r}: {why}")
    if "wasapi" not in pc:
        problems.append("native/src/platform/win32/win32_platform.c must report "
                        "the wasapi backend through lp_audio_sink_name")

    pl = plugin.read_text(encoding="utf-8") if plugin.exists() else ""
    for needle, why in (
        ("kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle",
         "the plugin has to register a GPU surface texture; a pixel buffer "
         "texture pulls every frame through the CPU"),
        ("GpuSurfaceTexture", "the texture variant is what selects the GPU "
                              "path in the embedder"),
        ("FlutterDesktopPixelFormatBGRA8888", "BGRA is the native order of the "
                                              "shared surface; declaring RGBA "
                                              "swaps red and blue"),
        ("lp_win32_gpu_surface", "the plugin asks the core for the current "
                                 "surface"),
    ):
        if needle not in pl:
            problems.append(f"packages/lanplayer_video/windows/"
                            f"lanplayer_video_plugin.cpp no longer contains "
                            f"{needle!r}: {why}")

    if build.exists():
        bc = build.read_text(encoding="utf-8")
        if "d3d11_output.c" not in bc:
            problems.append("scripts/build_windows.py does not compile "
                            "src/platform/win32/d3d11_output.c")
        if '"-lole32"' not in bc:
            problems.append("scripts/build_windows.py must link ole32; WASAPI "
                            "does not resolve without it")
        if '"-ld3d11"' not in bc and "d3d11.lib" not in bc:
            problems.append("scripts/build_windows.py must link d3d11 for the "
                            "shared surface output")
    notes.append("windows paths: d3d11va frames go to a shared BGRA surface "
                 "through VideoProcessorBlt (colour matrix honoured), audio "
                 "runs on WASAPI with a waveOut fallback")


def check_local_picker() -> None:
    """Guard the local file/folder picker and the wide-character file layer.

    Two separate things broke here at once when the picker was rewritten:
      * the C file transport used narrow `opendir`/`fopen`/`stat`, so every path
        with a Chinese character failed with "No such file or directory" on
        Windows (the UTF-8 path was handed to the ANSI API verbatim);
      * the picker itself could only list a fixed set of roots and dropped every
        file, so "pick a file" was not expressible at all.
    Both are invisible in the Dart tests, so they are pinned statically.
    """
    fsrc = ROOT / "native" / "src" / "source" / "file.c"
    if fsrc.exists():
        fc = fsrc.read_text(encoding="utf-8")
        if "wchar_t *wide_from_utf8(" not in fc or "_wopendir(" not in fc:
            problems.append("native/src/source/file.c no longer opens paths "
                            "through the wide-character API; directories whose "
                            "name is not representable in the ANSI code page "
                            "cannot be opened on Windows")
        if "_wfopen" not in fc:
            problems.append("native/src/source/file.c must open files with "
                            "_wfopen; fopen mangles non-ASCII paths")
    else:
        problems.append("native/src/source/file.c missing")

    header = ROOT / "native" / "include" / "lanplayer" / "lp_source.h"
    if header.exists():
        if "list_all" not in header.read_text(encoding="utf-8"):
            problems.append("LpSourceOptions lost list_all; the file picker "
                            "could not show anything but media files")
    else:
        problems.append("native/include/lanplayer/lp_source.h missing")

    picker = ROOT / "app" / "lib" / "ui" / "folder_picker.dart"
    if picker.exists():
        pc = picker.read_text(encoding="utf-8")
        for needle, why in (
            ("pickLocalPath", "the picker lost its public entry point"),
            ("askLocalPath", "the manual path dialog was renamed away"),
            ("'list_all': 1", "the picker no longer asks for the unfiltered "
                              "listing, so only playable files would be visible"),
            ("this.isFile = false", "the picker can no longer return a folder "
                                    "choice that is not a file"),
            # The kernel hands entries back with a `file://` prefix already,
            # while the roots (drives, home, downloads) are bare paths.  Adding
            # the prefix unconditionally produced `file://file://D:/x` and every
            # directory below a drive failed with "not found".
            ("path.startsWith('file://')", "the picker no longer tolerates both "
                                           "bare paths and file:// URLs, so "
                                           "descending past a drive breaks"),
            # The app theme sets every FilledButton to minimumSize
            # Size.fromHeight(48) -- an *infinite* minimum width.  In a Row that
            # squeezes the flexible text to zero and paints the button outside
            # the row, so the footer looked like it only had 取消.
            ("minimumSize: const Size(0, 48)", "the picker footer no longer "
                                               "overrides the theme's infinite "
                                               "minimum button width; 加进首页 "
                                               "would be clipped away again"),
        ):
            if needle not in pc:
                problems.append(f"app/lib/ui/folder_picker.dart: {why}")

        # 往回走的时候必须重新列目录。选择器只保留「当前这一层」的列表，
        # 弹栈之后那份数据就不属于要显示的那一层了；少了这次重拉，上级
        # 目录会画成「这一层是空的」，用户以为里面的文件全没了。
        up_part = pc.split("void _up()", 1)[-1].split(
            "LocalChoice? get _choice", 1)[0]
        if "unawaited(_reload())" not in up_part:
            problems.append("app/lib/ui/folder_picker.dart: _up() must reload "
                            "the parent listing; the stack only records paths, "
                            "so the parent renders as an empty folder and its "
                            "files seem to disappear")
    else:
        problems.append("app/lib/ui/folder_picker.dart missing")

    folders = ROOT / "app" / "lib" / "data" / "folders.dart"
    if folders.exists():
        fd = folders.read_text(encoding="utf-8")
        if "'isFile': isFile" not in fd:
            problems.append("LocalFolder must persist isFile; a single-file "
                            "source would come back as a directory after a "
                            "restart")
    else:
        problems.append("app/lib/data/folders.dart missing")

    repo = ROOT / "app" / "lib" / "data" / "repository.dart"
    if repo.exists():
        if "browseFile(" not in repo.read_text(encoding="utf-8"):
            problems.append("MediaRepository lost browseFile(); a single-file "
                            "source would render an empty section")
    else:
        problems.append("app/lib/data/repository.dart missing")

    notes.append("local picker: browses every drive with narrow-to-wide path "
                 "conversion, can return a file or a folder, and a file source "
                 "still shows its sidecar subtitles")


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
    check_release_policy()
    check_player_layout()
    check_script_encoding()
    check_track_selection()
    check_subtitle_fonts()
    check_subtitle_sheet_selection()
    check_subtitle_advanced()
    check_android_playback()
    check_playback_profiles()
    check_apple_wiring()
    check_hw_decode()
    check_local_picker()
    check_splash()
    check_windows_playback_paths()

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
