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

DATA = LIB / "data"

# `data/models.dart` is a facade: it re-exports the model files, and every
# call site still imports that one path.  The assertions below care about the
# model definitions, not about which file happens to hold them, so they read
# the whole group as one body.
MODEL_FILES = (
    "models.dart",
    "playback_settings.dart",
    "media_models.dart",
    "directory_view.dart",
    "subtitle_models.dart",
)


def model_text() -> str:
    parts = []
    for name in MODEL_FILES:
        path = DATA / name
        if path.exists():
            parts.append(path.read_text(encoding="utf-8"))
    return "\n".join(parts)


def check_model_split() -> None:
    """数据模型按职责分四个文件，`models.dart` 只当出口。

    评审指出 `models.dart` 一千多行、混了播放设置、目录视图、媒体信息和字幕
    四个层次。拆开之后调用方仍然只 import `models.dart`，所以这里钉住三件事：
    每个文件都得在、关键类型必须落在对应的文件里、facade 本身别再长回大文件。
    """
    facade = DATA / "models.dart"
    if not facade.exists():
        problems.append("app/lib/data/models.dart missing")
        return
    text = facade.read_text(encoding="utf-8")
    for name in MODEL_FILES[1:]:
        if not (DATA / name).exists():
            problems.append(f"app/lib/data/{name} missing; models.dart re-exports "
                            f"it, so the import would not resolve")
            continue
        if f"export '{name}';" not in text:
            problems.append(f"models.dart must re-export {name}; every call site "
                            f"imports models.dart and would lose the type")
    if len(text.splitlines()) > 60:
        problems.append("models.dart is growing back into a grab bag; model "
                        f"definitions belong in the split files, not the facade")
    for token in ("class PlaybackSettings {", "enum PlayerState {"):
        if token in text:
            problems.append(f"models.dart still defines `{token.rstrip(' {')}`; "
                            f"the facade must only re-export the split files")
    owned = {
        "playback_settings.dart": ("class PlaybackSettings {", "enum PlayerState {"),
        "media_models.dart": ("class MediaEntry {", "class MediaInfo {",
                              "class ServerProfile {"),
        "directory_view.dart": ("class DirectoryListing {",),
        "subtitle_models.dart": ("class SubtitleCue {", "class SubtitleStyle {"),
    }
    for name, decls in owned.items():
        path = DATA / name
        if not path.exists():
            continue
        body = path.read_text(encoding="utf-8")
        for decl in decls:
            if decl in body:
                continue
            problems.append(f"app/lib/data/{name} lost `{decl.rstrip(' {')}`; "
                            f"that is the responsibility this file owns")
            break
    notes.append("model split: preferences, media info, directory view and "
                 "subtitle cues live in their own files behind models.dart")


# Four Flutter hosts ship from this repository.  A job going missing from the
# workflow is silent: the code still builds locally on the one platform the
# author happens to use, and the breakage only shows up at release time.
WORKFLOW = ROOT / ".github" / "workflows" / "build.yml"
HOST_BUILDS = (
    ("flutter build windows", "the Windows desktop app"),
    ("flutter build macos --release", "the macOS desktop app"),
    ("flutter build ios", "the iOS app"),
    ("flutter build apk", "the Android apk"),
)

# AGP 8.6 is the first release that accepts compileSdk 35, and it in turn
# requires Gradle 8.7; both numbers are raised together or not at all.
AGP_MIN_MINOR = 6
GRADLE_MIN_MINOR = 7

# GitHub retires macOS runner images roughly a year after the OS ships, and a
# job asking for a retired label is cancelled while it is still queued: it never
# starts a single step, `runner_name` stays empty, and the run goes red looking
# exactly like a build break.  macos-14 was retired on 2026-11-02, so anything
# numbered below 15 is a job that cannot run any more.
MACOS_MIN_RUNNER_MAJOR = 15


def check_build_matrix() -> None:
    """CI builds every host, and the Android toolchain can be upgraded safely.

    A code review of 0.1.7 found the Android side already out of range (AGP 8.1
    with compileSdk 35, no 16 KB page alignment) and the workflow without a
    macOS desktop job.  Neither failure shows up when only one host is built
    locally, so they are pinned here.
    """
    if not WORKFLOW.exists():
        problems.append(".github/workflows/build.yml is gone")
    else:
        text = WORKFLOW.read_text(encoding="utf-8")
        for needle, what in HOST_BUILDS:
            if needle not in text:
                problems.append(f"build.yml never runs `{needle}`; {what} would "
                                f"stop being built without anyone noticing")

        # A retired macOS image does not fail the build, it cancels the job
        # before the runner is assigned.  Nothing in the log says so, so the
        # label itself is what has to be kept current.
        for m in re.finditer(r"runs-on:\s*macos-(\d+)", text):
            major = int(m.group(1))
            if major < MACOS_MIN_RUNNER_MAJOR:
                problems.append(f"build.yml still asks for macos-{major}; images that "
                                f"old are retired and the job is cancelled while "
                                f"queued, so nothing in it ever runs")

    settings = APP / "android" / "settings.gradle"
    if not settings.exists():
        problems.append("app/android/settings.gradle missing")
    else:
        text = settings.read_text(encoding="utf-8")
        m = re.search(r'com\.android\.application"\s+version\s+"8\.(\d+)\.', text)
        if not m:
            problems.append("app/android/settings.gradle no longer pins the Android "
                            "Gradle plugin version where this check can read it")
        elif int(m.group(1)) < AGP_MIN_MINOR:
            problems.append(f"AGP 8.{m.group(1)} is below 8.{AGP_MIN_MINOR}; "
                            f"compileSdk 35 needs the newer plugin")

    wrapper = APP / "android" / "gradle" / "wrapper" / "gradle-wrapper.properties"
    if not wrapper.exists():
        problems.append("gradle-wrapper.properties missing")
    else:
        text = wrapper.read_text(encoding="utf-8")
        m = re.search(r"gradle-8\.(\d+)-(?:all|bin)\.zip", text)
        if not m:
            problems.append("gradle-wrapper.properties no longer pins a Gradle 8.x "
                            "distribution")
        elif int(m.group(1)) < GRADLE_MIN_MINOR:
            problems.append(f"Gradle 8.{m.group(1)} is below 8.{GRADLE_MIN_MINOR}, "
                            f"which the Android Gradle plugin requires")

    gradle_app = APP / "android" / "app" / "build.gradle.kts"
    if not gradle_app.exists():
        problems.append("app/android/app/build.gradle.kts missing")
    else:
        text = gradle_app.read_text(encoding="utf-8")
        for needle, why in (
            ("ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES", "the 16 KB page-size linker flag"),
            ("useLegacyPackaging = false", "uncompressed native libraries"),
        ):
            if needle not in text:
                problems.append(f"app/android/app/build.gradle.kts lost `{needle}`; "
                                f"{why} would silently go away")
        m = re.search(r'LP_ANDROID_NDK"\)\s*\?:\s*"(\d+\.\d+\.\d+)"', text)
        if not m:
            problems.append("app/android/app/build.gradle.kts no longer pins a default "
                            "ndkVersion this check can read")
        else:
            pinned = m.group(1)
            for doc in (ROOT / "docs" / "build.md",):
                if doc.exists() and pinned not in doc.read_text(encoding="utf-8"):
                    problems.append(f"docs/build.md does not mention the pinned NDK "
                                    f"{pinned}")

    deps = ROOT / "scripts" / "build_android_deps.py"
    if not deps.exists():
        problems.append("scripts/build_android_deps.py missing")
    elif "max-page-size=16384" not in deps.read_text(encoding="utf-8"):
        problems.append("scripts/build_android_deps.py no longer links the prebuilt "
                        "FFmpeg / libsmb2 objects for 16 KB pages")

    notes.append("build matrix: four host builds in CI, and the Android toolchain "
                 "stays inside the range compileSdk 35 and 16 KB pages need")


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
    "app/lib/data/trace.dart",
    "app/lib/ui/add_sheet.dart",
    "app/lib/ui/home_screen.dart",
    "app/lib/ui/media_permission.dart",
    "app/lib/ui/browser_screen.dart",
    "app/lib/ui/player_screen.dart",
    "app/lib/ui/startup_reset.dart",
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
    "app/windows/runner/single_instance.h",
    "app/windows/runner/single_instance.cpp",
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
    "app/lib/data/playback_settings.dart",
    "app/lib/data/media_models.dart",
    "app/lib/data/directory_view.dart",
    "app/lib/data/subtitle_models.dart",
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
    # 无 GPU 的 runner 上必须能跳过 GPU 段，否则这个 job 永远是红的。
    # 断言认的是参数解析那一行，不是 usage 文案里的同名字样。
    if test.exists() and '"--allow-software") == 0' not in test.read_text(encoding="utf-8"):
        problems.append("texture test lost its --allow-software switch; a runner without a "
                        "D3D11 device can never pass it again")

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
    # 评审 4.7：网段过大要收敛到 /24 时，必须按本机地址收敛。按 CIDR 文字里
    # 的地址收敛的话，`192.168.0.0/16` 会去扫 192.168.0.x，而用户的本机在
    # 192.168.5.x —— 扫完一台都找不到，界面上却只是「这个网段没有 445 主机」。
    if "localAddress" not in body:
        problems.append("lan_scan.dart: hostsInSubnet must take the local "
                        "address when it narrows an oversized subnet down to "
                        "a /24; anchoring on the CIDR text scans the wrong /24")
    if "pivot = localAddress;" not in body:
        problems.append("lan_scan.dart: narrowing must pivot on the local "
                        "address (pivot = localAddress), otherwise a /16 in "
                        "the settings box scans the network address's /24")
    if "localAddress: parseIPv4(" not in (
            ui.read_text(encoding="utf-8") if ui.exists() else ""):
        problems.append("server_edit_screen.dart must pass the local address "
                        "into scanSubnet; without it the narrowing keeps "
                        "scanning the wrong subnet")

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
    models = DATA / "models.dart"
    if models.exists() and "displayName" not in model_text():
        problems.append("ServerProfile must expose displayName (falls back to "
                        "share) so cards stay readable when name is empty")


def check_listing_index() -> None:
    """目录页的派生列表只能算一次。

    `DirectoryListing` 的 `videos`/`folders`/`subtitles` 原来是每次读都
    `entries.where(...).toList()`；`subtitlesFor(video)` 每次都重扫全部字幕并
    逐条配对；`orphanSubtitles` 是 `V×S`；`browsable` 里再对每行跑
    `orphans.any(...)` 变成 `O(n²)`。行里的字幕标签又是
    `videos.firstWhere((v) => subtitlesFor(v).any(...))` —— 一个目录几百个
    文件时滚动就是 `O(n³)`。

    这个退化不会报错也不会崩，只是越滚越卡，所以用静态断言钉住：派生列表
    必须是 `late final` 的缓存，配对必须走一次建好的索引表，行里不许再
    `firstWhere` 现找归属。
    """
    models = DATA / "models.dart"
    if not models.exists():
        problems.append("app/lib/data/models.dart missing")
        return
    mc = model_text()
    listing = mc.split("class DirectoryListing {", 1)[-1].split("\n}", 1)[0]
    # 只看代码：注释里会提到旧写法（「原来是 `orphans.any(...)`」），那正是
    # 要说明的背景，不能当成回归。
    listing_code = "\n".join(line for line in listing.splitlines()
                             if not line.lstrip().startswith("//"))
    for token, why in (
        ("late final List<MediaEntry> videos =",
         "videos must be computed once; the row for every entry reads it"),
        ("late final List<MediaEntry> folders =",
         "folders must be computed once; the empty-state check reads it"),
        ("late final List<MediaEntry> subtitles =",
         "subtitles must be computed once"),
        ("late final List<MediaEntry> orphanSubtitles =",
         "orphanSubtitles must be computed once; it is O(V×S)"),
        ("late final List<MediaEntry> browsable =",
         "browsable must be computed once; it is rebuilt on every scroll tick"),
    ):
        if token not in listing:
            problems.append(f"DirectoryListing: {why} (expected `{token}`)")
    # 负向对照：派生列表不能退回成 getter。
    for name in ("videos", "folders", "subtitles", "orphanSubtitles",
                 "browsable"):
        if f"List<MediaEntry> get {name} =>" in listing:
            problems.append(f"DirectoryListing.{name} is a getter again; it "
                            f"re-walks entries on every read")
    if "_subtitleIndex" not in listing:
        problems.append("DirectoryListing must build one subtitle index; "
                        "re-pairing on every subtitlesFor call is O(V×S) per "
                        "row")
    if "subtitleBelongsTo(v.name, s.name)" not in listing:
        problems.append("DirectoryListing must still pair through "
                        "subtitleBelongsTo; a second rule set would drift from "
                        "subtitle_match.dart")
    if "ownerOfSubtitle(" not in listing:
        problems.append("DirectoryListing must expose ownerOfSubtitle so the "
                        "row label does not scan every video again")
    if "orphans.any(" in listing_code:
        problems.append("DirectoryListing.browsable is back to scanning the "
                        "orphan list per row; collect the paths into a Set")

    row = ROOT / "app" / "lib" / "ui" / "widgets" / "media_row.dart"
    if row.exists():
        rc = row.read_text(encoding="utf-8")
        label = rc.split("String subtitleLabel(", 1)[-1]
        if "listing.videos.firstWhere(" in label:
            problems.append("media_row.subtitleLabel is back to scanning every "
                            "video for the owner; use listing.ownerOfSubtitle")
        if "ownerOfSubtitle(" not in label:
            problems.append("media_row.subtitleLabel must take the owner from "
                            "the listing index")

    progress = ROOT / "app" / "lib" / "data" / "progress.dart"
    if not progress.exists():
        problems.append("app/lib/data/progress.dart missing")
        return
    pc = progress.read_text(encoding="utf-8")
    if "_keyCache" not in pc:
        problems.append("progress.dart must memoise sanitizeKey; every row "
                        "asks for a resume point on every frame and the "
                        "percent-decode is pure work done again and again")
    if "_sanitizeKeyUncached(" not in pc:
        problems.append("progress.dart: sanitizeKey must delegate to the "
                        "uncached implementation, otherwise the cache either "
                        "recurses or is bypassed")

    notes.append("listing index: derived lists are computed once, subtitles "
                 "pair through a single index, and progress keys are memoised")


def check_seek_step() -> None:
    """快进/快退步长：1..10 的整数，设置可改，播放页读设置。

    用户 2026-10-30 要求「可以设置快进快退的秒数，这个数字必须是整数且
    大于等于 1 小于等于 10」。界面上用下拉框只能选 1..10，但 settings.json
    是可以手改的 —— 读到 0 会让快进退原地不动，读到 999 一点就跳到片尾。
    所以断言同时盯住：模型里必须夹紧、默认值必须合法、播放页不得再写死 10。
    """
    models = DATA / "models.dart"
    if not models.exists():
        problems.append("app/lib/data/models.dart is missing")
        return
    md = model_text()

    # 断言字段声明本身，不是全文搜名字：名字还留在 toJson/fromJson 里，
    # 单纯删掉字段声明时全文搜索照样命中，护栏就成了摆设。
    if "int seekStepSeconds;" not in md:
        problems.append("PlaybackSettings lost the seekStepSeconds field; "
                        "the fast forward step would be fixed at ten "
                        "seconds again")
    if "static const int seekStepMin = 1;" not in md:
        problems.append("PlaybackSettings.seekStepMin must stay 1")
    if "static const int seekStepMax = 10;" not in md:
        problems.append("PlaybackSettings.seekStepMax must stay 10")
    # fromJson 必须过 clampSeekStep，否则手改过的 json 能绕过区间。
    if "seekStepSeconds: clampSeekStep(" not in md:
        problems.append(
            "PlaybackSettings.fromJson must clamp seek_step_seconds; a "
            "hand-edited 0 or 999 would otherwise reach the player")

    screen = ROOT / "app" / "lib" / "ui" / "settings_screen.dart"
    if not screen.exists():
        problems.append("app/lib/ui/settings_screen.dart is missing")
    else:
        sc = screen.read_text(encoding="utf-8")
        if "seekStepSeconds" not in sc:
            problems.append("the settings screen no longer exposes the seek "
                            "step; users could not change it any more")
        # 填数而不是滑杆（用户 2026-10-30 要求）：滑杆能拖出 7.3，且拖动
        # 过程中每帧都落盘。校验这一格用的是 NumberField。
        if "NumberField(" not in sc:
            problems.append("the seek step must be a NumberField the user "
                            "types into, not a slider")

    player = ROOT / "app" / "lib" / "ui" / "player_screen.dart"
    if not player.exists():
        problems.append("app/lib/ui/player_screen.dart is missing")
    else:
        pl = player.read_text(encoding="utf-8")
        # 同上：`_seekStep` 还会出现在调用处，必须断言 getter 定义本身。
        if "int get _seekStep" not in pl:
            problems.append("player_screen lost the _seekStep getter; the "
                            "buttons would jump a hard coded number of "
                            "seconds again")
        # 逐个调用点检查，全文搜 «_seekRelative(10)» 抓不住「一处改了、
        # 另一处还写死 10」这种半吊子状态。
        if pl.count("_seekRelative(10)") or pl.count("_seekRelative(-10)"):
            problems.append("player_screen still seeks a hard coded 10 seconds "
                            "somewhere; every call site must use _seekStep")
        # replay_10 / forward_10 是写死「10」的图标，步长改了图标就撒谎。
        for icon in ("Icons.replay_10", "Icons.forward_10"):
            if icon in pl:
                problems.append(
                    f"player_screen still uses {icon}; the digits in the icon "
                    f"are wrong once the step is not ten seconds")


def check_speed_steps() -> None:
    """播放倍速只允许固定的八档（用户 2026-10-30 指定 0.25..2.0）。

    三处必须共用同一份档位：模型的 speedSteps、设置页的下拉、播放页的倍速
    面板。任何一处各写一份列表，用户都会遇到「设置里选得出、播放页选不中」
    或者反过来。另外 fromJson 必须走 clampSpeed —— 老配置里存过 1.3 这类
    非档位值，不吸附的话 RadioListTile 的 groupValue 精确匹配会全落空。
    """
    models = DATA / "models.dart"
    if not models.exists():
        problems.append("app/lib/data/models.dart is missing")
        return
    md = model_text()

    if "static const List<double> speedSteps = [" not in md:
        problems.append("PlaybackSettings lost speedSteps; the speed menu "
                        "would go back to a free-form slider")
    for step in ("0.25,", "0.5,", "0.75,", "1.0,", "1.25,", "1.5,",
                 "1.75,", "2.0,"):
        if step not in md:
            problems.append(f"PlaybackSettings.speedSteps lost the {step[:-1]} "
                            f"step")
    if "static double clampSpeed(Object? raw)" not in md:
        problems.append("PlaybackSettings lost clampSpeed(); an old 1.3 in "
                        "settings.json would match no dropdown entry")
    # 逐个赋值点检查，光看名字在不在挡不住「fromJson 还在用原值」。
    if "speed: clampSpeed(" not in md:
        problems.append("PlaybackSettings.fromJson must snap speed through "
                        "clampSpeed, not store whatever the file says")

    screen = ROOT / "app" / "lib" / "ui" / "settings_screen.dart"
    if not screen.exists():
        problems.append("app/lib/ui/settings_screen.dart is missing")
    else:
        sc = screen.read_text(encoding="utf-8")
        if "PlaybackSettings.speedSteps" not in sc:
            problems.append("the settings screen no longer reads "
                            "PlaybackSettings.speedSteps; it would drift from "
                            "the player's menu")
        if "DropdownButton<double>(" not in sc:
            problems.append("the default speed must be a dropdown of fixed "
                            "steps, not a slider")

    player = ROOT / "app" / "lib" / "ui" / "player_screen.dart"
    if not player.exists():
        problems.append("app/lib/ui/player_screen.dart is missing")
    else:
        pl = player.read_text(encoding="utf-8")
        if "const speeds = PlaybackSettings.speedSteps;" not in pl:
            problems.append("player_screen must take its speed menu from "
                            "PlaybackSettings.speedSteps")
        # 面板上的 groupValue 要吸附，否则老配置下没有任何一档被选中。
        if "groupValue: PlaybackSettings.clampSpeed(_player.speed)" not in pl:
            problems.append("the speed sheet must snap groupValue through "
                            "clampSpeed; a stale 1.3 would select nothing")


