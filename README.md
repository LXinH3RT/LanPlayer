# LanPlayer · 局域网播放器

用 Flutter 一套 UI（Android / iOS / iPadOS / macOS）包一个 C11 + FFmpeg 的播放内核，
通过 `dart:ffi` 直连，目标只有一个：**把家里 SMB 共享里的视频，用硬解、带字幕、不卡顿地放出来**。

```
┌──────────────────────────── Flutter (Dart) ────────────────────────────┐
│  服务器列表 / 文件浏览器 / 播放页 / 解码设置                          │
│  PlayerController ── dart:ffi ──► liblanplayer.so / .a                 │
│  字幕气泡（Flutter Text 渲染）        视频：Texture(textureId)          │
│  图形字幕（直接混合进 BGRA 帧）                                          │
└───────────────┬────────────────────────────────────────────────────────┘
                │ JNI / C ABI
┌───────────────▼──────────────── native core (C11) ─────────────────────┐
│  demux 线程 → 视频包队列 → 解码线程（MediaCodec / VideoToolbox / sw）    │
│              → 音频包队列 → 解码 → swr → atempo → 环形缓冲 → 平台音频   │
│              → 字幕包   → libavcodec 文本字幕 / SRT·ASS 解析            │
│  主时钟：音频环形缓冲播放头 → 视频按 pts 排期 → A/V 同步                │
│  传输层：LpSource（libsmb2 / file / 预留 tcp）→ 自定义 AVIOContext      │
└────────────────────────────────────────────────────────────────────────┘
```

## 模块完成情况

|模块|需求|实现位置|
|-|-|-|
|1 连接与浏览|服务器增删改、保存 IP/端口/账号密码|`app/lib/data/stores.dart`、`ui/server_edit_screen.dart`|
||连接后以文件列表浏览共享目录|`native/src/source/smb.c`、`ui/browser_screen.dart`|
|2 播放内核|libavformat 打开网络流、解析音视频字幕轨道|`native/src/core/demux.c`|
||硬解：Android MediaCodec / Apple VideoToolbox / Windows D3D11VA|`platform/android/media_codec_decoder.c`、`platform/apple/videotoolbox_decoder.c`、`platform/win32/d3d11va_decoder.c`|
||主时钟音画同步|`core/audio_ring.c`（时钟映射）、`core/video.c`（排期与丢帧）|
||音频输出：AAudio / AudioQueue|`platform/android/aaudio_sink.c`、`platform/apple/coreaudio_sink.c`|
||字幕：内嵌解码 + 外挂 SRT/ASS/VTT + ASS 富文本 + 图形字幕（PGS/VobSub/DVB）|`core/subtitle.c`（`sub_compile_text`、`bitmap_from_rect`、`lp_sub_overlay_blend`）、`ui/widgets/subtitle_overlay.dart`|
|3 播放控制|播放/暂停/快进快退/音量/进度拖拽|`core/player.c`、`ui/player_screen.dart`|
||0.5x–2.0x 倍速且音调不变|`core/audio.c`（atempo 链）、`lp_player_set_speed`|
||当前目录自动连播|`app/lib/player/playlist.dart`、`ui/player_screen.dart`|
||音轨/字幕切换、加载外挂字幕|`lp_player_select_track`、`lp_player_add_subtitle`|
||记忆播放进度：重开续播，列表显示进度条与百分比；设置里可关（默认开）|`app/lib/data/progress.dart`、`data/models.dart`（`rememberProgress`）、`ui/player_screen.dart`、`ui/browser_screen.dart`|
||手势（双击 ±10s / 上下滑音量亮度 / 长按 2x）与桌面键盘快捷键、真全屏|`ui/player_screen.dart`、`ui/video_texture.dart`（`setFullscreen`）、`packages/lanplayer_video`（改窗口样式）|
||播放页控件：返回键左上角，画面/速度/字幕/音轨/音量在底部操作行，鼠标移动即显、静止 2s 收起|`ui/player_screen.dart`（`_topBar` / `_bottomBar` / `_autoHideDelay`）|
|4 解码设置|硬解开关、软件解码兜底|`settings_screen.dart`、`core/video.c`（自动回退）|
||渲染模式（缩放策略/像素格式转换）|`platform/android/egl_renderer.c`、`scale_mode`|
||去隔行（yadif）|`core/video.c`（libavfilter 图）|
|5 本地播放|打开本地文件走同一内核|`source/file.c`、`ui/browser_screen.dart`（本地根目录）|

## 目录

### 一张表看每个文件夹干什么

