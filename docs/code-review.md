# LanPlayer 代码实现评审

本文针对当前 `main` 分支（`0670f0d`）的实现做一次逐功能核对，目标是回答两个问题：**承诺的功能是否真的按预期工作**，以及**代码结构是否撑得住继续增删功能**。评审以源码阅读为主，配合 Windows 侧的静态检查（`tool/check_all.py` 34 项全过）与真实内核冒烟（`lp_smoke_test.exe`）交叉验证。

评审前提按项目定位设定：软件只在可信局域网内使用，不做防御性编程；衡量标准是运行效率、长时间播放的稳健性、跨平台一致性，以及功能增删的成本。

---

## 1. 总体结论

工程质量明显高于同规模的个人项目：ABI 只用标量与 JSON、事件由内核分配宿主释放、线程职责划分清晰、失败降级路径都有注释说明来由、静态检查覆盖了 34 类历史 bug。但**当前版本存在 5 个 P0 级缺陷，其中 2 个会导致进程崩溃、1 个会导致发行包直接起不来、1 个会让 Android 缩略图整体失效、1 个会周期性清空用户设置**。

分项评价：

| 层次 | 评价 | 主要指摘 |
|---|---|---|
| 播放内核（音视频管线） | 7 / 10 | 线程模型与主时钟设计清楚，但 `serial` 存在数据竞争，音频欠载时缺少降级路径 |
| 字幕子系统 | 6 / 10 | 解析器覆盖面很广，但三处解析 bug 让内嵌轨的 `\pos`/`\fs` 全部失效 |
| 源层（SMB / 本地） | 5 / 10 | 错误分类在传递链上被抹平，`LP_ERR_TIMEOUT` 是死码，预读效率偏低 |
| Dart 数据层 | 6 / 10 | 缓存与字幕匹配设计合理，落盘无串行化是 P0 |
| FFI / 控制层 | 8 / 10 | ABI 契约干净、释放路径正确，缺运行时 ABI 校验 |
| 播放页 UI | 5 / 10 | 功能齐全但单文件 1511 行、整页重建、7 个 P1 功能缺陷 |
| 首页 / 浏览 / 设置 | 6 / 10 | 有请求代际意识的只有首页一处，异步守卫不统一 |
| 构建系统 | 5 / 10 | Windows 双轨制、源文件清单四处复制、CI 缺 macOS 桌面 |
| 跨平台一致性 | 6 / 10 | macOS 全屏是空实现、Android 缩略图挂、Linux 桌面无输出后端 |

---

## 2. P0 缺陷（必须优先处理）

### P0-1 字幕关闭与 tick 线程无锁竞争，播放中关片可能崩溃

`src/core/player.c:511` 调 `lp_subtitle_close(p)`，而 `src/core/subtitle.c:2555` 的实现全程**不持 `p->subs.mutex`**：直接 `track_reset()` 释放每条 cue 的 `text`/`runs`、`avcodec_free_context()`、`overlay_reset()`。

同时 tick 线程每 20 ms 醒一次，只要 `state == PLAYING` 就调 `lp_subtitle_tick()`，而该函数在 `src/core/subtitle.c:2961` 持锁遍历 `t->cues[i]` 读 `c->start_us` 与 `c->text`。`lp_player_close()` 直到 `player.c:529` 才把 `opened` 置 0、`player.c:531` 才切到 IDLE，也就是说整个关闭过程中 tick 线程一直在跑。

结果是：播放中点「停止」「返回」「切集」有概率读到已释放内存，表现为 SIGSEGV 或静默的堆损坏。这是本轮评审里唯一一条**既必然在正常操作路径上、又直接导致进程退出**的缺陷。

修法：给 `lp_subtitle_close()` 加锁，并把 `p->subs.nb_tracks = 0` 放在锁内完成；或者把「销毁字幕」并入 `lp_player_close` 中已经 `abort_request = 1` 之后、且 tick 线程确认不再进入 PLAYING 分支的位置。

### P0-2 播完再按播放：永久无声且永远不会再次结束

`src/core/player.c:537` 的 `lp_player_play()` 允许 `st == LP_STATE_ENDED`，但只做了 `lp_request_seek(p, 0)` 与 `lp_set_state(PLAYING)`，**没有重启解码线程**。而音频线程在 `src/core/audio.c:325` 遇到 `p->audio.eof` 时 `audio_flush_graph()` 后直接 `break` 退出了，`lp_audio_start()` 未被调用。

随后的 seek 在 `src/core/demux.c:322` 把 `p->audio.eof` 清回 0，于是 `player.c:147` 的主时钟判据认为音频还活着，继续走 `lp_audio_clock_seconds()`；环形缓冲是空的，`lp_ring_clock_seconds()` 返回 -1，退化到墙钟，画面能出来，**但再也不会出声**。同时 `player.c:227` 的 `audio_done = atomic_load(&p->audio.eof)` 恒为 0，`LP_EVENT_ENDED` 再也不触发——用户看到的是「播到头了，点播放能出画面但没声音，也退不出播放态」。

修法：`LP_STATE_ENDED`/`LP_STATE_STOPPED` 分支里，在 `lp_request_seek` 之前按需调用 `lp_video_start`/`lp_audio_start`（`lp_player_set_surface` 里已有「停-重开-恢复位置」的现成写法可参照）。

### P0-3 `flutter build windows` 的产物缺 DLL，启动即崩

`app/windows/CMakeLists.txt` 的 install 段（`app/windows/CMakeLists.txt:81-114`）只安装 runner、`FLUTTER_LIBRARY`、`PLUGIN_BUNDLED_LIBRARIES`、ICU 数据与 assets，**没有任何一行涉及 `lanplayer.dll` 或 FFmpeg 的 `av*.dll`**；`add_subdirectory` 也只有 `flutter` 与 `runner`。

这两个库全靠 `scripts/build_windows_desktop.py:293` 在 `cmake --build --target INSTALL` 之后手工 `shutil.copy2`。Dart 侧加载用的是裸名（`app/lib/core/bindings.dart:146` `DynamicLibrary.open('lanplayer.dll')`），既没有读环境变量也没有找 exe 同目录——那条兜底逻辑只存在于 Windows 插件的 `CoreApi::Load` 里。

因此凡是不经该脚本产出的包（`flutter build windows`、Visual Studio 里直接 F5、`cmake --install`）一启动就抛 `ArgumentError`。`docs/build.md` 自己也写明了没有任何 CMake 目标会生成 `build/win-x64/lanplayer.dll`，等于把这条约束留在了流程之外。

修法：在 `app/windows/CMakeLists.txt` 里加 `install(FILES ...)` 或在 `runner` 目标上加 `add_custom_command` 拷贝；同时让 `bindings.dart` 在裸名失败时回退到 exe 同目录。

