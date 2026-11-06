/*
 * LanPlayer native core - internal structure shared by the core sources.
 *
 * Layout of the pipeline:
 *
 *   LpSource -> AVIOContext -> demux thread -> [video|audio|subtitle] packet
 *   queues -> decoder threads -> frame queue / PCM ring -> sinks
 *
 * The demux thread is the only owner of AVFormatContext; a seek is requested
 * from the UI thread and executed there, which is why every queue carries a
 * `serial` that is bumped on seek so that stale frames can be dropped.
 */
#ifndef LANPLAYER_PLAYER_INTERNAL_H
#define LANPLAYER_PLAYER_INTERNAL_H

#include <ctype.h>
#include <errno.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/time.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

/* Threads: real pthreads on Android/iOS/macOS/Linux, a small Win32 mapping for
 * native Windows builds (see platform/desktop/win32_pthread.h). */
#if defined(_WIN32) && !defined(LP_HAVE_PTHREAD)
#include "platform/desktop/win32_pthread.h"
#else
#include <pthread.h>
#endif

#include "lanplayer/lp_log.h"
#include "lanplayer/lp_player.h"
#include "lanplayer/lp_source.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 预读窗口。以前两个队列分别给 256 MB 与 128 MB，而背压条件是
 * 「超过 8 个包且填满容量」（queue.c），也就是最多能堆到 384 MB ——
 * 移动端有真实的 OOM 风险，而这么深的缓冲对局域网播放毫无收益：
 * 20 Mbps 的片源，24 MB 已经是 10 秒的预读量。取 24 MB / 12 MB 作为
 * 码率未知时的缺省；码率读得出来就按下面的秒数折算。 */
#define LP_MAX_PACKET_BYTES (24 * 1024 * 1024)
#define LP_AUDIO_PACKET_BYTES (12 * 1024 * 1024)
/* 预读按时间算，不按字节算：同样是 24 MB，对 4 Mbps 的老片是 48 秒
 * （远超需要），对 80 Mbps 的蓝光是 2.4 秒（不够）。开片后按码率折算一次。 */
#define LP_READAHEAD_SECONDS 8
/* 折算的上下限。下限保证低码率片源也有足够深的缓冲吸收 SMB 抖动；
 * 上限就是上面的缺省值，别让高码率把内存吃回去。 */
#define LP_MIN_PACKET_BYTES (4 * 1024 * 1024)
/* 单包上限：一个包超过它就说明解复用给出的尺寸不可信，直接拒绝，
 * 不要拿着它去 malloc。 */
#define LP_MAX_SINGLE_PACKET_BYTES (16 * 1024 * 1024)
/* 倍速的可用区间。上限来自 atempo 与时钟倍率的共同适用性，下限来自界面
 * 那个 0.25 档 —— 定成 0.5 的时候界面能选到 0.25、内核却悄悄钳回 0.5，
 * 表现出来就是「这一档和 0.5 一模一样」。 */
#define LP_SPEED_MIN 0.25
#define LP_SPEED_MAX 2.0
#define LP_DEFAULT_AUDIO_LATENCY_MS 120
/* 音频主时钟连续这么久不前进，就认为它不会自己恢复了（环空、声卡没在
 * 消费、或者解码线程被网络卡住），改用墙钟推着画面走。 */
#define LP_AUDIO_CLOCK_STALL_US 400000
#define LP_POSITION_INTERVAL_US 200000
#define LP_TICK_INTERVAL_US 20000
#define LP_STATS_INTERVAL_US 1000000
#define LP_MAX_SUBTITLE_TRACKS 16
#define LP_MAX_EXTERNAL_SUBS 8
#define LP_MAX_TEXT_BYTES 8192

#define LP_TIME_BASE 1000000.0 /* microseconds per second */

/* ------------------------------------------------------------------ util */

typedef struct LpStr {
    char *p;
    size_t len;
    size_t cap;
} LpStr;

void lp_str_init(LpStr *s);
void lp_str_free(LpStr *s);
void lp_str_reset(LpStr *s);
void lp_str_append(LpStr *s, const char *fmt, ...);
void lp_str_append_raw(LpStr *s, const char *v, size_t n); /* no formatting */
void lp_str_append_json_str(LpStr *s, const char *v); /* NULL -> "" */
char *lp_str_take(LpStr *s);                          /* ownership moves out */
char *lp_str_dup(const char *v);
char *lp_str_printf(const char *fmt, ...);

/* Copies `url` into `out` with the userinfo part replaced by three asterisks,
 * so the result is safe to write to a log.  For example a URL whose authority
 * is `user:pass@host` becomes one whose authority is `***@host`; a URL without
 * an `@` in its authority is copied unchanged.  `out` is always NUL terminated
 * when outlen > 0. */
void lp_url_redact(const char *url, char *out, size_t outlen);

/* Minimal flat JSON reader for option objects (no nesting except arrays of
 * strings).  Returns 0 on success, -1 when the key is absent. */
int lp_json_get_str(const char *json, const char *key, char *out, size_t outlen);
int lp_json_get_int(const char *json, const char *key, int64_t *out);
int lp_json_get_bool(const char *json, const char *key, int *out);
/* Fills `out` with up to `max` strings; caller frees each with free(). */
int lp_json_get_string_array(const char *json, const char *key, char **out, int max);
/* Collects every string value stored under key (any nesting depth). */
int lp_json_collect_strings(const char *json, const char *key, char **out, int max);

/* ----------------------------------------------------------------- clock */

typedef struct LpClock {
    double pts;         /* last set position, in media seconds */
    double pts_drift;   /* pts - wall at the moment it was set */
    double last_updated;
    double speed;
    int serial;
    int paused;
    pthread_mutex_t mutex;
} LpClock;

void lp_clock_init(LpClock *c);
void lp_clock_destroy(LpClock *c);
void lp_clock_set(LpClock *c, double pts_seconds, int serial);
void lp_clock_set_speed(LpClock *c, double speed);
double lp_clock_get(LpClock *c);
double lp_clock_get_raw(LpClock *c);
void lp_clock_sync(LpClock *c, double pts_seconds); /* gentle drift correction */
void lp_clock_pause(LpClock *c, int paused);

/* ---------------------------------------------------------------- queues */

typedef struct LpPacketNode {
    AVPacket *pkt;
    struct LpPacketNode *next;
} LpPacketNode;