「文件数」是该文件夹下的**递归**文件总数（含子目录），但已排除 `build/`、`.dart_tool/`、
`app/windows/flutter/ephemeral/`、`app/windows/out/` 这些生成目录——它们都在 `.gitignore` 里。

| 文件夹 | 文件数 | 作用 |
|-|-:|-|
| `app/` | 136 | Flutter 应用整体（Dart UI + 各平台外壳） |
| `app/lib/` | 19 | 全部 Dart 业务代码，下面五个子目录按职责拆开 |
| `app/lib/core/` | 2 | `bindings.dart` 是 `dart:ffi` 与 C ABI 的唯一契约；`player_controller.dart` 把事件流转成 `ChangeNotifier` |
| `app/lib/data/` | 5 | 数据层：`models.dart`（服务器/媒体/字幕模型）、`stores.dart` + `progress.dart`（JSON 持久化）、`repository.dart`（媒体源仓库）、`location.dart`（平台路径） |
| `app/lib/player/` | 1 | `playlist.dart`：播放列表与剧集识别（文件名里的集数解析） |
| `app/lib/ui/` | 9 | 五个界面（首页/浏览/播放/服务器编辑/设置）+ 主题、反馈文案、`video_texture.dart` 纹理桥 |
| `app/lib/ui/widgets/` | 1 | `subtitle_overlay.dart`：字幕气泡，纯 Flutter `Text.rich` 渲染，带描边层 |
| `app/lib/util/` | 1 | `format.dart`：时长、体积、码率等格式化 |
| `app/test/` | 3 | `flutter test` 用例：字幕 span 树断言 + golden 光栅化、设置项默认值 |
| `app/test/goldens/` | 1 | `rich_runs.png` 基准图，字幕颜色/粗细的像素级回归 |
| `app/tool/` | 1 | `browse_smoke.dart`：不开 UI 直接跑一遍 SMB 浏览的脚本 |
| `app/android/` | 6 | Android 外壳：Gradle、清单、Kotlin `MainActivity`（纹理/JNI）、`cpp/CMakeLists.txt`、生成的插件注册表 |
| `app/ios/` | 44 | iOS / iPadOS 外壳：`AppDelegate.swift`（纹理桥）、`Info.plist`、Bridging Header、`Runner.xcodeproj`、`Podfile` |
| `app/macos/` | 30 | macOS 外壳：`MainFlutterWindow.swift`（纹理桥）、`Runner.xcodeproj`、`Podfile`、两个 entitlements（含 `network.client`） |
| `app/windows/` | 19 | Windows 桌面外壳：CMake 工程 + Flutter runner |
| `app/windows/flutter/` | 5 | Flutter 与 CMake 的胶水层；`generated_plugins.cmake` 等文件由工具生成 |
| `app/windows/runner/` | 12 | 窗口与入口：`main.cpp`、`win32_window.cpp`（建窗/DPI）、`flutter_window.cpp`（纹理宿主） |
| `app/windows/runner/resources/` | 1 | `app_icon.ico`：exe 图标 |
| `packages/` | 14 | 本地 Flutter 插件包（不走 pub.dev，直接 path 依赖） |
| `packages/lanplayer_video/` | 6 | Windows 纹理插件，把内核的 BGRA 帧交进 Flutter 引擎 |
| `packages/lanplayer_video/lib/` | 1 | Dart 侧空壳（插件能力都走 MethodChannel，不需要 Dart API） |
| `packages/lanplayer_video/windows/` | 4 | C++ 实现 + CMake；`include/lanplayer_video/pixel_swizzle.h` 是 BGRA→RGBA 的唯一定义 |
| `packages/lanplayer_core/` | 8 | iOS / macOS 的 FFI 插件：两个 podspec 把 `liblanplayer.a` + FFmpeg + libsmb2 链进 Runner |
| `packages/lanplayer_core/ios/` | 3 | iOS podspec + `Classes/` 里一个编译期锚点（验证头文件搜索路径） |
| `packages/lanplayer_core/macos/` | 3 | macOS podspec + 同款锚点 |
| `native/` | 47 | C11 播放内核，三个平台共用一套 |
| `native/include/lanplayer/` | 4 | 公共 ABI 头（`lp_types/lp_player/lp_source/lp_log`），Dart 只认这四个文件 |
| `native/src/core/` | 7 | 内核心脏：`demux.c` 解封装、`video.c`/`audio.c` 解码与同步、`audio_ring.c` 主时钟、`queue.c` 包队列、`subtitle.c` 字幕（含 ASS 富文本与 PGS 位图）、`player.c` 状态机 |
| `native/src/source/` | 5 | `LpSource` 抽象：`smb.c`（libsmb2）、`file.c`、`url.c` 解析、`io.c` 自定义 AVIO |
| `native/src/util/` | 2 | `lp_str.c` 字符串/JSON 拼装、`lp_log.c` 分级日志 |
| `native/src/platform/` | 12 | 平台适配层，同一份内核换平台只换这个目录 |
| `native/src/platform/android/` | 4 | MediaCodec 硬解、AAudio 输出、EGL 纹理渲染、JNI 桥 |
| `native/src/platform/apple/` | 3 | VideoToolbox 硬解、CoreAudio 输出、CVPixelBuffer 纹理 |
| `native/src/platform/win32/` | 3 | `d3d11va_decoder.c` 硬解、`win32_platform.c` GDI 渲染 + waveOut 音频、`win32_preview.h` 导出给预览器/插件 |
| `native/src/platform/stub/` | 1 | 空实现（无渲染、拉模式音频），给 CI 和冒烟测试用 |
| `native/src/platform/desktop/` | 1 | `win32_pthread.h`：把 pthread 映射到 Win32 的兼容层 |
| `native/src/app/` | 1 | `lp_preview.c`：不依赖 Flutter 的原生窗口播放器（调试用） |
| `native/platform/` | 8 | 第三方库在 Windows 上的编译补丁 |
| `native/platform/win32/smb2/` | 8 | libsmb2 在 mingw 下缺的头（`poll.h`、`sys/socket.h`、`netdb.h` 等） |
| `native/tests/` | 4 | 四个测试可执行文件：冒烟、纹理/颜色、D3D11VA 端到端、硬解能力探针 |
| `scripts/` | 18 | 所有构建与验证脚本（见下方脚本表） |
| `tool/` | 8 | 静态检查与依赖下载（见下方工具表） |
| `docs/` | 15 | 6 篇文档 + 9 张验证截图 |
| `docs/images/` | 9 | 界面与硬解验证截图，README 与 `verification.md` 引用 |
| `.github/workflows/` | 1 | CI：Windows 内核构建 + 全部静态检查 |
| `.tools/` | — | 下载的工具链（zig / ffmpeg / libsmb2 / flutter-sdk），不进 git |
| `build/` | — | 构建产物与测试素材，不进 git |