### P0-4 Android 的 `lp_pixels_free` 未导出，缩略图整体失效

`native/lp_map.txt` 的 `global` 段列出了所有需要导出的符号，但**漏了 `lp_pixels_free`**（声明在 `native/include/lanplayer/lp_source.h:98`，定义在 `native/src/core/thumb.c:388`）。`native/CMakeLists.txt:322` 设了 `C_VISIBILITY_PRESET hidden`，`:337` 的 `--version-script=lp_map.txt` 是唯一能把符号提回 global 的手段，于是 Android 上该符号被隐藏。

Dart 侧 `app/lib/core/bindings.dart:214` 用 `lookupFunction` 取它，`:416`/`:421` 各调用一次——首次取缩略图就抛异常，被 `app/lib/data/thumbs.dart:192` 的 `catch (_) { return null; }` 吞掉，表现成「这个视频没有封面」。因为异常被吞，日志里也没有痕迹，属最难排查的一类。

脚本核对：头文件里 41 个 `LP_EXPORT` 与 `lp_map.txt` 求差集，唯一差项就是它。macOS/iOS 不受影响（podspec 的符号清单与头文件双向一致，`check_apple_wiring` 会守护），Windows 走 `__declspec(dllexport)` 也不受影响——**只有 Android 中招**，而 Android 恰好是最依赖缩略图的一侧。

修法：补进 `lp_map.txt`，并给 `tool/check_all.py` 增加一条「`LP_EXPORT` 集合 == 各平台导出清单」的断言（Apple 侧已有 `check_apple_wiring`，复制给 version-script 即可）。

### P0-5 设置落盘无串行化，会周期性清空全部配置

`app/lib/data/stores.dart:98` 的 `writeJson` 固定写 `$name.tmp`、`flush: true`，然后 `rename`。整条路径**没有串行化**，并发调用会互相截断同一个临时文件。

触发条件就摆在主路径上：`app/lib/ui/widgets/volume_sheet.dart:148` 的音量 `Slider` 只有 `onChanged` 没有 `onChangeEnd`，而 `app/lib/ui/player_screen.dart:694` 的回调里每帧都 `unawaited(SettingsStore.instance.save())`。拖动一次滑杆会连发几十次落盘请求。

一旦两次写重叠，`settings.json` 变成半截 JSON；下次启动 `stores.dart:92` 的 `readJson` 吞异常返回 `{'_error': ...}`，与「空配置」不可区分，于是**所有设置回到默认值，且原文件已被覆盖**。同时 `ServerStore`/`LocalFolderStore` 也走同一个 `writeJson`，理论上同样受影响。

修法：给 `writeJson` 加一把按文件名的互斥（或一个串行队列），并把音量面板改成 `onChangeEnd` 落盘、拖动中只改内存。

---

## 3. P1 缺陷（功能失效或明显劣化）

### 3.1 设置页的「字幕延迟」完全不生效

三处叠加：

1. `app/lib/ui/player_screen.dart:53` 的 `int _subtitleDelay = 0;` 从不从 `widget.settings.subtitleDelayMs` 初始化；
2. `:176` 无条件把 0 推给内核（`if (_subtitleDelay != 0)` 只保护了 `setSubtitleDelay`，下一行的 `setOption('subtitle_delay', '$_subtitleDelay')` 没有保护）；
3. `app/lib/core/player_controller.dart:118` 虽然把 `settings.subtitleDelayMs` 放进 open options，但内核的 `apply_open_options`（`src/core/demux.c:259-312`）**根本不读 `subtitle_delay` 这个键**。

于是设置页的滑杆（`app/lib/ui/settings_screen.dart:293`）写进 `PlaybackSettings.subtitleDelayMs` 的值，在播放时被无条件覆盖成 0。

### 3.2 暂停中拖动进度条，缓冲指示器永久转圈

`src/core/demux.c:326` 的 `perform_seek` 无条件 `lp_emit_buffering(p, 1, 0)`，而唯一的解除点 `src/core/player.c:202` 在 `st == LP_STATE_PLAYING` 分支里。暂停态下拖动进度条，或者缓冲过程中片子恰好播完，转圈就再也不停。

Dart 侧 `buffering` 也没有超时兜底（`player_controller.dart:107` 只在 `open()` 时置 true），一次误置就永久卡住。

### 3.3 0.25× 倍速档位形同虚设

UI 的档位表 `app/lib/data/models.dart:65` 从 0.25 起，但内核有三处下限都是 0.5：

- `src/core/player.c:600` `if (speed < 0.5f) speed = 0.5f;`
- `src/core/audio.c:30` 的 `audio_graph_build` 同样夹到 0.5
- `src/core/player.c:293` 的 `apply_open_options` 只在 `speed > 0.4 && speed < 2.1` 时接受，而 Dart 侧 `player_controller.dart:147` 的 `setSpeed` 也 `clamp(0.5, 2.0)`

用户选 0.25×，HUD 显示 `0.25x`（`player_screen.dart:1099`），实际播放 0.5×。要么把 UI 的档位下限改成 0.5，要么把内核三处下限放到 0.25（`atempo` 的合法区间是 0.5–100，0.25 需要串联两段，实现成本不低）。

### 3.4 连播切集时，三处状态沿用上一集

`app/lib/core/player_controller.dart:100` 的 `open()` 只重置了 `error` 与 `buffering`，**没有复位 `media` / `cue` / `positionUs` / `durationUs`**，成功路径也不 `notifyListeners()`。

连带的三个后果：

- `player_screen.dart:219` 的 `_prefsApplied` 在 OPENING 事件到达时就被置真，而此刻 `_player.media` 还是**上一集的轨道表**——从第二集起音轨/字幕语言偏好永不生效；
- `_applyPendingResume()` 用上一集的 `durationUs` 判断「是否已到片尾」，把 `_resumeHandled` 提前置真，续播位置丢失；
- 5 秒一次的 `_saveProgress` 把上一集的位置写进新集的进度记录。

修法：`open()` 里显式清空媒体状态；把「应用偏好」与「应用续播」的触发条件从「拿到任意 media」改成「拿到与本集匹配的 media」（例如比对 `open()` 时记录的序号）。

### 3.5 字幕匹配：C 与 Dart 双实现不一致，且认不出常见命名

`src/core/submatch.c` 与 `app/lib/data/subtitle_match.dart` 各写了一份匹配逻辑。C 侧 `episode_key()` 只认三条路径（`s<N>...e<M>`、`<N>x<M>`、末尾纯数字），**没有 `第 N 集`、没有独立的 `E02`**；Dart 侧有五条正则。两边的注释都写着「不一致会让列表里认得出的字幕在打开时挂不上」，但实现确实不一致。