def check_backspace_guard() -> None:
    """键盘触发时机：全应用统一「抬起才执行」，以及 Backspace 退一层的接线。

    用户 2026-10-30 两次要求叠在一起：
      1. Backspace 回到上一浏览层级；
      2. 所有按键都改成抬起后触发，长按或按下不抬起没有任何效果。

    这里的断言就是这两条的静态形态。任何一处退回「按下即触发」或
    「放行 KeyRepeatEvent」，长按就会被连续执行，深目录里按住两秒直接
    退到根 —— 而且这种回退肉眼很难发现，必须靠护栏盯住。
    """
    kb = ROOT / "app/lib/ui/keyboard.dart"
    if not kb.exists():
        problems.append("app/lib/ui/keyboard.dart missing; keyboard shortcuts "
                        "would lose their shared release-trigger logic")
        return

    kc = kb.read_text(encoding="utf-8")
    # 只看函数体：文件里的文档注释也提到了这颗键，全文搜索会把注释当成
    # 实现，导致「改成恒 false」这种真回退被抓漏。
    body = kc.split("bool isBackKey(", 1)
    body = body[1].split(";", 1)[0] if len(body) > 1 else ""
    if "LogicalKeyboardKey.backspace" not in body:
        problems.append("keyboard.dart no longer maps Backspace to the back "
                        "action")

    # 触发时机：按下只记录、重复吞掉、抬起才 fire。
    trig = kc.split("class KeyReleaseTrigger", 1)
    trig = trig[1].split("class BackKeyHandler", 1)[0] if len(trig) > 1 else ""
    if not trig:
        problems.append("keyboard.dart lost KeyReleaseTrigger; the app would "
                        "go back to firing shortcuts on key down")
    else:
        # 按分支切片：光看「有没有提到 KeyDownEvent」是查不出问题的 ——
        # 在记录键的同时顺手 fire 一下，两段文字都还在，但语义已经反了。
        down_part = trig.split("event is KeyDownEvent", 1)
        down_part = (down_part[1].split("if (event is", 1)[0]
                     if len(down_part) > 1 else "")
        if not down_part:
            problems.append("KeyReleaseTrigger must handle KeyDownEvent; the "
                            "press has to be remembered somewhere")
        else:
            if "_held.add(key)" not in down_part:
                problems.append("KeyReleaseTrigger must record the key on "
                                "KeyDownEvent")
            if "fire(" in down_part:
                problems.append("KeyReleaseTrigger must not fire on "
                                "KeyDownEvent; shortcuts would run the moment "
                                "the key goes down and a held key would repeat")

        repeat_part = trig.split("event is KeyRepeatEvent", 1)
        repeat_part = (repeat_part[1].split("if (event is", 1)[0]
                       if len(repeat_part) > 1 else "")
        if not repeat_part:
            problems.append("KeyReleaseTrigger must swallow KeyRepeatEvent; "
                            "holding a key would otherwise fire again and "
                            "again")
        elif "fire(" in repeat_part:
            problems.append("KeyReleaseTrigger must not fire on "
                            "KeyRepeatEvent; holding a key down would repeat "
                            "the action until it is released")
        if "event is KeyUpEvent" not in trig:
            problems.append("KeyReleaseTrigger must fire on KeyUpEvent; that "
                            "is the whole point of releasing")
        if "_held.remove(key)" not in trig:
            problems.append("KeyReleaseTrigger must only fire for keys it saw "
                            "pressed, otherwise a key held while focus moves "
                            "fires on release")
        if "void reset()" not in trig:
            problems.append("KeyReleaseTrigger must offer reset(); a page that "
                            "loses focus would keep a stale held key")

    for path, why in (
        ("app/lib/ui/browser_screen.dart",
         "the browser page would ignore Backspace and the file manager habit "
         "of stepping out one folder at a time breaks"),
        ("app/lib/ui/folder_picker.dart",
         "the local picker would ignore Backspace while every other list in "
         "the app honours it"),
    ):
        f = ROOT / path
        if not f.exists():
            continue
        page = f.read_text(encoding="utf-8")
        if "_backKey.handle(event," not in page:
            problems.append(f"{path}: no Backspace handler; {why}")
        if "_backKey.reset()" not in page:
            problems.append(f"{path}: the Backspace handler is never reset on "
                            "focus loss; a key held while the page loses focus "
                            "fires when it comes back")

    picker = ROOT / "app/lib/ui/folder_picker.dart"
    if picker.exists():
        pc = picker.read_text(encoding="utf-8")
        head = pc.split("_backKey.handle(", 1)[0][-400:]
        if "autofocus: true" not in head:
            problems.append("app/lib/ui/folder_picker.dart: the dialog's Focus "
                            "must autofocus, or Backspace never reaches it and "
                            "the key falls through to the page underneath")

    # 播放页：快捷键必须走同一套抬起触发，且不再有 repeat 分支。
    player = ROOT / "app/lib/ui/player_screen.dart"
    if player.exists():
        pl = player.read_text(encoding="utf-8")
        if "KeyReleaseTrigger(_isPlayerKey)" not in pl:
            problems.append("player_screen must drive its shortcuts through "
                            "KeyReleaseTrigger; firing on key down makes a held "
                            "arrow key seek dozens of times")
        if "event is KeyRepeatEvent" in pl or "KeyDownEvent" in pl:
            problems.append("player_screen still inspects KeyDownEvent/"
                            "KeyRepeatEvent itself; the release-trigger helper "
                            "should be the only place that decides when a "
                            "shortcut fires")
        if "_keys.reset()" not in pl:
            problems.append("player_screen must reset the key state on focus "
                            "loss, or the first release after a window switch "
                            "fires a phantom action")
        # 快捷键现在是可改的：动作表在 shortcuts.dart，播放页只是查表。
        # 一旦有人把它改回写死的 if 链，用户在设置里改的键就全失效了，
        # 而且界面上还显示着新键 —— 这种「设置页撒谎」很难靠肉眼发现。
        if "_settings.shortcuts.ownsKey(key)" not in pl:
            problems.append("player_screen no longer asks the user's bindings "
                            "which keys it owns; rebinding a shortcut in "
                            "settings would silently do nothing")
        if "ShortcutBindings.label(key)" not in pl:
            problems.append("player_screen stopped naming the action by its "
                            "binding; the key log would print a stale label")

    enum_file = ROOT / "app/lib/data/shortcuts.dart"
    if not enum_file.exists():
        problems.append("app/lib/data/shortcuts.dart missing; the settings page "
                        "could not list what is bound to what")
    else:
        sc = enum_file.read_text(encoding="utf-8")
        # 存进 settings.json 的是 id 字符串，不是枚举名 —— 枚举改名会
        # 静默丢掉所有用户的绑定。
        if "final String id;" not in sc:
            problems.append("ShortcutAction must carry a stable string id; "
                            "settings.json keys would follow enum renames and "
                            "user bindings would be lost")
        if "ShortcutBindings.fromJson(" not in sc:
            problems.append("shortcuts.dart lost fromJson; stored bindings "
                            "would never be read back")
        if "ShortcutBindings bind(ShortcutAction action" not in sc:
            problems.append("shortcuts.dart lost bind(); the recorder could "
                            "not store anything")
        if "ShortcutAction? conflictFor(" not in sc:
            problems.append("shortcuts.dart lost conflictFor(); binding a key "
                            "twice would leave one action dead with no hint")
        if "static String label(LogicalKeyboardKey key)" not in sc:
            problems.append("shortcuts.dart lost the key label helper; arrow "
                            "keys would render as ARROW LEFT")
        if "static const List<PointerGesture> all" not in sc:
            problems.append("shortcuts.dart lost the pointer gesture list; the "
                            "settings page would stop documenting double tap "
                            "and long press")

    section = ROOT / "app/lib/ui/widgets/shortcut_section.dart"
    if not section.exists():
        problems.append("app/lib/ui/widgets/shortcut_section.dart missing; the "
                        "shortcut bindings would have no UI")
    else:
        sec = section.read_text(encoding="utf-8")
        if "if (event is! KeyDownEvent)" not in sec:
            problems.append("the recorder must take the press, not the release; "
                            "recording on key up would capture the wrong key "
                            "when the user reuses a key held from before")
        if "_isModifier(key)" not in sec:
            problems.append("the recorder no longer rejects bare modifiers; a "
                            "user pressing Shift would bind Shift itself")
        if "class ShortcutPick" not in sec:
            problems.append("the recorder must distinguish cancel from clear; "
                            "showDialog returns null for both otherwise")


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
    settings = ROOT / "app" / "lib" / "ui" / "settings_screen.dart"
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
    tile_dispose = tile_code.split("void dispose()", 1)[-1]
    if "_image?.dispose" not in tile_dispose:
        problems.append("ThumbnailTile must dispose the ui.Image it owns when "
                        "the row goes away; ThumbnailCache.load() hands out "
                        "clones, so keeping the handle alive until the next GC "
                        "leaks a screenful of covers")
    if "image.dispose()" not in code:
        problems.append("thumbs.dart must release evicted covers (ImageLru "
                        "disposeValue), otherwise the LRU only drops references "
                        "and the pixels wait for a GC that may not come")

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
    # 封面只给视频取：音频取一帧没有意义，还白花一次网络往返或解码。
    # 这一行住在 media_row 里（首页与浏览页共用同一个行组件），不在浏览页。
    row_code = "\n".join(
        l for l in row.read_text(encoding="utf-8").splitlines()
        if not l.strip().startswith("//")) if row.exists() else ""
    if "entry.isVideo\n          ? ThumbnailTile(" not in row_code:
        problems.append("only videos may request a cover; audio should stay on "
                        "its icon instead of paying for a decode")

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

    # A cover that once failed to decode was remembered forever: one network
    # hiccup and that file never got a cover again. The marker now carries the
    # failure time and expires; the cache also needs a way to be emptied from
    # the UI, or the entries of deleted files stay on disk for good.
    if "markerExpired" not in code:
        problems.append("thumbs.dart must expire the '<key>.none' failure "
                        "marker; remembering a failure forever means one "
                        "network hiccup costs that file its cover")
    if "marker.writeAsString" not in code:
        problems.append("thumbs.dart must stamp the failure marker with the "
                        "time it happened, otherwise it can never expire")
    settings_text = (settings.read_text(encoding="utf-8")
                     if settings.exists() else "")
    if "ThumbnailCache.instance.diskUsage()" not in settings_text:
        problems.append("settings_screen.dart must show the cover cache size; "
                        "diskUsage() had no caller and users could not see "
                        "what the cache costs")
    if "ThumbnailCache.instance.clear()" not in settings_text:
        problems.append("settings_screen.dart must offer 清空封面缓存; clear() "
                        "had no caller, so stale covers stayed on disk")

    # 封面缓存的两个「只增不减」：内存里的 ui.Image 无上限、磁盘上的 .thumb
    # 文件只写不删。前者滑完一个剧集目录就吃掉几十 MB（一张 128×128 RGBA
    # 约 64 KB），后者库越滚越大，装久了就是几百 MB 的死重量。
    if "memoryLimit" not in code or "ImageLru" not in code:
        problems.append("thumbs.dart must cap the decoded-cover cache with an "
                        "LRU; an unbounded Map keeps every cover the user ever "
                        "scrolled past (about 64 KB each)")
    if "diskLimitBytes" not in code or "pruneDisk(" not in code:
        problems.append("thumbs.dart must evict old .thumb files (pruneDisk); "
                        "the cache had a diskUsage() ruler but nothing ever "
                        "deleted, so it only grew")
    if "setLastModified(" not in code:
        problems.append("thumbs.dart must touch a cover file when it is read; "
                        "without that the eviction cannot tell a hot cover "
                        "from one nobody opened in months")

    # 首页整块塞进 Column 时，一块来源摊开有几行就建几个 MediaRow，每行一个
    # ThumbnailTile —— 进首页就排起两百个串行封面请求。改成展平 + builder
    # 之后，只有视口内的行会被建出来。
    home = ROOT / "app" / "lib" / "ui" / "home_screen.dart"
    if home.exists():
        home_code = "\n".join(
            l for l in home.read_text(encoding="utf-8").splitlines()
            if not l.strip().startswith("//"))
        if "ListView.builder(" not in home_code:
            problems.append("home_screen must build its list with "
                            "ListView.builder; a plain ListView(children:) "
                            "creates every row of every source up front")
        if "abstract class _HomeItem" not in home_code:
            problems.append("home_screen must defer row construction through "
                            "_HomeItem; flattening into ready-made widgets "
                            "still mounts every MediaRow on the first frame")
        if "class _RowItem implements _HomeItem" not in home_code:
            problems.append("home_screen lost _RowItem; the media rows must "
                            "only be built when the builder asks for them")

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
    models = DATA / "models.dart"
    browser = ROOT / "app" / "lib" / "ui" / "browser_screen.dart"
    if models.exists():
        mc = model_text()
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
        if "AddSheetRoute(" not in hc:
            problems.append("home_screen must push the add sheet itself; "
                            "showModalBottomSheet resolves before the sheet "
                            "is off screen and the next push gets dropped")
        add_sheet = ROOT / "app" / "lib" / "ui" / "add_sheet.dart"
        if not add_sheet.is_file():
            problems.append("app/lib/ui/add_sheet.dart is gone; the add menu "
                            "would fall back to the framework barrier that "
                            "accepts the iPad ghost pointer")
        else:
            ac = add_sheet.read_text(encoding="utf-8")
            # iPad 上弹层会自己收回，日志里每次都是「约 348ms 后一个 (0,0)
            # 的指针事件 + maybePop」。遮罩必须自己认这一手。
            if "class AddSheetRoute extends ModalBottomSheetRoute<String>" not in ac:
                problems.append("add_sheet must extend ModalBottomSheetRoute so "
                                "the barrier can be replaced without losing the "
                                "sheet animation")
            if "Widget buildModalBarrier()" not in ac:
                problems.append("add_sheet must build its own barrier; the "
                                "framework one treats the (0,0) ghost pointer "
                                "as a tap outside and closes the sheet")
            if "_ghostOrigin = Offset.zero" not in ac:
                problems.append("add_sheet lost the ghost pointer origin; the "
                                "iPad sheet would close itself again")
            if "details.globalPosition == _ghostOrigin" not in ac:
                problems.append("add_sheet must compare the tap position "
                                "against the origin exactly, not by distance; "
                                "the top-left corner is the status bar")
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
        # 「还有 N 项」本来 push 一个浏览页，等于把同一份列表换个界面再列一遍。
        # 需求是就地摊开：按钮只改本页状态，不许再压新页面。
        if "还有 $hidden 项" not in hc:
            problems.append("home_screen lost the '还有 N 项' affordance for a "
                            "long directory; the rest of the listing would be "
                            "unreachable from the home screen")
        if "onExpand" not in hc or "onCollapse" not in hc:
            problems.append("home_screen must expand a long directory in place "
                            "(onExpand/onCollapse); it used to push a browser "
                            "page that re-listed the same entries")
        # 就地展开一定要能被撤回，否则一次点击就把首页拉成几十行。
        if "label: const Text('收起')" not in hc:
            problems.append("home_screen lost the collapse control; an "
                            "expanded source could never be folded again")


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

    # 版本号只在正式发版时更迭（用户在 2026-10-30 明确要求）。每个构建脚本都得
    # 留一个覆盖口子，本地构建才能不改 pubspec 就打出一个可区分的包 —— 否则下
    # 一次改代码又会有人顺手去升 pubspec，发版时 tag 和 asset 名全对不上。
    overrides = {
        "build_windows_desktop.py": '"--version"',
        "build_windows_installer.py": '"--version"',
        "build_macos_dmg.py": 'environ.get("VERSION"',
        "build_android_apk.py": 'environ.get("VERSION"',
    }
    for builder, token in overrides.items():
        path = ROOT / "scripts" / builder
        if not path.is_file():
            continue
        body = path.read_text(encoding="utf-8", errors="replace")
        if token not in body:
            problems.append(f"scripts/{builder} lost its version override "
                            f"({token}); local builds would have to bump "
                            f"app/pubspec.yaml just to tell packages apart")

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

def check_nal_behaviour() -> None:
    """Runs the NAL framing and profile-guard test when the build exists.

    Finding `to_annexb(` in media_codec_decoder.c proves somebody wrote the
    function, not that it converts the right bytes.  The two conversions and the
    hardware profile list are plain C, so Windows can execute them here and the
    answer is real: a packet whose length field happens to look like a start code
    must not be treated as Annex-B, and a 10-bit profile that the backend cannot
    decode must be refused before the decoder is opened.
    """
    out_dir = ROOT / "build" / "win-x64"
    exe = out_dir / "lp_nal_test.exe"
    build = ROOT / "scripts" / "build_windows.py"
    if build.exists() and 'build_test("lp_nal_test.exe"' not in build.read_text(encoding="utf-8"):
        problems.append("scripts/build_windows.py no longer builds lp_nal_test.exe; the "
                        "framing rule would only be checked by grepping for its name")
        return
    if not exe.exists():
        notes.append("nal framing: not built (scripts/build_windows.py)")
        return
    env = dict(os.environ)
    env["PATH"] = str(out_dir) + os.pathsep + env.get("PATH", "")
    code, out = run([str(exe)], env=env, cwd=str(out_dir))
    if code != 0 or "all nal framing and profile guard cases passed" not in out:
        problems.append("nal framing test failed:\n" + out.strip()[-1500:])
        return
    notes.append("nal framing: length-prefix vs start-code, both conversions "
                 "and the hw profile guard behave as specified")

def check_transport_behaviour() -> None:
    """Runs the transport registry test when the build exists.

    check_transport_registry() reads the source and proves the shape; this runs
    the registry itself and proves the answers: an unknown scheme resolves to
    nothing, smb2:// is the same entry as smb://, file:// has no default port,
    and the scheme list is derived from the table rather than typed out again.
    """
    out_dir = ROOT / "build" / "win-x64"
    exe = out_dir / "lp_transport_test.exe"
    build = ROOT / "scripts" / "build_windows.py"
    source = ROOT / "native" / "tests" / "lp_transport_test.c"
    if not source.exists():
        problems.append("native/tests/lp_transport_test.c is gone; the registry would only be "
                        "checked by reading its source")
        return
    if build.exists() and 'build_test("lp_transport_test.exe"' not in build.read_text(encoding="utf-8"):
        problems.append("scripts/build_windows.py no longer builds lp_transport_test.exe")
        return
    # URL 拼装的回归用例必须真的被调用：删掉那一行，exe 照样打印 "all cases
    # passed"，主机的端口就悄悄退回事故时的写法。
    if "test_authority_shape();" not in source.read_text(encoding="utf-8"):
        problems.append("native/tests/lp_transport_test.c no longer calls test_authority_shape; "
                        "the default port could leak a stray character into the host again")
        return
    # lp_smoke_test 链接共享库，看不到内部符号；断言必须留在这个可执行文件里。
    smoke = ROOT / "native" / "tests" / "lp_smoke_test.c"
    if smoke.exists() and "source_internal.h" in smoke.read_text(encoding="utf-8"):
        problems.append("lp_smoke_test.c includes source_internal.h again; on Linux the shared "
                        "library hides internal symbols and the test stops linking")
    if not exe.exists():
        notes.append("transport registry: not built (scripts/build_windows.py)")
        return
    env = dict(os.environ)
    env["PATH"] = str(out_dir) + os.pathsep + env.get("PATH", "")
    code, out = run([str(exe)], env=env, cwd=str(out_dir))
    if code != 0 or "all transport registry cases passed" not in out:
        problems.append("transport registry test failed:\n" + out.strip()[-1500:])
        return
    notes.append("transport registry: lookup, alias, URL shape and the scheme list all come "
                 "from the one table")

def check_subtitle_robustness() -> None:
    """Runs the malformed-subtitle test and pins the one path it cannot reach.

    Well-formed samples never touch these branches: an ASS ``Format:`` whose
    columns disagree with the ``Dialogue:`` rows, text truncated on a byte
    boundary in the middle of a multi-byte character, a ``\\u`` surrogate pair
    with an unchecked low half, or an animation grafted onto the previous run
    when a style-only block appends nothing.  The test builds those samples and
    asserts the behaviour, so the guard is on the outcome instead of on the
    presence of a line.
    """
    out_dir = ROOT / "build" / "win-x64"
    exe = out_dir / "lp_robust_test.exe"
    build = ROOT / "scripts" / "build_windows.py"
    source = ROOT / "native" / "tests" / "lp_robust_test.c"
    if not source.exists():
        problems.append("native/tests/lp_robust_test.c is gone; malformed subtitles would only "
                        "be checked by reading the parser")
        return
    if build.exists() and 'build_test("lp_robust_test.exe"' not in build.read_text(encoding="utf-8"):
        problems.append("scripts/build_windows.py no longer builds lp_robust_test.exe")
        return
    # 每个用例都必须真的被调用：只删掉一行调用，exe 照样打印 "all malformed
    # subtitle cases passed"，那条缺陷就悄悄回来了。
    calls = source.read_text(encoding="utf-8")
    for name in ("test_json_unicode_escapes();", "test_ass_text_before_times();",
                 "test_ass_format_reuse();", "test_ass_short_dialogue();",
                 "test_text_clamp_utf8();", "test_merge_keeps_prev_animation();"):
        if name not in calls:
            problems.append(f"native/tests/lp_robust_test.c no longer calls {name}")
            return
    # lp_subtitle_add_file 要完整的 LpPlayer（加载互斥量、source 表），纯 C
    # 测试建不出来，所以第 2.2 条只能用形状断言：重新加锁之后必须先重读
    # nb_tracks，再拿它算下标。少了这一步就是锁外的旧槽位号。
    subs = ROOT / "native" / "src" / "core" / "subtitle.c"
    text = subs.read_text(encoding="utf-8")
    marker = "int lp_subtitle_add_file("
    start = text.find(marker)
    if start < 0:
        problems.append("native/src/core/subtitle.c lost lp_subtitle_add_file")
        return
    body = text[start:text.find("\n}\n", start)]
    relock = body.rfind("pthread_mutex_lock(&p->subs.mutex);")
    if relock < 0:
        problems.append("lp_subtitle_add_file never takes the subtitle lock")
        return
    tail = body[relock:]
    if "nb = p->subs.nb_tracks;" not in tail:
        problems.append("lp_subtitle_add_file uses nb_tracks without refreshing it after "
                        "re-locking; the slot number from before the file read could be stale")
        return
    if "&p->subs.tracks[nb]" not in tail:
        problems.append("lp_subtitle_add_file no longer indexes p->subs.tracks[nb]")
        return
    if not exe.exists():
        notes.append("subtitle robustness: not built (scripts/build_windows.py)")
        return
    env = dict(os.environ)
    env["PATH"] = str(out_dir) + os.pathsep + env.get("PATH", "")
    code, out = run([str(exe)], env=env, cwd=str(out_dir))
    if code != 0 or "all malformed-subtitle cases passed" not in out:
        problems.append("malformed subtitle test failed:\n" + out.strip()[-1500:])
        return
    notes.append("subtitle robustness: mismatched ASS columns, truncated UTF-8, lone "
                 "surrogates and a style-only block appending nothing all behave as specified")

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