### 树状图

```
LanPlayer/
├─ app/                     Flutter 应用（Android / iOS / macOS / Windows）
│  ├─ lib/core/             FFI 绑定、播放器控制器
│  ├─ lib/data/             模型、存储、媒体源仓库
│  ├─ lib/player/           播放列表与集数识别
│  ├─ lib/ui/               五个界面 + 字幕气泡
│  ├─ android/…             Kotlin 纹理插件、JNI、Gradle、清单
│  ├─ ios/Runner/…          Swift 纹理桥、Bridging Header、Info.plist、Runner.xcodeproj
│  ├─ macos/Runner/…        MainFlutterWindow.swift 纹理桥、entitlements、Runner.xcodeproj
│  ├─ windows/…             runner + 生成的插件注册表（CMake + MSVC）
│  └─ test/                 字幕渲染 golden 测试 + 设置项默认值测试
├─ packages/lanplayer_video/ Windows 纹理插件（C++，把内核的 BGRA 帧交给 Flutter）
├─ packages/lanplayer_core/  iOS / macOS 的 FFI 插件（两个 podspec，把静态库链进 Runner）
├─ native/                  C11 播放内核
│  ├─ include/lanplayer/    公共 ABI（dart:ffi 的唯一契约）
│  ├─ src/core/             解封装、解码、同步、字幕、控制
│  ├─ src/source/           LpSource：SMB / 本地 / 自定义 AVIO
│  ├─ src/platform/         android / apple / win32 / stub（CI）
│  └─ tests/                无依赖冒烟测试
├─ scripts/                 各平台构建、截图、插件 junction 脚本
├─ tool/                    C 符号一致性检查、依赖下载、测试素材生成
└─ docs/                    架构、构建、协议、安全、路线图、验证记录
```

### 脚本（`scripts/`，18 个）