更实际的问题在两侧同病：`[Group] Show Name - 01 [1080p].mkv` 与 `[Group] Show Name - 02.chs.ass` 这种命名，两边的集数解析都返回空（数字后面跟的是 `]` 或 `.`），于是落到 `dice >= 0.86` 的近似判定。剥掉方括号后的 `show name 01` 与 `show name 02` 相似度约 0.909，**被判为同一片**——整季字幕会挂到每一集上。

同时 `src/core/submatch.c:50` 的 `kLang[]` 缺 `cn`/`tw`/`hans`/`hant`，导致 `Movie.2024.1080p.mkv` 与 `Movie.2024.zh-CN.srt` 判否；而 Dart 侧 `subtitle_match.dart:45` 的 `_languageTokens` 里却有 `简体`/`双语`/`特效` 等 C 侧没有的词。

测试也没兜住：`native/tests/lp_submatch_test.c` 与 `app/test/subtitle_match_test.dart` 的 20 余条用例都没有覆盖「数字后跟标点」这种最常见的形式。

### 3.6 播放页缺失的水平滑动手势

`app/lib/ui/player_screen.dart:826` 的 `GestureDetector` 只有 tap / doubleTap / longPress / verticalDrag 四类，**没有 `onHorizontalDrag*`**，全仓 grep `onHorizontalDrag` 零命中。

移动端常见操作里，「横向滑动调节播放进度」是标配；当前只能靠双击左右三分之一（±10 s）或拖进度条，而进度条只在控制条可见时才有。README 的功能清单里写的是「触屏手势」，实际缺了这一项。

### 3.7 纯矢量字幕（`\p`）被整条丢弃

`app/lib/ui/widgets/subtitle_overlay.dart:691` 的判断是 `if (cue.isEmpty) return SizedBox.shrink();`，而 `app/lib/data/models.dart:1035` 的 `isEmpty` 定义为 `text.trim().isEmpty`。只含 `\p1` 矢量绘图、没有文字的字幕行因此被判为空。

内核侧是明确支持的：`src/core/subtitle.c:2705` 把 `has_drawing_runs` 当作「有内容」处理，`subtitle_overlay.dart` 里也确实有 `_drawingsWithPlacement()` 负责绘制。也就是说渲染能力已经做好，只是被入口判断挡住了。OP/ED 的矢量标题、部分特效字幕会整段消失。

### 3.8 内嵌 ASS 轨的 `\pos` / `\fs` 全部失效

`src/core/subtitle.c:2659` 解析内嵌轨时用 `AssCtx ctx; memset(&ctx, 0, sizeof(ctx));`，`ctx.play_w` / `ctx.play_h` 恒为 0。而 `subtitle.c:1492`（`\pos`）与 `subtitle.c:1263`（`\fs`）都以 `ctx->play_w > 0` 作为硬性前提。

外挂 `.ass` 走的是另一条路径（`subtitle.c:2282` 正常传入 `play_w`/`play_h`），所以同一份字幕「另存为外挂文件再加载」就能正常定位。这个差异本身说明是内嵌路径漏了初始化，不是设计取舍。

### 3.9 无 BOM 的 UTF-16LE 字幕解析出 0 条 cue

`src/core/subtitle.c:511` 的 `if (c < 0x80) { i++; continue; }` 把 0x00 当作合法 UTF-8 继续，于是 `is_valid_utf8()` 对「UTF-16LE 的中文文本」返回真（每个汉字的高字节都是 0），`decode_text()`（`subtitle.c:621`）因此不会回落到 UTF-16 分支。

带 BOM 的文件不受影响（`subtitle.c:613` 先剥 BOM）。从某些工具链导出的字幕不带 BOM，表现为「文件加载成功、轨道列表里也有、但一条都不显示」。

### 3.10 图形字幕切到文本轨后残留，并让 Windows 永久放弃 GPU 直出

`src/core/subtitle.c:3085` 的 `lp_subtitle_select()` 只改 `selected` / `enabled` / `current_cue` / `dirty`，**不清 overlay**。而 `subtitle.c:199` 的 `lp_render_graphics_sub_active()` 只看 `p->subs.overlay.nb > 0`。

`native/src/platform/win32/win32_platform.c:232` 的判断是「有图形字幕就返回 `LP_ERR_UNSUPPORTED`，让调用方下载回 CPU 做混合」。overlay 一旦残留非零，Windows 就永久走 CPU 混合路径，硬解直出的优势消失。

### 3.11 缩略图失败会被永久记住

`app/lib/data/thumbs.dart:176` 在解码失败时写一个 `<key>.none` 标记文件，`:163` 命中标记就直接返回 null，**全文件没有任何删除该标记的逻辑**。SMB 抖动一次、或者那一刻文件正被占用，这个视频就永远没有封面了。

「清空封面缓存」本来能救，但 `thumbs.dart:298` 的 `clear()` 与 `diskUsage()` 全仓无调用者——设置页没有入口。

### 3.12 错误分类在传递链上被抹平

`native/src/source/io.c:91` 的 `if (tp->open(...) != LP_OK) { free(io->cache); free(io); return NULL; }` 丢弃了具体返回码；`native/src/source/smb.c:151` 的 `smb_connect` 失败直接 `return NULL`（不带错误码）；`native/src/core/demux.c:239` 的 `if (!p->io) return LP_ERR_IO;` 统一成 IO 错误。

结果：**密码错、共享名不存在、服务器不可达、网线没插**在 UI 上是同一句「无法访问，连接超时或服务器不可达」。`LP_ERR_AUTH` 这个错误码在整条链路上是死的。`app/lib/data/repository.dart` 的 `_errorFor` 注释把原因归结为「内核错误是线程本地的」，但即使不看文本，错误码本身也没有传出来。

配套问题：`native/src/source/smb.c:79` 靠 `strstr(e, "timed out")` 判断超时，而 libsmb2 实际给出的是全大写的 `SMB2_STATUS_IO_TIMEOUT`，`LP_ERR_TIMEOUT` 同样永远不会被置位。

### 3.13 缩略图的 4 秒预算基本失效

`native/src/core/thumb.c:114` 直接赋值 `fmt->interrupt_callback.callback = thumb_interrupt_cb;`，**覆盖了** `native/src/source/io.c:357` 里由 `lp_io_attach_avio` 设置的中断回调。覆盖之后 `io->abort` 永远不会被置位，而 `LP_THUMB_BUDGET_MS = 4000`（`thumb.c:56`）只在「包边界」生效。

libsmb2 没有 cancel 钩子，线程一旦阻塞在 `smb2_read` 里就只能等 socket 超时（默认 8 s）。列表页滑动时如果连的是已经掉线的 NAS，每个封面都会占用一个网络往返。

### 3.14 macOS 全屏是空实现