def check_source_manifest() -> None:
    """Keep the one source list honest.

    The list used to be copied into three places (native/CMakeLists.txt,
    scripts/build_windows.py, scripts/build_apple_deps.py).  It now lives in
    native/sources.cmake, which CMake includes and both Python build scripts
    parse through tool/native_sources.py.

    Two things can still go wrong without this check: a .c file appears under
    native/src/ but nobody adds it to the manifest (it silently never gets
    compiled, and only the link step notices -- on one platform only), or a
    manifest entry outlives its file (every build fails with a cryptic missing
    header).  Both are caught here, on every platform, before any compiler runs.
    """
    sys.path.insert(0, str(ROOT / "tool"))
    try:
        from native_sources import load_sources
    except ImportError as exc:  # pragma: no cover - import failure is a problem
        problems.append(f"tool/native_sources.py is missing or broken: {exc}")
        return
    try:
        manifest = load_sources()
    except (OSError, ValueError) as exc:
        problems.append(f"native/sources.cmake: {exc}")
        return

    listed = set(manifest.all_sources())
    native = ROOT / "native"

    missing = sorted(rel for rel in listed if not (native / rel).is_file())
    for rel in missing:
        problems.append(f"native/sources.cmake lists native/{rel}, which does "
                        f"not exist; every build fails on the missing file")

    # The manifest must cover every library translation unit.  Executables and
    # host-side helpers (app/, tests/, platform/desktop/) are built by name and
    # are deliberately not listed.
    wanted: set[str] = set()
    for folder in ("util", "core", "source"):
        wanted |= {f"src/{folder}/{p.name}"
                   for p in (native / "src" / folder).glob("*.c")}
    for family in ("stub", "win32", "apple", "android"):
        wanted |= {f"src/platform/{family}/{p.name}"
                   for p in (native / "src" / "platform" / family).glob("*.c")}
    unlisted = sorted(wanted - listed)
    for rel in unlisted:
        problems.append(f"native/{rel} is not in native/sources.cmake; add it "
                        f"there or the file is never compiled")

    # A USB stick of a rule: both build scripts must go through the manifest
    # instead of carrying their own copy of the list.
    for script, marker in (
        (ROOT / "scripts" / "build_windows.py", "load_sources()"),
        (ROOT / "scripts" / "build_apple_deps.py", "load_sources()"),
    ):
        text = script.read_text(encoding="utf-8") if script.exists() else ""
        if marker not in text:
            problems.append(f"{script.name} must read native/sources.cmake via "
                            f"native_sources.{marker[4:]} instead of listing "
                            f"sources itself")
    cmake = (ROOT / "native" / "CMakeLists.txt").read_text(encoding="utf-8")
    # 只认真正的 include 行：注释里也提到过 sources.cmake，光比字符串会漏。
    if "include(${CMAKE_CURRENT_LIST_DIR}/sources.cmake)" not in cmake:
        problems.append("native/CMakeLists.txt must include(${CMAKE_CURRENT_LIST_DIR}"
                        "/sources.cmake) so CMake and the scripts share one list")
    if "elseif(WIN32)" not in cmake:
        problems.append("native/CMakeLists.txt has no WIN32 branch; a CMake build "
                        "on Windows would link the stub platform back end")

    if not problems:
        notes.append(f"source manifest: {len(listed)} native source(s) in one "
                     f"list shared by CMake and both build scripts")

def strip_c_comments(text: str) -> str:
    """Drop // and /* */ comments so literal checks only see real code.

    Several checks assert that a string is gone from a translation unit, but
    the same string can legitimately appear in a comment that explains the
    format (url.c documents `"smb://host/share/电影/"`).  Comparing raw text
    would then fail on a correct file.
    """
    out: list[str] = []
    i = 0
    n = len(text)
    in_line = False
    in_block = False
    in_string = False
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line:
            if ch == "\n":
                in_line = False
                out.append(ch)
            i += 1
            continue
        if in_block:
            if ch == "*" and nxt == "/":
                in_block = False
                i += 2
                continue
            if ch == "\n":
                out.append(ch)  # keep line numbering intact
            i += 1
            continue
        if in_string:
            out.append(ch)
            if ch == "\\" and nxt:
                out.append(nxt)
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == "/" and nxt == "/":
            in_line = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            in_block = True
            i += 2
            continue
        if ch == '"':
            in_string = True
        out.append(ch)
        i += 1
    return "".join(out)


def check_transport_registry() -> None:
    """Keep "add a protocol" a one-line change.

    Before this the transport layer was a struct plus a hand-written if-chain:
    adding a scheme meant editing the extern block in source_internal.h, the
    if-chain in lp_transport_find, the #if ladder inside lp_source_schemes, two
    build scripts, and a literal `smb://` in Dart.  Every one of those could be
    forgotten silently, and the symptom was a URL that parsed but never opened.

    Now a scheme is one const LpTransport plus one row in io.c's table, and
    everything else -- the scheme list, the URL shape, the "does this scheme
    need its own AVIO" decision, the default port -- is derived from that table.
    This check asserts that derivation actually stays derived.
    """
    source = ROOT / "native" / "src" / "source"
    io_c = (source / "io.c").read_text(encoding="utf-8")
    internal = (source / "source_internal.h").read_text(encoding="utf-8")
    url_c = (source / "url.c").read_text(encoding="utf-8")

    # 1. 注册表本身：一张表 + 一次查表，不允许再长出 if 链。
    if "static const LpTransport *const lp_transports[]" not in io_c:
        problems.append("native/src/source/io.c has no lp_transports[] table; a "
                        "new scheme would have to be wired up by hand again")
    find_body = re.search(r"const LpTransport \*lp_transport_find\(const char \*scheme\)\s*\{(.*?)\n\}",
                          io_c, re.S)
    if not find_body:
        problems.append("native/src/source/io.c: lp_transport_find() is gone "
                        "or no longer matches the registry shape")
    else:
        body = find_body.group(1)
        if "registry_lookup(" not in body:
            problems.append("lp_transport_find() must delegate to "
                            "registry_lookup(); an inline chain means every new "
                            "scheme edits this function")
        if body.count("strcmp(") > 1:
            problems.append("lp_transport_find() still compares scheme strings "
                            "by hand; scheme aliases belong in canonical_scheme()")

    # 2. scheme 列表必须从表里推导，不能再是一段 #if 手工拼装。
    schemes_body = re.search(r"int32_t lp_source_schemes\(char \*\*out_json\)\s*\{(.*?)\n\}",
                             io_c, re.S)
    if not schemes_body:
        problems.append("native/src/source/io.c: lp_source_schemes() is gone")
    else:
        body = schemes_body.group(1)
        for needle, why in (
            ("lp_transport_at(", "the scheme list must walk the registry"),
            ("public_scheme", "the scheme list must honour the transport's "
                              "public_scheme flag instead of #if ladders"),
        ):
            if needle not in body:
                problems.append(f"lp_source_schemes(): {why} ({needle} missing)")
        if "#if" in body:
            problems.append("lp_source_schemes() is back to an #if ladder; the "
                            "registry table already knows which schemes exist")

    # 3. 头文件不再逐个 extern 每份 transport：那是注册表要消灭的东西。
    if "extern const LpTransport lp_transport_" in internal:
        problems.append("source_internal.h still externs individual transports; "
                        "only io.c's table needs to know their names")

    # 4. 「要不要自己挂 AVIO」必须问注册表，不能在 demux/thumb 里重新判断。
    for rel, label in (("core/demux.c", "demux"), ("core/thumb.c", "thumbnail")):
        text = (ROOT / "native" / "src" / rel).read_text(encoding="utf-8")
        if "lp_transport_custom_io(" not in text:
            problems.append(f"native/src/{rel}: the {label} path no longer asks "
                            f"lp_transport_custom_io(), so a new scheme would "
                            f"silently get no AVIO")
        if re.search(r'strcmp\(\s*[a-z_.>-]*scheme[^,]*,\s*"file"\s*\)', text):
            problems.append(f"native/src/{rel}: back to comparing the scheme "
                            f"against \"file\" by hand")

    # 5. URL 拼装也只能依靠注册表：url.c 里不该再出现 "smb://" 字面量。
    #    注释里举的例子（`"smb://host/share/电影/"`）不算，先剥掉注释。
    code_only = strip_c_comments(url_c)
    for prefix in ('"smb://', '"file://'):
        if prefix in code_only:
            problems.append("native/src/source/url.c still hard-codes a scheme "
                            f"prefix ({prefix}); lp_url_authority() builds it "
                            "from LpTransport")

    # 6. FFmpeg-only 的 scheme 也要在清单里有位置。
    manifest = (ROOT / "native" / "sources.cmake").read_text(encoding="utf-8")
    if "src/source/ffmpeg.c" not in manifest:
        problems.append("native/sources.cmake lost src/source/ffmpeg.c; http(s) "
                        "would drop out of the scheme list")

    # 7. Dart 侧：scheme 字面量只允许出现在 scheme.dart 里。
    data = ROOT / "app" / "lib"
    offenders = []
    for path in data.rglob("*.dart"):
        if path.name == "scheme.dart":
            continue
        text = path.read_text(encoding="utf-8")
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            if "'smb://" in line or "'file://" in line:
                offenders.append(f"{path.relative_to(ROOT).as_posix()}: "
                                 f"{stripped[:80]}")
    for entry in offenders:
        problems.append(f"{entry} hard-codes a URL scheme; use LpScheme from "
                        f"app/lib/data/scheme.dart")

    if not problems:
        notes.append("transport registry: one table drives scheme list, URL "
                     "shape, AVIO choice and default ports")

def check_video_bridge_contract() -> None:
    """Keep the texture bridge's channel contract in one place.

    The bridge is implemented four times -- a Windows C++ plugin, a macOS Swift
    window controller, an iOS Swift app delegate, and an Android activity -- and
    the only thing tying them together is a method channel.  That contract used
    to be written nowhere: `app/lib/ui/video_texture.dart` held the Dart half as
    bare string literals, and each host spelled the same names out again in its
    own `switch`.  Renaming a key meant four edits and the failure mode was a
    silently missing texture (or a window pointer that stayed 0 on Android, so
    the core drew into nothing).

    Now the names live in `packages/lanplayer_video/lib/src/channel.dart`; the
    app-side file is a one-line re-export.  This check asserts the hosts still
    answer the names the contract declares, and that no new copy of the channel
    name has grown back in app code.
    """
    channel = ROOT / "packages" / "lanplayer_video" / "lib" / "src" / "channel.dart"
    bridge = ROOT / "packages" / "lanplayer_video" / "lib" / "src" / "bridge.dart"
    facade = ROOT / "app" / "lib" / "ui" / "video_texture.dart"

    if not channel.exists():
        problems.append("packages/lanplayer_video/lib/src/channel.dart is gone; "
                        "the four hosts would be back to four private copies of "
                        "the channel contract")
        return
    contract = channel.read_text(encoding="utf-8")
    for needle, why in (
        ("lanplayerVideoChannel", "the channel name has to be a named constant"),
        ("'lanplayer/video'", "the channel name itself belongs here"),
        ("createTexture", "the create method name belongs here"),
        ("attachPlayer", "the attach method name belongs here"),
        ("destroyTexture", "the destroy method name belongs here"),
        ("setFullscreen", "the fullscreen method name belongs here"),
        ("TextureWindowPtr", "the \"platform gave us a window\" sentinel must be "
                             "named, not a bare 0 at the call site"),
    ):
        if needle not in contract:
            problems.append(f"packages/lanplayer_video/lib/src/channel.dart no "
                            f"longer declares {needle!r}: {why}")

    # 1. Dart 侧封装必须走常量，不能自己再抄一份通道名。
    if bridge.exists():
        bd = bridge.read_text(encoding="utf-8")
        if "MethodChannel(lanplayerVideoChannel)" not in bd:
            problems.append("packages/lanplayer_video/lib/src/bridge.dart must "
                            "build its MethodChannel from lanplayerVideoChannel")
        if "'lanplayer/video'" in bd:
            problems.append("packages/lanplayer_video/lib/src/bridge.dart "
                            "hard-codes the channel name again")
    else:
        problems.append("packages/lanplayer_video/lib/src/bridge.dart is gone")

    # 2. app 侧只剩转发：它以前是这份契约的唯一（也是孤立的）副本。
    if not facade.exists():
        problems.append("app/lib/ui/video_texture.dart is gone; player_screen "
                        "cannot reach the bridge")
    else:
        fc = facade.read_text(encoding="utf-8")
        if "export 'package:lanplayer_video/" not in fc:
            problems.append("app/lib/ui/video_texture.dart no longer re-exports "
                            "package:lanplayer_video; the bridge API would have "
                            "to be copied back into the app")
        if "MethodChannel(" in fc:
            problems.append("app/lib/ui/video_texture.dart builds its own "
                            "MethodChannel again instead of using the package")

    # 3. app 代码里不该再出现通道名字面量。
    for path in (ROOT / "app" / "lib").rglob("*.dart"):
        for line in path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            if "'lanplayer/video'" in line or '"lanplayer/video"' in line:
                problems.append(f"{path.relative_to(ROOT).as_posix()} hard-codes "
                                f"the video channel name; import it from "
                                f"package:lanplayer_video instead")

    # 4. 四份宿主必须认同一套方法名。
    hosts = (
        ("packages/lanplayer_video/windows/lanplayer_video_plugin.cpp",
         ("createTexture", "attachPlayer", "destroyTexture", "setFullscreen")),
        ("app/android/app/src/main/kotlin/dev/lanplayer/app/MainActivity.kt",
         ("createTexture", "attachPlayer", "destroyTexture",
          "lockLandscape")),
        ("app/ios/Runner/AppDelegate.swift",
         ("createTexture", "attachPlayer", "destroyTexture",
          "lockLandscape")),
        ("app/macos/Runner/MainFlutterWindow.swift",
         ("createTexture", "attachPlayer", "destroyTexture", "setFullscreen")),
    )
    for rel, methods in hosts:
        path = ROOT / rel
        if not path.exists():
            problems.append(f"{rel} is missing; one of the four texture bridge "
                            f"hosts disappeared")
            continue
        text = path.read_text(encoding="utf-8")
        # 注释里提到通道名是正常的（macOS 的文件头就写了它是干什么的），
        # 这里只认代码行。
        code = "\n".join(
            line for line in text.splitlines()
            if not line.strip().startswith("//"))
        if "lanplayer/video" not in code:
            problems.append(f"{rel} no longer registers the lanplayer/video "
                            f"method channel")
        for method in methods:
            if f'"{method}"' not in code:
                problems.append(f"{rel} no longer handles \"{method}\"; the "
                                f"Dart side calls it through the shared "
                                f"contract in packages/lanplayer_video")

    # 5. window 指针哨兵：Android 拿到的是 ANativeWindow*，Apple/Windows 是 0。
    #    丢掉这个区分，Android 会像 Apple/Windows 一样跳过 lp_player_set_surface，
    #    内核就往一个不存在的窗口里画 —— 表现是「有音频、黑屏」。
    if not re.search(r"abstract final class TextureWindowPtr\b", contract):
        problems.append("packages/lanplayer_video/lib/src/channel.dart lost the "
                        "TextureWindowPtr sentinel; Android would look like "
                        "Apple/Windows and skip lp_player_set_surface")
    if bridge.exists():
        bd = bridge.read_text(encoding="utf-8")
        if "TextureWindowPtr.inProcess" not in bd:
            problems.append("packages/lanplayer_video/lib/src/bridge.dart no "
                            "longer derives needsSurface from "
                            "TextureWindowPtr.inProcess")

    if not problems:
        notes.append("video bridge: one channel contract, four hosts answering "
                     "the same names")

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
        problems.append("the volume bar must still close out the drag on "
                        "release; without onChangeEnd a release leaves the "
                        "auto-hide timer paused")
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
    else:
        th = theme.read_text(encoding="utf-8")
        if "fontFamily: fontFamily" not in th:
            problems.append("theme.dart no longer sets fontFamily; the default UI "
                            "font would silently go back to the platform default")
        # 深浅色跟随系统（评审 4.6）：只有 dark() 的时候，系统设成浅色的用户
        # 会看到一个写死深色的界面，而 README 承诺的是跟随系统。
        if "static ThemeData light()" not in th or "static ThemeData dark()" not in th:
            problems.append("theme.dart must expose both light() and dark(); with "
                            "only one of them the app is stuck on a single "
                            "brightness no matter what the system says")
        main_dart = ROOT / "app" / "lib" / "main.dart"
        if main_dart.exists():
            md = main_dart.read_text(encoding="utf-8")
            # 外观可选（用户 2026-11-01）：默认黑、可选白或跟随系统。主入口
            # 要订阅 ThemeController，把用户选的那一档交给 MaterialApp；写死
            # ThemeMode.system 等于又把选项吞回去了。
            if "ThemeController.toThemeMode(" not in md:
                problems.append("main.dart must derive themeMode from "
                                "ThemeController.toThemeMode(); a fixed "
                                "ThemeMode would ignore the appearance setting")
            if "ValueListenableBuilder<AppThemeMode>" not in md:
                problems.append("main.dart must rebuild MaterialApp when the "
                                "appearance setting changes "
                                "(ValueListenableBuilder<AppThemeMode>)")
            if "darkTheme:" not in md:
                problems.append("main.dart must set darkTheme as well as theme; "
                                "one of the two is always missing without it")
            if "ThemeController.instance.apply(" not in md:
                problems.append("main.dart must seed the controller from the "
                                "saved settings during boot; without it the "
                                "window flashes the default theme first")

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


def check_player_rebuild_scope() -> None:
    """播放页的重建范围：位置与字幕只重建该重建的那一小块。

    内核每 200 ms 推一次 POSITION、带 `\\t` 的字幕每 20 ms 推一次 SUBTITLE。
    这两类事件原来都走 `notifyListeners()`，而播放页的监听器是
    `setState(() {})` —— 整页控件树（顶栏、底栏、按钮行列）跟着 50 Hz 重排。
    界面上看不出差别，代价却是一整个核。现在它们各走一条 ValueNotifier
    通道，只有底栏和字幕层订阅。

    这类退化不会报错、不会崩溃，只是在慢一点的机器上掉帧，所以只能用静态
    断言钉住：谁把 `notifyListeners()` 加回 `case 2` / `case 6`，谁就得看到
    这条红。
    """
    controller = ROOT / "app" / "lib" / "core" / "player_controller.dart"
    if not controller.exists():
        problems.append("app/lib/core/player_controller.dart missing")
        return
    cc = controller.read_text(encoding="utf-8")
    for token, why in (
        ("final ValueNotifier<int> positionUsNotifier",
         "the position channel that keeps POSITION out of the page rebuild"),
        ("final ValueNotifier<SubtitleCue> cueNotifier",
         "the subtitle channel that keeps animated cues out of the page rebuild"),
    ):
        if token not in cc:
            problems.append(f"player_controller.dart lost {token} ({why})")

    # 负向对照：位置分支必须在更新通道后直接返回。落到末尾那行
    # `notifyListeners()` 就等于整页重建，等于这次改动没做。
    position = cc.split("case 2: // position", 1)[-1].split("case 3:", 1)[0]
    if "positionUsNotifier.value" not in position:
        problems.append("player_controller.dart: the POSITION branch no longer "
                        "feeds positionUsNotifier; the progress bar would be "
                        "frozen because nothing else listens to it")
    if "return;" not in position:
        problems.append("player_controller.dart: the POSITION branch falls "
                        "through to notifyListeners(); the whole player page "
                        "would rebuild five times a second")
    subtitle = cc.split("case 6: // subtitle", 1)[-1].split("case 7:", 1)[0]
    if "cueNotifier.value = cue;" not in subtitle:
        problems.append("player_controller.dart: the SUBTITLE branch no longer "
                        "feeds cueNotifier; subtitles would stop updating")
    if "return;" not in subtitle:
        problems.append("player_controller.dart: the SUBTITLE branch falls "
                        "through to notifyListeners(); an animated cue rebuilds "
                        "the whole page at 50 Hz")
    if "positionUsNotifier.dispose()" not in cc or "cueNotifier.dispose()" not in cc:
        problems.append("player_controller.dart must dispose the two notifiers; "
                        "a listener added by ValueListenableBuilder keeps the "
                        "State alive after the page is gone")

    screen = ROOT / "app" / "lib" / "ui" / "player_screen.dart"
    if not screen.exists():
        problems.append("player_screen.dart missing")
        return
    text = screen.read_text(encoding="utf-8")
    if "valueListenable: _player.cueNotifier" not in text:
        problems.append("player_screen.dart no longer subscribes SubtitleOverlay "
                        "to cueNotifier; dropping the subscription either "
                        "freezes subtitles or forces the page back to a full "
                        "rebuild")
    if "valueListenable: _player.positionUsNotifier" not in text:
        problems.append("player_screen.dart no longer subscribes the transport "
                        "row to positionUsNotifier; the progress bar would only "
                        "move on unrelated rebuilds")
    # 负向对照：整页不能再直接读 cue / positionUs —— 读了就说明它还在靠
    # notifyListeners 驱动。
    bare = text.replace("_player.cueNotifier", "").replace(
        "_player.positionUsNotifier", "")
    if "_player.cue," in bare or "_player.cue)" in bare:
        problems.append("player_screen.dart still reads _player.cue directly; "
                        "the subtitle layer must come from cueNotifier or the "
                        "page rebuilds on every animation frame")
    if "final position =\n        _dragValue ?? _player.positionUs" in text:
        problems.append("player_screen.dart is back to computing the transport "
                        "position in build(); it belongs inside the "
                        "positionUsNotifier listener")

    overlay = ROOT / "app" / "lib" / "ui" / "widgets" / "subtitle_overlay.dart"
    if not overlay.exists():
        problems.append("widgets/subtitle_overlay.dart missing")
        return
    ot = overlay.read_text(encoding="utf-8")
    if "items: _drawingsWithPlacement()" in ot:
        problems.append("subtitle_overlay.dart calls _drawingsWithPlacement() a "
                        "second time inside the painter; that walk resolves "
                        "every animation again for nothing")
    if "oldDelegate.items != items" in ot:
        problems.append("subtitle_overlay.dart: _DrawingsPainter.shouldRepaint "
                        "compares the items list, which is rebuilt every frame, "
                        "so it is always true and the canvas repaints at the "
                        "display rate")
    if "identical(oldDelegate.cue, cue)" not in ot:
        problems.append("subtitle_overlay.dart: _DrawingsPainter must key its "
                        "repaint decision on the cue identity; comparing lists "
                        "makes shouldRepaint a constant true")
    if "_resolved.putIfAbsent(" not in ot:
        problems.append("subtitle_overlay.dart lost the per-build animation "
                        "cache; each run would be resolved once per text layer "
                        "(shadow + outline + body + clip)")

    if "void _noteActivity()" not in text or "void _hideWhenIdle()" not in text:
        problems.append("player_screen.dart lost the single-timer auto-hide; "
                        "re-creating a Timer on every hover event churns "
                        "hundreds of timers a second while the pointer moves")
    hover = text.split("void _onPointerHover(", 1)[-1].split("///", 1)[0]
    if "_hideTimer?.cancel()" in hover:
        problems.append("_onPointerHover cancels the auto-hide timer directly; "
                        "route it through _noteActivity so the timer is only "
                        "re-armed when it has actually stopped")

    notes.append("player rebuild scope: position and subtitles have their own "
                 "channels, only the transport row and the subtitle layer "
                 "rebuild, and one timer covers the whole hover burst")


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
            raw = path.read_bytes()
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError as exc:
                bad.append(f"{path.relative_to(ROOT).as_posix()}: not valid UTF-8 "
                           f"({exc.reason} at byte {exc.start}); Python would fail "
                           f"to import it")
                continue
            # A comment that quotes `\1c` gets its backslash eaten by an editor
            # that was aiming at the next character, which leaves a real control
            # byte in the file: invisible in a diff, and a build log full of
            # escape sequences.  Tab, CR and LF are the only ones we want.
            ctrl = sorted({hex(ord(c)) for c in text if ord(c) < 32 and ord(c) not in (10, 13, 9)})
            if ctrl:
                bad.append(f"{path.relative_to(ROOT).as_posix()}: raw control "
                           f"characters {' '.join(ctrl)}; the intended text was "
                           f"probably an escape sequence")

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

    # 测试与探针临时目录必须落在仓库里。旧写法把 TEMP 缺失兜底成 "."，
    # 也就是**当前目录**。从 D:\ 起一次验证，就在用户自己的盘根留下
    # D:\lp-upgrade-test 这类目录（真实的踩坑）。本文件自己会提到那段代码
    # 形状，所以跳过它。
    offenders: list[str] = []
    for folder in (ROOT / "scripts", ROOT / "tool"):
        if not folder.is_dir():
            continue
        for path in sorted(folder.rglob("*.py")):
            if path.name == "check_all.py":
                continue
            text = path.read_text(encoding="utf-8")
            if 'environ.get("TEMP", ".")' in text:
                offenders.append(
                    f"{path.relative_to(ROOT).as_posix()}: falls back to the current "
                    f"directory when TEMP is unset; use lp.scratch_dir(...) so test "
                    f"artefacts stay under .tools/tmp")
    if not (ROOT / "tool" / "lpscript.py").read_text(encoding="utf-8").count(
            "def scratch_dir("):
        offenders.append("tool/lpscript.py lost scratch_dir(); test scripts would "
                         "have nowhere repo-local to put their temp files")
    if offenders:
        problems.extend(offenders)