typedef struct LpPacketQueue {
    LpPacketNode *head;
    LpPacketNode *tail;
    int nb_packets;
    int64_t bytes;
    int64_t max_bytes;
    int abort_request;
    int eof;
    int serial;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
} LpPacketQueue;

void lp_pq_init(LpPacketQueue *q, int64_t max_bytes);
/* 改预读窗口。码率要等 find_stream_info 之后才知道，所以窗口不能只在
 * init 时定；已经在队里的包不受影响，只是背压阈值换了。 */
void lp_pq_resize(LpPacketQueue *q, int64_t max_bytes);
void lp_pq_destroy(LpPacketQueue *q);
void lp_pq_flush(LpPacketQueue *q);
void lp_pq_abort(LpPacketQueue *q);
void lp_pq_start(LpPacketQueue *q);
/* Takes ownership of `pkt` (refcounted).  Returns 0 or LP_ERR_IO on abort. */
int lp_pq_put(LpPacketQueue *q, AVPacket *pkt, int serial);
/* Blocking unless `block` is 0.  Returns NULL on abort/EOF-empty. */
AVPacket *lp_pq_get(LpPacketQueue *q, int *serial, int block);
/* 解码线程没拿到包时用这个睡，不要 av_usleep 轮询：每 2 ms 醒一次意味着每秒
 * 500 次加解锁，而且 queue.c 里那条 pthread_cond_wait 永远走不到。这里在条件
 * 变量上等，put/abort/flush/signal_eof 都会立刻唤醒；`timeout_ms` 只是兜底，
 * 防止某个分支漏了广播就把线程睡死。返回后调用方应当直接重试 lp_pq_get。 */
void lp_pq_wait_more(LpPacketQueue *q, int timeout_ms);
void lp_pq_signal_eof(LpPacketQueue *q, int serial);
int lp_pq_size(LpPacketQueue *q);
int lp_pq_eof(LpPacketQueue *q);
/* 1 = 队列已被 abort（停止或切轨），解码线程必须立刻退出，不能再等 eof。 */
int lp_pq_aborted(LpPacketQueue *q);

/* ---------------------------------------------------------- nal framing */

/* 1 = 这个包是 Annex-B（00 00 01 起始码分隔的 NAL），0 = 长度前缀（AVCC/HVCC）。
 * 只看包头会误判：长度前缀包里第一个 NAL 的长度字段可能正好长得像起始码，
 * 所以这里会验证整条长度链是否恰好走完整个包；详见 src/core/nal.c 的注释。 */
int lp_nal_is_annexb(const uint8_t *data, size_t size);
/* 从 start 处那个 NAL 的载荷字节数；格式不合法时返回 0。 */
size_t lp_nal_payload_len(const uint8_t *data, size_t size, size_t start);
/* AVCC（4 字节长度前缀）转 Annex-B（00 00 00 01 起始码）。返回写入字节数，
 * 0 表示源不是合法的长度链或 cap 不够。MediaCodec 只吃后者。 */
size_t lp_nal_avcc_to_annexb(const uint8_t *src, size_t size, uint8_t *dst, size_t cap);
/* 反方向：Annex-B 转 AVCC。VideoToolbox 只吃后者。3 字节起始码换成 4 字节
 * 长度，所以 dst 要比源略大（size + size/3 + 8 一定够）。返回 0 表示源里
 * 一个起始码都没有。 */
size_t lp_nal_annexb_to_avcc(const uint8_t *src, size_t size, uint8_t *dst, size_t cap);
/* 硬解不该接的 profile：10-bit / 4:2:2 / 4:4:4 的 H.264 在三个平台上都会
 * 「接了但解不动」，HEVC 只有 Apple 与 Android 有问题，D3D11VA 能正常解，
 * 所以 `refuse_hevc` 由调用方决定。放在这里而不是各平台各抄一份，是因为
 * 三份手抄件已经飘移过一次（Windows 抄错成连 8-bit 也拒）。 */
int lp_hw_profile_needs_software(int codec_id, int profile, int refuse_hevc);

/* ------------------------------------------------------------ audio ring */

typedef struct LpAudioMarker {
    int64_t sample;      /* ring play head sample index of the chunk start */
    double pts_seconds;  /* media (content) time of that sample */
    double scale;        /* content seconds per output second (speed factor) */
} LpAudioMarker;

#define LP_AUDIO_MARKERS 64

typedef struct LpAudioRing {
    float *buf; /* interleaved float32, capacity_frames * channels */
    int channels;
    int capacity_frames;
    int read_pos;
    int write_pos;
    int count; /* frames currently buffered */
    int abort_request;
    int paused;
    int flushing;
    int sample_rate;
    double gain;
    int64_t sample_index;      /* frames pulled by the sink since start */
    LpAudioMarker markers[LP_AUDIO_MARKERS];
    int marker_count;
    int marker_head;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
} LpAudioRing;

/* 锁与条件变量随播放器对象建/毁（setup/teardown），缓冲区本身随开片关片
 * 分配/释放（init/destroy）。分开是因为 tick 线程会一直读环形缓冲区的时钟，
 * 关片时毁掉锁会让它撞上 destroyed mutex 直接 abort。 */
void lp_ring_setup(LpAudioRing *r);
void lp_ring_teardown(LpAudioRing *r);
int lp_ring_init(LpAudioRing *r, int channels, int sample_rate, int latency_ms);
void lp_ring_destroy(LpAudioRing *r);
void lp_ring_flush(LpAudioRing *r);
void lp_ring_abort(LpAudioRing *r);
void lp_ring_set_paused(LpAudioRing *r, int paused);
void lp_ring_set_gain(LpAudioRing *r, double gain);
/* Writes `frames`; blocks while full (respecting abort).  `chunk_pts_seconds`
 * is the media time of the first sample and `scale` the content/playback rate
 * ratio (1.0 at normal speed, `speed` when atempo stretched the audio).
 * Returns frames written or LP_ERR_INTERRUPTED. */
int lp_ring_write(LpAudioRing *r, const float *interleaved, int frames,
                  double chunk_pts_seconds, double scale);
/* Pull for the sink thread; zero fills the tail.  Returns frames read. */
int lp_ring_read(LpAudioRing *r, float *out, int frames);
double lp_ring_clock_seconds(LpAudioRing *r);
int lp_ring_buffered_ms(LpAudioRing *r, int sample_rate);

/* ------------------------------------------------------------ audio sink */

typedef struct LpAudioSink LpAudioSink;
struct LpPlayer;