`app/macos/Runner/MainFlutterWindow.swift:88`：

```swift
case "setFullscreen":
  result(false)
```

注释写「macOS keeps its own fullscreen mode」，但 `app/lib/ui/player_screen.dart:1075` 的 `_toggleFullscreen()` 不检查返回值也不 await，于是用户按 F11 / 点全屏按钮：窗口 style 不变、`SystemChrome.setEnabledSystemUIMode` 在桌面端也不产生效果，**看起来就是按钮没反应**。

Mac 上 61.7 MB 的 `lanplayer.app`、300 行 dmg 脚本、两份 podspec 都是真实可用的，唯独这个入口是空的。

### 3.15 服务器离线时无法保存任何配置改动

`app/lib/ui/server_edit_screen.dart:185`：

```dart
Future<void> _save() async {
  final ok = await _test();
  if (!ok) return;
  await ServerStore.instance.upsert(_build());
  ...
```

「保存」强制先连通性测试。NAS 关机时用户想改一下显示名称、或者把端口从 445 改成 4450 再试，**保存按钮永远是无效的**。而 `_test()` 在 `!mounted` 时 `return true`（`:174`），又会反过来让组件已经销毁的情况下继续 upsert。

### 3.16 异步守卫不统一，三处会出问题

- `app/lib/ui/browser_screen.dart:91` 的 `_navigate()` 在 `await` 之后**没有 `if (!mounted) return;`**，直接 `_markOnline(); setState(...)`。请求飞行中 pop 掉浏览页会抛 `setState() called after dispose()`（`finally` 里的 mounted 检查挡不住 try 段这次）。
- `app/lib/ui/folder_picker.dart:113` 的 `_enter()` 有 mounted 检查但**没有请求代际**，快速连点两个目录时后到的结果覆盖先到的，会显示错目录、返回错路径。
- `app/lib/ui/home_screen.dart:150` 反而做对了：`_loadGen` 代际号 + `if (!mounted || _loadGen[s.id] != gen) return;`。三处各写一套，说明这条规则没有被固化成公共部件。

### 3.17 连播切集时，`apple_texture.c` 的缩放上下文不随分辨率重建

`native/src/platform/apple/apple_texture.c:98` 是一个**函数级 `static`**：

```c
static struct SwsContext *sws = NULL;
```

`apple_texture.c:123` 只在首次按 `frame->width/height/format` 建一次，`:128` 之后永远复用。软解路径下连播两个分辨率不同的文件（或同片切的轨像素格式变化），`sws_scale` 会用错误的源尺寸做转换。

对照：`native/src/platform/win32/win32_platform.c:137` 在尺寸变化时 `sws_freeContext` 后重建（正确做法）；`native/src/platform/android/egl_renderer.c:226` 只在 `!g_egl.sws` 时建（同病，但目前只处理非 YUV420P/NV12，暴露面小）。

### 3.18 切音轨会阻塞 UI isolate

`native/src/core/player.c:674` 的 `lp_player_select_track(AUDIO)` 会调用 `lp_audio_stop(p)`，而后者内部 `pthread_join(p->audio.thread)`。这条调用链是 Dart 经 FFI 同步发起的（`app/lib/core/player_controller.dart` → `_core.selectTrack`），join 期间整个 UI isolate 停摆。

SMB 抖动或队列里积压了几百毫秒的包时，切轨会卡住渲染与手势。`player.c:678` 之后还要 `lp_request_seek(pos)`，完整生效需要一次 seek，用户的观感是「点了音轨，界面卡一下」。

### 3.19 主时钟在音频欠载时退化，没有回同步机制

`src/core/audio_ring.c:196` 在 `r->count == 0` 时只填静音、`return frames`，**不推进 `sample_index`**；`src/core/player.c:147` 的判据只有 `!atomic_load(&p->audio.eof)`，没有「环空 / 时钟不前进」。

环空时 `lp_ring_clock_seconds()` 返回 -1，`lp_master_clock_us()` 退化到墙钟。此时画面按墙钟往前走，而音频环里其实还压着几百毫秒的数据——**一旦数据续上，音频从旧位置继续播，画面已经跑到前面**，音画永久错开一段时间，没有任何机制把它们重新对齐（`lp_clock_sync` 只作用于 `p->ac`，而 `p->ac` 在 `sync_mode == 0` 下并不参与主时钟）。

局域网 SMB 播大码率片源时这类欠载会反复发生，是「看着看着不同步了」的根因。

### 3.20 预读窗口上限过大

`src/core/player.c:409`：

```c
lp_pq_init(&p->video.pq, LP_MAX_PACKET_BYTES);        /* 256 MB */
lp_pq_init(&p->audio.pq, LP_MAX_PACKET_BYTES / 2);    /* 128 MB */
```

背压条件 `src/core/queue.c:91` 是 `q->nb_packets > 8 && q->bytes >= q->max_bytes`，也就说可以一路涨到 384 MB。移动端（尤其 Android 上被系统限制的后台内存）有真实的 OOM 风险，而这么深的缓冲对局域网播放毫无收益——按 20 Mbps 码率，16 MB 已经是 6 秒的预读量。

另外 `src/player_internal.h:62/64/65` 的 `LP_MAX_QUEUED_PACKETS 4096`、`LP_MIN_PACKET_BYTES`、`LP_VIDEO_FRAME_QUEUE 24` 三个常量**全仓没有任何引用**（grep 只有定义处），是设计期留下的空壳。

### 3.21 `serial` 声明为原子却裸读写

`src/player_internal.h:657` 声明 `atomic_int serial`，但：

- 写侧 `src/core/demux.c:316` 是 `p->serial++;`（普通读-改-写）；
- 读侧 `src/core/video.c:270/278/289`、`src/core/audio.c:253/256/266` 全是裸 `p->serial`。

demux 是唯一写者，撕裂风险低，但这是标准的数据竞争（C11 意义上的 UB），编译器完全可以把 `video.c:278` 的两次读缓存在 flush 之前。改成 `atomic_fetch_add` / `atomic_load` 零成本，没有理由不做。

### 3.22 两个 ASS 标签解析分支写错了

`src/core/subtitle.c:1255` 附近，`\fr` 的处理写成：

```c
} else if (!strncmp(p, "r", 1) && !tag_has_arg(p + 1)) {
```

紧跟其后才调 `tag_number(&p, &num)`。而 `tag_has_arg()`（`subtitle.c:905`）的判据是 `isdigit(*p) || *p == '-' || *p == '+' || *p == '.'`——`\fr45` 的参数是数字，`tag_has_arg` 返回真，这个分支就进不去了。`\fscx` / `\fscy` 不受影响（走的是前一分支），所以问题只出现在 `\fr<N>` 这种「只有角度、没有轴」的写法上，而它恰恰是旋转最常用的形式。结果：**`\fr<N>` 静默失效，不旋转也不报错**。