def check_dead_code() -> None:
    """Grep-level guard for the P3 clean-up (chapter 5 of the 0.1.7 review).

    Every item here was a real bug of the same shape: code that looks alive but
    is not wired to anything. None of them crash or print a warning, so the only
    way to keep them from creeping back is a static assertion. Each entry below
    names what breaks if the old code returns.

    The positive controls matter as much as the negative ones: deleting a dead
    function is fine until it was not actually dead.
    """
    def body(rel: str) -> str:
        path = ROOT / rel
        if not path.exists():
            problems.append(f"{rel} missing")
            return ""
        return path.read_text(encoding="utf-8")

    # 死代码：这些函数/方法全仓无调用者，留着只会让后来者以为有入口。
    for rel, token, why in (
        ("app/lib/ui/media_permission.dart",
         "static Future<MediaPermissionResult> status()",
         "status() had no caller; the only moment permissions are needed is "
         "opening a directory, and request() already returns the current "
         "result, so a query-only entry point is a second round trip"),
        ("app/lib/ui/feedback.dart",
         "Future<void> showSnack(",
         "showSnack() had no caller; every call site uses "
         "ScaffoldMessenger.showSnackBar directly"),
        ("app/lib/player/playlist.dart",
         "parseEpisode(",
         "parseEpisode() had no caller; episode order comes from the core's "
         "natural_cmp, and keeping a second parser invites the two to disagree"),
        ("app/lib/player/playlist.dart",
         "appendEpisodes(",
         "appendEpisodes() had no caller; a playlist is always built from a "
         "whole listing"),
        ("app/lib/ui/video_texture.dart",
         "static Future<void> resize(",
         "VideoTextureBridge.resize() had no Dart caller and the Windows "
         "plugin answered it with a bare Success()"),
        ("packages/lanplayer_video/windows/lanplayer_video_plugin.cpp",
         '"resizeTexture"',
         "the resizeTexture method channel case is dead: nothing on the Dart "
         "side calls it, and it only acknowledged the call"),
        ("app/android/app/src/main/kotlin/dev/lanplayer/app/MainActivity.kt",
         '"resizeTexture"',
         "the resizeTexture method channel case is dead: nothing on the Dart "
         "side calls it, and it only acknowledged the call"),
        ("app/ios/Runner/AppDelegate.swift",
         '"resizeTexture"',
         "the resizeTexture method channel case is dead: nothing on the Dart "
         "side calls it, and it only acknowledged the call"),
        ("app/macos/Runner/MainFlutterWindow.swift",
         '"resizeTexture"',
         "the resizeTexture method channel case is dead: nothing on the Dart "
         "side calls it, and it only acknowledged the call"),
        ("app/lib/core/bindings.dart",
         "installFrameCallback",
         "installFrameCallback() had no caller and the symbol it binds is not "
         "in lp_map.txt, so it could never have resolved at runtime"),
        ("app/lib/core/player_controller.dart",
         "void Function()? onReady;",
         "PlayerController.onReady was never assigned; media readiness is "
         "observed through the mediaInfo event"),
        ("native/src/player_internal.h",
         "LP_PLATFORM_DESKTOP",
         "the LP_PLATFORM_DESKTOP/APPLE/ANDROID block was defined and never "
         "used by any #if; the real platform switch is the CMake source list"),
        ("app/lib/data/track_prefs.dart",
         "[allowNull]",
         "pickTrack's doc promised an allowNull parameter that does not exist"),
        ("native/include/lanplayer/lp_player.h",
         "event_port.dart",
         "the header pointed at a Dart file that no longer exists"),
    ):
        if token in body(rel):
            problems.append(f"{rel}: {why}")

    # lp_preview.c 里手写的 json_str() 与内核 lp_json_get_str 重复，
    # 两份实现对转义与嵌套的处理迟早走岔（预览窗口显示错的值）。
    preview = body("native/src/app/lp_preview.c")
    if "static void json_str(" in preview:
        problems.append("native/src/app/lp_preview.c reintroduced its own "
                        "json_str(); the preview probe would parse events with "
                        "a second, subtly different parser than the one the "
                        "core ships")
    if preview and "lp_json_get_str(" not in preview:
        problems.append("native/src/app/lp_preview.c no longer reads the event "
                        "payload through lp_json_get_str()")

    # demux 的 discardcorrupt 提示以前写进一个随即 free 掉的临时字典，
    # 等于什么都没做。字典必须交给 avformat_find_stream_info。
    demux = body("native/src/core/demux.c")
    if demux:
        if 'hint_dict(&ifo, "discardcorrupt", "1")' not in demux:
            problems.append("native/src/core/demux.c lost the discardcorrupt "
                            "hint; high-bitrate files decode corrupt packets "
                            "that the player then has to drop")
        elif "avformat_find_stream_info(fmt, &ifo)" not in demux:
            problems.append("native/src/core/demux.c builds the options "
                            "dictionary but does not hand it to "
                            "avformat_find_stream_info(); freeing it right "
                            "after filling it is the same as not setting it")

    # pthread_join 的返回值。失败说明线程还活着，随后释放它的上下文就是
    # use-after-free —— 以前所有调用点都无声地扔掉了返回值。
    ignores: list[str] = []
    for rel in (
        "native/src/core/audio.c",
        "native/src/core/video.c",
        "native/src/core/player.c",
        "native/src/platform/stub/stub_platform.c",
        "native/src/platform/win32/win32_platform.c",
    ):
        src = body(rel)
        for line in src.splitlines():
            stripped = line.strip()
            # 只认「单独一行、既没接返回值也没断言」的调用。
            if not stripped.startswith("pthread_join("):
                continue
            ignores.append(f"{rel}:{line.strip()}")
    if ignores:
        problems.append("pthread_join return value ignored again at "
                        + "; ".join(ignores)
                        + " -- a failed join means the thread is still running "
                          "while its context gets freed")

    # 事件类型曾经是一串裸字面量（case 1: ... case 10:），与 lp_types.h
    # 的 LP_EVENT_* 各写一份。改常量表就等于改协议，得两边一起看。
    bindings = body("app/lib/core/bindings.dart")
    if bindings and "abstract final class LpEvent" not in bindings:
        problems.append("app/lib/core/bindings.dart lost the LpEvent constant "
                        "table; raw ints in the event switch drift from "
                        "native/include/lanplayer/lp_types.h")
    controller = body("app/lib/core/player_controller.dart")
    if controller:
        if "case LpEvent.position:" not in controller:
            problems.append("player_controller.dart no longer names the event "
                            "constants; a renumbered LP_EVENT_* would silently "
                            "route events to the wrong branch")
        # dispose 与 disposePlayer 曾经逐行相同、各调一次 super.dispose()。
        if "bool _teardown()" not in controller:
            problems.append("player_controller.dart lost the shared _teardown(); "
                            "dispose() and disposePlayer() must not both close "
                            "the player, or the second call double-frees the "
                            "native handle")
        if controller.count("super.dispose();") != 2:
            problems.append("player_controller.dart should call super.dispose() "
                            "exactly twice (once per public teardown path); "
                            "duplicating it inside the shared helper would "
                            "dispose the ChangeNotifier twice")

    # main.dart 的注释写着「并行加载」而代码是四个串行 await：启动白屏的
    # 长度等于四次磁盘 IO 之和。
    main_dart = body("app/lib/main.dart")
    if main_dart and "Future.wait<void>(" not in main_dart:
        problems.append("app/lib/main.dart is back to serialising the four "
                        "store loads; the start-up splash lasts as long as the "
                        "sum of four reads instead of the slowest one")

    # 目录 id 只用毫秒时间戳，同一毫秒内加两个目录会撞同一个 id，
    # 随后删除其中一个会把另一个一起带走。
    folders = body("app/lib/data/folders.dart")
    if folders:
        if "_newId(" not in folders:
            problems.append("app/lib/data/folders.dart lost the sequence-"
                            "stamped id helper")
        if "'dir-${DateTime.now().millisecondsSinceEpoch}'" in folders:
            problems.append("app/lib/data/folders.dart is back to a bare "
                            "millisecond id; two folders added in the same "
                            "millisecond collide, and removing one removes both")

    # 源码里混进控制字符：cat 看得见、diff 看不见，改了行却不知道改了什么。
    for rel in (
        "app/lib/data/models.dart",
        "app/lib/data/subtitle_anim.dart",
        "app/lib/core/player_controller.dart",
        "app/lib/ui/player_screen.dart",
    ):
        text = body(rel)
        bad = [f"0x{ord(ch):02x}" for ch in text if ord(ch) < 32
               and ch not in "\n\r\t"]
        if bad:
            problems.append(f"{rel} contains control character(s) {', '.join(sorted(set(bad)))}")

    # \t(\clip(...)) 只改矩形不置 clipOn 的话，整条动画白算；
    # 颜色动画从白色起步会让深色样式在动画开头闪一下。
    anim = body("app/lib/data/subtitle_anim.dart")
    if anim:
        if "inheritColor" not in anim:
            problems.append("app/lib/data/subtitle_anim.dart lost inheritColor; "
                            "a colour animation on a run without \\c would "
                            "start from white and flash")
        clip_branch = anim.split("fieldClip", 1)[-1][:400]
        if "clipOn = true;" not in clip_branch:
            problems.append("app/lib/data/subtitle_anim.dart: the clip "
                            "animation updates the rectangle but not clipOn, so "
                            "\\t(\\clip(...)) never takes effect")

    notes.append("dead code: the review's unused entry points are gone, the "
                 "event table has names, pthread_join results are checked, and "
                 "no control characters hide in the Dart sources")


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

    models = DATA / "models.dart"
    if models.exists():
        mt = model_text()
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

    models = DATA / "models.dart"
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
        mt = model_text()
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

    # \iclip 与 \fr<N> 曾各自被解析错：\iclip 因为共用首字母 'i' 被当成「开启
    # 斜体」，矩形整个丢掉；\fr45 因为「后面有没有参数」的判据而进不去，角度
    # 永远停在 0。两条都要有正向标记 + 负向对照。
    if header.exists():
        ht = header.read_text(encoding="utf-8")
        if "int clip_inverse;" not in ht:
            problems.append(
                "player_internal.h lost LpSubRun.clip_inverse; \\iclip would "
                "be painted the same way as \\clip, i.e. keep the wrong half")
    if core.exists():
        ct = core.read_text(encoding="utf-8")
        # \fr 简写：rz/rx/ry 已被前面的分支吃掉，剩下的 'r' 只可能是 \fr，
        # 不能再拿 tag_has_arg() 当「没有后缀」的判据。
        if '!strncmp(p, "r", 1) && !tag_has_arg(p + 1)' in ct:
            problems.append(
                "native/src/core/subtitle.c: the \\fr branch is gated on "
                "tag_has_arg() again; \\fr45 would parse as a bare \\fr")
        if "b->st.clip_inverse = 1;" not in ct:
            problems.append(
                "native/src/core/subtitle.c: no tag sets clip_inverse any "
                "more; every \\iclip would paint the inside of the window")
        # 无 BOM 的 UTF-16：NUL 不能被当成合法 UTF-8 字节，否则整份文件
        # 「通过」校验、不回落到 UTF-16 分支，解析出 0 条 cue。
        if "static int guess_utf16(" not in ct:
            problems.append(
                "native/src/core/subtitle.c lost guess_utf16(); a subtitle "
                "saved as BOM-less UTF-16 would decode to mojibake")
        if "if (c == 0) {" not in ct.split("static int is_valid_utf8(", 1)[-1][:600]:
            problems.append(
                "native/src/core/subtitle.c: is_valid_utf8() accepts 0x00 "
                "again; BOM-less UTF-16 files would be taken as UTF-8")
        # 切轨要清掉图形字幕的 overlay，否则 PGS 的残留矩形会永久贴在画面上。
        select = ct.split("void lp_subtitle_select(", 1)[-1][:1400]
        if "overlay_reset(&p->subs.overlay)" not in select:
            problems.append(
                "native/src/core/subtitle.c: lp_subtitle_select() no longer "
                "clears the bitmap overlay; leftovers from a PGS track stay "
                "on screen after switching to a text track")
    if overlay.exists():
        ot = overlay.read_text(encoding="utf-8")
        if "PathOperation.difference" not in ot:
            problems.append(
                "subtitle_overlay.dart lost the inverted clip path; \\iclip "
                "would hide exactly the region it should keep")

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

    models = DATA / "models.dart"
    if models.exists():
        mt = model_text()
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
        ("lp_nal_avcc_to_annexb(", "the AVCC -> Annex-B conversion no longer defers "
                                   "to the shared, behaviour-tested one in "
                                   "src/core/nal.c; a local copy drifts and "
                                   "MediaCodec then accepts every packet and "
                                   "decodes nothing (black screen)"),
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
        "native/src/platform/win32/d3d11va_decoder.c": ("D3D11VA", 0),
        "native/src/platform/apple/videotoolbox_decoder.c": ("VideoToolbox", 1),
        "native/src/platform/android/media_codec_decoder.c": ("MediaCodec", 1),
    }
    for rel, (name, refuse) in backends.items():
        path = ROOT / rel
        if not path.exists():
            problems.append(f"{rel} is gone; the {name} profile guard lives there")
            continue
        text = path.read_text(encoding="utf-8")
        # The list itself is not restated here: lp_nal_test.exe drives
        # lp_hw_profile_needs_software() with real profile numbers, so what is
        # left to check per backend is that it consults the shared rule (and with
        # the right answer for 10-bit HEVC on that platform).
        if "profile_needs_software(" not in text:
            problems.append(f"{rel} lost profile_needs_software(); {name} would be "
                            "handed 10-bit H.264 and would freeze on the first frame")
        elif not re.search(rf"lp_hw_profile_needs_software\([^\n]*[,(]\s*{refuse}\s*\)",
                           text):
            # A plain `, 1)` substring is too weak: those two bytes occur in
            # unrelated calls elsewhere in the same file, so the check would stay
            # green after the argument was flipped.  The first argument may itself
            # be a cast such as `(int)id`, hence the looser left edge.
            problems.append(f"{rel}: {name} no longer calls "
                            f"lp_hw_profile_needs_software(..., {refuse}); a hand-copied "
                            "profile list drifts and the freeze returns")
        if "profile_needs_software(cfg->codec_id, cfg->par->profile)" not in text:
            problems.append(f"{rel} no longer calls profile_needs_software() from "
                            "lp_hw_decoder_init(); the guard would never run")

    # 10-bit HEVC is a *different* failure on each platform, so the answer differs:
    # VideoToolbox decodes it at 2-9 fps (audio clock runs away, the picture
    # freezes), MediaCodec accepts every input buffer and dequeues none
    # (Qin:456 DQout:0/456 Render:0 -- a black frame with a walking progress
    # bar), and D3D11VA handles it fine, so Windows must NOT refuse it.  That is
    # the whole reason lp_hw_profile_needs_software() takes refuse_hevc at all;
    # the loop above already pins which answer each backend passes, and
    # lp_nal_test.exe pins the resulting truth table on Windows.

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
        "native/src/platform/apple/videotoolbox_decoder.c": ("VideoToolbox to_avcc()",
                                                             "lp_nal_annexb_to_avcc("),
        "native/src/platform/android/media_codec_decoder.c": ("MediaCodec to_annexb()",
                                                              "lp_nal_avcc_to_annexb("),
    }
    for rel, (name, convert) in callers.items():
        path = ROOT / rel
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        if "lp_nal_is_annexb(" not in text:
            problems.append(f"{name} in {rel} no longer calls lp_nal_is_annexb(); "
                            "length-prefixed packets that begin 00 00 01 would be "
                            "converted as if they were Annex-B and decode to nothing")
        elif convert not in text:
            problems.append(f"{name} in {rel} no longer calls {convert}; a second "
                            "hand-written converter is the copy that drifts")
    # The three entry points no longer each carry their own copy of the list;
    # they all reach native/src/core/{nal,hwprofile}.c through native/sources.cmake,
    # which check_source_manifest() verifies contains them.
    manifest = ROOT / "native" / "sources.cmake"
    manifest_text = manifest.read_text(encoding="utf-8") if manifest.exists() else ""
    for rel in ("src/core/nal.c", "src/core/hwprofile.c"):
        if rel not in manifest_text:
            problems.append(f"native/sources.cmake no longer compiles {rel}; "
                            "the decoders would fail to link")

    notes.append("playback profiles: hwaccel refuses 10-bit H.264 on all three "
                 "platforms, 10-bit HEVC on Apple + Android only, d3d11va draws "
                 "software frames instead of dropping them")
    notes.append("nal framing: start code vs length prefix decided by walking the "
                 "whole chain; one converter pair shared by VideoToolbox and "
                 "MediaCodec, driven by lp_nal_test.exe")

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
    else:
        # macOS 的全屏一度是 `result(false)` 的空实现：用户按 F11 时窗口不动、
        # 系统栏也不收，看着就是按钮坏了。这里钉住两件事 —— 走 AppKit 的原生
        # 全屏，并且用返回值告诉 Dart 有没有成功。
        macos_window = (APP / "macos" / "Runner" / "MainFlutterWindow.swift").read_text(
            encoding="utf-8")
        if "toggleFullScreen(nil)" not in macos_window:
            problems.append("macOS fullscreen must call AppKit toggleFullScreen; "
                            "resizing the styleMask alone leaves the menu bar on top")
        if "result(false)\n\n      default:" in macos_window:
            problems.append("macOS setFullscreen still answers false; the player then "
                            "shows a fullscreen HUD over an unchanged window")
        # swiftc 不认 `.fullscreen`：NSWindow.StyleMask 的成员是 `.fullScreen`
        # （大写 S）。写成小写时整份 Runner 编不过 —
        # "type 'NSWindow.StyleMask' has no member 'fullscreen'" —
        # 而这条只在 Mac 上真编一次才会暴露，Windows 侧一直没发现。
        if "styleMask.contains(.fullscreen)" in macos_window:
            problems.append("MainFlutterWindow.swift compares styleMask against "
                            ".fullscreen, but AppKit spells the member .fullScreen; "
                            "swiftc rejects it and the Runner never builds")

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


def check_offline_shortcut() -> None:
    """Do not dial a server again when we already know it is down.

    Opening a folder used to call the repository unconditionally, so a server
    that was off cost the user another full socket timeout (15 s) before the
    error dialog appeared - even though that very source was already showing
    an error row with a retry button.
    """

    health = ROOT / "app/lib/data/source_health.dart"
    if not health.exists():
        problems.append(
            "app/lib/data/source_health.dart is missing; nothing remembers that "
            "a source is offline, so every click would dial it again")
        return

    hs = health.read_text(encoding="utf-8", errors="replace")
    for token, why in (
            ("class SourceHealth extends ChangeNotifier",
             "the health state has to be observable so the home screen can repaint"),
            ("static final SourceHealth instance",
             "callers share one instance; a per-widget copy would never agree"),
            ("void markOffline(", "nothing can mark a source offline"),
            ("void markOnline(", "a source could never come back online"),
            ("void forget(", "removing a source would leave a stale offline entry"),
    ):
        if token not in hs:
            problems.append(f"app/lib/data/source_health.dart: {why} ({token})")

    if "请重新连接服务器或刷新后重试" not in hs:
        problems.append(
            "app/lib/data/source_health.dart: the offline hint lost its "
            "'请重新连接服务器或刷新后重试' tail; users would not know what to do")

    home = ROOT / "app/lib/ui/home_screen.dart"
    hc = home.read_text(encoding="utf-8", errors="replace")

    # `_openRootInner` 与 `_enterSubdirInner` 都必须先查已知状态，命中就直接返回。
    # 外层那一对只负责「同一个目标正在打开时去重」，真正的动作在内层里。
    for name in ("_openRootInner", "_enterSubdirInner"):
        start = hc.find(f"Future<void> {name}(")
        if start < 0:
            problems.append(f"app/lib/ui/home_screen.dart: {name} is gone")
            continue
        body = hc[start:]
        end = body.find("\n  }")
        body = body[:end if end > 0 else 1200]
        if "SourceHealth.instance.offlineReason(" not in body:
            problems.append(
                f"app/lib/ui/home_screen.dart: {name} does not consult the "
                "known offline state; tapping it on a dead server would wait "
                "for another socket timeout")
        if "offlineHint(" not in body:
            problems.append(
                f"app/lib/ui/home_screen.dart: {name} no longer shows the "
                "offline hint")

    # 去重壳子必须同时包住这两条：少了任何一条，双击目录就会 push 两层。
    for name in ("_openRoot", "_enterSubdir"):
        start = hc.find(f"Future<void> {name}(")
        if start < 0:
            problems.append(f"app/lib/ui/home_screen.dart: {name} is gone")
            continue
        body = hc[start:]
        end = body.find("\n  }")
        body = body[:end if end > 0 else 600]
        if "_opening != null" not in body:
            problems.append(
                f"app/lib/ui/home_screen.dart: {name} lost its in-flight "
                "guard; a double tap would push the same page twice")

    if "SourceHealth.instance.markOffline(" not in hc:
        problems.append(
            "app/lib/ui/home_screen.dart: a failed load no longer records the "
            "source as offline")
    if "SourceHealth.instance.markOnline(" not in hc:
        problems.append(
            "app/lib/ui/home_screen.dart: a successful load no longer clears "
            "the offline flag")
    if "SourceHealth.instance.forget(" not in hc:
        problems.append(
            "app/lib/ui/home_screen.dart: removing a source no longer forgets "
            "its health entry")

    browser = ROOT / "app/lib/ui/browser_screen.dart"
    bc = browser.read_text(encoding="utf-8", errors="replace")
    if "final String? sourceId;" not in bc:
        problems.append(
            "app/lib/ui/browser_screen.dart: the browser page lost its "
            "sourceId, so failures inside it cannot be attributed to a source")
    if "_markOffline(e.message)" not in bc:
        problems.append(
            "app/lib/ui/browser_screen.dart: a failed navigation no longer "
            "records the source as offline")

    # 异步守卫：await 之后必须先看 mounted 再动状态，否则请求飞行中被 pop
    # 掉的页面会抛 "setState() called after dispose()"。代际号则负责丢掉
    # 「点了 A 又点 B，A 后到」的过期响应。
    nav_part = bc.split("Future<void> _navigate(", 1)[-1].split(
        "Future<void> _reload(", 1)[0]
    if "if (!mounted || _navGen != gen) return;" not in nav_part:
        problems.append(
            "app/lib/ui/browser_screen.dart: _navigate must guard on mounted and "
            "the navigation generation after its await; without it a page popped "
            "mid-request calls setState on a disposed State")
    picker_nav = ROOT / "app/lib/ui/folder_picker.dart"
    if picker_nav.exists():
        pc_nav = picker_nav.read_text(encoding="utf-8", errors="replace")
        enter_part = pc_nav.split("Future<void> _enter(", 1)[-1].split(
            "Future<void> _reload(", 1)[0]
        if "if (!mounted || _navGen != gen) return;" not in enter_part:
            problems.append(
                "app/lib/ui/folder_picker.dart: _enter must compare the request "
                "generation, otherwise two quick taps stack the wrong path")

    notes.append(
        "offline: a failed listing marks its source offline, and opening it "
        "again shows the hint instead of dialling the dead server")