LpAudioSink *lp_audio_sink_create(struct LpPlayer *p);
int lp_audio_sink_start(LpAudioSink *s, int sample_rate, int channels);
void lp_audio_sink_stop(LpAudioSink *s);
void lp_audio_sink_pause(LpAudioSink *s, int paused);
void lp_audio_sink_destroy(LpAudioSink *s);
int lp_audio_sink_latency_us(LpAudioSink *s);
const char *lp_audio_sink_name(LpAudioSink *s);
/* Implemented in audio.c, called from the sink's realtime thread. */
int lp_audio_pull_pcm(struct LpPlayer *p, float *out, int frames);

/* --------------------------------------------------------- hardware decode */

typedef enum LpDecodedKind {
    LP_DEC_SURFACE = 1,      /* Android: output buffer waiting for release */
    LP_DEC_PIXEL_BUFFER = 2, /* Apple: retained CVPixelBufferRef */
    LP_DEC_HW_FRAME = 3,     /* Windows: AVFrame still on the D3D11 device */
} LpDecodedKind;

typedef struct LpDecodedFrame {
    int64_t pts_us;
    void *handle;      /* kind specific */
    int index;         /* Android output buffer index */
    int kind;
    int width;
    int height;
} LpDecodedFrame;

typedef struct LpVideoDecoder LpVideoDecoder;
typedef struct LpVideoDecoderConfig {
    AVCodecParameters *par;
    enum AVCodecID codec_id;
    int width;
    int height;
    AVRational time_base;
    void *native_window; /* Android ANativeWindow*, may be NULL */
    void *player;        /* LpPlayer*, used by the Apple texture bridge */
} LpVideoDecoderConfig;

LpVideoDecoder *lp_hw_decoder_create(void);
int lp_hw_decoder_init(LpVideoDecoder *d, const LpVideoDecoderConfig *cfg, char *err, size_t errlen);
int lp_hw_decoder_available(void);
const char *lp_hw_decoder_name(void);
int lp_hw_decoder_send(LpVideoDecoder *d, const AVPacket *pkt);
/* 1 = 这个解码器是异步的，一帧进来不保证马上能取走，解完两三帧才一起交出来。
 *
 * VideoToolbox 与 MediaCodec 都是这样：喂一包进去，回调攒够了才让
 * lp_hw_decoder_receive 取到帧，于是视频线程拿到的是一批而不是匀速的一帧。
 * 只有这类解码器需要内核补最小间隔（见 video.c 的 wait_for_presentation）；
 * Windows 的 d3d11va 就是同步 avcodec_receive_frame，插等待只会让它掉队。 */
int lp_hw_decoder_is_async(LpVideoDecoder *d);
/* 0 = frame out, LP_ERR_AGAIN = more input needed, <0 fatal */
int lp_hw_decoder_receive(LpVideoDecoder *d, LpDecodedFrame *out);
/* 把这一帧送到屏幕上。
 *
 * 三个后端内部差别很大（Windows 是 GDI 缓冲或共享纹理、Apple 是发布
 * CVPixelBuffer 给纹理、Android 是把 buffer index 交回 codec 的 Surface），
 * 但对内核来说语义只有一条：**调用它就是让用户看到这一帧**。
 *
 * 由此派生两条铁律：
 *   1. 判定为应该丢弃的帧（迟到超过阈值、seek/stop 时作废的）一律走
 *      lp_hw_decoder_release，不能走这里 —— 否则「丢帧」会变成「多显示
 *      一帧」，落后量立刻回补、下一帧又被判晚到，形成丢一帧补一帧的脉冲。
 *   2. 图形字幕该不该先合进来，由内核判断（lp_render_graphics_sub_active），
 *      不能推给后端各自决定 —— 上一轮那样做，Android 与 Apple 就一起漏掉了。
 */
int lp_hw_decoder_present(LpVideoDecoder *d, LpDecodedFrame *f);

/* 图形字幕（PGS / VobSub / DVB）是 CPU 位图，只有 lp_sub_overlay_blend 会画，
 * 而它一直挂在 lp_render_draw 这条软解路径上。以前硬解这边直接上屏，屏幕上
 * 是解码器给的干净画面 —— 图形字幕永远不出现。Windows 之所以正常，是因为
 * d3d11va 后端在 lp_render_graphics_sub_active() 为真时自己退回下载路径，
 * 等于把这条约束写在了后端里。
 *
 * 这里把「谁来合字幕」收进内核：先问后端能不能把字幕合进这一帧并上屏。
 * 返回 LP_OK 表示已经显示过了，内核不要再调 present；返回 LP_ERR_UNSUPPORTED
 * 表示该后端拿不到像素（Android 的 Surface 输出就是），内核按原样上屏，
 * 并在第一次发生时记一条日志说明这条限制。 */
int lp_hw_decoder_present_with_subtitles(LpVideoDecoder *d, LpDecodedFrame *f);
/* 丢弃一帧：把解码器持有的资源还回去，但**不**上屏。
 * 同步解码器（d3d11va）的 present 本来就是「下载 + 交给上层」二合一，
 * 所以它的 release 只是 unref；异步解码器（VideoToolbox / MediaCodec）
 * 的 release 是把输出缓冲区直接交还，不渲染。 */
int lp_hw_decoder_release(LpVideoDecoder *d, LpDecodedFrame *f);
/* 解码器自己丢掉的帧数（只增不减，调用方按需取差）。
 *
 * 这些帧从来没交到内核手上：VideoToolbox 的 push_frame 在队列满时
 * 会顶掉最旧的一帧，MediaCodec 在 present 失败时会释放掉输出缓冲。
 * 它们既不计入 decoded 也不计入 dropped，光看那两个数会以为一帧
 * 都没丢 —— 上一轮排查 iPad 卡顿时正是被这一点带偏的。 */
int64_t lp_hw_decoder_frames_dropped(LpVideoDecoder *d);
void lp_hw_decoder_flush(LpVideoDecoder *d);
void lp_hw_decoder_destroy(LpVideoDecoder *d);

/* ------------------------------------------------------------- video out */

typedef enum LpVideoOutKind {
    LP_VOUT_NONE = 0,
    LP_VOUT_ANDROID_WINDOW = 1, /* surface, rendered by EGL or codec */
    LP_VOUT_APPLE_TEXTURE = 2,  /* CVPixelBuffer pulled by Flutter */
} LpVideoOutKind;