`src/core/subtitle.c:1134` 的 `case 'i'` 分支：

```c
case 'i':
    b->st.flags = tag_number(&p, &num) == 0 && num == 0
                      ? (b->st.flags & ~LP_SUB_ITALIC)
                      : (b->st.flags | LP_SUB_ITALIC);
```

只认 `\i0` / `\i1`，碰上 `\iclip(...)` 时 `tag_number()` 返回非 0，于是按「无参数即开启」处理——**把逆裁剪当成了斜体**。配套的 `clip_inverse` 字段在整个 `subtitle.c` 里没有任何赋值点（只有拷贝与比较），JSON 里恒输出 `false`，所以即使解析对了也没有下游能消费。

修法：`case 'f'` 里先比完整标签名（`frz`/`frx`/`fry`/`fr`）再取参数，不要用「有没有参数」来区分；`case 'i'` 里先排除 `iclip` 再处理斜体开关。

---

## 4. P2：性能与一致性问题

### 4.1 热路径上的固定开销

| 位置 | 问题 |
|---|---|
| `src/core/demux.c:379` | 主循环里**每读一个包**都调 `getenv("LP_DEMUX_DISCARD")`，getenv 是 environ 线性扫描 |
| `src/core/video.c:295`、`audio.c:275` | `lp_pq_get(..., 0)` 传非阻塞，解码线程靠 `av_usleep(2000)` 每 2 ms 轮询加锁（各 500 次/秒）；`queue.c:121` 的 `pthread_cond_wait` 分支因此形同虚设 |
| `src/core/video.c:143` | 去隔行路径每帧 `av_frame_alloc` / `av_frame_free` |
| `src/core/audio.c:215` | 每个音频帧一次 `malloc` / `free` 装 PCM |
| `src/core/audio.c:80` | 变调图每帧两个 AVFrame + `av_frame_get_buffer` |
| `src/util/lp_str.c:66` | `lp_str_append_json_str` **逐字节**走 `lp_str_append`（每次两遍 vsnprintf + 可能 realloc）；媒体信息与字幕文本都经过它 |
| `src/core/subtitle.c:2778` | 一条字幕事件被整串拷贝三次（LpStr → append → `lp_emit_event` 再 malloc），文字还在 `append_runs_json` 里序列化两遍 |
| `src/core/subtitle.c:199` | 有图形字幕时每帧 `malloc`+`memcpy` 所有矩形再 `free`，混合循环里每像素 3 次整数除法 |
| `src/source/io.c:79` | 每个 `LpIo` 无条件 malloc 1 MiB 预读缓冲；一次 AVIO 读要两次 memcpy；`io_refill` 未命中时先 seek 再 read，等于两次 SMB 往返 |

### 4.2 UI 层的重建范围

- `app/lib/ui/player_screen.dart:206` 的 `_onPlayerChanged()` 只做三件事：应用续播、应用轨道偏好、`setState(() {})`。**整页重建**。POSITION 事件 200 ms 一次（`LP_POSITION_INTERVAL_US`），动画字幕的 SUBTITLE 事件 20 ms 一次（`lp_subtitle_tick` 每 tick），后者对应 50 Hz 的整页重建。
- `player_screen.dart:383` 的 `_onPointerHover` 每次 hover 事件都调 `_showControls()`，而后者每次都 `_hideTimer?.cancel()` 再 `_scheduleHide()`——鼠标划过时每秒重建上百次 2 秒定时器。
- `app/lib/ui/widgets/subtitle_overlay.dart` 同帧两次 `_drawingsWithPlacement()`，`shouldRepaint` 恒返回真，`SubtitleAnimator.resolve` 对同一 cue 重复解析。

### 4.3 目录页的算法复杂度

`app/lib/data/models.dart`：

- `videos` / `folders` / `subtitles` 三个 getter 每次访问都 `entries.where(...).toList()`；
- `subtitlesFor(video)` 遍历全部字幕做匹配（O(S)）；
- `orphanSubtitles` 对每个视频跑一遍 `subtitlesFor`（O(V×S)）；
- `browsable` 里再用 `orphans.any((o) => o.path == e.path)` 逐项线性查找（整体 O(n²)）。

`app/lib/ui/widgets/media_row.dart:166` 的 `subtitleLabel()` 每行调用一次 `listing.videos.firstWhere((v) => listing.subtitlesFor(v).any(...))`，于是在「每行每次 build」的放大下是 O(n³) 级别。1000 个文件的目录滚动会明显掉帧。

同样的模式还有 `app/lib/data/progress.dart:96`：`sanitizeKey()` 每次调用都跑一遍 `_decodePercent`（含 UTF-8 全扫），而 `media_row.dart:68` 每行每帧调一次。

### 4.4 缩略图链路

- `app/lib/data/thumbs.dart:64` 用 `ConcurrencyGate(max: 1)` **串行**取封面，注释里承认「NAS 上 4 路以上无收益、单次 0.6 s→5.0 s」。但 `app/lib/ui/home_screen.dart:526` 用的是非 builder 的 `ListView(children: [...])`，展开「还有 N 项」后行数无上限，每行又无条件建 `ThumbnailTile`（`media_row.dart:82`）——200 个视频的目录会一次排 200 个串行封面请求。
- 内存缓存 `_memory` 无上限，`ui.Image` 从不 `dispose()`（`thumbnail_tile.dart` 的 `dispose()` 只把引用置 null，注释说「由缓存持有」，但缓存本身也不释放）。128×128 RGBA 约 64 KB，1000 个视频就是 64 MB 原生纹理内存。
- 磁盘缓存只有 `diskUsage()` 统计，没有淘汰策略。

### 4.5 交互一致性

- 音量有三条调节路径，步长互不相同：滚轮 `volume_sheet.dart:55` 的 `wheelStep = 5.0`（注释写「每格 3」，与代码矛盾）、键盘 `player_screen.dart` 的 `_nudgeVolume(±0.05)` 对应显示刻度 2.5、底栏 Slider `divisions: 40` 也是 2.5。
- `app/lib/ui/settings_screen.dart:222` 的文案是「100 为原音量，上限 200」，而 `volume_sheet.dart:42` 的映射是 `displayOf(1.0) = 50`、`displayOf(2.0) = 100`——文案与实际相反。
- 倍速面板（`player_screen.dart:614`）改完不写 `_settings.speed` 也不落盘；「画面」面板（`:725`）切换缩放模式同样不 `SettingsStore.save()`。切集或重启后回到旧值。
- 「媒体信息」对话框里那行数值不在 `AnimatedBuilder` 内，打开后就冻结。

### 4.6 深色 / 浅色

