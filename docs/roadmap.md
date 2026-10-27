# 路线图与已知限制

## 已实现（v0.1 交付范围）

* 模块 1：SMB 服务器管理（重启后自动读回）、账号密码连接、目录浏览（SMB + 本地）、
  共享名的登录校验（`IPC$` 探测，密码错直接报错，不做共享列表枚举）
* 模块 2：libavformat 解封装、MediaCodec / VideoToolbox 硬解、音频主时钟同步、
  AAudio / AudioQueue 输出、内嵌文本字幕、外挂 SRT/ASS/VTT（含 GBK/Big5 编码兜底）、
  ASS 富文本（`{\b1} {\i1} {\c&H..&} {\fs..}` 等行内标签保留为有序 run）、
  图形字幕（PGS / VobSub / DVB 解码成 RGBA 叠加层，直接混合进视频帧）
* 模块 3：播放/暂停/进度/音量/±10s/上一集下一集、0.5x–2.0x（atempo 保音调）、
  当前目录连播、音轨切换、字幕切换与延迟微调、
  记忆播放进度（按路径存 `progress.json`，打开时自动续播，列表显示观看百分比）
* 模块 4：硬解开关（自动回退）、缩放策略、去隔行（yadif）、媒体信息面板（含解码计数）
* 模块 5：本地文件浏览与播放，复用同一内核
* 桌面：Windows 原生预览器（GDI + WASAPI）+ Flutter 桌面端（CMake/MSVC，纹理输出）
* ~~服务端：Windows 共享代理（一键共享 + 生成密码 + 吊销 + 自检）~~ 已移除：
  共享由系统自带的文件共享提供，app 只负责填地址/共享名/账号/密码

## 已知限制

| 限制 | 影响 | 计划 |
|------|------|------|
| ~~图形字幕（PGS / VobSub / DVB）跳过~~ | 已实现：`SUBTITLE_BITMAP` 矩形解码成 RGBA，按解码参考网格缩放到画面后由渲染器直通混合进视频帧（Windows GDI/waveOut、macOS BGRA 纹理两条路都接）。`anime-07.mkv` 的 6 条 `dvd_subtitle` 轨有画面，媒体信息里带 `"bitmap":true` | 完成（v0.1 追加）。仍不支持的：`\p` 矢量绘图里的动态特效、BD-J 交互 |
| ~~ASS 富文本不渲染~~ | 已实现：`{\b1} {\i1} {\u1} {\s1} {\c&H..&} {\fs..} {\an..} {\pos(..)} {\r}` 解析成有序 run，Dart 侧逐个 `TextSpan` 渲染，一行里可以混排颜色/粗斜体/字号 | 完成（v0.1 追加）。仍不支持的：卡拉 OK `\k`、`\t` 动画、`\clip`、矢量绘图 `\p`（按 ASS 规范丢弃） |
| ~~共享名要手填~~ | 已放弃：只填服务器地址就列出共享名的功能已移除（SRVSVC 在 Windows 家庭版常被关掉，而列出共享反而不如让用户直接填「属性 → 共享」里那个名字可靠）。现在只填主机 + 账号密码时，客户端连 `IPC$` 校验登录、只报「账号密码对不对」，共享名仍需自己填 | 有意不做 |
| Windows 桌面端 | **已构建并运行**：CMake + MSVC 编出 Release 版 `lanplayer.exe`，Flutter UI 渲染、SMB 浏览、视频纹理与外挂字幕都正常（见 `docs/images/desktop-*.png`）；一条命令 `scripts\build_windows_desktop.py`。官方 `flutter build windows` 也已跑通（`scripts\patch_flutter_tools.py` 注入 VS 2026 的 generator） | GPU 直出纹理与 WASAPI 已完成 |
| macOS 视频输出未接桌面纹理 | **已接并已在真机跑通**：`app/macos/Runner/MainFlutterWindow.swift` 注册 `lanplayer/video` 通道，`PlayerTexture` 从内核拉 `CVPixelBuffer` 交给 Flutter 引擎（BGRA，图形字幕已叠加）；VideoToolbox 硬解、AudioQueue 输出、外挂/内嵌字幕、SMB 浏览与进度保存全部通过。iPad 模拟器与实体设备同样跑通 | 完成 |
| 倍速上限 2.0x | 符合需求（0.5–2.0） | 若要更高需串联两级 atempo |
| 单实例单窗口 | 同时只播一个视频 | 按设计，播放页单例 |
| 字幕编码 | Windows 已用 `MultiByteToWideChar` 兜底（GB18030/GBK/Big5/Shift-JIS/CP949）；Android 的 iconv 常缺少 GB18030 | v0.2：内嵌 GBK→Unicode 表（或转码提示） |
| 音频直通 | 不支持 AC3/DTS passthrough 到功放 | v0.4 |
| HDR | 只做解码直出，不做 tone mapping | v0.4：zscale/libplacebo |

## 版本计划

**v0.2 — 观感补齐**

* ~~图形字幕叠加层（PGS/VobSub 解码成 RGBA 叠加层）~~ 已完成（v0.1 追加）：
  `native/src/core/subtitle.c` 的 `bitmap_from_rect()` 把调色板索引面展开成 RGBA，
  `lp_sub_overlay_blend()` 按参考网格缩放后直通混合到 BGRA 视频帧；测试用
  `LP_NO_GRAPHIC_SUB=1` 做 A/B，同一帧差异 27635 像素且 148 行有差异的行全部落在
  `y=875..1026` 的字幕带（"开/开"对照组差异为 0）。
