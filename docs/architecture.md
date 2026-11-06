# 架构与线程模型

## 1. 分层

```
Dart UI ──► PlayerController ──► dart:ffi ──► lp_player_*   （唯一 ABI 契约）
                                               │
                            ┌──────────────────┴───────────────────┐
                            │              LpPlayer                │
                            │  demux 线程（独占 AVFormatContext）   │
                            │  视频解码线程   音频解码线程    tick 线程 │
                            └──────────────────┬───────────────────┘
                                               │
                        LpSource（libsmb2 / file / tcp…）→ 自定义 AVIOContext
```

设计原则：

1. **ABI 只用标量与 JSON**。不传结构体、不传回调结构体指针，因此 FFmpeg/NDK 升级不会
   破坏 Dart 绑定；`lp_abi_version()` 在 Dart 侧断言。
2. **谁创建谁释放**。`lp_*` 返回的字符串由调用方 `lp_string_free`；事件回调里的 JSON
   由内核分配、宿主释放（见 §6）。
3. **平台层只做“输出”**。解码策略、同步、字幕解析都在跨平台代码里，平台文件只负责
   “把帧送到屏幕 / 把 PCM 送到扬声器”。
4. **配置读取不挡第一帧**。`main()` 只读 `LANPLAYER_STATE_DIR` 就 `runApp`，四个 store
   的加载放到 `SplashGate` 背后并行进行：首页从第一帧就挂在栈底，图标动画盖在上面，
   加载完再淡出（`app/lib/ui/splash_gate.dart`）。移动端默认开启，桌面端默认关闭
   （窗口已经出现，不需要遮罩），`LANPLAYER_SPLASH=1/0` 可强制。三端的原生启动画面
   （iOS `LaunchScreen.storyboard`、Android `launch_background.xml` 与 Android 12 的
   `windowSplashScreen*`）用同一个深色底与同一个图标，避免 Dart 起来之前闪白。
5. **界面字形只有一个来源**。`LanPlayerTheme` 设全局 `fontFamily: 'MiSans'`，
   字体是随包分发的可变字体 `app/assets/fonts/MiSansVF.ttf`。界面代码里不再出现
   `monospace` / `Courier` / `Consolas` 这类写死的等宽家族——时间码与统计数字要对齐
   时用 `FontFeature.tabularFigures()`，而不是换字体。字幕例外：字幕的字族来自 ASS
   的 `Fontname` / `\fn`，属于内容而不是界面。
6. **配色是用户的设置，不是编译期常量**。`LanPlayerTheme.light()` / `dark()` 给出两套
   完整的 `ThemeData`，用哪一套由 `ThemeController`（`ValueNotifier<AppThemeMode>`）
   决定：默认黑色，可选白色或跟随系统，选择存进 `settings.json` 的 `theme_mode`。
   `main.dart` 用 `ValueListenableBuilder<AppThemeMode>` 订阅它——改配色只重建
   `MaterialApp` 那一层，不会把播放页一起重排。
7. **数据模型按职责分文件，出口只有一个**。`app/lib/data/models.dart` 只做转发，
   定义落在四个文件里：`playback_settings.dart`（播放态与持久化偏好）、
   `media_models.dart`（服务器、目录项、流信息与媒体信息）、`directory_view.dart`
   （`DirectoryListing` 与目录页的派生列表）、`subtitle_models.dart`（解析后的字幕
   行、样式与动画）。调用方仍然只 import `models.dart`，改一处职责不会牵动全仓。
8. **设置页的每一格目录对应一个决策，而不是一份控件清单**。一次只构建一格，
   所以「怎么放」相关的三件事（步长、默认倍速、连播）合在「播放」页里，而不是
   按历史上先写哪个控件分三格存放。字号、延迟这类离散量用下拉而不是滑杆：
   滑杆能拖出 1.37 这种值，既不可复述也不可比对。