`app/lib/ui/theme.dart:13` 只有 `static ThemeData dark()`，`app/lib/main.dart:234` 写死 `theme: LanPlayerTheme.dark()`，**没有 `darkTheme` 也没有 `themeMode`**。README 承诺「深浅色跟随系统」未实现。另有约 40 处硬编码 `fontSize:`（仅 8 处用 `textTheme.`），补齐 light 主题时需要逐个改。

### 4.7 局域网扫描的网段收敛

`app/lib/data/lan_scan.dart:78`：

```dart
if ((1 << (32 - prefix)) - 2 > maxHosts) effective = 24;
```

`effective` 之后用于 `network = ip & mask`，用的是 **CIDR 字符串里的 ip**，而注释说的是「收敛到本机地址所在的 /24」。传 `192.168.0.0/16` 会扫 `192.168.0.x` 而不是本机所在的 `192.168.5.x`。

`app/test/lan_scan_test.dart:63` 把这个行为写成了期望值，于是测试是绿的、行为是错的。

### 4.8 主 isolate 上的同步 IO

`app/lib/data/repository.dart:163` 的 `_windowsDrives()` 在**主 isolate** 里对 A–Z 逐个 `existsSync()`。本机盘符很快，但如果挂过已经掉线的网络盘，每个盘符都要等一个 SMB 超时，启动时白屏数秒。这段代码应该和 `background.dart` 里其他探测一样放进 isolate。

---

## 5. P3：整洁性与可维护性

- **死代码**：`app/lib/ui/media_permission.dart:40` 的 `status()`、`app/lib/ui/feedback.dart:20` 的 `showSnack()`、`app/lib/ui/keyboard.dart:79` 的 `isBackKey()`、`app/lib/data/thumbs.dart:298` 的 `clear()`/`diskUsage()`、`app/lib/player/playlist.dart` 的 `parseEpisode()`/`appendEpisodes()`（排序实际靠内核 `url.c:293` 的 `natural_cmp`）、`app/lib/ui/video_texture.dart` 的 `resize()`、`PlayerController.onReady`（全仓无赋值点）、`installFrameCallback` 绑定。
- **零引用常量**：`LP_MAX_QUEUED_PACKETS`、`LP_MIN_PACKET_BYTES`、`LP_VIDEO_FRAME_QUEUE`、`LP_PLATFORM_DESKTOP/APPLE/ANDROID`（`player_internal.h:54` 定义但全仓无 `#if` 使用）。
- **死代码路径**：`src/core/demux.c:278` 的 `hint_dict(&ifo, "discardcorrupt", "1")` 写进一个随即 `av_dict_free` 的临时字典，从未传给任何 FFmpeg 函数。
- **重复实现**：`src/app/lp_preview.c` 的 `json_str()` 是手写的字符串匹配 JSON 读取，与内核的 `lp_json_get_str` 重复；`pthread_join` 忽略返回值；`dispose()` 与 `disposePlayer()` 逐行相同且都调 `super.dispose()`。
- **注释与实际不符**：`native/include/lanplayer/lp_player.h:9` 指向不存在的 `lib/core/ffi/event_port.dart`；`player_controller.dart` 的 `attachVideo` 注释说「桌面端不用纹理」，实现里 `textureId` 只赋值不读取；`app/lib/main.dart:49` 注释称四个 store 并行加载，实际是串行 `await`；`app/lib/data/track_prefs.dart:178` 的文档提到不存在的 `allowNull` 参数。
- **编码瑕疵**：`app/lib/data/models.dart:961` 的注释里混入了一个 BEL 控制字符（0x07，来自 `\alpha` 的 `\a`），`cat -v` 显示为 `^G`。
- **魔法数字**：Dart 侧的事件类型全是字面量（`case 1:` 到 `case 10:`），没有与 `lp_types.h` 的 `LP_EVENT_*` 对应的常量。`LP_EVENT_LOG = 8` 在 `switch` 里没有分支，被 `default` 静默丢弃（内核当前也不发，属预留）。
- **id 生成**：`app/lib/data/folders.dart:153` 用 `'dir-${DateTime.now().millisecondsSinceEpoch}'`，同一毫秒内添加两个目录会撞 id。
- **`\t` 内的 clip 动画**：`app/lib/data/subtitle_anim.dart:52` 的 `final clipOn = run.clipOn;` 从不变为 true，`\t(\clip())` 永不生效。
- **颜色动画起点**：`subtitle_anim.dart:58` 的 `_colorOr(run.color, 0xFFFFFFFF)` 在 run 无色时用白色作为起点，与 ASS 语义（从默认色插值）不符。

---

## 6. 逐功能实现核对

对照 README 的功能清单，逐项给出结论。