def check_ui_thread() -> None:
    """Keep blocking native calls off the Flutter UI thread.

    `lp_source_list` and `lp_source_probe` are synchronous: they open a TCP
    connection, negotiate SMB2 and read a directory, and when the server does
    not answer they sit there until the socket times out (15 s by default).
    Called from the main isolate they freeze everything the user can see --
    the window paints nothing (a solid white client area), buttons produce no
    ripple, spinners stop turning and a "retry" tap does nothing at all.

    The fix is that the repository hands those calls to `Isolate.run`.  It is
    easy to undo without noticing, because the code still compiles, the unit
    tests still pass and it only misbehaves when a share is unreachable.
    """
    bg = ROOT / "app/lib/core/background.dart"
    repo = ROOT / "app/lib/data/repository.dart"
    if not bg.exists():
        problems.append(
            "app/lib/core/background.dart is gone; the directory listing would "
            "run on the UI thread again and freeze the window when a share is "
            "unreachable")
        return
    text = bg.read_text(encoding="utf-8")
    for raw in ("_listRaw(url, options)", "_probeRaw(url, options)"):
        # 两个入口都必须各自包一层 Isolate.run —— 只包住其中一个，
        # 另一条路径（例如「添加服务器」时的凭据校验）照样会冻住界面。
        if f"Isolate.run(() => {raw})" not in text:
            problems.append(
                f"background.dart calls {raw} outside Isolate.run(); that "
                f"blocking native call would run on the UI thread")
    for name in ("listDirectoryInBackground", "probeServerInBackground"):
        if name not in text:
            problems.append(
                f"background.dart lost {name}(); the UI would call the "
                f"blocking native function directly")

    if not repo.exists():
        problems.append("app/lib/data/repository.dart is gone")
        return
    src = repo.read_text(encoding="utf-8")
    if "fetchListing ?? listDirectoryInBackground" not in src:
        problems.append(
            "repository.dart no longer defaults its listing fetcher to the "
            "background isolate; scrolling into a dead share would freeze "
            "the window")
    if "_core.listDirectory(" in src:
        problems.append(
            "repository.dart calls _core.listDirectory() on the UI thread "
            "again; that is the call that freezes the window for 15 s")
    # 三个列目录入口必须各自把「取不到」变成异常。少一个，那条路径就会
    # 静默返回空列表 —— 用户看到「这里是空的」而不是「连不上」。
    for method, next_marker in (
        ("Future<DirectoryListing> browse(", "Future<DirectoryListing> browseUrl("),
        ("Future<DirectoryListing> browseUrl(", "Future<SourceProbe> probeServer("),
        ("Future<DirectoryListing> browseLocal(", "localRoots("),
    ):
        start = src.find(method)
        end = src.find(next_marker, start + 1)
        body = src[start:end] if start >= 0 and end > start else ""
        if "throw MediaSourceException(" not in body:
            name = method.split()[-1].rstrip("(")
            problems.append(
                f"repository.dart {name}() no longer turns a failed listing "
                f"into a MediaSourceException; the list would just stay empty")
    # 评审 4.8：盘符探测会同步 stat，掉线的网络盘要等系统重试好几秒，不能在
    # 主 isolate 上做，否则「添加本地文件夹」的对话框迟迟不出现。
    if "scanDrives ?? windowsDriveRootsInBackground" not in src:
        problems.append(
            "repository.dart must probe Windows drive roots through the "
            "background isolate (windowsDriveRootsInBackground); existsSync() "
            "on a dropped network drive blocks the UI for seconds")
    if "existsSync(" in "\n".join(l for l in src.splitlines()
                                  if not l.strip().startswith("//")):
        problems.append(
            "repository.dart calls existsSync() on the UI thread again; a "
            "dropped network drive makes the add-folder dialog hang")
    bg = ROOT / "app" / "lib" / "core" / "background.dart"
    if not bg.exists():
        problems.append("app/lib/core/background.dart is gone")
    elif "Isolate.run(_scanWindowsDrives)" not in bg.read_text(encoding="utf-8"):
        problems.append(
            "background.dart must run the drive scan on an isolate "
            "(Isolate.run(_scanWindowsDrives)); keeping it inline defeats the "
            "whole point of the file")
    notes.append("ui thread: directory listings and probes run on a "
                 "background isolate, the window keeps painting")


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


def check_settings_layout() -> None:
    """Guard the two-pane settings screen.

    The screen used to be one long ListView: on a phone the 关于 section sat
    seven screens down and `devicectl` has no way to scroll to it. It is now a
    left rail plus one pane, and both sides take their type from the theme
    (the user asked for 目录标题与正文统一的字体字号 —— a hand-rolled 12px
    caption next to 16px rows read like two different products).
    """
    screen = ROOT / "app" / "lib" / "ui" / "settings_screen.dart"
    if not screen.exists():
        problems.append("app/lib/ui/settings_screen.dart is missing")
        return
    st = screen.read_text(encoding="utf-8")

    # 目录与右侧内容必须由同一张表驱动，否则加一格设置就得记得改两处。
    if "enum SettingsTab" not in st:
        problems.append("settings_screen.dart lost the SettingsTab enum; the left "
                        "rail and the right pane would drift apart")
    # 窄屏不能把目录丢掉，只能换成横条。
    for needle, why in (
        ("_TabRail", "the wide layout lost its left navigation rail"),
        ("_TabStrip", "the narrow layout lost its tab strip; the rail would be "
                      "unreachable on a phone"),
        ("LayoutBuilder", "settings_screen.dart no longer adapts to the window "
                          "width; a 220 rail on a phone eats the whole screen"),
    ):
        if needle not in st:
            problems.append(f"settings_screen.dart: {why}")

    # 字号必须取自主题，不能在页面里另写一套。
    if "textTheme.titleMedium" not in st:
        problems.append(
            "settings_screen.dart no longer takes the rail's type from "
            "textTheme.titleMedium; the directory titles would go back to a "
            "hand-rolled size that does not match the rows")
    if "fontSize: 12," in st and "letterSpacing: 1.2" in st:
        problems.append("settings_screen.dart is drawing its own small-caption "
                        "style again; the rail must share the body type")

    # 一次只构建一格：整页 ListView 会让「关于」在手机上下沉好几屏。
    if "switch (tab)" not in st:
        problems.append("settings_screen.dart no longer builds one pane at a "
                        "time; the whole list would be laid out again")
    # 真机取证开关：移动端没有输入注入，只能靠它直接落到某一格。
    if "LANPLAYER_SETTINGS_TAB" not in st:
        problems.append("settings_screen.dart lost the LANPLAYER_SETTINGS_TAB "
                        "switch; the paged layout cannot be photographed on a "
                        "device without injecting taps")
    probe = ROOT / "app" / "lib" / "data" / "probe.dart"
    if probe.exists() and "LANPLAYER_SETTINGS_TAB" not in probe.read_text(
            encoding="utf-8"):
        problems.append("probe.dart lost LANPLAYER_SETTINGS_TAB; the compile-time "
                        "branch would not exist for iOS/Android builds")

    notes.append("settings layout: a left rail of SettingsTab entries next to "
                 "one pane, both typed from theme.textTheme.titleMedium")


def check_settings_groups() -> None:
    """Guard the 2026-11-01 rearrangement of the settings tabs.

    Four things the user asked for, each with a failure mode that the widget
    tests cannot see:
      * 外观 must be a real setting (persisted, applied immediately), not a
        hard-coded ThemeMode in main.dart;
      * 字幕大小 and 字幕延迟 are discrete ladders now — a Slider can produce
        1.37, which no DropdownButton can select, so the model has to snap;
      * 进度 / 连播 / 默认倍速 answer one question ("how does this file
        play"), so they live in one 播放 tab and the old tabs are gone;
      * 「秒」 moved outside the field because suffixText shrinks the box.
    """
    screen = ROOT / "app" / "lib" / "ui" / "settings_screen.dart"
    model = DATA / "playback_settings.dart"
    shortcuts = DATA / "shortcuts.dart"
    for f in (screen, model, shortcuts):
        if not f.exists():
            problems.append(f"{f.relative_to(ROOT).as_posix()} is missing")
            return
    st = screen.read_text(encoding="utf-8")
    mt = model.read_text(encoding="utf-8")
    sl = shortcuts.read_text(encoding="utf-8")

    # --- 外观 ---
    if "appearance('外观')" not in st:
        problems.append("settings_screen.dart lost the 外观 tab; there is no "
                        "entry point for choosing a theme any more")
    if "RadioListTile<AppThemeMode>" not in st:
        problems.append("settings_screen.dart must offer the three appearance "
                        "choices (RadioListTile<AppThemeMode>)")
    if "ThemeController.instance.apply(" not in st:
        problems.append("settings_screen.dart must apply the theme immediately; "
                        "choosing 白色 and seeing no change equals no choice")
    if "enum AppThemeMode" not in mt:
        problems.append("playback_settings.dart lost AppThemeMode")
    # 默认黑色是用户点名的，不是随手取的；把它钉住免得以后又改回 system。
    if "defaultMode = AppThemeMode.dark" not in mt:
        problems.append("the appearance default must stay dark "
                        "(AppThemeMode.defaultMode = AppThemeMode.dark)")
    if "'theme_mode': themeMode.id" not in mt:
        problems.append("theme_mode must be persisted; without it the choice "
                        "resets on every launch")

    # --- 字幕页的两个下拉 ---
    for key, kind in (("settings-subtitle-scale", "double"),
                      ("settings-subtitle-delay", "int")):
        if f"DropdownButton<{kind}>(" not in st or key not in st:
            problems.append(f"settings_screen.dart: 字幕 {key} must be a "
                            f"DropdownButton<{kind}>, not a slider")
    if "subtitleScaleSteps" not in mt or "subtitleDelaySteps" not in mt:
        problems.append("playback_settings.dart lost the subtitle ladder "
                        "tables; the dropdown items would come from nowhere")
    for fn in ("clampSubtitleScale", "clampSubtitleDelay"):
        if f"static " not in mt or f"{fn}(Object? raw)" not in mt:
            problems.append(f"playback_settings.dart lost {fn}; a settings.json "
                            f"written by the slider build would not be "
                            f"selectable and DropdownButton would throw")
        if f"{fn}(" not in st:
            problems.append(f"settings_screen.dart must pass the stored value "
                            f"through {fn}() before handing it to the dropdown")
    # 字幕页不能再出现滑杆。
    subtitle_start = st.find("case SettingsTab.subtitle:")
    if subtitle_start >= 0:
        body = st[subtitle_start:subtitle_start + 4000]
        if "Slider(" in body:
            problems.append("the 字幕 pane still builds a Slider; the two "
                            "ladders were supposed to become dropdowns")

    # --- 合并出来的「播放」页 ---
    if "playback('播放')" not in st:
        problems.append("settings_screen.dart lost the merged 播放 tab")
    for gone in ("progress('进度')", "autoplay('连播')"):
        if gone in st:
            problems.append(f"settings_screen.dart still has a separate "
                            f"{gone[gone.find('(') + 1:-2]} tab; 进度、连播与"
                            f"默认倍速 answer one question and must stay "
                            f"together in 播放")
    playback_start = st.find("case SettingsTab.playback:")
    if playback_start < 0:
        problems.append("settings_screen.dart no longer builds the 播放 pane")
    else:
        body = st[playback_start:playback_start + 6000]
        for needle, what in (
            ("快进 / 快退步长", "the seek step row"),
            ("默认倍速", "the default speed row (moved out of 音频)"),
            ("当前目录自动连播", "the auto-next switch (came from 连播)"),
            ("记忆上次播放位置", "the resume switch (came from 连播)"),
        ):
            if needle not in body:
                problems.append(f"the 播放 pane lost {what}")
    audio_start = st.find("case SettingsTab.audio:")
    if audio_start >= 0:
        audio_body = st[audio_start:st.find("case SettingsTab.subtitle:")]
        if "默认倍速" in audio_body:
            problems.append("the 音频 pane still carries 默认倍速; it now lives "
                            "in 播放")

    # --- 「秒」在输入框外 ---
    if "suffix: '秒'" in st:
        problems.append("settings_screen.dart writes 秒 into the field suffix "
                        "again; suffixText shrinks the box and breaks the "
                        "baseline it sits on")
    if "Text('秒'" not in st:
        problems.append("settings_screen.dart no longer renders 秒 as its own "
                        "Text next to the seek step field")

    # --- 快捷键默认键位与手势 ---
    for action, key in (
        ("speedUp", "keyC"),
        ("speedDown", "keyZ"),
        ("speedReset", "keyX"),
        ("fullscreen", "enter"),
        ("subtitleEarlier", "comma"),
        ("subtitleLater", "slash"),
        ("subtitleReset", "period"),
        ("stats", "tab"),
    ):
        if not re.search(rf"{action}\([^)]*LogicalKeyboardKey\.{key}\)", sl):
            problems.append(f"shortcuts.dart: {action} no longer defaults to "
                            f"{key}; the keymap the user specified is gone")
    if "subtitleReset('subtitle_reset'" not in sl:
        problems.append("shortcuts.dart lost the 字幕复位 action; there would "
                        "be no way to clear the accumulated subtitle offset")
    if "_resetSubtitleDelay() {" not in (
            ROOT / "app" / "lib" / "ui" / "player_screen.dart").read_text(
                encoding="utf-8"):
        problems.append("player_screen.dart lost _resetSubtitleDelay; the bound "
                        "key would fire into nothing")
    if "出厂" in sl or "出厂" in st or "出厂" in (
            ROOT / "app" / "lib" / "ui" / "widgets" / "shortcut_section.dart"
    ).read_text(encoding="utf-8"):
        problems.append("the shortcut section still says 出厂设置; the user "
                        "asked for 默认设置 throughout")
    if "PointerGesture('单击画面'" not in sl or "播放 / 暂停" not in sl:
        problems.append("shortcuts.dart: 单击画面 must map to 播放 / 暂停")
    for gone in ("双击画面左侧三分之一", "双击画面右侧三分之一"):
        if gone in sl:
            problems.append(f"shortcuts.dart still lists {gone}; the split "
                            f"double-tap was removed")
    if "PointerGesture('双击画面'" not in sl:
        problems.append("shortcuts.dart must list 双击画面 as the fullscreen "
                        "gesture")

    notes.append("settings groups: 外观 drives the theme, 字幕 ladders snap, "
                 "进度 / 连播 / 默认倍速 share one 播放 pane, and the default "
                 "keymap is the one the user dictated")


def check_playback_orientation() -> None:
    """Guard the forced-landscape behaviour on phones and tablets.

    The user asked for "点击视频播放时，默认强制进入横屏播放". Two failure modes
    are invisible to the Dart tests, which never rotate a real device:
      * someone reintroduces a bare `SystemChrome.setPreferredOrientations`
        call in the player, so the desktop build starts asking the OS for a
        direction it has no use for;
      * the switch is added to the 播放 pane but never read on entry, which
        looks like a settings page that does nothing.
    The texture size matters too: it is computed before the rotation lands, so
    it has to be laid out on the long/short edge, not on the stale portrait
    window.
    """
    orientation = ROOT / "app" / "lib" / "ui" / "playback_orientation.dart"
    player = ROOT / "app" / "lib" / "ui" / "player_screen.dart"
    model = DATA / "playback_settings.dart"
    screen = ROOT / "app" / "lib" / "ui" / "settings_screen.dart"
    for f in (orientation, player, model, screen):
        if not f.exists():
            problems.append(f"{f.relative_to(ROOT).as_posix()} is missing")
            return
    ot = orientation.read_text(encoding="utf-8")
    pt = player.read_text(encoding="utf-8")
    mt = model.read_text(encoding="utf-8")
    st = screen.read_text(encoding="utf-8")

    for needle, what in (
            ("isMobileHost", "the host test"),
            ("shouldLockLandscape(", "the decision function"),
            ("lockedOrientations(", "the orientation list"),
            ("surfaceSizeFor(", "the texture sizing helper"),
            ("SystemChrome.setPreferredOrientations(", "the platform call"),
    ):
        if needle not in ot:
            problems.append(f"playback_orientation.dart lost {what} "
                            f"({needle}); phone playback would open upright")

    # 只有两个横屏方向。加上竖屏就等于没锁 —— 系统会挑当前这个方向继续用。
    if "DeviceOrientation.landscapeLeft" not in ot or \
            "DeviceOrientation.landscapeRight" not in ot:
        problems.append("playback_orientation.dart must lock to both landscape "
                        "directions; locking one leaves the other unusable")
    if "DeviceOrientation.portraitUp" in ot.split("lockedOrientations", 1)[-1] \
            .split("Future<void> enterPlaybackOrientation", 1)[0]:
        problems.append("playback_orientation.dart includes a portrait "
                        "orientation in the locked list; that is the same as "
                        "not locking at all")

    if "enterPlaybackOrientation(" not in pt:
        problems.append("player_screen.dart never calls "
                        "enterPlaybackOrientation; opening a video stays upright")
    if "leavePlaybackOrientation(" not in pt:
        problems.append("player_screen.dart never calls "
                        "leavePlaybackOrientation; the list page stays sideways "
                        "after playback")
    if "surfaceSizeFor(" not in pt:
        problems.append("player_screen.dart builds the texture from the raw "
                        "portrait window again; hardware decoding would keep "
                        "drawing into a vertical buffer")

    # 反向断言：方向只允许经 playback_orientation.dart 改，播放页里不许直接调。
    for lineno, line in enumerate(pt.splitlines(), 1):
        if "setPreferredOrientations(" in line and "//" not in line:
            problems.append(f"player_screen.dart:{lineno} calls "
                            f"setPreferredOrientations directly; route it "
                            f"through playback_orientation.dart so the desktop "
                            f"build stays out of it")

    if "bool lockLandscape;" not in mt:
        problems.append("playback_settings.dart lost lockLandscape; the switch "
                        "has nothing to persist")
    if "'lock_landscape': lockLandscape" not in mt:
        problems.append("lockLandscape must be persisted, otherwise the switch "
                        "flips back on every launch")
    if "settings-lock-landscape" not in st:
        problems.append("settings_screen.dart lost the 手机上强制横屏播放 switch")

    # 5. 锁横屏要靠宿主原生通道，两个移动平台都走，理由不同：
    #    Android 的 SystemChrome 那套到 Android 上只是 FULL_USER，用户关掉系统
    #    「自动旋转」之后播放页就不再跟着机身翻；iPad 上 SystemChrome 那套根本
    #    不生效，得由宿主发 requestGeometryUpdate。
    activity = (ROOT / "app" / "android" / "app" / "src" / "main" / "kotlin" /
                "dev" / "lanplayer" / "app" / "MainActivity.kt")
    appdelegate = ROOT / "app" / "ios" / "Runner" / "AppDelegate.swift"
    contract = (ROOT / "packages" / "lanplayer_video" / "lib" / "src" /
                "channel.dart")
    if not activity.exists():
        problems.append("MainActivity.kt is gone; Android playback cannot ask "
                        "for the sensor-driven landscape mode anymore")
    else:
        at = activity.read_text(encoding="utf-8")
        if "SCREEN_ORIENTATION_SENSOR_LANDSCAPE" not in at:
            problems.append("MainActivity.kt no longer requests "
                            "SCREEN_ORIENTATION_SENSOR_LANDSCAPE; Android would "
                            "stay on FULL_USER and stop following the gyroscope "
                            "once the user turns off auto-rotate")
        if "lockLandscape" not in at:
            problems.append("MainActivity.kt no longer answers the "
                            "lockLandscape method")
        if "SCREEN_ORIENTATION_UNSPECIFIED" not in at:
            problems.append("MainActivity.kt never restores "
                            "SCREEN_ORIENTATION_UNSPECIFIED; leaving the player "
                            "would pin the whole app to a landscape sensor mode")
    if not appdelegate.exists():
        problems.append("app/ios/Runner/AppDelegate.swift is gone; the iPad "
                        "would go back to ignoring setPreferredOrientations")
    else:
        st_ios = appdelegate.read_text(encoding="utf-8")
        if "requestGeometryUpdate(" not in st_ios:
            problems.append("AppDelegate.swift never calls requestGeometryUpdate; "
                            "iPad playback would stay portrait because the system "
                            "ignores setPreferredOrientations there")
        if "setNeedsUpdateOfSupportedInterfaceOrientations" not in st_ios:
            problems.append("AppDelegate.swift does not refresh the supported "
                            "orientations; the geometry request would be refused "
                            "whenever the current set does not include landscape")
        if "lockLandscape" not in st_ios:
            problems.append("AppDelegate.swift no longer answers the "
                            "lockLandscape method")
    if contract.exists():
        ct = contract.read_text(encoding="utf-8")
        if "lockLandscape" not in ct:
            problems.append("channel.dart no longer declares the lockLandscape "
                            "method; both mobile hosts and the Dart side would be "
                            "back to private string literals")
    if "shouldAskHostForLandscape(" not in ot:
        problems.append("playback_orientation.dart lost the host-landscape "
                        "decision; the player would stop asking the hosts")
    for needle, why in (
            ("VideoTextureBridge.lockLandscape(true)",
             "entering playback never asks the host to turn the window"),
            ("VideoTextureBridge.lockLandscape(false)",
             "leaving playback never gives the orientation back")):
        if needle not in ot:
            problems.append(f"playback_orientation.dart {why} ({needle})")

    notes.append("orientation: phones and tablets lock to landscape when a "
                 "video opens, desktops never do, the texture is sized on "
                 "the long/short edge, Android follows the gyroscope through "
                 "SENSOR_LANDSCAPE, and iPad takes requestGeometryUpdate "
                 "because it ignores the framework call")