| 脚本 | 作用 |
|-|-|
| `build_windows.ps1` | 编 C 内核：`lanplayer.dll`、`lanplayer_stub.dll`、`lp_smoke_test.exe`、`lanplayer_preview.exe`、`lp_win32_texture_test.exe`、`lp_hw_decode_test.exe`；先编 48 个 libsmb2 源文件；`-DeployTo <dir>` 把 DLL 复制到目标目录 |
| `build_windows_desktop.ps1` | 一条命令出桌面端：建 junction → 解 Dart 依赖 → VS 自带 cmake/MSBuild 构建 → INSTALL → 复制 DLL |
| `build_windows_app.ps1` | 不用 `flutter` CLI 直接编桌面端的备用通道（flutter CLI 需要管道 stdio） |
| `msvc_chain.bat` | 纯 MSVC 直编（无 CMake、无 flutter 工具）的最小链路 |
| `gen_windows_runner.ps1` | 从 Flutter SDK 自带模板生成 `app/windows/` |
| `fix_plugin_links.ps1` | 用 junction 预建 `.plugin_symlinks`（本机没有建符号链接的特权） |
| `patch_flutter_tools.ps1` | 给 `flutter_tools` 注入 `Visual Studio 18 2026` generator 并重建快照 |
| `make_test_media.ps1` | 生成测试素材：`test.mp4`、`clip.mp4`+`clip.srt`、`subbed.mkv`、`colortest/red.mp4`（60 秒纯红）、`colortest/black.mp4`（60 秒纯黑，测量控件用） |
| `build_android_deps.sh` | 交叉编译 Android 的 FFmpeg + libsmb2 到 `native/third_party/` |
| `build_apple_deps.sh` | 编 iOS / iPadOS / macOS 的 FFmpeg + libsmb2 **和 C 内核**，产出三份 universal 静态库到 `native/third_party/` |
| `capture_app.ps1` | 起桌面端、等一会、抓窗口 PNG、关掉 |
| `capture_window.ps1` | 同上，更早的窗口版（拿来做 UI 证据） |
| `capture_screen.ps1` | 按用户视角截图；`-WholeScreen` 抓整屏（窗口矩形在缩放显示器上会错过客户区） |
| `capture_playback_ui.ps1` | 起播放页、先把光标停进窗口让控制栏出现，再整屏抓取并按客户区裁剪，同时统计四个区域的亮像素 |
| `hover_probe.ps1` | 断言「鼠标移动显示控件、静止 2 秒收起」：真实移动系统光标，看 `LanPlayer controls:` 日志序列 |
| `send_keys.ps1` | 向真实窗口投递按键，验证快捷键/全屏 |
| `sync_github.ps1` | 一条命令把工作区推到 GitHub：`git add -A` → 有变化才 commit → `git push`；无变化时是空操作 |
| `install_git_hooks.ps1` | 安装 `.git/hooks/post-commit`（每次 commit 后自动 push）；钩子不在版本库里，新克隆要跑一次 |

### 工具（`tool/`，8 个）

| 工具 | 作用 |
|-|-|
| `check_all.py` | 全项目静态检查的总入口，一条命令跑完下面所有项 |
| `check_c_syntax.py` | C 源码括号/预处理/`#include` 解析/编码检查（不需要编译器） |
| `check_symbols.py` | 声明/定义/调用/Dart 绑定四处符号一致性 |
| `fetch_deps.py` | 下载工具链（zig / ffmpeg / libsmb2 / dart / flutter / ffi / path_provider）到 `.tools/` |
| `image_stats.ps1` | `LockBits` 采样图片区域，打印主色、均值，可裁剪另存 |
| `make_pgs_fixture.py` | 手写 PGS（`.sup`）测试素材，验证位图字幕 |
| `pgs_probe.c` | 独立解码 PGS，打印矩形/调色板/字节 |
| `smb_probe.c` | 探针：libsmb2 接受哪种共享根路径写法 |

## 快速开始

**1. 在 Windows 上开一个只读共享**（这一步用系统自带的文件共享即可，与本项目无关）：

```powershell
# 举例：把 D:\Movies 共享成 Movies，给账号 lanplay 只读权限
New-SmbShare -Name Movies -Path D:\Movies -ReadAccess lanplay
```

`app` 只需要 **地址 / 共享名 / 用户名 / 密码** 四个输入框，
不依赖本仓库提供的任何服务端脚本。

**2. 手机上连**：`添加 → 填地址、共享名、用户名、密码 → 连接并浏览`。
共享名就是 Windows 上「属性 → 共享」里填的那个名字；客户端不会去枚举服务器的共享列表。

**3. 播放**：点视频即播。字幕默认自动加载同目录同名文件（`S01E01.zh-CN.srt` 之类），
播放页可切音轨、切字幕、调字幕延迟、切倍速。

## 图形界面：两个都能打开

仓库里有 **两套 GUI**，共用同一份 C 内核（`lanplayer.dll`）：