| 功能 | 结论 |
|---|---|
| SMB 只读浏览 | 可用。`smb.c` 的 relpath 处理、IPC$ 探测、OS 垃圾文件过滤都正确。问题在错误分类被抹平（§3.12）与预读效率（§4.1）。 |
| 本机路径浏览 | 可用。`file.c` 与 `demo-*.mp4` 的冒烟通过。 |
| FFmpeg 定容器/编码 | 可用。`av_find_best_stream` + `probesize 8 MB` / `analyzeduration 6 s` 覆盖绝大多数片源，弹幕（FLV）等特殊容器另有 `spins` 防死循环守卫。 |
| 三端硬解 + 自动回退 | 可用。`video.c:228` 的降级路径与 `LP_EVENT_STATS {fallback_from}` 都在，`d3d11va` 与软件解码的像素级对比测试存在。缺 D3D11 设备的 CI 上这条永远跳过（§7.3）。 |
| 四端音频输出 | 可用。WASAPI / waveOut / AAudio / AudioQueue 四套实现齐全，Pull 模型统一。问题是 WASAPI 忽略 `lp_audio_pull_pcm` 的返回值（`win32_platform.c:577`），环空时提交静音块；AAudio 设备采样率与源不一致时只告警（`aaudio_sink.c`）不重采样。 |
| 内嵌 + 外挂字幕 | 部分可用。编码判定（UTF-8/UTF-16/GB18030/ANSI）覆盖到位，但无 BOM 的 UTF-16LE 会解析出 0 条（§3.9）。 |
| ASS 富文本（颜色/描边/字号/字体/定位/动画/裁剪/矢量/卡拉OK） | 大部分可用。`\pos`/`\fs` 在内嵌轨上失效（§3.8）、`\fr<N>` 不可达与 `\iclip` 被当斜体（§3.22）、纯 `\p` 被丢弃（§3.7）、`\t(\clip())` 无效（§5）。 |
| PGS / VobSub / DVB 图形字幕 | 可用但有残留问题（§3.10）。CPU 混合路径每帧深拷贝、每像素 3 次除法，1080p 全屏对白框时开销可观。 |
| 选轨双面板 + 首选/次选语言 | 面板可用；自动挑轨从第二集起失效（§3.4）。内核的媒体信息 JSON 没有 `disposition` 字段，Dart 只能拿「第一条」近似「默认轨」（`player_screen.dart:234`）。 |
| 播放控制（暂停/±10s/拖拽/0.5–2.0x/音量/静音/全屏） | 桌面基本可用。0.25× 档无效（§3.3）、macOS 全屏无效（§3.14）、水平滑动 seek 缺失（§3.6）。 |
| `SxxEzz` / `第 N 集` 连播 | 可用。正则在 `playlist.dart`，实际排序靠内核 `natural_cmp`（`url.c:293`），E2 < E10。 |
| 记忆进度 | 可用，但切集瞬间会串集（§3.4）。`resumablePosition` 的 8 s / 15 s 双阈值设计合理。 |
| 缩略图 | Windows 可用；Android 因符号未导出整体失效（§P0-4）；失败永久记忆（§3.11）；失败预算失效（§3.13）。 |
| 移动端启动动画 | 可用。`splash_gate.dart` 的 1.2 s + 淡出与 `_boot()` 并行。 |
| 局域网扫描 | 可用。TCP 445 并发探测，64 路封顶。网段收敛逻辑与注释不符（§4.7）。 |
| 桌面快捷键 | 可用。`keyboard.dart` 的「抬起才触发」+ 长按不重复的实现是正确的。`rebind()` 没有调用者，改「返回上一级」对已打开页面不生效。 |
| 触屏手势 | 部分可用。双击左右 ±10 s、垂直拖亮度/音量、长按 2.0× 都在，水平拖 seek 缺失（§3.6）。 |
| 深浅色跟随系统 | **未实现**（§4.6）。 |
| 设置项 | 大部分可用。字幕延迟不生效（§3.1）；音量文案与实际映射相反（§4.5）；倍速/缩放模式不落盘（§4.5）。 |
| 关于页版本号与 ABI | 可用。Dart 侧 `const int abiVersion = 1` 与内核 `lp_abi_version()` 的比对只用于展示，**没有在启动时断言**；Windows 插件反而做了这件事（`lanplayer_video_plugin.cpp:176`）。 |

---

## 7. 架构与扩展性

### 7.1 做得好的部分

- **ABI 契约干净**。只用标量、字符串与 JSON，不传结构体、不传回调结构体指针；返回值字符串由调用方 `lp_string_free` 释放，事件 JSON 由内核 malloc、宿主释放。这一层几乎没有历史包袱，新增函数不需要改 ABI 版本——`lp_abi_version()` 只在真正不兼容时递增。
- **线程职责清晰**。`AVFormatContext` 只由 demux 线程持有；seek 通过原子标志请求；四个线程的生命周期在 `lp_player_close` 里按「abort → join open → join demux → stop video → stop audio → close subtitle」的顺序收拢，注释解释了每一处曾经的死锁。
- **失败降级有统一出口**。硬解初始化失败 → `LP_EVENT_STATS {fallback_from}` 切软解；音频设备打不开 → 视频继续、时钟退化；字幕解析失败 → `LP_ERR_UNSUPPORTED`。
- **音频后端收敛在一处**。`src/core/audio.c:197` 的工厂是唯一的后端选择点，新增平台只要实现 `lp_audio_sink_*` 五个函数。
- **静态检查确实拦过 bug**。34 项 `check_*` 里的「`LP_ERR_AGAIN=-7` vs `AVERROR(EAGAIN)=-11`」「abort 后 join 死锁」「纹理 R↔B 反序」都是真实踩过的坑，注释与断言配套。

### 7.2 扩展性的结构性障碍

**新增一个 C 源文件要改 5–6 处。** `native/CMakeLists.txt` 的 `LP_CORE_SOURCES`、`scripts/build_windows.py` 的 `CORE_SOURCES`、`scripts/build_apple_deps.py` 的清单、`tool/check_all.py` 的 `REQUIRED`（还漏登记了 11 个现存 `.c`），再加上平台分支。三处清单目前彼此一致（CMake 16 = build_windows 16；build_apple 19 = 16 + 3 个 Apple 文件），但一致性靠人工维护。`AgentsReadMe.md` §11.2 把这条写成了纪律，说明已经被坑过。

**新增一种源类型要改 6 处。** `source_internal.h:46` 的 `extern`、`io.c:366` 的 `lp_transport_find` if 链、`io.c:494` 的 scheme 列表、两处构建脚本，以及 Dart 侧 `models.dart:192` 硬编码的 `smb://`。传输层已经有 `LpTransport` 这层抽象，但没有做成注册表。

**Windows 是双轨制。** `native/CMakeLists.txt` 的平台分支只有 `ANDROID` / `APPLE` / `else → stub`，**完全没有 win32 分支**；Windows 产物只由 `scripts/build_windows.py` 用 Zig 直接编。这导致：CMake 路线在 Windows 上产出的是 stub 后端（无画面无声），而真正的后端只在脚本路线里存在。任何「用 CMake 构建」的假设在 Windows 上都会落空（§P0-3 是它的直接后果之一）。

**平台抽象没有真正统一。** `LP_PLATFORM_DESKTOP/APPLE/ANDROID` 是死宏；`LpVideoOutKind` 写进去之后没有读取点。视频输出后端在三种平台上用三种不同的机制（FlutterTexture / EGL / D3D11 共享纹理），接缝散落在 12 处、跨 4 种语言：

```
Dart MethodChannel  →  Windows C++ 插件  →  d3d11_output.c
                    →  macOS Swift 插件  →  apple_texture.c
                    →  Android Kotlin    →  jni_bridge.c → egl_renderer.c
```

`packages/lanplayer_video` 本该承担这层抽象，但它的 `pubspec.yaml` 只声明 `windows` 平台，`lib/lanplayer_video.dart` 全文只有一个常量，真正的 API 是 `app/lib/ui/video_texture.dart:25` 的裸 `MethodChannel('lanplayer/video')`。结果是三份平台实现各自独立演进。

**单文件过大。** `src/core/subtitle.c` 3214 行、`app/lib/ui/player_screen.dart` 1511 行、`app/lib/data/models.dart` 1036 行（混了六个层次的职责）、`app/lib/ui/widgets/subtitle_overlay.dart` 910 行。新增功能时改动的定位成本很高。

### 7.3 测试与守护的实际强度

`tool/check_all.py` 34 项全过，`dart tests: +264` 全过，`lp_smoke_test` 全过——基础是扎实的。但守护有几处明显偏软：