typedef struct LpVideoOut {
    LpVideoOutKind kind;
    void *window; /* ANativeWindow* */
    int window_w;
    int window_h;
    int frame_w;
    int frame_h;
    int scale_mode;
    LpFrameCallback frame_cb;
    void *frame_cb_user;
    void *pixel_buffer; /* retained CVPixelBufferRef of the latest frame */
    int has_new_frame;
    int64_t frames_published;
    /* 被宿主「跳过」的帧数，只有 Apple 平台会累加。
     *
     * Apple 这条路上「内核出帧」和「屏幕画出帧」是两件事：内核把最新一帧
     * 放进唯一的 pixel_buffer 槽，引擎什么时候来 copyPixelBuffer 才什么时候
     * 拿走；中间被顶掉的帧屏幕上永远看不到。解码和同步都按时做完了，所以
     * 原来的统计里这件事完全隐形（dropped 恒为 0、fps 满帧）——
     * 「音频正常、画面卡顿」因此一直查不出来。单独计数，
     * STATS 事件以 dropped_delivery 上报。桌面与 Android 恒为 0。 */
    int64_t frames_delivery_lost;
    /* 交付节奏的抖动，只有 Apple 平台会累加。
     *
     * 帧数与丢帧数都对不上卡顿的观感时，问题往往在「间隔不均」：
     * 一秒钟交出去 24 帧，但其中 20 帧挤在 200 ms 里、剩下 4 帧拖到另外
     * 800 ms，屏幕上看就是一跳一跳的，而 fps 统计显示 24、dropped 显示 0。
     * 这里记两件事：
     *   pull_gap_max_us——相邻两次取帧的最大间隔；
     *   pull_stall_count——间隔超过 1.5 个帧周期的次数。
     * 一秒钟里 stall_count 只要有 3，人眼就能看出来。
     *
     * 取帧是引擎按 vsync 来要的，所以 pull_gap 天生会被 vsync 量化
     * （60 Hz 上只会出现 50 / 66 / 83 ms 这种台阶）。要分清「解码吐得不均」
     * 与「引擎取帧对不齐」，还得单独量内核这边的送帧间隔：
     *   push_gap_max_us——相邻两次 publish 的最大间隔；
     *   push_gap_avg_us——本秒内所有 publish 间隔的均值。
     * 两个数都远小于 pull_gap、但画面仍然一顿一冲，问题就在引擎侧。 */
    int64_t pull_gap_max_us;
    int64_t pull_stall_count;
    int64_t last_pull_at_us;
    /* 引擎到底多久来取一次帧。
     *
     * pull_gap 只量「真的交出一帧」的那些调用，所以它天生被内核的出帧节奏
     * 限住：内核每秒给 24 帧，pull_gap 就不可能小于 41.7 ms，这时它反映的
     * 是内核不是引擎。要判断「引擎自己有没有掉队」，得数调用次数：
     *   pull_calls——本秒 copyPixelBuffer 被调了多少次（含返回 NULL 的）；
     *   pull_hits——其中真的拿到新帧的次数。
     * 60 Hz 屏正常应是 60 / 24，120 Hz ProMotion 是 120 / 24。如果
     * pull_calls 只有二三十，说明 raster 线程本身就在丢 vsync，
     * 那是引擎侧的事，改内核出帧节奏没有用。
     *   pull_null_run_max——连续空手而归的最长次数，等价于「画面上停住了
     * 多少个 vsync」，这才是用户眼里的卡顿。 */
    int64_t pull_calls;
    int64_t pull_hits;
    int64_t pull_null_run;
    int64_t pull_null_run_max;
    /* 帧「准备好了」到「被取走」之间的等待，本秒的最大与均值。
     *
     * 前面几个量都只看同向相邻的间隔：push_gap 是两次 publish 之间，
     * pull_gap 是两次 pull 之间。两者都可以完全正常，而整条流水线一直
     * 恒定晚几百毫秒——间隔不变，只是整体平移，所有指标照旧全绿。
     * 观感上「流畅一段、然后卡住一段」正是这种平移在来回摆：
     * 引擎这一秒追上了（等待 20 ms），下一秒又落后了（等待 400 ms），
     * 而 publish 与 pull 各自的间隔始终均匀。
     * 所以这里记的是**跨方向**的一对量：publish 那一刻打时间戳，
     * 下一次 pull 真正拿走时算差。等待如果长时间超过一两帧，
     * 屏幕上就是「帧在那儿摆着没人取」。 */
    int64_t pull_wait_max_us;
    int64_t pull_wait_sum_us;
    int64_t pull_wait_count;
    int64_t published_at_us;
    /* 取帧间隔按帧周期分档的计数。
     *
     * 24 fps 内容放在 60 Hz 屏上，每帧必然显示 2 或 3 个 vsync（33.3 / 50 ms），
     * 这叫 3:2 pulldown，是 24 fps 上 60 Hz 的固有特征。它到底可不可见，
     * 取决于这 2 和 3 是不是**均匀交替**：均匀交替看到的是轻微的点动，
     * 连续几个 2 再连续几个 3 就会变成肉眼可见的一顿一顿。
     * 所以光有「最大间隔」不够，必须知道分布：
     *   pull_fast——间隔短于一个帧周期（≈2 个 vsync）；
     *   pull_mid ——在 1.0–1.5 个帧周期之间（≈3 个 vsync，正常档）；
     *   pull_slow——超过 1.5 个帧周期（掉了一帧以上，才是真的卡）。
     * 24 fps 每秒 24 次取帧，若 pull_fast ≈ pull_mid ≈ 12 就是标准 3:2；
     * 若 pull_slow 有几次，那几次屏幕上是停住的。 */
    int64_t pull_fast;
    int64_t pull_mid;
    int64_t pull_slow;
    int64_t push_gap_max_us;
    int64_t push_gap_sum_us;
    int64_t push_gap_count;
    int64_t last_push_at_us;
    /* Software fallback scaler, owned by this player.
     *
     * 以前是 apple_texture.c 里的函数级 static：两个播放器实例会共用同一个
     * 上下文，各自按自己的源尺寸重建，互相把对方的上下文换掉（单播放器时
     * 看不出来，多实例或开第二个窗口就是花屏）。win32_platform.c 一直是按
     * 实例存的，这里对齐。`sws_src_*` 记下当前上下文的源帧参数，源一变就
     * 重建 —— 连播两个分辨率不同的文件、或切到像素格式不同的轨时，不重建
     * 就会按错误的源尺寸取样。 */
    struct SwsContext *sws;
    int sws_src_w;
    int sws_src_h;
    int sws_src_fmt;
    pthread_mutex_t mutex;
} LpVideoOut;

