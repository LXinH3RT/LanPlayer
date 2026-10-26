# LanPlayer · 局域网播放器

[English](README.en.md) | 简体中文

一个把 SMB 共享里的视频直接放出来的播放器：Flutter 写一套界面（Windows / macOS /
Android / iOS / iPadOS），底下是一个用 C11 和 FFmpeg 写的播放内核，通过 `dart:ffi`
直连，没有中间层。

![首页](docs/images/desktop-home.png)

## 它解决什么

家用网络里最常见的形态是「一台机器存片，其它设备看」。现成的播放器要么只能放本地文件，
要么在电视盒子上依赖 DLNA 转码，要么把 SMB 当成网盘挂载、拖动进度条要等几十秒。
LanPlayer 只做一件事：**把共享里的文件当成本地文件播**——硬解、带字幕、进度条能拖、
放完自动接下一集。

它不做的：不做服务端、不做转码、不做下载缓存、不枚举服务器上的共享名。共享由系统自带的
文件共享提供，App 只负责填地址、共享名、账号、密码。

## 功能

| | |
|-|-|
| **来源** | SMB 共享（只读）、本机任意盘符下的文件或文件夹 |
| **容器 / 编码** | 由 FFmpeg 决定：MKV / MP4 / AVI / MOV / TS / FLV / WebM 等，H.264 / HEVC / VP9 / AV1 等 |
| **硬解** | Windows D3D11VA、macOS / iOS VideoToolbox、Android MediaCodec，失败自动回退软件解码 |
| **音频** | Windows waveOut、Apple AudioQueue、Android AAudio；AAC / MP3 / FLAC / Vorbis / Opus 等 |
| **字幕** | 内嵌轨 + 外挂 SRT / ASS / SSA / VTT；ASS 富文本（颜色、描边、字号、字体、定位）；PGS / VobSub / DVB 图形字幕 |
| **选轨** | 音轨与字幕各自成面板，可列出文件内全部轨道并切换；按首选 / 次选语言自动挑默认轨 |
| **播放控制** | 播放暂停、±10 秒、进度拖拽、0.5x–2.0x 变速不变调、音量 0–200%、静音、全屏 |
| **连播** | 当前目录按 `SxxEzz` / 第 N 集 识别顺序自动接下一集 |
| **记忆进度** | 重开同一文件从上次位置续播，列表上显示进度条与百分比 |
| **浏览** | 缩略图取首帧、本地缓存、按需生成；只列视频与字幕，`.txt` / `.docx` 之类不显示，字幕归到对应视频下面 |
| **其它** | 局域网扫描（并发探测本机网段）、桌面键盘快捷键与触屏手势、深浅色跟随系统 |

## 界面

| 首页 | 浏览共享 |
|-|-|
| ![首页](docs/images/desktop-home.png) | ![浏览](docs/images/desktop-browse.png) |

| 音轨面板 | 字幕面板 |
|-|-|
| ![音轨](docs/images/desktop-audio-sheet.jpg) | ![字幕](docs/images/desktop-subtitle-sheet.jpg) |

ASS 字幕里的 `Fontname` 与行内 `\fn` 都会真正生效，同一条字幕里可以混排两种字体：

![字幕字体](docs/images/desktop-subtitle-fonts.jpg)

移动端是同一套界面（纹理 + 字幕气泡）：

<img src="docs/images/ipad-player.png" width="420" alt="移动端播放">

## 快速开始

### 用安装包