| | 原生预览器 | Flutter 桌面端 |
|-|-|-|
| 可执行文件 | `build\win-x64\lanplayer_preview.exe` | `app\windows\out\build\x64-VisualStudio182026\runner\Release\lanplayer.exe` |
| 依赖 | 只要 FFmpeg DLL | Flutter 引擎 + MSVC 构建 + `lanplayer_video_plugin.dll` |
| 用途 | 验证内核（解码/同步/字幕），临时看片 | **产品 UI**：服务器列表、浏览、播放页、设置 |
| 一条命令 | `scripts\build_windows.ps1` | `scripts\build_windows_desktop.ps1` |

### Flutter 桌面端（推荐，已实测）

```powershell
# 需要：Flutter SDK（.tools\flutter-sdk）、Visual Studio 2022/2026（含 C++ 桌面工作负载）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows_desktop.ps1 -Core -Run
```

* `-Core` 先用 Zig 重编 `lanplayer.dll`；不带则复用 `build\win-x64` 里的现成 DLL。
* `-Run` 编完直接启动。产物目录里已经放好 `lanplayer.dll`、`lanplayer_video_plugin.dll`、
  `flutter_windows.dll` 与 7 个 FFmpeg DLL，可以直接拷走。
* 调试用环境变量：`LANPLAYER_STATE_DIR`（状态目录）、`LANPLAYER_OPEN=<视频路径或 smb://>`、
  `LANPLAYER_BROWSE=<smb://host/share>` + `LANPLAYER_USER` / `LANPLAYER_PASS`、
  `LANPLAYER_NO_TEXTURE=1`（不接纹理，只看覆盖层）、
  `LANPLAYER_LAYOUT_PROBE=1`（打印返回键/画面按钮的真实全局矩形，验证布局用）。
* 内核调试开关（给 `lp_smoke_test.exe` / `lp_preview_c.exe` 用）：`LP_LOG_LEVEL`、
  `LP_DUMP_SUBS=1`、`LP_NO_VIDEO`、`LP_NO_AUDIO`、`LP_NO_SUB_SCAN`、`LP_NO_GRAPHIC_SUB=1`
  （跳过图形字幕叠加，做 A/B 对照）、`LP_PQ_MAX_KB`、`LP_DEMUX_DISCARD`。

播放页里鼠标和键盘都能操作：**鼠标只要在画面上移动，控制栏就出现，静止 2 秒自动收起**
（不用再单击唤出），单击仍可手动切控制栏；双击左/右三分之一 ∓10 秒，上下滑左半边调亮度、
右半边调音量，长按临时 2x；键盘 `Space`/`K` 播放暂停、`←`/`→` ±10s、`↑`/`↓` 音量、
`M` 静音、`F` 全屏、`[`/`]` 字幕延迟、`S` 统计、`Esc` 退出。
其中全屏是真的改窗口（`WS_POPUP` + 铺满显示器），不是只藏状态栏。

播放页的控件位置：返回键在**左上角**，文件名在它右边；画面设置（缩放方式/解码统计/媒体信息）
和「速度」「字幕」「音轨」「音量」一起放在**底部操作行**，右上角不再有孤立的按钮。

实测画面（`docs/images/`）：

* `desktop-home-release.png` —— 启动首页
* `desktop-browse.png` —— 浏览真实 SMB 共享（192.168.1.10）的目录，视频行显示观看进度
* `desktop-smb-play.png` —— 直接播放共享里的 1920×820 h264 视频
* `desktop-stats.png` —— 按 `S` 打开的解码统计覆盖层

### 原生预览播放器（只要内核）

```powershell
build\win-x64\lanplayer_preview.exe "D:\Movies\某部电影.mkv"

# 或者直接双击 build\win-x64\lanplayer_preview.exe（会弹出打开文件对话框）
```

* 窗口内：空格 播放/暂停，←/→ 快退/快进 10 秒，↑/↓ 音量，+/- 倍速，`F` 适应/铺满，
`O` 打开文件，`Esc` 退出；也可以把视频文件直接拖进窗口。
* 画面用 GDI 绘制（软件解码 → BGRA），声音走 waveOut，字幕按 FFmpeg 解析结果实时绘制，
底部有进度条与时间。