int lp_render_init(LpPlayer *p);
void lp_render_close(LpPlayer *p);
int lp_render_set_window(LpPlayer *p, void *window, int width, int height);
int lp_render_resize(LpPlayer *p, int width, int height);
/* Software path: convert + draw the frame (Android EGL / desktop BGRA). */
int lp_render_draw(LpPlayer *p, AVFrame *frame);
/* Hardware path (Windows): hand a decoder-owned D3D11 NV12 picture straight to
 * the shared-texture output, without downloading it.  Returns
 * LP_ERR_UNSUPPORTED when the GPU path cannot take this frame; the caller then
 * falls back to the software download. */
int lp_render_draw_hw(LpPlayer *p, void *d3d_texture, unsigned slice, int width,
                      int height);
/* Colour space of the compressed stream, so the GPU conversion picks the same
 * YCbCr matrix the encoder used.  `matrix` is 0 = unknown, 1 = BT.601, 2 = BT.709;
 * `full_range` is 1 for JPEG/PC range and 0 for the usual 16-235. */
typedef struct LpColorInfo {
    int matrix;
    int full_range;
    int bit_depth;
} LpColorInfo;
int lp_render_draw_hw_ex(LpPlayer *p, void *d3d_texture, unsigned slice, int width, int height,
                         LpColorInfo color);
/* GPU output: tell the video processor which YCbCr matrix the stream uses.
 * Without it the processor assumes BT.601, which turns BT.709 reds orange. */
int lp_gpu_output_set_color(int matrix, int full_range);
/* Apple path: store a retained CVPixelBufferRef and notify the host. */
int lp_render_publish_pixel_buffer(LpPlayer *p, void *cv_pixel_buffer);
int lp_render_available(void);
const char *lp_render_name(void);

/* d3d11_output.c (Windows only): the picture is published as a D3D11 shared
 * texture so the Flutter texture bridge can sample it without a CPU copy. */
int lp_gpu_output_init(void);
int lp_gpu_output_ready(void);
int lp_gpu_d3d11va_device(AVBufferRef **out);
int lp_gpu_output_upload(LpPlayer *p, const uint8_t *bgra, int w, int h, int stride);
int lp_gpu_output_blit(LpPlayer *p, void *d3d_texture, unsigned slice, int w, int h);
int lp_gpu_output_readback(unsigned char *dst, size_t cap, int *width, int *height, int *stride);
void lp_gpu_output_close(void);

/* -------------------------------------------------------------- subtitle */

typedef struct LpSubStyle {
    char name[64];          /* ASS style name, "Default" when unnamed */
    int bold;
    int italic;
    int underline;
    int strikeout;
    uint32_t color;         /* 0xAARRGGBB */
    uint32_t secondary_color; /* 0xAARRGGBB, karaoke before it is sung */
    uint32_t outline_color; /* 0xAARRGGBB */
    uint32_t back_color;    /* 0xAARRGGBB, used by BorderStyle 3/4 */
    int outline_width;      /* in script units (ASS Outline) */
    int shadow;             /* in script units (ASS Shadow) */
    int border_style;       /* 1 = outline + shadow, 3 = opaque box, 4 = box */
    double spacing;         /* script units (ASS Spacing) */
    double scale_x;         /* percent, 100 = normal (ASS ScaleX) */
    double scale_y;         /* percent, 100 = normal (ASS ScaleY) */
    double angle;           /* degrees, clockwise (ASS Angle) */
    double margin_l;        /* script units (ASS MarginL) */
    double margin_r;        /* script units (ASS MarginR) */
    double margin_v;        /* script units (ASS MarginV) */
    int align;              /* ASS alignment 1..9 (2 = bottom center) */
    double pos_x;           /* 0..1, < 0 for automatic */
    double pos_y;
    double font_scale;      /* fraction of video height, default 0.05 */
    double play_res_y;      /* script resolution height, for margins/borders */
    double play_res_x;      /* script resolution width, for \p and \clip x */
    char font_name[64];
} LpSubStyle;

/* Bit flags for LpSubRun::flags. */
#define LP_SUB_BOLD 0x1
#define LP_SUB_ITALIC 0x2
#define LP_SUB_UNDERLINE 0x4
#define LP_SUB_STRIKEOUT 0x8

/* Which properties a `\t` animation actually drives.  Only these get
 * interpolated; everything else keeps whatever the run already had. */
#define LP_SUB_ANIM_COLOR 0x1
#define LP_SUB_ANIM_SCALE_X 0x2
#define LP_SUB_ANIM_SCALE_Y 0x4
#define LP_SUB_ANIM_FONT 0x8
#define LP_SUB_ANIM_ANGLE 0x10
#define LP_SUB_ANIM_SPACING 0x20
#define LP_SUB_ANIM_BORDER 0x40
#define LP_SUB_ANIM_SHADOW 0x80
#define LP_SUB_ANIM_ALPHA 0x100
#define LP_SUB_ANIM_CLIP 0x200

/* One entry of a `\t(<t1>,<t2>,<tags>)` list.  ASS replays the nested tags
 * continuously between t1 and t2 (milliseconds relative to the cue start). */
typedef struct LpSubAnim {
    double t1_ms;
    double t2_ms;
    double accel;    /* 0 = linear, 1..3 = the ASS power curve */
    unsigned fields; /* LP_SUB_ANIM_* bits, only the animated ones */
    uint32_t color;
    double scale_x;
    double scale_y;
    double font_scale;
    double angle;
    double spacing;
    int border;
    int shadow;
    double alpha;
    /* \clip animated inside \t: the rectangle moves, which is how ASS wipes
     * reveal a title.  Coordinates are script units (see LpSubCue). */
    int clip_on;
    double clip_x1;
    double clip_y1;
    double clip_x2;
    double clip_y2;
} LpSubAnim;

/* One node of a `\p<n>` drawing.  `sub` groups the points into subpaths so a
 * polygon can be closed per contour. */
typedef struct LpSubPathPoint {
    int sub;
    double x;
    double y;
} LpSubPathPoint;

/* One styled span inside a cue.  A cue with nb_runs == 0 is plain text that
 * inherits the whole cue style; otherwise each run carries the inline
 * overrides an ASS line asked for ({\b1}, {\c&H..&}, {\fs..}, ...). */