从 [Releases](https://github.com/LXinH3RT/LanPlayer/releases) 下载对应平台的文件：

| 平台 | 文件 | 安装方式 |
|-|-|-|
| Windows 10+ | `LanPlayer-<版本>-windows-x64-setup.exe` | 双击，装到当前用户目录，不弹 UAC |
| macOS (Apple Silicon) | `LanPlayer-<版本>-macos-arm64.dmg` | 拖进「应用程序」 |
| Android 8+ (arm64) | `LanPlayer-<版本>-android-arm64.apk` | 允许安装未知来源后安装 |

Windows 包没有代码签名，SmartScreen 会提示「仍要运行」；macOS 包是 ad-hoc 签名，
首次打开需在「系统设置 → 隐私与安全性」里放行。

### 准备一个共享

用系统自带的文件共享即可，App 不依赖任何服务端组件：

```powershell
# 举例：把 D:\Movies 共享成 Movies，给账号 lanplay 只读权限
New-SmbShare -Name Movies -Path D:\Movies -ReadAccess lanplay
```

### 添加来源

`添加 → SMB 服务器`，填 **地址 / 共享名 / 用户名 / 密码** 四项。
共享名是 Windows「属性 → 共享」里填的那个名字；App 不会去枚举服务器的共享列表，
因为那项服务在部分系统上默认关闭。不知道 IP 时可以点「扫描局域网」，它会并发探测本机
所在网段的 SMB 端口，把有响应的主机列出来，点一行自动填进地址框。

`添加 → 添加本地文件/文件夹` 可以逐层浏览本机任意盘符，选中一块目录或一个视频文件。
选文件时，这个文件会作为单独一条来源出现在首页，点开即播。

添加完首页就直接摊开每个来源的根目录，不用再点一次；有多个来源时它们并排列出，
顶部一排按钮可以只看其中一个，每块标题右边的「全部」进完整浏览页。

### 播放

点视频即播。默认自动加载同目录同名的字幕文件（`S01E01.zh-CN.srt` 之类），
播放页可切音轨、切字幕、调字幕延迟、切倍速。

桌面端快捷键：`空格` / `K` 播放暂停，`←` / `→` 前后 10 秒（长按 5 秒），
`↑` / `↓` 音量，`M` 静音，`F` 全屏，`[` / `]` 字幕延迟，`S` 解码统计，`Esc` 退出。

## 构建

仓库只含源码，依赖（FFmpeg、libsmb2、工具链）由 `tool/fetch_deps.py` 下载到 `.tools/`，
产物落在 `.gitignore` 覆盖的目录里。

### Windows

```powershell
python tool\fetch_deps.py

# 内核（用 Zig，不需要 Visual Studio）
python scripts\build_windows.py
build\win-x64\lp_smoke_test.exe

# 桌面端（需要 VS 的「使用 C++ 的桌面开发」工作负载）
python scripts\build_windows_desktop.py --core
# -> app\windows\out\build\x64-VisualStudio182026\runner\Release\lanplayer.exe

# 安装包
python tool\fetch_deps.py nsis
python scripts\build_windows_installer.py
# -> dist\LanPlayer-<版本>-windows-x64-setup.exe
```

### macOS / iOS

```bash
# 依赖与内核
SLICES=macosx python3 scripts/build_apple_deps.py

# app
cd app && flutter pub get && flutter build macos --release
flutter build ios --release --no-codesign

# 真机
TEAM_ID=<你的 10 位 Team ID> python3 scripts/ios_device_install.py

# dmg
python3 scripts/build_macos_dmg.py
```

### Android

```bash
ANDROID_NDK_HOME=~/android-ndk-r26 python3 scripts/build_android_deps.py
python3 scripts/build_android_apk.py
```

### 自检

```powershell
# 静态检查 + dart 编译 + dart 用例 + 安装器与发布断言
.\.tools\python\python.exe tool\check_all.py
```

`flutter analyze` / `flutter test` 在 Windows 上会因 `%APPDATA%\.flutter_tool_state`
不可写而失败，用包装脚本（把 `TMP` / `TEMP` / `APPDATA` / `LOCALAPPDATA` / `PUB_CACHE`
重定向进仓库内 `.tools/`）：

```bash
python scripts/run_flutter_tests.py            # = flutter test
python scripts/run_flutter_tests.py analyze    # = flutter analyze
```

各平台的坑与报错对照表见 [docs/build.md](docs/build.md)。

## 平台状态

| | Windows | macOS | Android | iOS / iPadOS |
|-|-|-|-|-|
| 界面 | ✅ | ✅ | ✅ | ✅ |
| SMB 浏览 | ✅ | ✅ | ✅ | ✅ |
| 硬解 | ✅ D3D11VA | ✅ VideoToolbox | ✅ MediaCodec | ✅ VideoToolbox |
| 音频输出 | ✅ waveOut | ✅ AudioQueue | ✅ AAudio | ✅ AudioQueue |
| 安装包 | ✅ exe | ✅ dmg | ✅ apk | 需自行签名 |

Windows 桌面端已接 D3D11VA 硬解，但仍是「解码在 GPU、出画回 CPU」，GPU 直出纹理
与 WASAPI 尚未实现。

## 已验证

| 项 | 结论 |
|-|-|
| C 内核 / libsmb2 / FFmpeg 链接 | ✅ Windows 上 Zig 编 14 个源文件 + 48 个 libsmb2 文件，0 error |
| 视频 + 音频播放 | ✅ H.264 软解、AAC → float 立体声、位置推进正确 |
| 硬解 | ✅ D3D11VA（与软件参考均值差 ≤0.2 级）、VideoToolbox、MediaCodec 均真机跑通 |
| 10-bit 片源 | ✅ 宽色深 H.264 / HEVC 在硬解不稳的平台自动改走软件解码，不再出现「有进度没画面」 |
| 字幕 | ✅ 内嵌 + 外挂 SRT/ASS/VTT + 非 UTF-8 按代码页回退 + ASS 富文本（含行内 `\fn`）+ 图形字幕 |
| SMB 浏览 / 凭据校验 / 局域网扫描 | ✅ 只读、共享名自填、不做枚举 |
| 列表缩略图 | ✅ 只解第一帧、`LPT2` 头落盘缓存、只对视频行请求 |
| 含 FLV 的文件夹不再卡死 | ✅ 修掉内核三处缺陷 + 一处并发过载 |
| 浏览列表只留媒体 | ✅ `.txt` / `.docx` / `.DS_Store` 等不显示，字幕归到对应视频 |
| 多音轨 / 多字幕默认轨 | ✅ 按首选 / 次选语言挑，音轨与字幕面板拆开 |
| 音量 | ✅ 0–200% 滑杆，内核 `lp_ring_set_gain` 直接作用在环形缓冲上 |
| 覆盖升级 | ✅ 旧版在跑也能直接装新版，安装器会先请退旧进程 |
| Dart 用例 | ✅ 124 个用例全过，`flutter analyze` 无 issue |
| 三端安装包 | ✅ Windows / macOS / Android 装到真机后均能播 |
| iPad 真机 | ✅ 签名装机、SMB 浏览、VideoToolbox 硬解出画、播放位置推进均实测 |

## 已知限制

* ASS 的 `\t` 动画、`\clip`、矢量绘图 `\p`、卡拉 OK `\k` 不渲染（其余行内标签都支持）。
* 不枚举服务器共享名，共享名需手填。
* 不支持 AC3 / DTS 直通到功放；HDR 只解码直出，不做 tone mapping。
* 同时只播一个视频（播放页单例）。

完整列表与版本计划见 [docs/roadmap.md](docs/roadmap.md)。

## 目录

```
LanPlayer/
├─ app/                     Flutter 应用（Windows / macOS / Android / iOS）
│  ├─ lib/core/             FFI 绑定、播放器控制器
│  ├─ lib/data/             模型、存储、媒体源仓库、局域网扫描、封面缓存、选轨偏好
│  ├─ lib/player/           播放列表与集数识别
│  ├─ lib/ui/               界面、字幕气泡、封面格、音量/音轨面板
│  └─ test/                 124 个用例
├─ packages/
│  ├─ lanplayer_video/      Windows 纹理插件（C++，把内核的 BGRA 帧交给 Flutter）
│  └─ lanplayer_core/       iOS / macOS 的 FFI 插件（把静态库链进 Runner）
├─ native/                  C11 播放内核
│  ├─ include/lanplayer/    公共 ABI（dart:ffi 的唯一契约）
│  ├─ src/core/             解封装、解码、同步、字幕、封面、控制
│  ├─ src/source/           LpSource：SMB / 本地 / 自定义 AVIO
│  ├─ src/platform/         android / apple / win32 / stub
│  └─ tests/                无依赖的测试可执行文件
├─ scripts/                 各平台构建、截图、安装包与升级/卸载对照脚本
├─ tool/                    静态检查、依赖下载、测试素材生成
└─ docs/                    架构、构建、协议、安全、路线图
```

## 开发约定

* 脚本一律 Python（`python scripts/xxx.py`），UTF-8 编码；构建、截图与验证脚本共用
  `tool/lpscript.py`（进程、路径、环境重定向）、`tool/lpwin.py` / `tool/lpimage.py`
  （窗口、位图）。`tool/check_all.py` 有编码与静态断言护栏。
* C 源码 UTF-8 无 BOM、以换行结尾。
* 生成物一律不入库：`build/`、`dist/`、`.tools/`、`app/build/`、`app/windows/out/`、
  `native/third_party/`。
* 文档、脚本、注释与截图中不写真实环境：地址用 `192.168.1.10` 这类示例，账号用
  `share`，设备只写平台名；素材与截图用 `scripts/make_doc_media.py` 生成的合成文件，
  不贴真实影音画面。详见 [docs/security.md](docs/security.md)。

## 文档

* [架构与线程模型](docs/architecture.md)
* [构建指南](docs/build.md)
* [媒体源与协议扩展](docs/media-source.md)
* [安全边界](docs/security.md)
* [路线图与已知限制](docs/roadmap.md)

## 许可

代码为本项目原创；FFmpeg（LGPL-2.1+，需动态链接并遵守其条款）、libsmb2（MIT）作为
外部依赖由使用者自行编译与分发。