9. **屏幕方向是播放态的一部分，不是界面的常量**。手机 / 平板进播放页锁横屏、
   退出时把四个方向一起交还（`app/lib/ui/playback_orientation.dart`），桌面端
   永远不锁。判定收在三个纯函数里，`player_screen.dart` 只负责在 `initState` /
   `dispose` 调用它们；纹理尺寸也按物理长 / 短边算，因为 `_bootstrap()` 跑在
   旋转真正落地之前，照着那一刻的竖屏窗口建纹理会让硬解一直往竖缓冲区里画。
   另外「跟着机身翻」和「窗口是横的」不是一件事，而且两个移动平台卡在不同
   的地方，所以除了框架那次调用，宿主还要各自补一半（通道方法 `lockLandscape`）：
   Android 上 Flutter 把 `[landscapeLeft, landscapeRight]` 翻成
   `SCREEN_ORIENTATION_FULL_USER`，仍受系统「自动旋转」开关支配，宿主改切只听
   加速度计与陀螺仪的 `SCREEN_ORIENTATION_SENSOR_LANDSCAPE`；iPad 上框架那次
   调用**根本不生效**（Flutter 文档写明要在关掉多任务时才会被尊重，而 iPadOS 26
   起 `UIRequiresFullScreen` 也已被忽略），宿主改发
   `requestGeometryUpdate(.iOS(interfaceOrientations:))`。两处都靠
   `tool/check_all.py` 钉住。
10. **同一块画面上的同一个手势，不同宿主可以有不同含义，但必须只有一处判定**。
    播放页的单击在鼠标宿主（Windows / macOS）上是播放暂停，在触屏宿主上是
    「显示 / 隐藏控制栏」（`app/lib/ui/pointer_input.dart` 的 `surfaceTapAction`）。
    两种设计各有其理：桌面端控制栏跟着鼠标移动自己会回来，点一下的意图是暂停；
    触屏上控制栏收起后没有别的入口，点一下必须先把它叫出来。判定写成纯函数而不是
    让 `player_screen.dart` 自己 `Platform.isX` 分支，是因为「哪台机器该做哪件事」
    要能被测试单独钉住；设置页那份手势说明也走同一张表
    （`PointerGesture.forHost`），避免在平板上写着鼠标的操作。
11. **「设置里的默认值」和「这一次的临时调整」是两件事，不能共用一个字段**。
    设置 → 音频 里的「音量增益」（0.1x–2.0x，1.0x = 跟随系统音量）只在开片时
    套一次，`PlayerController.open` 把它送进内核的 `volume` 选项，内核乘在解码
    出的 PCM 上；播放页里的滑杆、滚轮、上下键只改这一次播放的增益，不写回
    `SettingsStore`。早先两者是同一个值，结果是「我刚才嫌吵调小了」会悄悄变成
    「以后每一片都这么小声」，而用户没有任何地方能看到这个副作用。
    `tool/check_all.py` 的 `check_volume_gain` 直接从源码里找
    `_settings.volume =` / `SettingsStore.instance.value.volume =`，出现即报错。

## 2. 线程

| 线程 | 归属 | 职责 | 阻塞点 |
|------|------|------|--------|
| open worker | `lp_player_open` 启动 | 建立连接、`avformat_open_input`、`find_stream_info`、拉起解码线程 | SMB 连接、探测（可用 abort 打断） |
| demux | `demux.c` | `av_read_frame` 分发到三条包队列；执行 seek；EOF 广播 | 包队列满（背压）、网络读 |
| video | `video.c` | 解码一帧 → 等主时钟 → 呈现 → 再解码 | 时钟排期（5–10 ms 粒度睡眠） |
| audio | `audio.c` | 解码 → swr → atempo → 写环形缓冲 | 环形缓冲满（背压） |
| tick | `player.c` | 20 ms 心跳：位置事件 / 字幕切换 / 统计 / 结束判定 | `av_usleep` |
| 音频设备线程 | AAudio / AudioQueue | 拉取 PCM，推进音频时钟 | 实时回调 |

**唯一持有 `AVFormatContext` 的是 demux 线程**，seek 通过 `seek_req/seek_target_us`
原子标志请求，由 demux 线程真正执行。这样就不需要在 UI 线程加锁访问 libavformat。

## 3. 主时钟与 A/V 同步

音频是主时钟：

* 环形缓冲为每段写入的 PCM 记录一个标记 `{播放头采样号, 该采样对应的媒体时间, 速率比}`。
* 设备回调取走 `n` 帧后，播放头前进 `n`，于是
  `clock = marker.pts + (playhead - marker.sample) / sample_rate * scale`。