**`flutter build windows` 也能跑通了**：本机装的是 **VS 18（2026）**，而
`flutter_tools` 的 generator 是硬编码的 `17 => 'Visual Studio 17 2022', _ => 'Visual
Studio 16 2019'`，于是报 `Generator Visual Studio 16 2019 could not find any instance
of Visual Studio`。`scripts\patch_flutter_tools.ps1` 会从 `cmake --help` 里读出正确的
generator 名并把它作为一个显式分支注入进去，然后重建工具快照：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\patch_flutter_tools.ps1
cd app; flutter build windows --release
```

产物在 `app\build\windows\x64\runner\Release\`（约 25 秒）。注意 `flutter build windows`
**不会**部署 `lanplayer.dll` 和 FFmpeg DLL，要再补一步：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ..\scripts\build_windows.ps1 `
    -DeployTo build\windows\x64\runner\Release
```

另一处限制仍然存在：`flutter pub get` 需要给插件建**符号链接**，普通用户令牌没有
`SeCreateSymbolicLink` 权限（`errno 1314`），所以 `scripts\fix_plugin_links.ps1` 改用
**junction** 预建；`flutter_tools` 对已存在的链接直接跳过，因此 `pub get` 能过。

`scripts\build_windows_desktop.ps1` 是这两条路之外的一条独立通道（VS 自带 cmake +
MSBuild），在不打补丁的机器上也能用，产物在 `app\windows\out\build\x64-VisualStudio182026\`。

### 关于版本管理

仓库已经推到 GitHub：<https://github.com/LXinH3RT/LanPlayer>（`origin`，分支 `main`）。

每次改完代码都会自动推送，靠两层：

```powershell
# 钩子失效时的手动兜底（add + commit + push 一条命令）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sync_github.ps1 -Message "fix: 说明改了什么"

# 新克隆的机器装一次钩子（之后每次 git commit 都会自动 push）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install_git_hooks.ps1
```

`.gitignore` 同时是一份"哪些目录是生成物"的清单：
`build/`、`.tools/`、`app/windows/out/`、`app/windows/flutter/ephemeral/` 都是几百 MB 级的
构建产物（单是 `avcodec-63.dll` 就有 **114 MB**，超过 GitHub 100 MB 的单文件上限）。
按 `.gitignore` 过滤后，实际上传的只有约 **232 个文件 / 3.7 MB**。

工具链（`.tools/`，含 Flutter SDK）不入库，`python tool\fetch_deps.py` 可以重新拉回。

## 构建

### Windows 内核（不需要 Visual Studio）

`tool/fetch_deps.py` 会下载 Zig 0.13（clang + mingw-w64 libc + lld）、FFmpeg 7.x 共享库和
libsmb2 4.0.0 源码，然后 `scripts/build_windows.ps1` 直接编出 `lanplayer.dll`、
`lp_smoke_test.exe`、`lanplayer_preview.exe`：

```powershell
python tool\fetch_deps.py                  # zig + ffmpeg + libsmb2（约 165 MB）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows.ps1 -Clean
build\win-x64\lp_smoke_test.exe            # ABI + 协议自检

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\make_test_media.ps1
build\win-x64\lp_smoke_test.exe build\media\clip.mp4 6    # 视频+音频+外挂字幕
build\win-x64\lp_smoke_test.exe build\media\subbed.mkv 6  # 内嵌字幕
```

### Windows Flutter 桌面端（需要 Visual Studio 的 C++ 工作负载）

```powershell
python tool\fetch_deps.py flutter dart     # Flutter SDK + Dart
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_windows_desktop.ps1 -Core -Clean
```

它依次做四件事：建插件 junction（`fix_plugin_links.ps1`）→ 解析 Dart 依赖 → 用 VS 自带的
cmake/MSBuild 构建 → `INSTALL` 到 `runner\<Config>` 并把 `lanplayer.dll` + FFmpeg DLL 复制到
exe 旁边。产物可以直接拷到别的机器上运行。

输出与实测记录见 [docs/verification.md](docs/verification.md)。

### Android / iOS / macOS

本仓库不包含移动端与 Apple 端的 FFmpeg / libsmb2 预编译产物，按 `docs/build.md` 生成后放进
`native/third_party/`，然后：

```bash
# 1) 先编依赖（FFmpeg + libsmb2 + C 内核），产物落到 native/third_party/
ANDROID_NDK_HOME=~/android-ndk-r26 ./scripts/build_android_deps.sh
./scripts/build_apple_deps.sh          # 三切片：iphoneos / iphonesimulator / macosx