typedef struct LpSubRun {
    char *text;        /* owned UTF-8, may contain '\n' */
    unsigned flags;    /* LP_SUB_* */
    uint32_t color;    /* 0 = inherit from the cue style */
    uint32_t outline_color; /* 0 = inherit; set by an inline \3c */
    uint32_t back_color;    /* 0 = inherit; set by an inline \4c */
    double font_scale; /* 0 = inherit from the cue style */
    double scale_x;    /* percent, 0 = inherit */
    double scale_y;    /* percent, 0 = inherit */
    double spacing;    /* script units, 0 = inherit */
    double angle;      /* degrees, 0 = inherit */
    int border;        /* script units, -1 = inherit */
    int shadow;        /* script units, -1 = inherit */
    char font_name[64]; /* empty = inherit from the cue style */
    double alpha;      /* 0..1 text opacity, 1 = opaque */
    /* Karaoke: \k / \kf / \ko attach a duration to the glyphs that follow,
     * counted from the cue start.  karaoke_end_ms is the running total when
     * this run ends, so the renderer only needs the cue-relative time. */
    double karaoke_start_ms;
    double karaoke_end_ms;
    int karaoke_kind;  /* 0 = none, 1 = \k, 2 = \kf, 3 = \ko */
    /* Animated overrides produced by \t. */
    LpSubAnim *anims;
    int nb_anims;
    /* Vector drawing (\p<n>); when nb_path > 0 the run paints a shape instead
     * of glyphs and `text` holds the raw command string. */
    LpSubPathPoint *path;
    int nb_path;
    int drawing_scale; /* the \p exponent: 2^scale script units per pixel */
    /* \clip(x1,y1,x2,y2) in script units.  clip_on = 0 means "no clip"; the
     * renderer clips the line block, which is how ASS reveals a title with a
     * moving rectangle. */
    int clip_on;
    double clip_x1;
    double clip_y1;
    double clip_x2;
    double clip_y2;
    int clip_inverse; /* \iclip */
} LpSubRun;

/* One decoded bitmap subtitle rectangle (PGS / VobSub / DVB).  Pixels are
 * straight-alpha RGBA8; x/y/w/h are in the reference video's pixel grid, which
 * is what libavcodec reports. */
typedef struct LpSubBitmap {
    int x;
    int y;
    int w;
    int h;
    uint8_t *rgba; /* owned, w*h*4 bytes */
} LpSubBitmap;

typedef struct LpSubCue {
    int64_t start_us;
    int64_t end_us;
    int style;
    char *text;       /* UTF-8, '\n' separated, ASS override tags stripped */
    LpSubRun *runs;   /* optional styled spans, owned */
    int nb_runs;
    LpSubBitmap *bitmaps; /* set instead of text for graphics subtitles */
    int nb_bitmaps;
    int cap_bitmaps; /* capacity of `bitmaps`, grown geometrically */
    int align_override; /* ASS 1..9 from {\anN}, 0 = use the style */
    double pos_x;       /* from {\pos(x,y)}, normalised, < 0 = use the style */
    double pos_y;
    double margin_l;    /* script units, < 0 = use the style */
    double margin_r;
    double margin_v;
} LpSubCue;

typedef struct LpSubtitleTrack {
    int index;     /* stream index, or 1000+n for external files */
    int is_external;
    int enabled;   /* selected */
    int embedded;
    char lang[24];
    char title[128];
    char path[512]; /* external source path/url */
    AVCodecContext *avctx; /* embedded text subtitle decoder, may be NULL */
    LpSubCue *cues;
    int nb_cues;
    int cap_cues;
    LpSubStyle *styles;
    int nb_styles;
    int cap_styles;
    int current_cue; /* -1 when nothing on screen */
    int bitmap;      /* graphics subtitles: cues carry LpSubBitmap instead of text */
    int ref_w;       /* reference grid the decoder positions rectangles in */
    int ref_h;
} LpSubtitleTrack;

/* The rectangles currently on screen, flattened into one overlay the renderer
 * blends onto the converted video frame.  Keeping a copy (instead of pointing
 * into the cue array) means history trimming can never invalidate it. */
#define LP_SUB_OVERLAY_MAX 8
typedef struct LpSubOverlayRect {
    int x;
    int y;
    int w;
    int h;
    uint8_t *rgba; /* owned, w*h*4 */
    /* 引用计数：overlay 自己持一份，渲染线程取快照时再 +1。这样渲染线程
     * 不必每帧把整块位图 memcpy 出来，只要还有引用，内存就还在。 */
    atomic_int refs;
} LpSubOverlayRect;

typedef struct LpSubOverlay {
    LpSubOverlayRect rects[LP_SUB_OVERLAY_MAX];
    int nb;
    int ref_w;
    int ref_h;
    int first; /* index of the first active cue, -1 = nothing on screen */
    int count; /* how many cues were active when this was built */
    int version; /* bumped on every change so renderers can skip the work */
} LpSubOverlay;

typedef struct LpSubtitleState {
    LpSubtitleTrack tracks[LP_MAX_SUBTITLE_TRACKS];
    int nb_tracks;
    int selected;      /* index into tracks, -1 = off */
    int64_t delay_us;
    int dirty;         /* style/selection changed, re-emit */
    LpSubOverlay overlay;
    pthread_mutex_t mutex;
} LpSubtitleState;

/* ----------------------------------------------------------------- video */

