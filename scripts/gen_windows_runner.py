#!/usr/bin/env python3
"""Generate app/windows/ from the Flutter SDK's own Windows runner templates.

``flutter create --platforms=windows .`` does exactly this; reproducing it here
means the desktop runner can be generated on machines where the flutter tool
cannot run (no git, no interactive console) and the generated tree stays
reviewable in the repository.

生成物并不等于模板原文：``RUNNER_PATCHES`` 里的几条是本仓库对 runner 的改动
（目前只有单实例一条），模板里找不到对应原文时会直接报错而不是默默丢掉它们。

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

# 模板之外本仓库自己加的改动：桌面图标再点一次不该开第二个窗口，第二个进程
# 把已存在的窗口提到前台就退出（实现见 runner/single_instance.cpp）。
# 每一条都是 (相对路径, 原文, 替换)；原文在模板里找不到就直接报错 —— 模板
# 一旦改版，这里必须有人看一眼，而不是默默生成一个丢掉单实例的 runner。
RUNNER_PATCHES = [
    ("runner/main.cpp",
     '#include "flutter_window.h"\n#include "utils.h"\n',
     '#include "flutter_window.h"\n#include "single_instance.h"\n#include "utils.h"\n'),
    ("runner/main.cpp",
     "                      _In_ wchar_t *command_line, _In_ int show_command) {\n"
     "  // Attach to console when present (e.g., 'flutter run') or create a\n",
     "                      _In_ wchar_t *command_line, _In_ int show_command) {\n"
     "  // 已经有实例在跑时把它提到前台，然后直接退出：托盘图标/桌面快捷方式\n"
     "  // 连点两下不该出现第二个窗口和第二份播放状态。必须在建窗口之前判断，\n"
     "  // 否则会先闪一个空白窗口再退出。\n"
     "  if (ActivateRunningInstance()) {\n"
     "    return EXIT_SUCCESS;\n"
     "  }\n"
     "\n"
     "  // Attach to console when present (e.g., 'flutter run') or create a\n"),
    ("runner/CMakeLists.txt",
     '  "main.cpp"\n  "utils.cpp"\n',
     '  "main.cpp"\n  "single_instance.cpp"\n  "utils.cpp"\n'),
    # 下面两条是本仓库更早就有的改动，一直没写进这张表：重新生成 app/windows/
    # 会把它们冲掉（/utf-8 没了之后带中文注释的源文件在 /WX 下直接编译失败，
    # 播放内核与 FFmpeg 的 DLL 也不会再进 bundle）。
    ("CMakeLists.txt",
     "  target_compile_options(${TARGET} PRIVATE /EHsc)\n",
     "  target_compile_options(${TARGET} PRIVATE /EHsc)\n"
     "  # 本项目的 C/C++ 源码用 UTF-8 保存，注释里带简体中文。\n"
     "  # MSVC 默认按系统代码页（中文 Windows 是 GBK）读源文件，会把 UTF-8 的中文注释\n"
     "  # 读成乱码，甚至在某个字节恰好构成反斜杠时吃掉下一行代码。\n"
     "  # /utf-8 明确告诉编译器「源文件和执行字符集都是 UTF-8」。\n"
     "  target_compile_options(${TARGET} PRIVATE /utf-8)\n"),
    ("CMakeLists.txt",
     '# Copy the native assets provided by the build.dart from all packages.\n',
     "# 播放内核与它依赖的 FFmpeg DLL。\n"
     "#\n"
     "# 以前这两个都靠 scripts/build_windows_desktop.py 在 INSTALL 之后手工\n"
     "# shutil.copy2 —— 也就是说 `flutter build windows` 直接出来的产物缺\n"
     "# lanplayer.dll 与这些 DLL，一启动就在 DynamicLibrary.open('lanplayer.dll')\n"
     "# 那里抛 Invalid argument，窗口连闪都不闪。放在这里，两条出包路径都齐。\n"
     "#\n"
     "# av* 与 sw* 都要：内核直接链了 swresample / swscale（重采样与缩放），\n"
     "# 只装 av* 的话打包脚本会报 missing swresample-*.dll —— 那正是本机\n"
     "# `flutter build windows` 产物缺两个 DLL 时的样子。\n"
     'set(LP_CORE_DLL "${CMAKE_CURRENT_SOURCE_DIR}/../../build/win-x64/lanplayer.dll")\n'
     'if(EXISTS "${LP_CORE_DLL}")\n'
     '  install(FILES "${LP_CORE_DLL}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"\n'
     "    COMPONENT Runtime)\n"
     "endif()\n"
     "file(GLOB LP_FFMPEG_DLLS\n"
     '  "${CMAKE_CURRENT_SOURCE_DIR}/../../.tools/ffmpeg/bin/av*.dll"\n'
     '  "${CMAKE_CURRENT_SOURCE_DIR}/../../.tools/ffmpeg/bin/sw*.dll")\n'
     "if(LP_FFMPEG_DLLS)\n"
     "  list(SORT LP_FFMPEG_DLLS)\n"
     '  install(FILES ${LP_FFMPEG_DLLS} DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"\n'
     "    COMPONENT Runtime)\n"
     "endif()\n"
     "\n"
     "# Copy the native assets provided by the build.dart from all packages.\n"),
    (".gitignore",
     "flutter/ephemeral/\n",
     "flutter/ephemeral/\n"
     "\n"
     "# Local CMake/MSBuild build tree (cmake -B windows/out/build/...).\n"
     "out/\n"),
]


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
            text = expand(source.read_text(encoding="utf-8"), project, organization)
            for patch_name, old, new in RUNNER_PATCHES:
                if patch_name != name:
                    continue
                if old not in text:
                    raise lp.ScriptError(
                        f"{name}: the Flutter template no longer contains the text "
                        f"the single-instance patch expects - check RUNNER_PATCHES "
                        f"in scripts/gen_windows_runner.py")
                text = text.replace(old, new, 1)
            target.write_text(text, encoding="utf-8", newline="")
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
