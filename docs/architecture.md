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
diff > 0         → 睡 min(diff, 20ms) 后重试（上限 20ms 保证暂停/seek 响应）
diff <= 0        → 立即显示
diff < -250ms    → 判定迟到，丢帧（仍然 present，保证硬解缓冲区回收）
```

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

## 7. 视频输出两条路

**Android**：Kotlin 用 `TextureRegistry.createSurfaceTexture()` 拿 `SurfaceTexture`，
包成 `Surface`，通过 JNI `ANativeWindow_fromSurface` 得到 `ANativeWindow*`，把指针经
MethodChannel 交给 Dart，再 `lp_player_set_surface(ptr)`。

* 硬解：MediaCodec `configure(surface=…)`，输出缓冲索引按 pts 排队，
  到点后 `AMediaCodec_releaseOutputBuffer(index, render=true)` —— 零拷贝，GPU 直接上屏。
* 软解：EGL + GLES2，Y/U/V 三平面上传，片元着色器做 BT.601 有限范围 → RGB 转换，
  顶点坐标按 `scale_mode` 计算（适应/铺满/拉伸）。

**Apple**：Swift 持有 `FlutterTexture`，`copyPixelBuffer()` 调
`lp_player_copy_pixel_buffer()` 取一个 +1 的 `CVPixelBufferRef`（IOSurface 支撑，
Flutter 直接消费，无拷贝）。内核解出帧后 `lp_render_publish_pixel_buffer` 保存并回调，
Swift 切到主线程 `textureFrameAvailable`。

**桌面/CI**：`platform/stub` 提供空渲染 + 空音频设备，但音频设备线程真实按 10 ms 拉取，
所以主时钟、同步、字幕时序都能在没有设备的机器上跑通（`native/tests/lp_smoke_test.c`）。
Windows 上线程原语由 `platform/desktop/win32_pthread.h` 提供（SRWLOCK/CONDITION_VARIABLE），
因此同一份内核源码在 Windows x64 实测可编译、可播放（见 docs/build.md §0.5）。

## 8. 字幕

* 内嵌文本字幕：demux 线程把字幕包交给 `lp_subtitle_feed_packet`，libavcodec 解出
  ASS 行，复用 ASS 解析器提取起止时间与文本。
* 外挂字幕：`lp_subtitle_add_file` 通过 `LpIo` **直接读 SMB 上的文件**，不落地临时文件。
  编码识别顺序：UTF-8 BOM → UTF-16 BOM → 合法 UTF-8 → GB18030（iconv）→ 原样标记告警。
* 渲染在 Flutter：内核只发 `{text,start,end,style}`，UI 用 `Text` + 阴影描边绘制，
  任意分辨率清晰、跟随系统字号，且不额外占一张纹理。图形字幕（PGS/VobSub）当前跳过。

## 9. 失败降级

| 场景 | 行为 |
|------|------|
| 硬解初始化失败（不支持/无 surface） | 打日志 + `LP_EVENT_STATS{fallback_from}`，自动切软解 |
| 硬解运行中报错 | 上报 `LP_EVENT_ERROR`，置 `draining`，不会死锁 |
| 音频设备打不开 | 音频流水线失败但视频继续，主时钟退化到 `extc` |
| 字幕解析失败 | `LP_ERR_UNSUPPORTED`，UI 提示编码问题，不影响播放 |
| SMB 认证失败 | `LP_ERR_AUTH` + `lp_source_last_error` 文本，UI 直接显示 |