* ~~ASS 富文本（颜色块/描边/定位）~~ 已完成（v0.1 追加）：
  `native/src/core/subtitle.c` 的 `sub_compile_text()` 把一行拆成带样式的 run，
  事件 JSON 多一个 `runs` 数组，`app/lib/ui/widgets/subtitle_overlay.dart` 用 `Text.rich` 逐段渲染；
  `app/test/subtitle_overlay_test.dart` 对渲染出的 `TextSpan` 做断言，并用
  `RepaintBoundary.toImage()` 取真实像素后统计纯红/纯绿/纯白像素数（截图无法用于视频
  区域：覆盖层会落到 `GetWindowRect` 报告的窗口矩形之外；金色文件又绑死宿主的字体光栅化器）
* 字幕编码兜底（GBK 表）
* ~~播放页手势：双击左右快进、上下滑音量/亮度、长按倍速~~ 已完成（v0.1 追加）：
  `app/lib/ui/player_screen.dart` 用 `GestureDetector` 实现；桌面端另有键盘快捷键
  （空格/K 暂停、←→ ±10s、↑↓ 音量、F 全屏、M 静音、S 统计、[ ] 字幕延迟、Esc 退出），
  F 键通过插件 `setFullscreen` 真正改窗口样式与尺寸
* ~~记忆播放进度（按文件路径存 `position`，下次续播）~~ 已完成（v0.1 追加）：
  `app/lib/data/progress.dart` 只存"未加凭据的路径"，密码不进 `progress.json`；
  少于 8 秒不记、片尾 15 秒内视为看完并清除、最多保留 300 条

**v0.3 — 桌面与发现**

* Windows：~~D3D11VA 硬解~~（`native/src/platform/win32/d3d11va_decoder.c`）、~~GPU 直出纹理~~（`native/src/platform/win32/d3d11_output.c`）、~~WASAPI~~（`native/src/platform/win32/win32_platform.c`）均已完成；macOS 同步
* Apple：~~iOS / macOS 工程接线~~（已完成：`packages/lanplayer_core` 两个 podspec + 两个 Podfile + macOS 纹理通道 + 部署目标对齐 + 每个平台族独立的静态库目录，见 `docs/build.md` 第 4 节）。**macOS 桌面 bundle 与 iPad 都已真机跑通**（VideoToolbox 硬解、AudioQueue、外挂字幕、SMB 浏览）
* ~~SMB 局域网自动发现~~ 已完成（改成了更可靠的做法）：`app/lib/data/lan_scan.dart`
  并发探测本机所在 /24 的 **SMB 端口**，命中后反查主机名，结果点一下填进「IP 地址」。
  **没有**做 mDNS `_smb._tcp`：家用 NAS 与 Windows 共享一般不广播这条记录。
  共享名仍由用户填写，不做列表枚举
* ~~缩略图/海报~~（已完成）：`native/src/core/thumb.c` 只解一帧、缩放到 128 宽，RGBA 交给
  `app/lib/data/thumbs.dart` 落盘缓存（`LPT2` 头：魔数 + 宽 + 高，坏文件直接丢弃重取）；
  列表用 `ThumbnailTile` 显示，**只对视频行**请求封面，取不到就退回图标、不报错。
  封面按需生成，不预扫整个目录
* ~~发布安装包~~（已完成）：Windows 用 NSIS 出
  `dist\LanPlayer-<ver>-windows-x64-setup.exe`（按用户装到
  `%LOCALAPPDATA%\Programs\LanPlayer`，不弹 UAC，FFmpeg 与 VC++ 运行时全部 app-local）；
  macOS 出 `dist/LanPlayer-<ver>-macos-<arch>.dmg`（ad-hoc 签名，拖拽安装）。
  两者都支持静默安装/卸载与覆盖升级。
  尚未做：代码签名证书（Windows Authenticode / Apple Developer ID + 公证），
  未签名时 SmartScreen 与 Gatekeeper 都会提示
* ~~发布安装包到 Release~~（已完成）：Windows / macOS / Android 三个平台的包一起发。

**v0.4 — 画质与音频**

* HDR → SDR tone mapping；色彩管理（BT.709/2020）
* 音频直通（AC3/DTS/TrueHD）与声道映射
* 音频延迟微调（当前只有字幕延迟）

**未排期**

* 剧集刮削（TMDB）
* 投屏（DLNA sender）
* 服务端改成 TCP 私有协议（`LpSource` 已就绪，见 `docs/media-source.md`）

## 工程质量待办

* CI：~~三个 job~~（已扩到五个目标：Android NDK + `flutter build apk`、
  Apple iOS 静态库 + `flutter build ios`、Linux CMake + `lp_smoke_test`、Windows Zig
  内核、Windows MSVC 桌面 bundle）
* 桌面构建脚本化：~~`scripts/build_windows_desktop.py` 串成一条命令~~（已完成并接进
  CI，带 `-FlutterRoot` / `-NoEnvRedirect` 与 bundle 断言）
* 内核单元测试：`subtitle.c` 的 SRT/ASS 解析器可以用纯 C 测试驱动，
  目前只做了冒烟测试（`native/tests/lp_smoke_test.c`）
* 内存检查：ASan 跑一遍长片（2 小时）确认无泄漏，重点看 seek 与切集路径
* 性能基线：4K HEVC 10bit 硬解掉帧率、SMB 顺序读吞吐（`tool/bench_*` 待补）
* `build_apple_deps.py` 的跨族缓存：现在切族只跳过 FFmpeg/libsmb2 的编译（按 slice 缓存），
  但三族的 `native/third_party/*/apple/<family>` 目录是分开的，换族时脚本仍会重跑
  `lipo`/`cp` 那几步（几秒钟，可接受）。若以后族变多，可加一个「本族已完成」的早退