def check_windows_single_instance() -> None:
    """Guard the desktop single-instance rule in the Windows runner.

    Clicking the desktop icon while the app is open used to start a second
    process with its own window and its own playback state; the second launch
    now restores and foregrounds the window that already exists.  The window
    class name is shared with every other Flutter Windows runner (the WeChat
    work helper ships a hidden window in the same class), so the lookup has to
    filter by executable path - a bare FindWindow would grab that stranger's
    hidden window and do nothing visible.
    """
    runner = ROOT / "app" / "windows" / "runner"
    main_cpp = runner / "main.cpp"
    single = runner / "single_instance.cpp"
    cmake = runner / "CMakeLists.txt"
    gen = ROOT / "scripts" / "gen_windows_runner.py"
    msvc = ROOT / "scripts" / "msvc_chain.py"

    if not single.exists():
        problems.append("app/windows/runner/single_instance.cpp is gone; a "
                        "second desktop launch would open a second window")
    else:
        text = single.read_text(encoding="utf-8")
        for needle, why in (
            ("::CreateMutexW(", "the second launch has nothing to detect the "
                                "first one with"),
            ("::GetLastError() != ERROR_ALREADY_EXISTS", "CreateMutexW returns a "
             "valid handle even when the mutex exists; only GET_LAST_ERROR "
             "distinguishes the first launch"),
            ("!SameExecutable(pid)", "the window lookup must confirm the window "
             "belongs to this executable; the Flutter window class name is "
             "shared with unrelated apps"),
            ("::ShowWindow(window, SW_RESTORE);", "a minimized window would stay "
                                                  "minimized"),
            ("if (!::SetForegroundWindow(window)) {", "the window would be raised "
             "without the focus, so it just blinks in the taskbar"),
        ):
            if needle not in text:
                problems.append(f"single_instance.cpp no longer contains "
                                f"{needle!r}: {why}")
        if "FindWindowW(" in text:
            problems.append("single_instance.cpp went back to a bare "
                            "FindWindowW; that matches any process using the "
                            "Flutter window class and silently picks the wrong "
                            "window")

    mt = main_cpp.read_text(encoding="utf-8") if main_cpp.exists() else ""
    if "ActivateRunningInstance()" not in mt:
        problems.append("app/windows/runner/main.cpp never calls "
                        "ActivateRunningInstance(); the mutex would be created "
                        "but nothing would come to the front")
    elif mt.index("ActivateRunningInstance()") > mt.index("window.Create("):
        problems.append("app/windows/runner/main.cpp calls "
                        "ActivateRunningInstance() after creating the window; "
                        "the user would see a blank window flash before the "
                        "second process exits")

    ct = cmake.read_text(encoding="utf-8") if cmake.exists() else ""
    if '"single_instance.cpp"' not in ct:
        problems.append("app/windows/runner/CMakeLists.txt does not list "
                        "single_instance.cpp; the flutter build would fail to "
                        "link ActivateRunningInstance")
    mt_chain = msvc.read_text(encoding="utf-8") if msvc.exists() else ""
    if "app/windows/runner/single_instance.cpp" not in mt_chain:
        problems.append("scripts/msvc_chain.py does not compile "
                        "single_instance.cpp; the MSVC-only build path would "
                        "reproduce the link error CMake would have")

    gt = gen.read_text(encoding="utf-8") if gen.exists() else ""
    if "RUNNER_PATCHES" not in gt:
        problems.append("scripts/gen_windows_runner.py lost RUNNER_PATCHES; "
                        "regenerating app/windows/ would silently drop the "
                        "single-instance wiring")
    for needle, why in (
            ('RUNNER_PATCHES = [', "the table itself is gone"),
            ('"runner/main.cpp"', "the main.cpp patch is gone"),
            ('"runner/CMakeLists.txt"', "the CMakeLists patch is gone"),
            ('"CMakeLists.txt"', "the top-level CMakeLists patch is gone; "
             "regenerating app/windows/ would drop /utf-8 and the DLL install "
             "rules again"),
            ('".gitignore"', "the .gitignore patch is gone"),
            ("single_instance.cpp", "the generator no longer adds the source"),
            ("no longer contains the text", "the generator no longer fails when "
             "the template drifts away from what the patch expects"),
    ):
        if needle not in gt:
            problems.append(f"scripts/gen_windows_runner.py no longer mentions "
                            f"{needle}: {why}")

    notes.append("single instance: a second desktop launch restores and "
                 "foregrounds the window that is already open instead of "
                 "starting a second process with its own playback state")


def check_texture_delivery() -> None:
    """Guard the Apple texture hand-off path.

    "音频正常、画面卡顿" traced back to three separate things on the Apple
    platforms, none of which shows up in the kernel's own counters:

      * the core kept a single pixel buffer slot that a new frame overwrote
        whether or not Flutter had taken the previous one, so frames the
        raster thread never picked up vanished silently;
      * `lp_player_copy_pixel_buffer` returned the slot without asking
        whether it held a new frame, so the engine could draw the same frame
        twice;
      * both hosts wrapped the frame notification in `DispatchQueue.main.async`
        even though `textureFrameAvailable` is documented to be callable from
        any thread, which added a main-runloop of latency to every frame.

    Each of the three is cheap to reintroduce by accident, so assert them.

    A fourth cause lives in the core's frame pacing.  VideoToolbox hands
    frames over in batches (it decodes two or three asynchronously and then
    calls back), and `wait_for_presentation` used to present every frame whose
    timestamp was already in the past without any spacing at all.  A batch
    therefore hit the screen within a couple of milliseconds and the thread
    then idled until the next one: 24 fps on the counter, one lurch per batch
    on the screen.  iPad traces showed a pull interval of 145 ms on average
    and 216 ms at worst while `dropped` stayed at 0 throughout.
    """
    apple = ROOT / "native" / "src" / "platform" / "apple" / "apple_texture.c"
    internal = ROOT / "native" / "src" / "player_internal.h"
    player = ROOT / "native" / "src" / "core" / "player.c"
    video = ROOT / "native" / "src" / "core" / "video.c"
    demux = ROOT / "native" / "src" / "core" / "demux.c"
    ios = ROOT / "app" / "ios" / "Runner" / "AppDelegate.swift"
    macos = ROOT / "app" / "macos" / "Runner" / "MainFlutterWindow.swift"

    if not internal.exists():
        problems.append("native/src/player_internal.h is gone")
    else:
        it = internal.read_text(encoding="utf-8")
        if "int64_t frames_delivery_lost;" not in it:
            problems.append(
                "LpVideoOut lost frames_delivery_lost; overwritten frames "
                "would go back to being invisible in the stats, which is "
                "exactly how this stutter stayed unfixed for so long")
        # 交付节奏的抖动：帧数与丢帧数都对不上观感时，剩下的解释就是「到了，
        # 但间隔不均」。没有这两个计数，24 fps 里夹着几次 100 ms 的停顿在
        # 统计上永远看不出来。
        for needle, why in (
            ("int64_t pull_gap_max_us;",
             "LpVideoOut lost pull_gap_max_us; uneven frame spacing would go "
             "back to being invisible"),
            ("int64_t pull_stall_count;",
             "LpVideoOut lost pull_stall_count; you could no longer tell a "
             "smooth run from one with occasional 100 ms hiccups"),
            # 取帧那侧被 vsync 量化过，光有 pull_* 分不清「解码吐得不均」与
            # 「引擎取帧对不齐」，所以内核侧的送帧间隔要单独记。
            ("int64_t push_gap_max_us;",
             "LpVideoOut lost push_gap_max_us; pull_gap alone cannot tell a "
             "bursty decoder from a raster thread that pulls at the wrong time"),
            ("int64_t push_gap_sum_us;",
             "LpVideoOut lost push_gap_sum_us; the average publish interval "
             "could not be computed"),
            ("int64_t push_gap_count;",
             "LpVideoOut lost push_gap_count; there would be no denominator "
             "for the average publish interval"),
            ("int64_t last_push_at_us;",
             "LpVideoOut lost last_push_at_us; publish intervals could not be "
             "measured at all"),
        ):
            if needle not in it:
                problems.append(f"player_internal.h: {why} ({needle})")
        if "LP_VOUT_SLOTS" in it or "frame_slots" in it:
            problems.append(
                "player_internal.h has a multi-slot frame queue again; the "
                "raster thread wants the newest frame, not a backlog")

    if not apple.exists():
        problems.append("native/src/platform/apple/apple_texture.c is gone; "
                        "the Apple hosts would lose their texture path")
    else:
        at = apple.read_text(encoding="utf-8")
        for needle, why in (
            ("frames_delivery_lost++",
             "publishing no longer counts the frame it overwrote"),
            ("if (image && p->vout.has_new_frame)",
             "copyPixelBuffer hands out the slot without checking for a new "
             "frame; the engine would draw the same frame twice"),
            # 间隔只在「真的交出一帧」时量。挪到函数开头（每次 vsync 都量）
            # 会把「没新帧的空转」也算成停顿，读数立刻失真。
            ("pull_stall_count++",
             "copyPixelBuffer stopped counting uneven pull spacing; a stream "
             "that delivers all 24 frames in bursts would look perfect again"),
            # 内核侧的送帧间隔在 publish 里量，别挪到 copyPixelBuffer：
            # 那是「取」不是「送」，量出来的还是同一个被量化过的数。
            ("push_gap_sum_us += push_gap;",
             "publish no longer accumulates the interval between frames; the "
             "average would always read 0"),
        ):
            if needle not in at:
                problems.append(f"apple_texture.c: {why} ({needle})")

    if not player.exists():
        problems.append("native/src/core/player.c is gone")
    else:
        pt = player.read_text(encoding="utf-8")
        # Match the format string itself, not the word: the comment above the
        # emit explains dropped_delivery too, so a bare substring test would
        # stay green after the field was dropped from the payload.
        if '\\"dropped_delivery\\":%lld' not in pt:
            problems.append(
                "the STATS event no longer reports dropped_delivery; the "
                "debug overlay could not tell 'core never produced the "
                "frame' from 'Flutter never took it'")
        if '\\"pull_gap_ms\\":%lld,\\"pull_stalls\\":%lld' not in pt:
            problems.append(
                "the STATS event no longer reports pull_gap_ms / pull_stalls; "
                "a run where every frame arrives but unevenly would look "
                "identical to a smooth one")
        if '\\"push_gap_ms\\":%lld,\\"push_avg_ms\\":%lld' not in pt:
            problems.append(
                "the STATS event no longer reports push_gap_ms / push_avg_ms; "
                "there would be no way to tell a bursty decoder from a raster "
                "thread that pulls at the wrong moment")

    if not video.exists():
        problems.append("native/src/core/video.c is gone")
    else:
        vt = video.read_text(encoding="utf-8")
        for needle, why in (
            ("wait_for_presentation(LpPlayer *p, int64_t pts_us, int serial, double frame_dur)",
             "wait_for_presentation stopped taking the frame period; the "
             "spacing below cannot be derived without it"),
            ("p->video.last_present_at_us = av_gettime_relative();",
             "nothing records when a frame actually reached the screen, so the "
             "pacer has no reference point and every late frame presents at once"),
            # 帧周期必须取 demux 量出来的真实值，而不是写死的 0.04：异步
            # 硬解分支从不更新局部 frame_dur，30 fps 内容每帧多等 6.7 ms，
            # 60 fps 直接被压到 25 fps。同理必须除以播放速度，2 倍速下不除
            # 就是每显示一帧丢一帧。
            ("const int64_t period = (int64_t)(fd * 1000000.0 / sp);",
             "the spacing no longer uses the measured frame period, or it "
             "ignores playback speed and drops every other frame at 2x"),
            ("const double fd = p->video.frame_duration > 0.0 ? p->video.frame_duration",
             "the pacer went back to the hard-coded 0.04 s frame period"),
            ("const double sp = p->speed > 0.01 ? p->speed : 1.0;",
             "the pacer no longer divides by playback speed"),
            # 节拍必须对着「绝对时刻」推进，不能以上一帧上屏时刻为起点。
            # 以它为起点时，av_usleep 睡过头的误差会原样带进下一帧，一秒
            # 二十几次累积下来就是稳定落后；iPad 实测 0.9 倍周期版每秒最大
            # 间隔 92.6 ms，整周期版 av_diff 长期停在 -0.3 ~ -0.5 s、30 秒
            # 丢 46 帧。按相邻 pts 差逐帧等更糟：VideoToolbox 一次并发交出
            # 好几帧，实测 fps 掉到 4–6、每秒丢 19 帧。
            # 落后超过 LP_PACE_CATCHUP_US 时必须临时加快，否则落后量会被
            # 整周期摊平锁死，一路漂到 -500 ms 丢帧线才纠正（iPad 实测
            # av_diff 稳定停在 -0.4 ~ -0.5 s、30 秒丢 46 帧）。
            # 提前一个刷新周期上屏。引擎只在 vsync 上合成，一帧从
            # 「交给纹理」到「真的画出来」还要跨一次线程；恰好在 vsync 之后
            # 几十微秒准备好的帧只能等下一个 vsync，24 fps 内容上就变成
            # 「本该停 2 个 vsync 的帧停了 3 个」。iPad 实测把提前量从
            # 0 加到 8.33 ms 再到 16.67 ms，pull_slow 从 9 降到 6 再到 1、
            # stalls 从 0.30 降到 0.20 再到 0.03；30 fps 无变化（它本来就
            # 每帧占两个 vsync，不需要这个余量）；60 fps 仍受限（见下）。
            ("#define LP_PRESENT_LEAD_US 16667",
             "the present lead is gone; frames that finish just after a vsync "
             "would wait a whole extra refresh and stutter on 24 fps content"),
            ("if (diff > 0 && diff < LP_PRESENT_LEAD_US) {",
             "the present lead is declared but never applied to the pacing decision"),
            ("#define LP_PACE_CATCHUP_US 120000",
             "the pacer lost its catch-up threshold; a steady lag would never be "
             "paid back until frames start being dropped"),
            ("if (catchup > 0 && diff < -catchup) {",
             "the pacer never shortens its spacing; it stays a fixed period even "
             "when the stream is running behind"),
            ("const int64_t catchup = (int64_t)(LP_PACE_CATCHUP_US / sp);",
             "the catch-up threshold no longer scales with playback speed; at 2x "
             "it would only kick in after a full second of lag"),
            # 异步解码器才需要节拍。这条被删掉会变成「所有硬解都补等待」，
            # Windows 的 d3d11va 是同步取帧，插等待直接掉帧（实测 12 秒丢 32）。
            ("lp_hw_decoder_is_async(p->video.hw)",
             "the pacer no longer restricts itself to asynchronous decoders; "
             "a synchronous one like d3d11va would fall behind and drop frames"),
            # 异步解码器要被喂饱几帧，否则它自己的调度抖动直接变成出帧间隔
            # 的抖动（iPad 实测 publish 间隔每秒 11 次超过 84 ms、最大 151 ms，
            # 而 dropped 恒为 0）。
            ("#define LP_HW_PREFETCH 4",
             "the async decoders are back to one frame of work in flight; their "
             "own scheduling jitter becomes jitter on screen again"),
            ("while (!draining && p->video.in_flight < LP_HW_PREFETCH)",
             "nothing keeps the async decoder fed; prefetching was the fix"),
            # 同步解码器绝不能走补料那一支：send 只是把包交给 FFmpeg 的重排
            # 队列，连喂几个才吐第一帧，in_flight 一满就永远收不到帧。
            ("if (p->video.hw && lp_hw_decoder_is_async(p->video.hw)) {",
             "the prefetch loop no longer excludes synchronous decoders; "
             "d3d11va would stall at 0 fps"),
        ):
            if needle not in vt:
                problems.append(f"video.c: {why} ({needle})")
        # 上屏时刻必须两处都记：硬解走 present_hw，软解走内联分支。只补一处
        # 会让「一半片子卡、一半不卡」这种最难查的现象重新出现。
        if vt.count("p->video.last_present_at_us = av_gettime_relative();") < 2:
            problems.append(
                "video.c only stamps last_present_at_us on one of the two "
                "present paths; hardware and software playback would then be "
                "paced differently")
        if "p->video.last_present_at_us = 0;" not in vt:
            problems.append(
                "lp_video_start never resets last_present_at_us; the first "
                "frame of the next file is paced against the previous file's "
                "last present time")

    if not demux.exists():
        problems.append("native/src/core/demux.c is gone")
    else:
        dt = demux.read_text(encoding="utf-8")
        for needle, why in (
            ("static void note_frame_duration(LpPlayer *p)",
             "nothing records the stream's real frame rate any more"),
            ("note_frame_duration(p);",
             "note_frame_duration is defined but never called; the pacer would "
             "keep assuming 25 fps for 24 and 23.976 fps material"),
            ("p->video.frame_duration = 1.0 / fps;",
             "the frame period is no longer written to the player"),
        ):
            if needle not in dt:
                problems.append(f"demux.c: {why} ({needle})")

    # 每个平台后端都必须回答「你是不是异步的」。漏一个就是链接失败，
    # 答错一个（同步的说成异步）会让那条路径凭空掉帧。
    for rel, want_async in (
        ("native/src/platform/apple/videotoolbox_decoder.c", "1"),
        ("native/src/platform/android/media_codec_decoder.c", "1"),
        ("native/src/platform/win32/d3d11va_decoder.c", "0"),
        ("native/src/platform/stub/stub_platform.c", "0"),
    ):
        path = ROOT / rel
        if not path.exists():
            problems.append(f"{rel} is gone")
            continue
        text = path.read_text(encoding="utf-8")
        if "int lp_hw_decoder_is_async(LpVideoDecoder *d)" not in text:
            problems.append(f"{rel} does not answer lp_hw_decoder_is_async; the "
                            f"pacer cannot tell a batching decoder from a "
                            f"synchronous one")
            continue
        start = text.find("int lp_hw_decoder_is_async(LpVideoDecoder *d)")
        end = text.find("\n}", start)
        body = text[start:end if end > 0 else len(text)]
        if f"return {want_async};" not in body:
            problems.append(
                f"{rel} answers lp_hw_decoder_is_async with the wrong verdict; "
                f"it must return {want_async}")

    # 解码器自己丢掉的帧必须能被数出来。这些帧从来没进过内核，既不在
    # decoded 里也不在 dropped 里 —— 上一轮排查 iPad 卡顿时，「dropped=0、
    # fps 满帧」与肉眼可见的卡顿同时成立，就是因为少了这一路计数。
    for rel in (
        "native/src/platform/apple/videotoolbox_decoder.c",
        "native/src/platform/android/media_codec_decoder.c",
        "native/src/platform/win32/d3d11va_decoder.c",
        "native/src/platform/stub/stub_platform.c",
    ):
        path = ROOT / rel
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        if "int64_t lp_hw_decoder_frames_dropped(LpVideoDecoder *d)" not in text:
            problems.append(
                f"{rel} does not answer lp_hw_decoder_frames_dropped; frames the "
                f"decoder throws away would stay invisible in the stats")
    for rel, needle, why in (
        ("native/src/platform/apple/videotoolbox_decoder.c", "d->frames_dropped++;",
         "the VideoToolbox output queue can still discard the oldest frame "
         "without counting it; that is one of the two ways frames vanish "
         "silently on Apple"),
        ("native/src/platform/android/media_codec_decoder.c", "d->frames_dropped++;",
         "a MediaCodec output buffer that cannot be released is never counted; "
         "the frame is gone with no trace in any statistic"),
        ("native/src/core/player.c", "lp_hw_decoder_frames_dropped(p->video.hw)",
         "the stats event never reports the decoder's own drops"),
        ("native/src/core/player.c", 'decoder_dropped\\":%lld',
         "the decoder drop count is computed but not emitted in the stats JSON"),
        ("native/src/core/player.c",
         "p->video.frames_received - p->video.frames_decoded -",
         "the stats no longer reconcile received frames against shown, dropped "
         "and discarded ones; a frame swallowed on an unaccounted branch would "
         "go unnoticed again"),
    ):
        path = ROOT / rel
        if not path.exists():
            continue
        if needle not in path.read_text(encoding="utf-8"):
            problems.append(f"{rel}: {why} ({needle})")

    # 帧数守恒的第三项：seek 时作废的帧。硬解与软解各有一次计数，少一处就会
    # 在每次 seek 之后报出虚假差额，所以这里按次数断言，不只查「出现过」。
    video_src = (ROOT / "native/src/core/video.c").read_text(encoding="utf-8")
    discarded_hits = video_src.count("p->video.frames_discarded++;")
    if discarded_hits != 2:
        problems.append(
            "native/src/core/video.c: frames thrown away on seek are counted "
            f"{discarded_hits} time(s), expected once on the hardware path and "
            "once on the software path; the conservation check would then report "
            "a false gap after every seek")
    if video_src.count("p->video.frames_received++;") != 2:
        problems.append(
            "native/src/core/video.c: received frames are not counted on both "
            "decode paths, so the conservation check only covers one of them")

    for path, name in ((ios, "AppDelegate.swift"),
                       (macos, "MainFlutterWindow.swift")):
        if not path.exists():
            problems.append(f"{name} is gone")
            continue
        text = path.read_text(encoding="utf-8")
        if "textureFrameAvailable(" not in text:
            problems.append(f"{name} never notifies the texture registry")
        start = text.find("func installFrameCallback()")
        if start < 0:
            problems.append(f"{name} lost installFrameCallback()")
            continue
        end = text.find("\n  }", start)
        body = text[start:end if end > 0 else len(text)]
        if "DispatchQueue.main.async" in body:
            problems.append(
                f"{name} hops to the main queue before notifying the texture "
                "registry; textureFrameAvailable is safe from any thread and "
                "the extra hop delays every frame by up to a runloop, which "
                "is what made video stutter while audio stayed smooth")

    notes.append("texture delivery: the Apple hosts hand every decoded frame "
                 "straight to the texture registry, the core counts the frames "
                 "a busy raster thread never picked up and reports the spacing "
                 "on both sides of that hand-off (publish intervals inside the "
                 "core, pull intervals as the engine asks for frames), the "
                 "stats event keeps them apart from decode drops, and late "
                 "frames are spaced by the real frame period instead of being "
                 "flushed as a batch")