typedef struct LpVideoStream {
    int stream_index;
    AVCodecContext *avctx;
    LpPacketQueue pq;
    pthread_t thread;
    int thread_started;
    int64_t last_pts_us;
    double frame_duration;
    int width;
    int height;
    enum AVPixelFormat pix_fmt;
    int hw_active;
    const char *hw_name;
    atomic_int eof;
    int64_t frames_decoded;
    int64_t frames_dropped;
    /* 解码器交出来、但因为 seek 而被就地作废的帧数（既没上屏也不算「迟到」
     * 丢帧）。守恒式里的第四项：
     *     解码器交出的帧 = frames_decoded + frames_dropped + frames_discarded
     * 三项之和与解码器实际交出数对不上，就说明有帧在某条分支里被无声吞掉。
     * 这条式子在排查「一帧没丢、画面却卡」时是唯一能自证的东西 —— 那时
     * dropped 与 decoded 都对得上，差额藏在一条没人计数的 break 里。 */
    int64_t frames_discarded;
    /* 解码器实际交出来的帧数（收到就算，不管后面是上屏、丢还是作废）。
     * 与上面三项之和比对即可自证守恒；快照里直接给差额。 */
    int64_t frames_received;
    /* 已经为「这个平台合不了图形字幕」提示过日志，避免每帧刷屏。 */
    int sub_blend_warned;
    /* 上一次真正上屏的时刻（av_gettime_relative，微秒）。用来给「已经落后于
     * 主时钟」的帧补一个最小间隔：硬解是一次一批地吐帧的，只按主时钟判断
     * 会让一批帧在几毫秒内连续上屏、随后空等下一批，观感是一顿一冲。 */
    int64_t last_present_at_us;
    /* 下一帧最早应该上屏的绝对时刻。节拍对着它推进，睡过头不补账，
     * 所以误差不会一层层累积。见 video.c 的 wait_for_presentation。 */
    int64_t next_present_at_us;
    /* 已经喂给异步解码器、但还没被取走解码结果的包数。
     *
     * 循环原本是「取一个包 → 喂 → 收一帧 → 上屏 → 再来」，异步解码器手上
     * 永远只有一帧的活，它自己的调度抖动就直接变成出帧间隔的抖动。iPad
     * 实测：内核侧 publish 间隔的平均值是 41 ms（正好一个帧周期），但每秒
     * 有 11 次超过 84 ms、最大 151 ms —— 这就是「帧数不缺、节奏在跳」。
     * 让解码器保持几帧的待处理量，它的抖动就被队列吸收掉。 */
    int in_flight;
    LpVideoDecoder *hw; /* non-NULL when decoding on the platform decoder */
    /* deinterlace / enhancement filter chain, created lazily */
    AVFilterGraph *fg;
    AVFilterContext *fg_src;
    AVFilterContext *fg_sink;
    AVFrame *filtered;
    double last_fps_sample_t;
    int64_t last_fps_frames;
    double fps;
} LpVideoStream;

typedef struct LpAudioStream {
    int stream_index;
    AVCodecContext *avctx;
    LpPacketQueue pq;
    pthread_t thread;
    int thread_started;
    struct SwrContext *swr;
    int out_rate;
    int out_channels;
    LpAudioRing ring;
    AVFilterGraph *graph; /* atempo chain for speed changes */
    AVFilterContext *filt_src;
    AVFilterContext *filt_sink;
    atomic_int graph_dirty;
    double applied_speed;
    /* swr 输出的常驻 PCM 暂存区（交错 float32 立体声）。容量按需扩容，
     * 避免每个音频帧一次 malloc/free。 */
    float *pcm;
    int pcm_cap;
    /* atempo 图的进出口帧，随图一起建/毁，避免每个音频帧两次 alloc。 */
    AVFrame *graph_in;
    AVFrame *graph_out;
    /* 最后一段写进环的内容时间（秒）。正常路径按帧 pts 写绝对时间；
     * 只有图排空（audio_flush_graph）没有帧可用，它得从「上一条写到的
     * 位置」接着算，否则尾段的时间戳会跳回 0，主时钟跟着倒回去。 */
    double content_cursor;
    atomic_int eof;
    int draining;
    int64_t frames_decoded;
    /* 切轨请求（index + 1，0 = 没有请求）。宿主是同步 FFI 调用，不能在那个
     * 线程上 join 解码线程，改由 tick 线程负责真正停下、换流、重启。 */
    atomic_int switch_req;
} LpAudioStream;

/* ---------------------------------------------------------------- player */

typedef enum LpHwMode {
    LP_HW_AUTO = 0,
    LP_HW_SOFTWARE = 1,
    LP_HW_FORCED = 2, /* platform name was given explicitly */
} LpHwMode;

/* Forward declaration: the player owns a transport handle. */
typedef struct LpIo LpIo;

struct LpPlayer {
    pthread_mutex_t lock;
    atomic_int state;
    atomic_int abort_request;
    int opened;
    int playing;

    char *url;
    char *options_json;
    LpSourceOptions sopts;

    LpIo *io; /* custom AVIO for SMB/local; NULL for FFmpeg native protocols */
    AVFormatContext *fmt;

    LpEventCallback event_cb;
    void *event_user;

    pthread_t demux_thread;
    int demux_started;
    pthread_t open_thread;
    int open_started;
    pthread_t tick_thread;
    int tick_started;
    /* 只给 tick 线程用的退出标志。tick 线程活在整个播放器对象的生命周期里，
     * 不能跟着 abort_request 走 —— abort_request 在每次关片（换片、连播）
     * 时都会置位，tick 线程一旦跟着退出就再也没人发 POSITION / 判定 ENDED，
     * 表现为连播第二个文件时进度条冻住、播完不结束。 */
    atomic_int quit_request;
    int64_t read_timeout_ms;

    LpVideoStream video;
    LpAudioStream audio;
    LpSubtitleState subs;
    int subs_inited;
    LpAudioSink *sink;

    LpClock ac;
    LpClock extc;
    int sync_mode; /* 0 = audio master (default), 1 = external clock */
    double speed;
    float volume;
    int muted;

    LpVideoOut vout;
    int deinterlace;
    int hw_mode;
    char hw_forced_name[32];

    int64_t duration_us;
    int64_t start_us;      /* container start_time, used to normalise timestamps */
    int64_t seek_start_us; /* position requested by the caller on open */
    atomic_int serial;

    /* seek request, consumed by the demux thread */
    atomic_int seek_req;
    int64_t seek_target_us;
    atomic_llong position_us;

    atomic_int eos_demux;
    int eos_audio;
    int eos_video;

    /* stats */
    int64_t stats_frames;
    int64_t stats_dropped;
    double stats_fps;
    double stats_av_diff;
    int64_t stats_last_emit_us;
    int64_t stats_last_frames;
    double stats_last_time;
    int buffering;

    /* 音频主时钟的健康检查：环空（解码跟不上、或声卡没在消费）时
     * lp_ring_clock_seconds() 会一直返回同一刻，主时钟跟着冻住，画面
     * 也不走了。记下上一次看到的值与时刻，超过阈值就退回墙钟。 */
    atomic_llong audio_clock_seen_us;
    atomic_llong audio_clock_seen_at;
};