# 2) 在 Mac 上装依赖并运行（iOS / macOS 都不需要手工改 Xcode 工程）
cd app
flutter pub get
flutter build macos --release          # 或 flutter run -d macos
flutter build ios --release --no-codesign
```

Apple 端的工程接线已经写在仓库里，`docs/build.md` 第 4 节有完整说明：
`packages/lanplayer_core/` 的两个 podspec 负责把
`liblanplayer.a + libav*.a + libsmb2.a` 链进 Runner，两个 `Podfile` 声明
`platform :ios, '13.0'` / `platform :osx, '11.0'`（与 `build_apple_deps.sh` 的
`MIN_IOS` / `MIN_MACOS` 对齐），macOS 的 `MainFlutterWindow.swift` 注册
`lanplayer/video` 通道把 `CVPixelBuffer` 交给 Flutter 引擎。

## 已验证 / 未验证

在本机（Windows 10 x64）实际编译并运行的：

|项|结果|
|-|-|
|C 内核编译|✅ 14 个源文件，`-std=gnu11 -Wall`，0 error|
|libsmb2 编译|✅ 48 个文件 → `libsmb2.a`（含 mingw 移植 shim）|
|FFmpeg 链接|✅ FFmpeg 7.x 共享构建（libavutil 61），`lanplayer.dll` 338 KiB|
|视频 + 音频播放|✅ mp4 6s：h264 软解 640×360、AAC→float 立体声、位置推进到 3.99s|
|外挂字幕自动加载|✅ 同目录 `clip.srt` → 3 cues，事件文本正确|
|GBK / Big5 / Shift-JIS 字幕|✅ 非 UTF-8 文件按 Windows 代码页回退解码（`decoded 106 bytes with code page 54936`）|
|内嵌字幕|✅ mkv `subrip` 轨默认选中，4 次事件，文本已剥离 ASS 字段|
|图形字幕（PGS/VobSub）|✅ `anime-07.mkv` 的 6 条图形字幕轨（`dvd_subtitle` 1920x1080）全部打开，`bitmap rect 0 274x119 at 824,956` 之类逐条解出，媒体信息带 `"bitmap":true`；`--dump` 同一帧在 `LP_NO_GRAPHIC_SUB=1` 下 A/B 差 **27635** 像素，148 行全部落在 `y=875..1026` 的字幕带（同样开着的两次 dump 差异为 0，排除随机性）|
|ASS 富文本|✅ 一行 `AAAA{\c&H0000FF&}BBBB{\c&H00FF00&}CCCC` → 3 个 run，颜色 `0xFFFF0000` / `0xFF00FF00`；Dart 侧断言 3 个 `TextSpan`，并用金色文件 `app/test/goldens/rich_runs.png` 逐像素比对（`flutter test` 全部 8 个用例）|
|硬解请求回退|✅ `hw=mediacodec` → `active=software`，播放不中断|
|SMB 协议栈|✅ 链接 libsmb2 4.0.0；不可达主机返回可读错误而非崩溃|
|SMB 目录浏览|✅ 真实共享 192.168.1.10「共享」→ 9 项；「电影」→ 31 项（13 目录 / 9 视频）；可逐层进入|
|SMB 凭据校验|✅ 只给主机 + 账号密码时连 `IPC$` 验证登录：`{"server":"192.168.1.10","authenticated":true}`；密码错误报 `login failed … wrong user name or password`；共享名由用户自己填，不做枚举|
|SMB 直接播放|✅ 1920×820 h264 经 SMB 流式解码，waveOut 48 kHz 立体声，字幕侧挂自动加载|
|服务器列表持久化|✅ 重启后自动读回 `servers.json`（`LanPlayer loaded: servers=1`），不再丢服务器|
|Flutter 桌面端构建|✅ CMake + MSBuild（VS 18）产出 `lanplayer.exe` 55 KiB + 插件 106 KiB，INSTALL 后可直接运行；官方 `flutter build windows --release` 也已跑通（24 秒出包）|
|Flutter 桌面端画面|✅ 1280×720 Release 窗口内渲染视频帧（11,320 种颜色，画面铺满）|
|画面颜色顺序|✅ 纯红素材 `colortest/red.mp4`：内核 BMP 中心 `R=253 G=0 B=0`；纹理契约 `mid_pixel=#FFFD0000` → `mid_rgba=#FD0000FF`；整屏截图像素扫描 `R=253 G=0 B=0`，期望色匹配 88.5%，成品图 `docs/images/desktop-color-red.png`（修复前同一路径 `B>R`，即「画面偏蓝」）|
|字幕描边粗细|✅ 不再用 `Shadow` 假描边与 `w500`：只用 `w400`/`w700` + 第二层 `Text.rich` 真描边，`flutter test` 金色文件逐像素比对|
|Windows D3D11VA 硬解|✅ 预览器 `--hw auto` 打出 `hardware decode d3d11va 640x360`，同一位置 BMP 与软件解码均值差 ≤ 0.2 级；`lp_hw_decode_test.exe` 断言报出的解码器名 + 逐通道均值 + 对 8 帧软件参考取最佳匹配（`mean_delta=0.64`，纯红素材 `mid_pixel=#FD0000`）；`--hw sw` 负向对照如期失败|
|记忆播放进度|✅ 62 秒片看到 22 秒退出，重开报 `LanPlayer resume: demo.mp4 -> 19.2s`；列表行显示 `已看 35%` 与进度条（像素扫描确认填充随进度变长）；设置里可关闭（`remember_progress`），关闭后 A/B/C 实测不再写 `progress.json`|
|播放页控件位置|✅ 用 `LANPLAYER_LAYOUT_PROBE=1` 打印真实矩形：返回键 `back=x=4.0 y=6.0`（左上角），「画面」`picture=x=527.1 y=637.4`（底部操作行）；鼠标移动显示 / 静止 2 秒收起由 `scripts/hover_probe.ps1` 断言（`hidden`→`shown`→`hidden`）|
|桌面键盘快捷键|✅ 用 `scripts\send_keys.ps1` 向真实窗口投递按键：`LanPlayer key: Space / Arrow Right / F / M / S / Escape` 全部命中|
|真全屏|✅ 按 F 后窗口从 `1280x720 at 10,10` 变 `1646x1029 at 0,0`（整屏），再按 F 精确还原|
|Windows 原生预览器|✅ 创建窗口、消息循环正常（hwnd 有效、Responding）|
|画面渲染|✅ 无头渲染 120 帧并导出 BMP，烧录时间码 4.76s 与内部位置一致|
|声音输出|✅ waveOut 48 kHz 立体声，AAC→float→设备，播放推进到 4.76s/6s|
|Dart 语法|✅ `dart format` 解析 22 个文件，0 语法错误|
|Dart 测试|✅ `flutter test` 12 个用例（字幕 span 树 + golden 光栅化 + 设置项默认值）全部通过|