* `scale` 是倍速因子：atempo 把 2 秒内容压成 1 秒输出，播放头每前进 1 秒输出，
  媒体时间就前进 `speed` 秒——所以 `scale = speed`，倍速下位置与字幕依然对齐。
* 采样率用源采样率（8k–192k），输出固定 float32 立体声，swr 负责重采样与下混。

视频排期（`video.c::wait_for_presentation`）：

```
diff = frame_pts - master_clock
diff > 0         → 睡 min(diff, 10ms) 后重试（上限 10ms 保证暂停/seek 响应）
diff <= 0        → 立即显示
diff < -250ms    → 判定迟到，丢帧（仍然 present，保证硬解缓冲区回收）
```

上面三条是软解的原则。硬解路径在这之上还有两条修正，都是实测逼出来的：

**丢帧阈值放宽到 500 ms**。硬解有固有的管线延迟——帧要等解码器吐出来才能上屏，
VideoToolbox 在 1080p H.264 上稳定落后主时钟 200–300 ms（`av_diff` 长期停在
-196 ~ -336 ms）。这是延迟，不是「跟不上」，按 250 ms 丢会把正常出帧当落后丢掉，
实测 30 秒丢 127 帧。放宽到 500 ms 仍拦得住真正跟不上的情况（软解来不及、机器太慢）。

**落后时的「追赶」是温和的，不是 0.7 倍**。VideoToolbox 一次吐一批帧，一批在几毫秒
内接连上屏、然后线程干等下一批——平均帧率看着是 24，观感却「一顿一冲」。所以落后时
要把出帧间距摊平。这里踩过一个坑：早先的实现是「落后超过 120 ms 就把间距压到周期的
0.7 倍」，而硬解的 `av_diff` 常年就在 -145 ~ -310 ms，几乎每秒都越过阈值，内核于是以
约 1.43 倍速度去要还没解出来的帧，把缓冲抽干后只能干等——反而制造了 88–231 ms 的
单帧最长间隔。现在的规则是只把超出阈值的部分摊 15% 到每帧，且间距有周期 85% 的下限：

```
diff < 0 且 -diff > LP_PACE_CATCHUP_US(120ms)
  → spacing = period - (lag - 120ms) * 15%
  → 下限 max(spacing, period * 85%)
```

下限同时挡住「越落后越快」的正反馈。改完 24 fps 片源在 macOS 与 iPad 上 `dropped`
均为 0，单帧最长间隔 46–75 ms / 43–49 ms，贴近 41.67 ms 的帧周期本身。**往这个函数里
加阈值之前，先确认 `av_diff` 的负值到底是「内容超速」还是「管线延迟」——两者看起来
一模一样，处置却相反。**

暂停时时钟冻结（`lp_clock_pause` + 音频环暂停），视频线程原地等待而不是丢帧。

纯视频（无音轨）时主时钟退化为 `extc`：由 wall clock × speed 推进，seek/暂停/变速时
重置漂移量，因此不需要音轨也能正常计时。

## 4. Seek 与 serial

`p->serial` 是“媒体代次”，每次 seek 自增。

1. UI 线程 `lp_request_seek(us)` 设置目标并置位 `seek_req`。
2. demux 线程执行 `avformat_seek_file`，清空三条队列与音频环，把时钟设到目标位置。
3. 解码线程每轮循环检查 `serial`，发现变化就 `avcodec_flush_buffers` /
   `AMediaCodec_flush` / `VTDecompressionSession` 清队列，丢弃旧帧。
4. 排期函数发现 `serial` 不匹配直接返回中断，避免 seek 后闪现旧画面。

## 5. 背压与缓冲

* 视频包队列上限 256 MiB、音频 128 MiB；`lp_pq_put` 在队列满时阻塞 demux 线程，
  因此内存恒定，且天然把“读得太快”压回磁盘/网络速度。
* 音频环形缓冲默认 120 ms，满则阻塞解码线程。
* 视频没有帧队列：解码与呈现同线程，“只比屏幕快一帧”，这正是硬解解码器想要的节奏。
* `LP_EVENT_BUFFERING` 在 seek 与队列枯竭时上报，UI 显示转圈。

## 6. 事件契约

```c
typedef void (*LpEventCallback)(void *user, int32_t event, const char *json, int64_t value);
```