/* player.c helpers used by the other modules */
void lp_emit_event(LpPlayer *p, int event, const char *json_fmt, ...);
/* Takes ownership of an already-built JSON payload (free()d on every path). */
void lp_emit_event_owned(LpPlayer *p, int event, char *json);

void lp_set_state(LpPlayer *p, LpState state);
LpState lp_get_state(LpPlayer *p);
void lp_emit_error(LpPlayer *p, int code, const char *fmt, ...);
char *lp_media_info_json(LpPlayer *p);
void lp_note_position(LpPlayer *p, int64_t position_us);
int64_t lp_master_clock_us(LpPlayer *p);
void lp_request_seek(LpPlayer *p, int64_t target_us);
int lp_is_abort(LpPlayer *p);
void lp_emit_buffering(LpPlayer *p, int buffering, int percent);

/* demux.c */
int lp_demux_open(LpPlayer *p);

void *lp_demux_thread_fn(void *arg);

/* video.c */
int lp_video_start(LpPlayer *p);
void lp_video_stop(LpPlayer *p);
void *lp_video_thread_fn(void *arg);


/* audio.c */
int lp_audio_start(LpPlayer *p);
void lp_audio_stop(LpPlayer *p);
void *lp_audio_thread_fn(void *arg);
double lp_audio_clock_seconds(LpPlayer *p);
void lp_audio_rebuild_graph(LpPlayer *p);
int lp_audio_buffered_ms(LpPlayer *p);

/* subtitle.c */
int lp_subtitle_open(LpPlayer *p);
void lp_subtitle_close(LpPlayer *p);
void lp_subtitle_tick(LpPlayer *p, int64_t now_us);
int lp_subtitle_add_file(LpPlayer *p, const char *url, const char *options_json);
void lp_subtitle_select(LpPlayer *p, int track_index);
void lp_subtitle_set_delay(LpPlayer *p, int64_t delay_ms);
void lp_subtitle_seek(LpPlayer *p, int64_t pos_us);
void lp_subtitle_feed_packet(LpPlayer *p, int stream_index, AVPacket *pkt);
/* Blends the graphics-subtitle overlay onto a converted BGRA picture.  The
 * renderer calls this right after sws_scale, with no other locks held. */
void lp_sub_overlay_blend(LpPlayer *p, uint8_t *bgra, int w, int h, int stride);
/* True while a graphics (bitmap) subtitle is on screen.  The GPU output cannot
 * blend those and falls back to the download path meanwhile. */
int lp_render_graphics_sub_active(LpPlayer *p);

/* submatch.c — 外挂字幕和视频的配对规则。与 Dart 侧
 * app/lib/data/subtitle_match.dart 同一套判定，改一边必须同步另一边。 */
void lp_sub_match_stem(const char *name, char *out, size_t outlen);
int lp_sub_match_related(const char *video_stem, const char *sub_stem);

/* subtitle.c — 仅供 native/tests/lp_subcolor_test.c 用，正常播放不会调。 */
int lp_sub_test_parse_runs(const char *dialogue_text, int run_index,
                           uint32_t *color, uint32_t *outline_color,
                           uint32_t *back_color);

/* \t / \k / \clip / \p 的解析结果，供 native/tests/lp_subanim_test.c 断言。
 * 正常播放路径不碰这个结构。 */
typedef struct LpSubTestAnim {
    int nb_runs;
    int nb_anims;
    double anim_t1;
    double anim_t2;
    double anim_accel;
    unsigned anim_fields;
    uint32_t anim_color;
    double anim_scale_x;
    double anim_scale_y;
    double anim_alpha;
    int anim_clip_on;
    double anim_clip_x1;
    double anim_clip_x2;
    int karaoke_kind;
    double karaoke_start_ms;
    double karaoke_end_ms;
    double alpha;
    double angle; /* \fr / \frz, in degrees */
    int clip_on;
    double clip_x1;
    double clip_y1;
    double clip_x2;
    double clip_y2;
    int clip_inverse; /* \iclip: keep what is OUTSIDE the rectangle */
    int drawing_scale;
    int nb_path;
    int nb_subpaths;
    double path_x0;
    double path_y0;
    double path_last_x;
    double path_last_y;
} LpSubTestAnim;

int lp_sub_test_parse_anim(const char *dialogue_text, int run_index,
                           int64_t cue_dur_us, LpSubTestAnim *out);

/* 畸形 ASS 输入的回归钩子，供 native/tests/lp_robust_test.c 使用。
 * 正常播放路径不会调它们。 */
typedef struct LpSubTestMerge {
    int nb_runs;
    int nb_animated_runs;
    int first_nb_anims;
    double first_anim_t2;
    char first_text[64];
} LpSubTestMerge;

LpSubtitleTrack *lp_sub_test_parse_ass(const char *text, size_t len);
void lp_sub_test_free_track(LpSubtitleTrack *t);
char *lp_sub_test_clamp_text(const char *text);
int lp_sub_test_merge_runs(const char *r1, const char *r2, const char *r3,
                           LpSubTestMerge *out);

/* Decode a raw subtitle byte blob exactly the way lp_subtitle_add_file() does
 * (BOM strip, BOM-less UTF-16 guess, legacy code-page fallback).  Returns a
 * malloc'd NUL-terminated UTF-8 buffer, or NULL when the buffer itself could
 * not be allocated.  Test-only. */
char *lp_sub_test_decode_text(const void *raw, size_t len, int *charset_ok);

/* source layer (see src/source) */
typedef struct LpIo LpIo;
LpIo *lp_io_open(const char *url, const LpSourceOptions *opts, char *err, size_t errlen);
void lp_io_close(LpIo *io);
int lp_io_read(LpIo *io, uint8_t *buf, int size);
int64_t lp_io_seek(LpIo *io, int64_t offset, int whence);
int64_t lp_io_size(LpIo *io);
/* Attach as AVFormatContext custom IO; returns 0 on success. */
int lp_io_attach_avio(LpIo *io, AVFormatContext **fmt, char *err, size_t errlen);
int lp_io_interrupt(void *user);
void lp_io_abort(LpIo *io);
/* 这一次失败属于哪一类（LP_ERR_AUTH / LP_ERR_NOT_FOUND / LP_ERR_TIMEOUT …）。
 * lp_io_open 返回 NULL 之后由调用方取，别再一律报 LP_ERR_IO。 */
int32_t lp_io_last_result(void);

#ifdef __cplusplus
}
#endif

#endif /* LANPLAYER_PLAYER_INTERNAL_H */