仍需在别的机器上完成：

|项|原因|
|-|-|
|Android / iOS / macOS 构建|本机没有 NDK / Xcode / CocoaPods，只能在 Windows 上做静态检查|
|Apple 端真机验证|`packages/lanplayer_core` 的两个 podspec、两个 `Podfile`、macOS 纹理通道都已写好，`tool/check_all.py` 的 `apple wiring` 一项会在静态层面守护它们（podspec 必须链 `-llanplayer`、Podfile 的部署目标必须等于 `build_apple_deps.sh` 的 `MIN_IOS`/`MIN_MACOS`），但**没有在 Mac / iPad 上真正编过一次**|
|真机硬解（MediaCodec / VideoToolbox）|需要设备；桌面只有 stub 输出。Windows D3D11VA 已在本机真 GPU 上跑通并接进 `tool/check_all.py`|
|Flutter `analyze`|Dart 侧用 `flutter test` + kernel 编译两重检查（都已接进 `tool/check_all.py`）；`flutter analyze` 需要完整依赖解析，未在本机跑|
|视频区域的截图验证|`PrintWindow` 读不到 Flutter 合成结果（客户区全黑）；`CopyFromScreen` 按窗口矩形抓也会因为缩放显示器上合成位置与 `GetWindowRect` 不一致而整个错过客户区。**改用整屏抓取**（`capture_screen.ps1 -WholeScreen`）后视频区域可见并已用于颜色顺序验证；字幕渲染仍以 `flutter test` 金色文件为准|

**限制（有意为之，见 `docs/roadmap.md`）**：ASS 的 `\t` 动画、`\clip`、矢量绘图 `\p`、
卡拉 OK `\k` 不渲染（按规范丢弃，其余行内标签 `{\b1} {\i1} {\c&H..&} {\fs..} {\an..}
{\pos(..)} {\r}` 都已支持）；不枚举服务器共享名，共享名需手填；
Windows 桌面端硬解已接入 D3D11VA，剩下 GPU 直出纹理与 WASAPI。

## 文档

* [架构与线程模型](docs/architecture.md)
* [构建指南](docs/build.md)
* [媒体源与协议扩展](docs/media-source.md)
* [安全边界](docs/security.md)
* [路线图与已知限制](docs/roadmap.md)
* [验证记录（Windows 实测输出）](docs/verification.md)

## 许可

代码为本项目原创；FFmpeg（LGPL-2.1+，需动态链接并遵守其条款）、libsmb2（MIT）作为
外部依赖由使用者自行编译与分发。