* `json` 是**内核 malloc 的字符串，所有权交给宿主**，宿主必须 `lp_string_free`。
  原因：Dart 的 `NativeCallable.listener` 在 isolate 事件循环里异步执行，回调返回时
  原生栈帧早已销毁，栈上的字符串会变成野指针。
* Dart 侧 `PlayerController._handleEvent` 先 `toDartString()` 再释放，随即解析 JSON。
* 事件类型见 `lp_types.h` 的 `LpEvent`：STATE / POSITION / MEDIA_INFO / ERROR / ENDED /
  SUBTITLE / STATS / LOG / BUFFERING / TRACKS。

## 7. 视频输出

画面怎么到屏幕，**桌面与移动端是两条路**。原因在引擎侧：只要存在活跃的外部纹理，
Flutter 就会在每个 vsync 上重绘整棵图层树，与视频帧率无关
（`flutter/flutter#188616`、`#192181`，维护者不打算暴露
`CADisplayLink.preferredFrameRateRange` 之类的节拍控制）。桌面端不走那条被动的采样
路径，所以留在纹理上；移动端把这块矩形交给原生视图，退出引擎的合成循环。

### 移动端：平台视图

**Android**：`app/android/app/src/main/kotlin/dev/lanplayer/app/VideoSurfaceView.kt`
是一个 `PlatformView`，内含一块 `SurfaceView`。`attach()` 先
`nativeCreateWindow(surface)`（JNI 里就是 `ANativeWindow_fromSurface`）拿到
`ANativeWindow*`，再 `lp_player_set_surface`；`detach()` 顺序相反 —— 先
`lp_player_set_surface(0)` 再释放窗口，反了就是 use-after-free。
`createTexture` 回 `{textureId: -1, window: 0, platformView: true}`。

* 硬解：MediaCodec `configure(surface=…)`，输出缓冲索引按 pts 排队，
  到点后 `AMediaCodec_releaseOutputBuffer(index, render=true)` —— 零拷贝，GPU 直接上屏。
* 软解：EGL + GLES2，Y/U/V 三平面上传，片元着色器做 BT.601 有限范围 → RGB 转换，
  顶点坐标按 `scale_mode` 计算（适应/铺满/拉伸）。

**iOS / iPadOS**：`app/ios/Runner/VideoPlatformView.swift` 是一个
`layerClass = AVSampleBufferDisplayLayer.self` 的 `UIView`。`VideoFrameBridge`
自己装 `lp_player_install_frame_callback`，回调里把内核发布的 `CVPixelBuffer`
（IOSurface 支撑）用 `CMSampleBufferCreateReadyWithImageBuffer` 包成 `CMSampleBuffer`
再 enqueue。两个必须知道的约束：

* 内核的帧回调**只有一个槽**（`p->vout.frame_cb` 单字段赋值，后装覆盖先装），
  所以 iOS 删掉了 `PlayerTexture`，纹理与平台视图不能并存。
* 内核不暴露 PTS。宿主用 `kCMSampleAttachmentKey_DisplayImmediately` 加自增的
  `frameIndex` 伪造时间戳；不设这个附件，layer 会按假 PTS 排队而卡住。
* API 分叉：iOS 17+ 走 `layer.sampleBufferRenderer.enqueue`，15/16 走
  `layer.enqueue`（layer 上那批方法 iOS 18 起全部弃用，且非主线程不安全）。

### 桌面端：外部纹理

**Windows**：走我方插件 `packages/lanplayer_video/`，`VideoTexture::Copy()` 把内核
解码得到的 D3D11 纹理经视频处理器转成 BGRA，写进共享纹理后交给引擎
`GpuSurfaceTexture(kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle)` 直接采样；没有 GPU
直出能力的主机（原生预览器）才走 `lp_win32_gpu_readback` 回读。

**macOS**：`app/macos/Runner/MainFlutterWindow.swift` 的 `PlayerTexture` 实现
`FlutterTexture`，`copyPixelBuffer()` 调 `lp_player_copy_pixel_buffer()` 取一个 +1 的
`CVPixelBufferRef`（IOSurface 支撑，引擎直接消费，无拷贝）。内核解出帧后
`lp_render_publish_pixel_buffer` 保存并回调，Swift 在**内核解码线程上直接**调
`textureFrameAvailable`。