def check_startup_home() -> None:
    """Cold start must land on the home screen, never on the last player.

    Both mobile hosts can bring the previous UI back when the process is
    recreated -- Android because `FlutterActivity.shouldRestoreAndSaveState()`
    returns true by default (the engine gets the saved InstanceState and
    restores the whole navigation stack with it), iPadOS because window-scene
    restoration may return the last controller hierarchy.  The player is the
    wrong thing to restore: its SMB source is usually unreachable by then, so
    the user lands on a connection error and has to press back once.

    The fix is in two places on purpose -- the Android host refuses to
    save/restore state at all, and the Dart side collapses whatever stack it
    inherited right before the verification hooks run.  Either one alone would
    leave the other platform's behaviour to chance.
    """
    reset = ROOT / "app" / "lib" / "ui" / "startup_reset.dart"
    if not reset.exists():
        problems.append("app/lib/ui/startup_reset.dart is gone; nothing pulls "
                        "the navigation stack back to the home screen on "
                        "launch")
        return
    text = reset.read_text(encoding="utf-8")
    for needle, why in (
        ("int collapseToHome(NavigatorState navigator)",
         "the helper must take the navigator and report how many routes it "
         "dropped"),
        ("popUntil(", "collapsing has to go through popUntil so the routes "
                      "actually run their exit callbacks"),
        ("route.isFirst", "the collapse must stop at the first route; popping "
                          "past it would leave the app with no page at all"),
    ):
        if needle not in text:
            problems.append(f"app/lib/ui/startup_reset.dart no longer has "
                            f"{needle!r}: {why}")

    main = ROOT / "app" / "lib" / "main.dart"
    mt = main.read_text(encoding="utf-8")
    if "import 'ui/startup_reset.dart';" not in mt:
        problems.append("app/lib/main.dart does not import startup_reset; the "
                        "collapse would have no effect")
    if "collapseToHome(navigator)" not in mt:
        problems.append("app/lib/main.dart never calls collapseToHome; a cold "
                        "start could still land on the restored player page")
    else:
        probes = mt.find("void _runProbes()")
        collapse = mt.find("collapseToHome(navigator)")
        if probes == -1:
            problems.append("app/lib/main.dart lost _runProbes; the startup "
                            "hooks moved and the collapse went with them")
        elif collapse < probes:
            problems.append("app/lib/main.dart collapses the stack from "
                            "outside _runProbes; it has to run after the first "
                            "frame, when the navigator exists")

    activity = (ROOT / "app" / "android" / "app" / "src" / "main" / "kotlin"
                / "dev" / "lanplayer" / "app" / "MainActivity.kt")
    if not activity.exists():
        problems.append("app/android/.../MainActivity.kt is gone")
        return
    at = activity.read_text(encoding="utf-8")
    if "override fun shouldRestoreAndSaveState(): Boolean = false" not in at:
        problems.append("MainActivity no longer overrides "
                        "shouldRestoreAndSaveState to false; Android would "
                        "hand the saved InstanceState to the engine again and "
                        "reopen the player after the process is killed")

    notes.append("startup: a cold start always lands on the home screen - "
                 "Android refuses to save/restore instance state, and the Dart "
                 "side collapses any inherited stack before the hooks run")


def check_surface_tap() -> None:
    """单击画面在鼠标宿主与触屏宿主上要做不同的事。

    用户 2026-11-02 要求把两端分开：桌面端仍然是「点一下暂停」，
    手机 / 平板上改成「把控制栏叫出来」。

    这条容易在以后的重构里悄悄退回去，因为三个症状都很难被发现：
      * 播放页直接写死 `togglePlay`，触屏上控制栏收起之后就没有入口了；
      * 分档判定散在界面代码里，而不是一个能被测试的纯函数；
      * 设置页那份手势说明不跟着宿主变，在触屏上写着「播放 / 暂停」。
    """
    host = ROOT / "app" / "lib" / "ui" / "pointer_input.dart"
    if not host.exists():
        problems.append("app/lib/ui/pointer_input.dart is gone; the player "
                        "would have no way to tell a mouse host from a touch "
                        "host")
        return
    ht = host.read_text(encoding="utf-8")
    for needle, why in (
        ("bool get isMouseDrivenHost", "the host split needs one named answer"),
        ("Platform.isWindows", "Windows has to count as a mouse host"),
        ("Platform.isMacOS", "macOS has to count as a mouse host"),
        ("enum SurfaceTapAction", "the two outcomes must be named, not a bool "
                                  "that reads differently at each call site"),
        ("SurfaceTapAction surfaceTapAction({required bool mouseDriven})",
         "the decision has to be a pure function so it can be tested without "
         "building a decoder"),
        ("mouseDriven ? SurfaceTapAction.togglePlay",
         "mouse hosts still pause on a click"),
        (": SurfaceTapAction.revealControls",
         "touch hosts must reveal the controls instead of pausing"),
    ):
        if needle not in ht:
            problems.append(f"app/lib/ui/pointer_input.dart no longer has "
                            f"{needle!r}: {why}")

    player = ROOT / "app" / "lib" / "ui" / "player_screen.dart"
    pt = player.read_text(encoding="utf-8")
    if "onTap: _handleSurfaceTap," not in pt:
        problems.append("player_screen.dart no longer routes the surface tap "
                        "through _handleSurfaceTap; one of the two hosts would "
                        "get the other one's behaviour")
    if "surfaceTapAction(mouseDriven: isMouseDrivenHost)" not in pt:
        problems.append("player_screen.dart does not consult surfaceTapAction; "
                        "the tap handler would have to guess the host itself")
    if "SurfaceTapAction.togglePlay" not in pt or \
            "SurfaceTapAction.revealControls" not in pt:
        problems.append("player_screen.dart handles only one of the two tap "
                        "outcomes")
    if "setState(() => _controls = false)" not in pt:
        problems.append("the touch path can reveal the controls but never hide "
                        "them again; the bar would be stuck on screen")

    sc = (ROOT / "app" / "lib" / "data" / "shortcuts.dart").read_text(
        encoding="utf-8")
    if "static List<PointerGesture> forHost({required bool mouseDriven})" not in sc:
        problems.append("shortcuts.dart lost PointerGesture.forHost; the 快捷键 "
                        "page would document pause-on-click on a tablet")
    if "static const String revealControlsEffect" not in sc:
        problems.append("shortcuts.dart lost revealControlsEffect; the touch "
                        "wording would drift away from the player behaviour")

    sec = (ROOT / "app" / "lib" / "ui" / "widgets" / "shortcut_section.dart"
           ).read_text(encoding="utf-8")
    if "PointerGesture.forHost(mouseDriven: isMouseDrivenHost)" not in sec:
        problems.append("the 快捷键 section still renders PointerGesture.all; "
                        "a tablet would list the mouse behaviour")

    notes.append("surface tap: a mouse host pauses on a click, a touch host "
                 "brings the controls up, and the 快捷键 page documents "
                 "whichever one the current host actually does")


def check_volume_gain() -> None:
    """Guard the 音量增益 setting and the "playback volume is temporary" rule.

    User changed this on 2026-11-02: 设置 → 音频 used to hold 默认音量 as a
    0–100 percentage that every cold open applied to the player. It is now a
    multiplicative gain (0.1x–2.0x, step 0.1, 1.0x = leave the system volume
    alone), and the volume slider inside the player must NOT write back to it.
    Both halves are easy to get wrong in a way no screenshot would show:
      * if the player writes back, 设置 stops meaning "where each file starts";
      * if the core option still reads a stale field name, the gain silently
        stays at 1.0 and the user cannot tell whether the setting works.
    """
    settings = (ROOT / "app" / "lib" / "data" / "playback_settings.dart"
                ).read_text(encoding="utf-8")
    for needle, why in (
        ("double volumeGain;",
         "PlaybackSettings lost the gain field; the slider would be a dead knob"),
        ("static const List<double> volumeGainSteps = [",
         "the gain ladder is gone; the 设置 dropdown would have nothing to show"),
        ("static const double volumeGainDefault = 1.0;",
         "the default gain must stay 1.0 - that is 'follow the system volume'"),
        ("static double clampVolumeGain(Object? raw)",
         "the dropdown matches values exactly; without snapping, an old 0.85 "
         "leaves every entry unselected"),
    ):
        if needle not in settings:
            problems.append(f"playback_settings.dart: {why}")

    # 档位表本身要完整：0.1 起步、0.1 一档、到 2.0 收尾。写成字面量比对
    # 是为了让「手滑删了一档」也红 —— 少一档在下拉里就是凭空少一个选项。
    ladder = [
        round(0.1 * n, 1) for n in range(1, 21)
    ]
    declared = re.search(
        r"static const List<double> volumeGainSteps = \[(.*?)\];",
        settings, re.S)
    if declared is None:
        problems.append("playback_settings.dart: volumeGainSteps is not a "
                        "literal list any more; the ladder cannot be verified")
    else:
        values = [float(v) for v in
                  re.findall(r"\d+\.\d+", declared.group(1))]
        if values != ladder:
            problems.append("volumeGainSteps must be 0.1..2.0 in steps of 0.1; "
                            f"got {values}")

    controller = (ROOT / "app" / "lib" / "core" / "player_controller.dart"
                  ).read_text(encoding="utf-8")
    if "'volume': settings.volumeGain," not in controller:
        problems.append("player_controller.dart: the open options no longer "
                        "carry settings.volumeGain; the setting would be ignored")
    if "volume = settings.volumeGain;" not in controller:
        problems.append("player_controller.dart: a fresh file must start from "
                        "the gain setting, otherwise yesterday's slider position "
                        "carries over")

    player = (ROOT / "app" / "lib" / "ui" / "player_screen.dart"
              ).read_text(encoding="utf-8")
    for needle in ("_settings.volume =", "SettingsStore.instance.value.volume ="):
        if needle in player:
            problems.append(f"player_screen.dart still writes back ({needle} "
                            "...); the in-player slider must stay local to this "
                            "playback, or 音量增益 stops meaning anything")

    screen = (ROOT / "app" / "lib" / "ui" / "settings_screen.dart"
              ).read_text(encoding="utf-8")
    if "const Text('音量增益')" not in screen:
        problems.append("settings_screen.dart: the audio page lost the 音量增益 "
                        "row (user renamed 默认音量 on 2026-11-02)")
    if "默认音量" in screen:
        problems.append("settings_screen.dart still shows 默认音量; the setting "
                        "is a gain now, and the old name promises a fixed level")
    if "PlaybackSettings.volumeGainSteps" not in screen:
        problems.append("settings_screen.dart: the gain row must offer the "
                        "shared ladder, not a hand-written list")
    if "PlaybackSettings.clampVolumeGain(" not in screen:
        problems.append("settings_screen.dart: the dropdown value must be "
                        "snapped, or a stale value leaves it blank")

    notes.append("volume gain: 设置 offers 0.1x-2.0x in 0.1 steps and every file "
                 "starts from it, while the in-player slider stays local to that "
                 "one playback instead of writing back")


def check_review5_fixes() -> None:
    """第五轮评审里那批「会崩 / 会永久卡死 / 功能缺失」的修复，逐条钉住。

    这些位置各自只差一行两行，改回去不会有任何编译错误，跑起来也看不出来 ——
    要么要播到自然结尾才炸（音频图收尾的双重释放），要么要硬解连续失败四帧
    才冻结，要么要用户去找一部带 PGS 字幕的片子才知道不显示。静态断言在这里
    比测试更合适：测试跑不到这些分支，而它们又恰好都是「一改就没」的那种。
    """
    def text_of(rel: str) -> str:
        return (ROOT / rel).read_text(encoding="utf-8")

    audio = text_of("native/src/core/audio.c")
    for needle, why in (
        ("p->audio.graph_out",
         "the flush path no longer works on the resident frame; a local AVFrame *"
         " copy would leave p->audio.graph_out dangling after av_frame_free"),
        ("p->audio.content_cursor",
         "the flush path starts its timestamps from zero again; the tail of a "
         "speed-changed stream would jump back to the beginning"),
    ):
        if needle not in audio:
            problems.append(f"native/src/core/audio.c: {why}")
    # 局部别名本身没问题（push_through_graph 也用），危险的是对别名 av_frame_free。
    if "av_frame_free(&out);" in audio:
        problems.append(
            "native/src/core/audio.c: the flush path frees its local frame again; "
            "the resident graph_out would be freed twice")

    video = text_of("native/src/core/video.c")
    for needle, why in (
        ("if (r == LP_OK) {",
         "a failed hardware send counts as in-flight again; four failures in a row "
         "leave in_flight at the cap and the video thread stops taking packets"),
        ("p->video.in_flight++",
         "the in-flight counter is gone; the prefetch loop would spin"),
        ("lp_hw_decoder_release(p->video.hw, hf);",
         "dropped frames are presented anyway; the picture would show a frame the "
         "clock already gave up on"),
        ("lp_hw_decoder_present_with_subtitles(",
         "graphics subtitles never reach the hardware path; PGS / VobSub stay "
         "invisible on Apple"),
        ("p->video.sub_blend_warned",
         "nothing remembers that this platform cannot blend graphics subtitles; "
         "the log line would repeat every frame"),
        ("const double fd = p->video.frame_duration > 0.0 ? p->video.frame_duration",
         "the pacer is back on the hard-coded 0.04 s frame period; 30 and 60 fps "
         "content would drift behind the clock"),
        ("const double sp = p->speed > 0.01 ? p->speed : 1.0;",
         "the pacer ignores playback speed; at 2x it would wait a full frame "
         "period and drop every other frame"),
        ("if (diff > 0 && diff < LP_PRESENT_LEAD_US) {",
         "the present lead is declared but never applied"),
        ("p->video.last_present_at_us = 0;",
         "a seek leaves the pacer anchored before the seek; the first frames "
         "after it would be spaced by a stale timestamp"),
        ("av_usleep(100000);",
         "the idle wait is back to a few milliseconds; a stopped player would "
         "spin at 200 wakeups per second"),
    ):
        if needle not in video:
            problems.append(f"native/src/core/video.c: {why}")

    # 帧数守恒：两个分支各一次，不能只留一处。
    if video.count("p->video.frames_discarded++;") != 2:
        problems.append(
            "native/src/core/video.c: frames_discarded is not counted on both the "
            "hardware and software paths; the conservation check would go nonzero "
            "on whichever one is missing")
    if video.count("p->video.frames_received++;") != 2:
        problems.append(
            "native/src/core/video.c: frames_received is not counted on both paths")

    player = text_of("native/src/core/player.c")
    for needle, why in (
        ("p->opened = 0;",
         "close no longer clears opened up front; the tick thread can call "
         "apply_audio_switch and join the same audio thread twice"),
        ("if (lp_is_abort(p)) {",
         "apply_audio_switch does not check the abort flag; closing while a track "
         "switch is pending tears down the sink twice"),
        ("p->vout.frames_delivery_lost = 0;",
         "the delivery-lost counter is never reset; it would report the total "
         "since playback started while every other counter reports one second"),
        ("lp_audio_sink_latency_us(",
         "the master clock ignores the output latency; it runs ahead of what the "
         "user actually hears by one audio buffer"),
        ("lp_clock_sync(&p->extc,",
         "the external clock is never pulled back toward the audio clock; after a "
         "stall it drifts away until the picture is visibly behind"),
    ):
        if needle not in player:
            problems.append(f"native/src/core/player.c: {why}")

    demux = text_of("native/src/core/demux.c")
    for needle, why in (
        ('\\"default\\":%s',
         "audio tracks no longer report their default disposition; the track "
         "picker has to guess that the first one is the default"),
        ("lp_pq_signal_eof(&p->video.pq, eof_serial);",
         "a read error no longer signals end of stream; the decoders would wait "
         "forever and ENDED would never fire"),
        ("lp_clock_set(&p->extc, start_seconds,",
         "the clocks start at zero again; a file with a start_time offset shows "
         "black until the offset elapses"),
    ):
        if needle not in demux:
            problems.append(f"native/src/core/demux.c: {why}")

    queue = text_of("native/src/core/queue.c")
    if "q->nb_packets > 8 || q->bytes >= q->max_bytes" not in queue:
        problems.append(
            "native/src/core/queue.c: back pressure needs both limits again; a "
            "stream of tiny packets can grow the queue without bound")

    subs = text_of("native/src/core/subtitle.c")
    for needle, why in (
        ("if (!p || !p->subs_inited) {",
         "lp_subtitle_set_delay reaches for the subtitle mutex before it is "
         "initialised; setting a delay from open options is undefined behaviour"),
        ("p->subs.delay_us = 0;",
         None),
    ):
        if why and needle not in subs:
            problems.append(f"native/src/core/subtitle.c: {why}")
    if "void lp_subtitle_open" in subs:
        start = subs.index("void lp_subtitle_open")
        head = subs[start:start + 2000]
        if "p->subs.delay_us = 0;" in head:
            problems.append(
                "native/src/core/subtitle.c: opening a subtitle track clears the "
                "delay again; the value set from open options would be lost")

    # 图形字幕后端：四平台都要回答，Apple 必须真的混合。
    hosts = {
        "native/src/platform/apple/videotoolbox_decoder.c": "lp_sub_overlay_blend(d->player, base",
        "native/src/platform/android/media_codec_decoder.c": "return LP_ERR_UNSUPPORTED;",
        "native/src/platform/win32/d3d11va_decoder.c": "return LP_ERR_UNSUPPORTED;",
        "native/src/platform/stub/stub_platform.c": "return LP_ERR_UNSUPPORTED;",
    }
    for rel, needle in hosts.items():
        text = text_of(rel)
        if "lp_hw_decoder_present_with_subtitles" not in text:
            problems.append(
                f"{rel}: does not answer lp_hw_decoder_present_with_subtitles; the "
                "core would have to guess whether graphics subtitles can be drawn")
        if needle not in text:
            problems.append(f"{rel}: lost its subtitle blending behaviour")

    # 宿主纹理：销毁时必须先摘播放器指针。
    for rel in ("app/ios/Runner/AppDelegate.swift",
                "app/macos/Runner/MainFlutterWindow.swift"):
        text = text_of(rel)
        if "func detach()" not in text:
            problems.append(
                f"{rel}: PlayerTexture has no detach(); the raster thread can still "
                "be inside copyPixelBuffer when the player is freed")
        if "tex.detach()" not in text:
            problems.append(f"{rel}: destroyTexture never detaches the player pointer")
        if "lock.lock()" not in text:
            problems.append(
                f"{rel}: the player pointer is read without a lock; detach could "
                "free it mid-copy")

    dart_checks = {
        "app/lib/data/progress.dart": ("_scheduleFlush()",
            "progress writes are flushed synchronously again; the player calls "
            "save() every five seconds and each one rewrites the whole table"),
        "app/lib/data/trace.dart": ("traceMaxBytes",
            "the trace file grows without a bound; a long session fills the device"),
        "app/lib/ui/splash_gate.dart": ("if (_phase != _Phase.content)",
            "the splash swaps the tree shape when it finishes; the home screen "
            "state is rebuilt and every source is listed twice"),
        "app/lib/ui/server_edit_screen.dart": ("_statusOk",
            "the connection banner goes back to matching on the word inside the "
            "message instead of a boolean"),
        "app/lib/data/thumbs.dart": ("unawaited(file.delete()",
            "a corrupt thumbnail stays on disk; every scroll past it re-reads and "
            "re-fails the same file"),
    }
    for rel, (needle, why) in dart_checks.items():
        if needle not in text_of(rel):
            problems.append(f"{rel}: {why}")

    notes.append(
        "review 5: the flush path keeps ownership of its resident frame, a failed "
        "hardware send no longer pins in_flight, dropped frames are released instead "
        "of shown, graphics subtitles blend on the Apple hardware path, the pacer "
        "uses the real frame period divided by speed, a read error ends the stream, "
        "and the host textures detach the player before it is freed")


def check_audio_underfill() -> None:
    """三个音频回调都要把「没拉满」的那段补成静音。

    回调拿到一块缓冲区去填，`lp_audio_pull_pcm` 可能只给回一部分（环里就
    这么多）。剩下的那段如果原样交回去，设备会把上一轮留在同一块内存里的
    样本再播一遍：听感不是欠载的静音，而是一小段回声。CoreAudio 那端一直
    是对的，另外两端漏了。
    """
    win = (ROOT / "native/src/platform/win32/win32_platform.c").read_text(
        encoding="utf-8", errors="replace")
    if win.count("lp_audio_pull_pcm(") != 3:
        problems.append(
            "native/src/platform/win32/win32_platform.c: the WASAPI renderer no "
            "longer pulls in all three places (render thread, priming chunk, "
            "waveOut fill)")
    if win.count("if (got < frames) {") != 1:
        problems.append(
            "native/src/platform/win32/win32_platform.c: the render thread does "
            "not top up a partial pull; the tail of the buffer would replay the "
            "previous chunk as an echo")
    if win.count("if (primed < s->frames_per_buffer) {") != 1:
        problems.append(
            "native/src/platform/win32/win32_platform.c: the priming chunk is "
            "released without being topped up")
    if "IAudioRenderClient_ReleaseBuffer(s->was_render, (UINT32)frames, 0);" not in win:
        problems.append(
            "native/src/platform/win32/win32_platform.c: the render buffer is no "
            "longer released with the full length after a partial pull")

    aa = (ROOT / "native/src/platform/android/aaudio_sink.c").read_text(
        encoding="utf-8", errors="replace")
    if "memset(samples + from, 0, (total - from) * sizeof(float));" not in aa:
        problems.append(
            "native/src/platform/android/aaudio_sink.c: a partial pull is not "
            "zero-filled; AAudio would replay the stale tail of its buffer")
    if "#include <string.h>" not in aa:
        problems.append(
            "native/src/platform/android/aaudio_sink.c: memset is used without "
            "including <string.h>")

    notes.append(
        "audio underfill: every platform zero-fills the part of its callback "
        "buffer that the ring could not supply, so an underrun is silence "
        "instead of the previous chunk played twice")