- `check_playback_profiles` 与 `check_android_playback` 是**纯字符串存在性断言**（在源码里找某段文字），不能证明行为。
- `check_windows_plugin`（`tool/check_all.py:1688`）只验证「名字在头文件里有声明」，不验证定义与导出。
- `tool/check_symbols.py` 不区分平台，且 `SKIP_PREFIX` 跳过 `lp_str_`/`lp_pq_`/`lp_ring_`/`lp_clock_`/`lp_json_`/`lp_log_vemit` 六个前缀——恰好把「某平台缺渲染/音频/硬解实现」排除在外。
- `check_hw_decode` 在无 D3D11 设备的 CI runner 上永远走跳过分支，**D3D11VA 直出从未被 CI 验证过**。
- 没有任何检查守护 `lp_map.txt` 与头文件符号集合的一致性（P0-4 就是这么漏掉的）。
- 内核单元测试只有冒烟；ASan 长片未跑（重点在 seek 与切集路径，而 §P0-1 正好落在这条路径上）。

### 7.4 CI

`.github/workflows/build.yml` 五个 job：Linux 原生核（stub 平台）、Android arm64-v8a、Apple（仅 iOS 构建）、Windows 原生核（Zig）、Windows 桌面应用（Flutter + MSVC）。

**没有 macOS 桌面 job。** 近 500 行代码（`build_macos_dmg.py` + Apple 纹理桥 + 两份 podspec + `MainFlutterWindow.swift`）服务于一个从未在 CI 上构建过的平台——§3.14 的 macOS 全屏空实现之所以能留到现在，与这条空白直接相关。

Android 侧配置也已越界：AGP `8.1.0` + `compileSdk = 35`（AGP 8.1 的官方上限是 34），Gradle `8.3`，缺少 16 KB page 对齐（`targetSdk 35` 的 Play 提交要求）。当前能编过，但升级链路已经断了。

### 7.5 版本号一致性

`app/pubspec.yaml:4` 是 `0.1.7+8`（app 侧单一真源，Gradle 与 `Generated.xcconfig` 都溯源到这里），但 `packages/lanplayer_core/pubspec.yaml`、`packages/lanplayer_video/pubspec.yaml` 与两份 podspec 都停在 `0.1.0`，`scripts/build_macos_dmg.py:52` 找不到版本串时只 `lp.warn` 不失败。

---

## 8. 修复建议与排序

### 第一批：正确性与数据安全（建议本轮一起做完）

1. 给 `lp_subtitle_close()` 加锁（§P0-1）。
2. `LP_STATE_ENDED`/`STOPPED` 分支重启解码线程（§P0-2）。
3. `app/windows/CMakeLists.txt` 补 `lanplayer.dll` 与 FFmpeg DLL 的 install 规则；`bindings.dart` 加 exe 同目录兜底（§P0-3）。
4. `lp_map.txt` 补 `lp_pixels_free`，并加一条符号集合一致性断言（§P0-4）。
5. `AppStorage.writeJson` 串行化；音量面板改 `onChangeEnd` 落盘（§P0-5）。

### 第二批：功能失效（用户可感知）

6. 字幕延迟链路打通（初始化 `_subtitleDelay` + 内核读 `subtitle_delay`）（§3.1）。
7. `buffering` 在非 PLAYING 态也能解除，Dart 侧加超时兜底（§3.2）。
8. 统一倍速下限（§3.3）。
9. `PlayerController.open()` 复位媒体状态，偏好与续播的触发条件绑定到本案（§3.4）。
10. 字幕匹配：C 与 Dart 合并为一份规则表，补 `cn`/`tw`/`hans`/`hant`，补「数字后跟标点」的集数形式，测试用例跟上（§3.5）。
11. 补水平滑动 seek（§3.6）。
12. `cue.isEmpty` 改为「文本与绘图都为空」（§3.7）。
13. 内嵌轨 `AssCtx` 传入 `play_w`/`play_h`（§3.8）。
14. `is_valid_utf8` 把 0x00 判为非法（§3.9）。
15. `lp_subtitle_select` 清 overlay（§3.10）。
16. 缩略图失败标记加时效或改内存态（§3.11）。
17. 错误码在 `io → demux → source_last_error` 链路上透传（§3.12）。
18. `thumb.c` 不要覆盖 IO 的中断回调，改成两级判断（§3.13）。
19. macOS 全屏实现或从 UI 摘掉入口（§3.14）。
20. 服务器编辑允许「不测试直接保存」（§3.15）。
21. 三处异步守卫统一成公共模式（§3.16）。
22. Apple/Android 的 sws 按尺寸重建（§3.17）。
23. `\fr<N>` 与 `\iclip` 的解析分支修正（§3.22）。

### 第三批：稳健性与性能

24. `serial` 改原子操作（§3.21）。
25. 音频欠载时把主时钟切到墙钟并在恢复后重新对齐（§3.19）。
26. 预读上限按码率自适应（§3.20）。
27. `lp_pq_get` 改阻塞等待（§4.1）。
28. `getenv` 提到函数入口（§4.1）。
29. `lp_str_append_json_str` 改批量写入（§4.1）。
30. 播放页拆分：`PlayerController` 的细粒度通知（position / subtitle / stats 分开），把整页 `setState` 收窄到具体部件（§4.2）。
31. 目录派生列表缓存（§4.3）。
32. 缩略图内存缓存加 LRU 上限并 `dispose`（§4.4）。

### 第四批：架构债务

33. 源文件清单收敛到单一来源（例如 `native/sources.cmake` 供三处 `include`）。
34. 传输层改成注册表，新增源类型只改注册点。
35. `native/CMakeLists.txt` 补 win32 分支，取消 Windows 双轨制。
36. `packages/lanplayer_video` 真正承载跨平台纹理 API，三份平台实现改为它的实现。
37. `models.dart` 按职责拆分（媒体模型 / 播放设置 / 目录视图 / 字幕模型）。
38. 补 macOS 桌面 CI job；Android 升 AGP 8.6+ 并做 16 KB 页对齐。
39. 补 `lp_map.txt` 与头文件的符号一致性检查；把字符串存在性断言换成行为断言。

---

## 9. 结语

这套代码的设计水平在同类项目里属于上游：ABI 的克制、线程模型的清晰、降级路径的完整、静态检查与注释里沉淀的历史坑，都不是「从头写一遍」能轻易复制的。问题集中在两类地方——**跨层的状态传递没有闭环**（错误码、字幕延迟、媒体状态、事件常量），以及**构建与平台抽象的重复实现**（源文件清单、纹理通道、Windows 双轨制）。

P0 那五条里有四条（缺 DLL、缺符号、缺锁、缺重启）本质上是同一个问题的不同侧面：**某个环节正确地做了取舍，但没有在这个环节之外留下可验证的接口**。补上这些接口的成本远低于它们的破坏力，建议按第 8 节的批次顺序推进。