最后这一点是本项目修过的一个卡顿根因：以前这一步绕了
`DispatchQueue.main.async`，等于给每一帧加了整整一个主线程 runloop 的延迟，主线程一忙
内核就已经把单槽缓冲换成下一帧，于是画面跳帧而音频正常。**不能用主线程转发了事。**

### 两条路共用的部分

* 画面怎么贴合窗口由 `app/lib/ui/widgets/video_surface.dart` 决定。纹理路径把帧排进
  一个虚拟盒子（`1000` 逻辑像素高）再 `FittedBox`，这对纹理无害 —— 纹理只是把位图画进
  目标矩形。平台视图不行：原生视图的**布局尺寸就是系统分配图形缓冲的尺寸**，所以它
  走 `fittedSize()` 手算目标矩形（stretch 取满、fill 取较大边、默认取较小边），
  再用 `OverflowBox` 放开四个边界。按虚拟盒子布局会让系统分配一块比屏幕还大的缓冲：
  实测过 5777×3250 / 约 72.5 MiB 一块，三缓冲约 218 MiB，而修好后是 2133×1200。
* 旋转不需要原生侧额外处理。平台视图那一层确实不带变换矩阵
  （`PlatformViewLayer.addToScene` 只交 `offset` 和宽高），但旋转发生在 `SceneBuilder`
  的父层，整棵子树（含原生视图的宿主层）一起被变换 —— 竖拍片源实测过。
* 移动端渲染路径不再参与 Flutter 的透明度、非矩形裁剪等效果。

**无窗口（自动检查用）**：`platform/stub` 提供空渲染 + 空音频设备，但音频设备线程真实按 10 ms 拉取，
所以主时钟、同步、字幕时序都能在没有设备的机器上跑通（`native/tests/lp_smoke_test.c`）。
Windows 上线程原语由 `platform/desktop/win32_pthread.h` 提供（SRWLOCK/CONDITION_VARIABLE），
因此同一份内核源码在 Windows x64 可编译、可播放（见 docs/build.md §0.5）。

## 8. 字幕

* 内嵌文本字幕：demux 线程把字幕包交给 `lp_subtitle_feed_packet`，libavcodec 解出
  ASS 行，复用 ASS 解析器提取起止时间与文本。
* 外挂字幕：`lp_subtitle_add_file` 通过 `LpIo` **直接读 SMB 上的文件**，不落地临时文件。
  编码识别顺序：UTF-8 BOM → UTF-16 BOM → 合法 UTF-8 → GB18030（iconv）→ 原样标记告警。
* 渲染在 Flutter：内核只发 `{text,start,end,style,runs,now}`，UI 用 `Text` + 阴影描边绘制，
  任意分辨率清晰、跟随系统字号，且不额外占一张纹理。图形字幕（PGS/VobSub）由内核在
  CPU 上混合进画面。
* 富文本与特效都在内核解析、宿主解算：每个 run 带自己的字体/颜色/描边/字号/缩放的
  同时，还带 `anims`（`\t` 的窗口与目标字段）、`clip`（`\clip` 矩形）、`path`（`\p`
  路径点列）与卡拉 OK 时间片。事件里的 `now` 是「这条字幕已经过去多久」，宿主据此
  在 `app/lib/data/subtitle_anim.dart` 里插值出当前帧的样子；带特效的字幕由 tick
  线程每 20 ms 重发一次。
* 只有矢量图形、没有文字的 Dialogue 也算有效字幕（wipe 揭示、无字版式）。

## 9. 失败降级

| 场景 | 行为 |
|------|------|
| 硬解初始化失败（不支持/无 surface） | 打日志 + `LP_EVENT_STATS{fallback_from}`，自动切软解 |
| 硬解运行中报错 | 上报 `LP_EVENT_ERROR`，置 `draining`，不会死锁 |
| 音频设备打不开 | 音频流水线失败但视频继续，主时钟退化到 `extc` |
| 字幕解析失败 | `LP_ERR_UNSUPPORTED`，UI 提示编码问题，不影响播放 |
| SMB 认证失败 | `LP_ERR_AUTH` + `lp_source_last_error` 文本，UI 直接显示 |