def check_browser_error_surface() -> None:
    """浏览链路里「不是网络错误」的异常也要落到界面上。

    这两处原来只 catch `MediaSourceException`：解析越界、状态错乱这类异常
    被 `finally` 吞掉，转圈收了、页面没动，用户只觉得点了没反应。服务器
    保存失败同理 —— 写盘抛错时以前连一句提示都没有。
    """
    browser = (ROOT / "app/lib/ui/browser_screen.dart").read_text(
        encoding="utf-8", errors="replace")
    if browser.count("} catch (e) {") != 2:
        problems.append(
            "app/lib/ui/browser_screen.dart: navigation and refresh no longer "
            "catch anything but MediaSourceException; a non-network failure "
            "would stop the spinner and leave the old directory on screen")
    if browser.count("await showError(context, '$e');") != 2:
        problems.append(
            "app/lib/ui/browser_screen.dart: an unexpected navigation failure is "
            "caught but never shown")

    edit = (ROOT / "app/lib/ui/server_edit_screen.dart").read_text(
        encoding="utf-8", errors="replace")
    if "_status = '保存失败：$e';" not in edit:
        problems.append(
            "app/lib/ui/server_edit_screen.dart: a failed save is swallowed; the "
            "dialog would close over an unsaved profile")
    if "} catch (e) {\n      // 写盘失败" not in edit:
        problems.append(
            "app/lib/ui/server_edit_screen.dart: the save path no longer catches "
            "every failure; only the exception types it names would be reported")

    notes.append(
        "error surface: a browser failure that is not a network error and a "
        "failed profile save both reach the user instead of vanishing into a "
        "finally block")


def check_runtime_guards() -> None:
    """启动期的三道自检：ABI 版本、返回键绑定、共享包的版本号。

    这三处的共同点是「写错了也不报错」。ABI 版本不查，库和 Dart 代码不配套
    时会在第一次调用里炸在别的地方；返回键绑定不重推，用户改完设置当场没
    反应，下次进页面才好；包版本号不跟，`pub get` 的解析结果取决于 pub 的
    缓存而不是仓库里写的值。
    """
    def text_of(rel: str) -> str:
        return (ROOT / rel).read_text(encoding="utf-8")

    bindings = text_of("app/lib/core/bindings.dart")
    for needle, why in (
        ("static NativeCore _openChecked()",
         "the core is opened without checking its ABI version; a mismatched "
         "lanplayer.dll would be accepted and fail somewhere far away"),
        ("if (actual != abiVersion) {",
         "the ABI check compares nothing; both sides would load regardless"),
        ("两边的库文件不配套",
         "a mismatched core surfaces as a bare error without telling the user "
         "that the library and the app do not belong together"),
    ):
        if needle not in bindings:
            problems.append(f"app/lib/core/bindings.dart: {why}")

    keyboard = text_of("app/lib/ui/keyboard.dart")
    if "void rebind(LogicalKeyboardKey? key) {" not in keyboard:
        problems.append(
            "app/lib/ui/keyboard.dart: BackKeyHandler lost rebind; a changed "
            "back-key binding would only take effect on the next page open")
    if "final next = key ?? ShortcutBindings.empty.keyFor(ShortcutAction.back);" not in keyboard:
        problems.append(
            "app/lib/ui/keyboard.dart: rebind no longer treats null as the default "
            "binding; the folder picker passes null on purpose and would end up "
            "with no back key at all")
    for rel, needle, why in (
        ("app/lib/ui/browser_screen.dart",
         "_backKey.rebind(SettingsStore.instance.value.shortcuts",
         "the browser page binds the back key once and never follows a later change"),
        ("app/lib/ui/folder_picker.dart", "_backKey.rebind(widget.backKey);",
         "the folder picker never follows a changed back-key binding"),
    ):
        if needle not in text_of(rel):
            problems.append(f"{rel}: {why}")

    app_version = ""
    for line in text_of("app/pubspec.yaml").splitlines():
        if line.startswith("version: "):
            app_version = line.split(":", 1)[1].strip()
            break
    if not app_version:
        problems.append("app/pubspec.yaml: no version line")
    for rel in ("packages/lanplayer_core/pubspec.yaml", "packages/lanplayer_video/pubspec.yaml"):
        found = ""
        for line in text_of(rel).splitlines():
            if line.startswith("version: "):
                found = line.split(":", 1)[1].strip()
                break
        if found != app_version:
            problems.append(
                f"{rel}: version {found or '(none)'} does not match the app's "
                f"{app_version}; the two ship together and should carry one number")

    notes.append(
        "runtime guards: a mismatched core ABI is rejected at startup, a changed "
        "back-key binding reaches the open pages, and every package carries the "
        "app's version")
    demux_seek = text_of("native/src/core/demux.c")
    for needle, why in (
        ('LP_WARN("demux", "seek to %lld us failed: %d"',
         "a failed seek is logged without the return code; nothing downstream "
         "can tell that the position did not move"),
        ('lp_emit_error(p, LP_ERR_IO, "seek failed");',
         "a failed seek is silent; the UI would show the old position while the "
         "user believes the drag took effect"),
    ):
        if needle not in demux_seek:
            problems.append(f"native/src/core/demux.c: {why}")
    seek_fail = demux_seek.find('lp_emit_error(p, LP_ERR_IO, "seek failed");')
    if seek_fail < 0 or "lp_emit_buffering(p, 0, 0);" not in demux_seek[seek_fail:seek_fail + 400]:
        problems.append(
            "native/src/core/demux.c: the failed-seek path does not clear the "
            "buffering flag; the spinner would sit there until playback resumes")

    audio_src = text_of("native/src/core/audio.c")
    if "            av_usleep(1000);\n            continue;\n        }\n        if (p->audio.eof) {" not in audio_src:
        problems.append(
            "native/src/core/audio.c: the drain wait loop spins without sleeping; "
            "on a fallback decoder that sets eof asynchronously it burns a core")

    player_src = text_of("native/src/core/player.c")
    for needle, why in (
        ("int best = av_find_best_stream(", 
         "av_find_best_stream is called without keeping its result; a negative "
         "return would be stored as the stream index"),
        ('LP_WARN("player", "no video stream after the surface arrived',
         "a missing video stream after the surface arrives is not reported"),
    ):
        if needle not in player_src:
            problems.append(f"native/src/core/player.c: {why}")

    notes.append(
        "recovery paths: a seek that cannot move reports it and clears the spinner, "
        "a drained decoder does not spin, and a video stream that disappears after "
        "the surface arrives is caught before the queue is started")


def check_boot_failure() -> None:
    """启动失败要能在界面上看到，而不是留一块空白。

    状态目录打不开（磁盘满、权限被收回、容器被系统清掉）时四个 store 一个
    都读不成。以前首页在这条路径上画的是 `SizedBox.expand()`：没有说明、
    没有按钮，用户只能杀掉重开，重开还是同一块空白。
    """
    def text_of(rel: str) -> str:
        return (ROOT / rel).read_text(encoding="utf-8", errors="replace")

    boot = ROOT / "app/lib/data/boot_status.dart"
    if not boot.exists():
        problems.append(
            "app/lib/data/boot_status.dart is missing; a failed boot has "
            "nowhere to report itself and the home screen stays blank")
        return
    bs = text_of("app/lib/data/boot_status.dart")
    for needle, why in (
        ("class BootStatus extends ChangeNotifier",
         "the boot result has to be observable, otherwise nobody repaints "
         "once it fails"),
        ("static final BootStatus instance",
         "callers must share one instance; a per-widget copy would never see "
         "the failure"),
        ("void failed(Object error)", "nothing can record a boot failure"),
        ("void succeeded()", "a boot could never come back from a failure"),
        ("Future<void> Function()? retry;",
         "the failure screen has no way back to the boot routine"),
    ):
        if needle not in bs:
            problems.append(f"app/lib/data/boot_status.dart: {why} ({needle})")

    main = text_of("app/lib/main.dart")
    for needle, why in (
        ("BootStatus.instance.retry = _boot;",
         "the retry hook is never connected; the button on the failure screen "
         "would do nothing"),
        ("BootStatus.instance.failed(e);",
         "a failed boot is swallowed again; the home screen would stay blank"),
        ("BootStatus.instance.succeeded();",
         "a successful boot never clears the failure, so the error would "
         "survive the retry"),
    ):
        if needle not in main:
            problems.append(f"app/lib/main.dart: {why} ({needle})")
    if main.count("BootStatus.instance.failed(e);") != 2:
        problems.append(
            "app/lib/main.dart: only one of the two boot steps reports its "
            "failure; a state directory that opens but cannot be read would "
            "still end in a blank screen")

    home = text_of("app/lib/ui/home_screen.dart")
    for needle, why in (
        ("_BootFailureIfAny(status: BootStatus.instance)",
         "the empty home screen no longer offers a failure view"),
        ("BootStatus.instance.addListener(_onBootChanged);",
         "the home screen never listens for the boot result; the failure view "
         "would only appear after an unrelated rebuild"),
        ("BootStatus.instance.removeListener(_onBootChanged);",
         "the boot listener is added but never removed"),
        ("onPressed: status.retry == null",
         "the retry button is wired unconditionally; it would throw when no "
         "boot routine is attached"),
        ("打不开配置目录",
         "the failure view lost its title and is back to an unexplained blank"),
    ):
        if needle not in home:
            problems.append(f"app/lib/ui/home_screen.dart: {why} ({needle})")
    if "const _BootFailureIfAny()" in home:
        problems.append(
            "app/lib/ui/home_screen.dart: the failure view is a const no-arg "
            "widget again; a canonical const child is never rebuilt, so the "
            "message would stay on screen after a successful retry")
    # 读单例必须发生在父级的 build 里，由参数传进来。若改回「组件内部自己读
    # 单例」，它就会退化成那个 const 无参组件，重试成功后擦不掉。
    fail_body = home.split("class _BootFailureIfAny", 1)[-1]
    if "final status = BootStatus.instance;" in fail_body:
        problems.append(
            "app/lib/ui/home_screen.dart: the failure view reads the boot "
            "singleton inside its own build; it can no longer be invalidated "
            "by a retry and would keep showing the old error")

    notes.append(
        "boot failure: a state directory that cannot be opened or read shows "
        "up on the home screen with the underlying error and a retry that "
        "re-runs the same boot routine")


def check_dart_hot_paths() -> None:
    """列表与设置页的热路径：这些写法改回去不会报错，只会变慢。

    每一条都对应一次真实的每帧开销：`build()` 里重扫整份目录、每帧跨一次
    FFI、每个来源行现编一次正则。它们都不影响功能，所以只有静态断言能拦住。
    """
    def text_of(rel: str) -> str:
        return (ROOT / rel).read_text(encoding="utf-8")

    probes = (
        ("app/lib/data/home_sources.dart",
         "final RegExp _rePathSeparator = RegExp(r'[\\\\/]');",
         "the path separator regex is compiled once per source line again"),
        ("app/lib/data/home_sources.dart",
         "path.split(_rePathSeparator)",
         "the cached separator regex is declared but never used"),
        ("app/lib/ui/browser_screen.dart",
         "'${_listing.videos.length} 个视频 · '",
         "the header counts videos by scanning the directory tree again on "
         "every frame instead of using the cached list"),
        ("app/lib/ui/browser_screen.dart",
         "'${_listing.folders.length} 个文件夹'",
         "the header counts folders by scanning the directory tree again on "
         "every frame instead of using the cached list"),
        ("app/lib/ui/home_screen.dart",
         "if (identical(servers, _sourcesServers) &&",
         "the home source list is rebuilt from scratch on every read again; "
         "build(), _loadAll() and _onStoreChanged() all read it"),
        ("app/lib/ui/settings_screen.dart",
         "if (_abiLoaded) return _abiCache;",
         "the settings pane asks the core for its ABI version across FFI on "
         "every rebuild again; it cannot change within one process"),
        ("app/lib/ui/server_edit_screen.dart",
         "if (traceEnabled) {\n        for (final host in hosts) {",
         "the LAN scan result is printed unconditionally again; that list is "
         "part of the user's network"),
        ("app/lib/player/playlist.dart",
         "List<MediaEntry> get items => _items;",
         "the playlist getter copies the whole list on every read again"),
        ("app/lib/ui/home_screen.dart",
         "if (!setEquals(ids, _loads.keys.toSet())) {",
         "store notifications are no longer merged; ServerStore and "
         "LocalFolderStore each notify on load, so startup would fire _loadAll "
         "twice and the second one would discard the first one's results"),
        ("app/lib/ui/home_screen.dart",
         "if (serverEdited) unawaited(_load(s));",
         "renaming a source reloads every source again; a rename does not "
         "change any directory"),
    )
    cache: dict[str, str] = {}
    for rel, needle, why in probes:
        if rel not in cache:
            cache[rel] = text_of(rel)
        n = cache[rel].count(needle)
        if n != 1:
            problems.append(f"{rel}: {why} (found {n} occurrences)")

    # 三处零调用的死代码，删掉之后不该再冒出来。
    gone = (
        ("app/lib/ui/feedback.dart", "String describeServer(ServerProfile p)",
         "the UI copy of describeServer is back; the data layer already has "
         "describeServerLine and this one has no callers"),
        ("app/lib/ui/widgets/number_field.dart", "this.suffix,",
         "NumberField grew a suffix again; the unit belongs outside the box"),
        ("app/lib/ui/feedback.dart", "../data/models.dart",
         "feedback.dart no longer needs the model import once describeServer "
         "is gone"),
    )
    for rel, needle, why in gone:
        text = cache.get(rel)
        if text is None:
            text = text_of(rel)
            cache[rel] = text
        if needle in text:
            problems.append(f"{rel}: {why}")

    # 播完一个片子回来，不该重拉根目录：目录内容没变，SMB 上重列一次要
    # 1–3 秒，列表会先闪成占位再填回去。这段逻辑在内层没有唯一串可用，
    # 所以按函数体判：`_play` 里允许 setState，不允许再 `_load`。
    hc = text_of("app/lib/ui/home_screen.dart")
    start = hc.find("Future<void> _play(")
    if start < 0:
        problems.append("app/lib/ui/home_screen.dart: _play is gone")
    else:
        body = hc[start:]
        end = body.find("\n  }")
        body = body[:end if end > 0 else 4000]
        if "unawaited(_load(s))" in body or "await _load(s)" in body:
            problems.append(
                "app/lib/ui/home_screen.dart: returning from the player reloads "
                "the whole root directory again; on SMB that is seconds of "
                "placeholder for a listing that did not change")

    notes.append(
        "dart hot paths: the directory header and the LAN scan use their "
        "cached lists, the home source list is reused across reads, the "
        "settings pane reads the ABI version once, and the zero-call helpers "
        "are gone")



def check_platform_lifecycle() -> None:
    """宿主生命周期：Surface 回收、音频中断、竖拍视频的朝向。

    这三处都只在真机上才走得到 —— Windows 上没有 ANativeWindow、没有
    AVAudioSession，测试片也不是竖拍的。改回去不会有任何编译错误，也过不了
    任何一条自动化测试，所以只能靠静态断言钉住。
    """
    def text_of(rel: str) -> str:
        return (ROOT / rel).read_text(encoding="utf-8")

    kotlin = text_of("app/android/app/src/main/kotlin/dev/lanplayer/app/MainActivity.kt")
    for needle, why in (
        ("installSurfaceCallback(p)",
         "the surface producer is created without a callback; when the system "
         "reclaims the Surface the core keeps a released ANativeWindow"),
        ("override fun onSurfaceDestroyed()",
         "nothing reacts to the Surface being destroyed"),
        ("VideoTextureBridge.nativeSetSurface(handle, 0L)",
         "the core is not told to drop the window before it is released"),
        ("VideoTextureBridge.nativeSetSurface(handle, w)",
         "a rebuilt Surface never reaches the core; playback would resume into "
         "nothing"),
        ("if (producer !== p) {",
         "a stale callback from a released producer can still swap the window"),
    ):
        if needle not in kotlin:
            problems.append(f"MainActivity.kt: {why}")

    jni = text_of("native/src/platform/android/jni_bridge.c")
    if "nativeSetSurface" not in jni:
        problems.append(
            "native/src/platform/android/jni_bridge.c: no nativeSetSurface entry "
            "point; Kotlin has no way to hand a rebuilt window to the core")
    if "lp_player_set_surface(" not in jni:
        problems.append(
            "native/src/platform/android/jni_bridge.c: nativeSetSurface does not "
            "go through lp_player_set_surface; the core would not restart the "
            "video pipeline when a window appears")

    ios = text_of("app/ios/Runner/AppDelegate.swift")
    for needle, why in (
        ("configureAudioSession()\n    observeAudioSession()",
         "the audio session is configured once at launch and never repaired; "
         "after a phone call the app plays picture without sound"),
        ("AVAudioSession.interruptionNotification",
         "no interruption observer; an ended interruption leaves the session "
         "inactive"),
        ("AVAudioSession.mediaServicesWereResetNotification",
         "a reset audio service leaves every session object invalid"),
        ("options.contains(.shouldResume)",
         "the session is reactivated even when the system says not to; that "
         "would steal audio back while the user is still on a call"),
    ):
        if needle not in ios:
            problems.append(f"AppDelegate.swift: {why}")

    demux = text_of("native/src/core/demux.c")
    for needle, why in (
        ("av_packet_side_data_get(",
         "the display matrix is read from the stream-level side data that FFmpeg 6 "
         "removed; portrait phone video would lie on its side again"),
        ("av_display_rotation_get(matrix)",
         "the rotation angle is computed by hand instead of through libavutil"),
        ("stream_rotation_degrees(st)",
         "the media info no longer reports a rotation"),
    ):
        if needle not in demux:
            problems.append(f"native/src/core/demux.c: {why}")

    models = text_of("app/lib/data/media_models.dart")
    for needle, why in (
        ("int get displayWidth",
         "VideoInfo lost its display-oriented width; a 90-degree rotated video "
         "would be laid out with the encoded aspect ratio"),
        ("int get displayHeight", "VideoInfo lost its display-oriented height"),
        ("rotation: _normalizeRotation(",
         "any angle is accepted; a slanted matrix would be applied as if it were "
         "a quarter turn"),
    ):
        if needle not in models:
            problems.append(f"app/lib/data/media_models.dart: {why}")

    screen = text_of("app/lib/ui/player_screen.dart")
    if "quarterTurns: _videoQuarterTurns" not in screen:
        problems.append(
            "app/lib/ui/player_screen.dart: the texture is never rotated; portrait "
            "video would still be sideways")
    if "video.displayWidth > 0 && video.displayHeight > 0" not in screen:
        problems.append(
            "app/lib/ui/player_screen.dart: the aspect ratio is back on the encoded "
            "dimensions")

    notes.append(
        "platform lifecycle: a reclaimed Android Surface is detached before release "
        "and re-attached when it returns, iOS audio is reactivated after an "
        "interruption, and portrait video is rotated using the container's display "
        "matrix")


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
            ("'list_all': 1", "the picker no longer asks for the unfiltered "
                              "listing, so only playable files would be visible"),
            ("this.isFile = false", "the picker can no longer return a folder "
                                    "choice that is not a file"),
            # The kernel hands entries back with a `file://` prefix already,
            # while the roots (drives, home, downloads) are bare paths.  Adding
            # the prefix unconditionally produced `file://file://D:/x` and every
            # directory below a drive failed with "not found".
            ("LpScheme.isFileUrl(path)", "the picker no longer tolerates both "
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

    # 2026-11-01：用户要求「添加」菜单里删掉「直接输入路径」。那条路径手写
    # 对话框既绕过了权限申请，也绕过了窄→宽的路径转换，一直是本地来源出
    # 问题的入口；现在只剩「添加服务器」与「添加本地文件/文件夹」两项。
    home = ROOT / "app" / "lib" / "ui" / "home_screen.dart"
    if home.exists():
        hc = home.read_text(encoding="utf-8")
        if "直接输入路径" in hc:
            problems.append("app/lib/ui/home_screen.dart still offers 直接输入"
                            "路径 in the add menu; the user removed it")
        if "askLocalPath" in hc:
            problems.append("home_screen.dart still calls askLocalPath; the "
                            "manual path flow was deleted with the menu entry")
    else:
        problems.append("app/lib/ui/home_screen.dart missing")

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
    check_source_manifest()
    check_transport_registry()
    check_video_bridge_contract()
    check_model_split()
    check_build_matrix()
    check_symbols()
    check_native_runtime()
    check_dart_syntax()
    check_dart_compile()
    check_dart_tests()
    check_windows_plugin()
    check_texture_colors()
    check_lan_scan()
    check_listing_index()
    check_thumbnails()
    check_backspace_guard()
    check_seek_step()
    check_speed_steps()
    check_installers()
    check_release_policy()
    check_player_layout()
    check_player_rebuild_scope()
    check_dead_code()
    check_script_encoding()
    check_track_selection()
    check_subtitle_fonts()
    check_subtitle_sheet_selection()
    check_subtitle_advanced()
    check_android_playback()
    check_playback_profiles()
    check_apple_wiring()
    check_hw_decode()
    check_nal_behaviour()
    check_transport_behaviour()
    check_subtitle_robustness()
    check_settings_layout()
    check_settings_groups()
    check_playback_orientation()
    check_windows_single_instance()
    check_texture_delivery()
    check_review5_fixes()
    check_audio_underfill()
    check_browser_error_surface()
    check_runtime_guards()
    check_dart_hot_paths()
    check_boot_failure()
    check_platform_lifecycle()
    check_startup_home()
    check_surface_tap()
    check_volume_gain()
    check_local_picker()
    check_splash()
    check_ui_thread()
    check_offline_shortcut()
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
