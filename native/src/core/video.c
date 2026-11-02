/*
 * Video decode + presentation.
 *
 * One worker thread decodes and presents.  Presentation waits on the master
 * clock (driven by the audio sink), which is what produces A/V sync; the
 * bounded packet queue is the only back-pressure towards the demuxer.
 *
 * The async hardware decoders (VideoToolbox, MediaCodec) are kept a few frames
 * deep: feeding them one packet per received frame made their own scheduling
 * jitter show up as uneven presentation, which is exactly the stutter that
 * "dropped" never reports.  See LP_HW_PREFETCH.
 */
#include <stdlib.h>

#include "player_internal.h"

#if LIBAVUTIL_VERSION_MAJOR >= 58
#define LP_FRAME_INTERLACED(f) (((f)->flags & AV_FRAME_FLAG_INTERLACED) != 0)
#else
#define LP_FRAME_INTERLACED(f) ((f)->interlaced_frame != 0)
#endif

static int64_t pts_to_us(AVRational tb, int64_t pts)
{
    return av_rescale_q(pts, tb, AV_TIME_BASE_Q);
}

/* 异步硬解要「喂饱」的深度。
 *
 * 原来的循环是「取一个包 → 喂进去 → 立刻收一帧 → 上屏」，解码器手上永远
 * 只有一帧待处理：它自己的线程什么时候跑、跑多久，全都直接体现在出帧间隔
 * 上。iPad 实测（内核侧 publish 间隔，与引擎取帧无关）：
 *
 *   push 间隔 平均 41 ms（正好一个帧周期），每秒 11 次超过 84 ms、最大 151 ms
 *
 * 也就是说每秒 24 帧一帧不少，但节奏每秒要断十几次 —— 屏幕上看就是一顿
 * 一冲，而 dropped 统计恒为 0。软解与 Windows 的 d3d11va 是同步的
 * （send 之后立刻能 receive），预读反而会让延迟变大，所以只给异步解码器用。
 * 4 帧约合 170 ms 的缓冲，足够吸收一次调度抖动。 */
#define LP_HW_PREFETCH 4

/* 落后超过这个量才让节拍临时加快。整周期摊平不看落后多少，落后量会被
 * 锁死在那里一路漂到丢帧线（-500 ms）才纠正 —— iPad 实测 av_diff 稳定
 * 停在 -0.4 ~ -0.5 s、30 秒丢 46 帧。120 ms 大约是三帧，比解码器的
 * 固有管线延迟小、比渲染抖动大：正常情况下永远进不到这一支。 */
#define LP_PACE_CATCHUP_US 120000

/* Waits until the master clock reaches pts_us.
 * Returns 0 = present, 1 = too late (drop), <0 = interrupted. */
static int wait_for_presentation(LpPlayer *p, int64_t pts_us, int serial, double frame_dur)
{
    for (;;) {
        if (lp_is_abort(p) || serial != atomic_load(&p->serial)) {
            return LP_ERR_INTERRUPTED;
        }
        if (atomic_load(&p->state) != LP_STATE_PLAYING) {
            av_usleep(5000);
            continue;
        }
        int64_t diff = pts_us - lp_master_clock_us(p);
        if (diff <= 0) {
            /* 开播阶段不要丢帧：主时钟在 lp_demux_open 的时候就开始走了，
             * 而第一帧要等解复用 + 解码器初始化（macOS 上 VideoToolbox
             * 建会话约 200 ms），于是头一两秒的帧天生「晚了 300 ms」，
             * 按 250 ms 规则会被整段丢掉 —— 24 fps 的片子前 2 秒就丢 17 帧，
             * 看起来像开播卡一下。规则只对「已经出过画面之后」的晚到生效。 */
            if (p->video.frames_decoded == 0) {
                return 0;
            }
            /* 硬解有固有的管线延迟：帧要等解码器吐出来才能上屏，VideoToolbox
             * 在 1080p H.264 上实测稳定落后主时钟 200–300 ms（av_diff 长期
             * 停在 -196 ~ -336 ms）。这是延迟不是「跟不上」，按 250 ms 丢会
             * 把正常出帧当成落后丢掉 —— 实测 30 秒丢 127 帧。阈值放宽到
             * 500 ms：仍然拦得住真正跟不上的情况（软解来不及、机器太慢），
             * 但不再误伤解码延迟。 */
            if (diff < -500000) {
                return 1;
            }
            /* 落后不等于「可以立刻连续刷屏」。VideoToolbox 是一次一批地吐帧
             * 的（异步解完两三帧再回调），而这里原本对任何 diff <= 0 都直接
             * 返回 0，于是一批帧在几毫秒内接二连三地上屏，接着线程没事干、
             * 等下一批 —— 平均帧率看着是 24，观感却是「一顿一冲」。
             *
             * iPad 上实测（把每两次取帧的间隔记成 pull_gap）：每秒有 6 次
             * 超过 60 ms 的停顿，最大 145–216 ms，而内核 dropped 始终是 0，
             * 也就是说统计里完全看不见。
             *
             * 处理办法是给「已经在后面」的帧补一个最小间隔：按帧周期缩放
             * 到 0.9，把一批帧摊平到它们本该占用的那段时间里。它不改变
             * A/V 偏移的稳态（本来就已经落后），只是把「挤在一起 + 随后
             * 长停顿」换成匀速。
             *
             * 只对异步解码器生效。软解是自己一帧一帧解、解完就上屏，本来就
             * 匀速；Windows 的 d3d11va 也是同步 avcodec_receive_frame。给它们
             * 中间插一个帧周期的等待只会让解码线程追不上 —— Windows 上实测：
             * 加上等待后 12 秒里丢 24–32 帧（此前 0 帧）。真正会「成批吐」
             * 的是 VideoToolbox 与 MediaCodec（解完两三帧才一起交出来）。 */
            if (p->video.hw && lp_hw_decoder_is_async(p->video.hw) &&
                p->video.frames_decoded > 0 && frame_dur > 0) {
                /* 摊平用的最小间隔必须正好等于帧周期，不能比它短。
                 *
                 * 这里曾经写 0.9（37.5 ms 对 41.67 ms 的帧周期），本意是
                 * 「落后时慢慢追回来」。实际上帧的 pts 间距本来就是 41.67 ms，
                 * 用 37.5 ms 出帧等于比内容自身的节奏快 10%：线程会一直比
                 * 解码器快，把手上那点缓冲抽干，然后干等下一批 —— 每秒
                 * 稳定出现一两次 90 ms 以上的空档。
                 *
                 * iPad 实测（24 fps 内容、60 Hz 屏）：平均送帧间隔 41.2 ms
                 * （折合 24.3 fps，总体是实时的），但每秒内最大间隔平均
                 * 92.6 ms。反解这一秒：2 次 92 ms + 21 次 38.9 ms ——
                 * 38.9 正是被 0.9 压短后的出帧间隔，抽干后才有那两次空档。
                 *
                 * 改成整周期后，出帧节奏与 pts 间距一致：既不抽干缓冲，也
                 * 仍然把「一次吐两三帧」摊平到它们本该占用的时间里。
                 *
                 * 但是只按整周期摊平也有代价：它对「已经落后多少」完全不看，
                 * 落后量就被锁死在那里，只能一路漂到丢帧线才被纠正 —— iPad
                 * 实测 av_diff 稳定停在 -0.4 ~ -0.5 s，30 秒丢 46 帧。所以
                 * 加一条：落后超过 LP_PACE_CATCHUP_US 才临时加快到 0.7 倍
                 * 周期把差距拉回来，回到窗口内立刻恢复整周期。加快只发生在
                 * 真的落后时，不会像 0.9 那版那样常态抽干缓冲。
                 *
                 * 还试过两种「更聪明」的写法，都被 iPad 实测否决：
                 * 按相邻两帧的 pts 差逐帧等 —— VideoToolbox 一次并发交出
                 * 好几帧，逐帧等等于把整批按顺序排开，fps 掉到 4–6、每秒
                 * 丢 19 帧；改成对着「下一帧最早该上屏的绝对时刻」推进 ——
                 * 出帧是匀速了（av_diff 从 -0.4 s 收到 -0.1 s、dropped 归零），
                 * 但引擎那边反而拉不到帧：每秒有一次 165 ms 的空档，
                 * dropped_delivery 30 秒涨到 303，实际渲染只剩 14 fps。 */
                const int64_t period = (int64_t)(frame_dur * 1000000.0);
                const int64_t since = av_gettime_relative() - p->video.last_present_at_us;
                int64_t spacing = period;
                if (diff < -LP_PACE_CATCHUP_US) {
                    spacing = (int64_t)(period * 0.7);
                }
                if (spacing > 0 && since >= 0 && since < spacing) {
                    av_usleep((unsigned)(spacing - since));
                    continue;
                }
            }
            return 0;
        }
        unsigned nap = diff > 10000 ? 10000u : (unsigned)diff;
        if (nap < 1000) {
            nap = 1000;
        }
        av_usleep(nap);
    }
}

/* -------------------------------------------------------------- filters --- */

static int filter_init(LpPlayer *p, const AVFrame *ref)
{
    const AVFilter *buf = avfilter_get_by_name("buffer");
    const AVFilter *sink = avfilter_get_by_name("buffersink");
    AVFilterInOut *outs = NULL;
    AVFilterInOut *ins = NULL;
    char args[256];
    int r;

    snprintf(args, sizeof(args),
             "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d",
             ref->width, ref->height, ref->format, ref->sample_aspect_ratio.den,
             ref->sample_aspect_ratio.num > 0 ? ref->sample_aspect_ratio.den : 1,
             ref->sample_aspect_ratio.num, ref->sample_aspect_ratio.den);

    AVFilterGraph *g = avfilter_graph_alloc();
    if (!g) {
        return LP_ERR_NOMEM;
    }
    if ((r = avfilter_graph_create_filter(&p->video.fg_src, buf, "in", args, NULL, g)) < 0 ||
        (r = avfilter_graph_create_filter(&p->video.fg_sink, sink, "out", NULL, NULL, g)) < 0) {
        avfilter_graph_free(&g);
        p->video.fg_src = p->video.fg_sink = NULL;
        return r;
    }
    outs = avfilter_inout_alloc();
    ins = avfilter_inout_alloc();
    if (!outs || !ins) {
        avfilter_inout_free(&outs);
        avfilter_inout_free(&ins);
        avfilter_graph_free(&g);
        return LP_ERR_NOMEM;
    }
    outs->name = av_strdup("in");
    outs->filter_ctx = p->video.fg_src;
    outs->pad_idx = 0;
    outs->next = NULL;
    ins->name = av_strdup("out");
    ins->filter_ctx = p->video.fg_sink;
    ins->pad_idx = 0;
    ins->next = NULL;

    r = avfilter_graph_parse_ptr(g, "yadif=deint=interlaced:mode=send_frame", &ins, &outs, NULL);
    if (r >= 0) {
        r = avfilter_graph_config(g, NULL);
    }
    avfilter_inout_free(&ins);
    avfilter_inout_free(&outs);
    if (r < 0) {
        LP_WARN("video", "deinterlace filter init failed: %d", r);
        avfilter_graph_free(&g);
        p->video.fg_src = p->video.fg_sink = NULL;
        return r;
    }
    p->video.fg = g;
    return 0;
}

static void filter_close(LpPlayer *p)
{
    if (p->video.fg) {
        avfilter_graph_free(&p->video.fg);
        p->video.fg = NULL;
        p->video.fg_src = p->video.fg_sink = NULL;
    }
    av_frame_free(&p->video.filtered);
}

/* Returns a borrowed frame, possibly the filtered one. */
static AVFrame *maybe_deinterlace(LpPlayer *p, AVFrame *frame)
{
    if (!p->deinterlace || !LP_FRAME_INTERLACED(frame)) {
        return frame;
    }
    if (!p->video.fg && filter_init(p, frame) < 0) {
        return frame;
    }
    if (av_buffersrc_add_frame(p->video.fg_src, frame) < 0) {
        return frame;
    }
    /* 复用同一个输出帧：以前每帧 av_frame_alloc / av_frame_free，30 fps 下
     * 一年多就是上亿次分配。帧缓冲本身由 unref 归还，不需要重新申请。 */
    if (!p->video.filtered) {
        p->video.filtered = av_frame_alloc();
        if (!p->video.filtered) {
            return frame;
        }
    }
    AVFrame *out = p->video.filtered;
    av_frame_unref(out);
    if (av_buffersink_get_frame(p->video.fg_sink, out) < 0) {
        return frame;
    }
    return out;
}

/* ------------------------------------------------------------ decoding --- */

static int open_software_decoder(LpPlayer *p)
{
    AVStream *st = p->fmt->streams[p->video.stream_index];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) {
        LP_ERROR("video", "no decoder for %s", avcodec_get_name(st->codecpar->codec_id));
        return LP_ERR_UNSUPPORTED;
    }
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) {
        return LP_ERR_NOMEM;
    }
    if (avcodec_parameters_to_context(ctx, st->codecpar) < 0) {
        avcodec_free_context(&ctx);
        return LP_ERR_CODEC;
    }
    ctx->pkt_timebase = st->time_base;
    ctx->thread_count = 0;
    ctx->flags2 |= AV_CODEC_FLAG2_FAST;
    /* AV_CODEC_CAP_TRUNCATED / AV_CODEC_FLAG_TRUNCATED were removed in FFmpeg 8;
     * the modern decoders no longer need the hint. */
    int r = avcodec_open2(ctx, codec, NULL);
    if (r < 0) {
        LP_ERROR("video", "avcodec_open2(%s) failed: %d", codec->name, r);
        avcodec_free_context(&ctx);
        return LP_ERR_CODEC;
    }
    p->video.avctx = ctx;
    p->video.width = ctx->width;
    p->video.height = ctx->height;
    p->video.pix_fmt = ctx->pix_fmt;
    p->video.hw_active = 0;
    p->video.hw_name = "software";
    LP_INFO("video", "software decode %s %dx%d", codec->name, ctx->width, ctx->height);
    return LP_OK;
}

static int open_hardware_decoder(LpPlayer *p)
{
    AVStream *st = p->fmt->streams[p->video.stream_index];
    LpVideoDecoderConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.par = st->codecpar;
    cfg.codec_id = st->codecpar->codec_id;
    cfg.width = st->codecpar->width;
    cfg.height = st->codecpar->height;
    cfg.time_base = st->time_base;
    cfg.native_window = p->vout.window;
    cfg.player = p;

    LpVideoDecoder *dec = lp_hw_decoder_create();
    if (!dec) {
        return LP_ERR_UNSUPPORTED;
    }
    char err[256] = {0};
    if (lp_hw_decoder_init(dec, &cfg, err, sizeof(err)) != LP_OK) {
        LP_WARN("video", "%s unavailable (%s), using software decode", lp_hw_decoder_name(),
                err[0] ? err : "unknown");
        lp_hw_decoder_destroy(dec);
        return LP_ERR_CODEC;
    }
    p->video.hw = dec;
    p->video.hw_active = 1;
    p->video.hw_name = lp_hw_decoder_name();
    p->video.width = cfg.width;
    p->video.height = cfg.height;
    p->video.pix_fmt = AV_PIX_FMT_NONE;
    LP_INFO("video", "hardware decode %s %dx%d", lp_hw_decoder_name(), cfg.width, cfg.height);
    return LP_OK;
}

static int open_decoder(LpPlayer *p)
{
    if (p->hw_mode != LP_HW_SOFTWARE && lp_hw_decoder_available()) {
        if (open_hardware_decoder(p) == LP_OK) {
            return LP_OK;
        }
        LpStr s;
        lp_str_init(&s);
        lp_str_append(&s, "{\"hw\":\"software\",\"fallback_from\":\"%s\"}",
                      p->hw_forced_name[0] ? p->hw_forced_name : lp_hw_decoder_name());
        lp_emit_event(p, LP_EVENT_STATS, "%s", s.p);
        lp_str_free(&s);
    }
    return open_software_decoder(p);
}

/* --------------------------------------------------------------- thread --- */

static void present_hw(LpPlayer *p, LpDecodedFrame *hf, int drop)
{
    if (drop) {
        p->video.frames_dropped++;
        p->stats_dropped++;
        lp_hw_decoder_present(p->video.hw, hf);
        return;
    }
    lp_hw_decoder_present(p->video.hw, hf);
    p->video.frames_decoded++;
    p->stats_frames++;
    p->video.last_pts_us = hf->pts_us;
    p->video.last_present_at_us = av_gettime_relative();
    lp_note_position(p, hf->pts_us);
}

void *lp_video_thread_fn(void *arg)
{
    LpPlayer *p = arg;
    AVFrame *frame = av_frame_alloc();
    AVPacket *pending = NULL;
    if (!frame) {
        return NULL;
    }

    int serial = atomic_load(&p->serial);
    int draining = 0;
    int drained = 0;
    int drain_rounds = 0;
    int hw_eos_sent = 0;
    int64_t last_pts_us = 0;
    double frame_dur = 0.04;

    while (!lp_is_abort(p)) {
        if (serial != atomic_load(&p->serial)) { /* seek happened */
            if (p->video.hw) {
                lp_hw_decoder_flush(p->video.hw);
            } else {
                avcodec_flush_buffers(p->video.avctx);
            }
            filter_close(p);
            av_packet_free(&pending);
            draining = 0;
            drained = 0;
            drain_rounds = 0;
            hw_eos_sent = 0;
            /* flush 之后解码器里什么都不剩，在途计数要跟着归零，否则
             * 补料循环会以为还有货，一直不去要新的包。 */
            p->video.in_flight = 0;
            serial = atomic_load(&p->serial);
            continue;
        }

        int r = LP_OK;
        int again = 0;
        if (p->video.hw && lp_hw_decoder_is_async(p->video.hw)) {
            /* 异步硬解（VideoToolbox / MediaCodec）先补料，理由见
             * LP_HW_PREFETCH 的注释。同步解码器**不能**走这一支：它 send 完
             * 只是把包交进 FFmpeg 的重排队列，要连喂几个包才吐第一帧，
             * 而 in_flight 一满就不再取包，receive 永远返回 AGAIN。 */
            int stop = 0;
            while (!draining && p->video.in_flight < LP_HW_PREFETCH) {
                if (!pending) {
                    int qserial = serial;
                    pending = lp_pq_get(&p->video.pq, &qserial, 0);
                    if (pending) {
                        serial = qserial;
                    } else if (lp_pq_aborted(&p->video.pq)) {
                        /* 停止 / 换轨：队列里还有包也立刻退出，否则
                         * lp_video_stop 的 pthread_join 会一直等到超时。 */
                        stop = 1;
                        break;
                    } else if (lp_pq_eof(&p->video.pq)) {
                        draining = 1;
                        break;
                    } else if (p->video.in_flight == 0) {
                        /* 队列空、解码器里也没货：睡在条件变量上等解复用线程
                         * 广播，别让 receive 的 10 ms 超时变成空转。 */
                        lp_pq_wait_more(&p->video.pq, 0);
                        continue;
                    } else {
                        /* 队列暂时空着，但解码器里还有在途的包：先把手上的
                         * 帧收掉，下一轮再来要包。 */
                        break;
                    }
                }
                r = lp_hw_decoder_send(p->video.hw, pending);
                again = (r == LP_ERR_AGAIN);
                if (again) {
                    break;
                }
                if (r < 0 && r != AVERROR_EOF) {
                    LP_WARN("video", "send_packet: %d", r);
                }
                av_packet_free(&pending);
                p->video.in_flight++;
            }
            if (stop) {
                break;
            }
            /* EOS 只发一次：VideoToolbox 收到 NULL 会 WaitForAsynchronousFrames，
             * 反复发会让排空阶段一直等在那上面。 */
            if (draining && !hw_eos_sent) {
                lp_hw_decoder_send(p->video.hw, NULL);
                hw_eos_sent = 1;
            }
        } else {
            if (!pending && !draining) {
                int qserial = serial;
                pending = lp_pq_get(&p->video.pq, &qserial, 0);
                if (pending) {
                    serial = qserial;
                } else if (lp_pq_aborted(&p->video.pq)) {
                    /* 停止 / 换轨：队列里还有包也立刻退出，否则 lp_video_stop
                     * 的 pthread_join 会一直等到超时。 */
                    break;
                } else if (lp_pq_eof(&p->video.pq)) {
                    draining = 1;
                } else {
                    /* 队列空：睡在条件变量上等解复用线程广播。以前是
                     * av_usleep(2000) 每 2 ms 醒一次轮询，既白烧 500 次/秒的
                     * 加解锁，也把 queue.c 里的 cond_wait 分支架空了。 */
                    lp_pq_wait_more(&p->video.pq, 0);
                    continue;
                }
            }

            if (p->video.hw) {
                /* 同步硬解（d3d11va）：喂一包、收一帧，和同步软解同节奏。 */
                r = lp_hw_decoder_send(p->video.hw, draining ? NULL : pending);
                /* 硬解走的是我们自己的接口，用的是 LP_ERR_AGAIN(-7)；软解走
                 * FFmpeg，用的是 AVERROR(EAGAIN)(-11)。两者编号不同，早先这里
                 * 只判 AVERROR(EAGAIN)，于是硬解返回 -7 时掉进下面的 r < 0 分支
                 * 把包 av_packet_free 掉 —— MediaCodec 一帧都收不到，画面全黑。 */
                again = (r == LP_ERR_AGAIN);
            } else {
                r = avcodec_send_packet(p->video.avctx, draining ? NULL : pending);
                again = (r == AVERROR(EAGAIN));
            }
            if (again) {
                /* Keep the packet, drain below, retry on the next iteration. */
            } else if (r < 0 && r != AVERROR_EOF) {
                LP_WARN("video", "send_packet: %d", r);
                av_packet_free(&pending);
            } else {
                av_packet_free(&pending);
            }
        }

        for (;;) {
            if (p->video.hw) {
                LpDecodedFrame hf;
                memset(&hf, 0, sizeof(hf));
                int hr = lp_hw_decoder_receive(p->video.hw, &hf);
                if (hr == LP_ERR_AGAIN) {
                    break;
                }
                if (hr == LP_ERR_END_OF_STREAM) {
                    /* 解码器真的吐完了：VideoToolbox / MediaCodec 都是在收到
                     * EOS 之后再过一轮才回 END_OF_STREAM。这里必须跳出外层
                     * 循环（只 break 内层的话外层会空转，p->video.eof 永远不
                     * 置位，LP_EVENT_ENDED 发不出去，界面就卡在最后一帧上
                     * 转圈）。 */
                    draining = 1;
                    drained = 1;
                    break;
                }
                if (hr < 0) {
                    if (hr != LP_ERR_INTERRUPTED) {
                        LP_ERROR("video", "hw receive: %d", hr);
                        lp_emit_error(p, hr, "hardware decoder failure");
                    }
                    draining = 1;
                    break;
                }
                int64_t pts_us = hf.pts_us > 0 ? hf.pts_us : last_pts_us + (int64_t)(frame_dur * 1e6);
                if (p->video.in_flight > 0) {
                    p->video.in_flight--;
                }
                int drop = wait_for_presentation(p, pts_us, serial, frame_dur);
                if (drop < 0) {
                    /* Seek or stop: release the buffer and let the outer loop
                     * re-sync (do NOT exit the thread). */
                    lp_hw_decoder_present(p->video.hw, &hf);
                    break;
                }
                present_hw(p, &hf, drop);
                last_pts_us = pts_us;
                continue;
            }

            r = avcodec_receive_frame(p->video.avctx, frame);
            if (r == AVERROR_EOF) {
                /* 软解的排空结束信号，语义同上面的 LP_ERR_END_OF_STREAM。 */
                drained = 1;
                break;
            }
            if (r == AVERROR(EAGAIN)) {
                break;
            }
            if (r < 0) {
                LP_WARN("video", "receive_frame: %d", r);
                break;
            }
            if (frame->duration > 0) {
                frame_dur = frame->duration * av_q2d(p->video.avctx->pkt_timebase);
            }
            int64_t pts_us;
            if (frame->best_effort_timestamp != AV_NOPTS_VALUE) {
                pts_us = pts_to_us(p->video.avctx->pkt_timebase, frame->best_effort_timestamp);
            } else if (frame->pts != AV_NOPTS_VALUE) {
                pts_us = pts_to_us(p->video.avctx->pkt_timebase, frame->pts);
            } else {
                pts_us = last_pts_us + (int64_t)(frame_dur * 1e6);
            }
            AVFrame *shown = maybe_deinterlace(p, frame);
            int drop = wait_for_presentation(p, pts_us, serial, frame_dur);
            if (drop < 0) {
                av_frame_unref(frame);
                break;
            }
            if (drop == 1) {
                p->video.frames_dropped++;
                p->stats_dropped++;
            } else {
                lp_render_draw(p, shown);
                p->video.frames_decoded++;
                p->stats_frames++;
                p->video.last_pts_us = pts_us;
                p->video.last_present_at_us = av_gettime_relative();
                lp_note_position(p, pts_us);
            }
            last_pts_us = pts_us;
            av_frame_unref(frame);
            break;
        }

        if (drained) {
            /* 解码器已经吐完所有帧：本路视频到此为止。
             * （以前这里继续回到 while 顶部，却已经没有包可发，于是无限
             * 空转 —— 见上面 LP_ERR_END_OF_STREAM 分支的注释。） */
            break;
        }
        if (draining && !pending) {
            /* 排空中但还没拿到 END_OF_STREAM：让出 CPU 再问一次，别忙等。
             * 兜一个次数上限：个别解码器（尤其硬解）在 EOS 之后既不回
             * END_OF_STREAM 也不报错，一直 TRY_AGAIN。真遇到这种就在 500 轮
             * 之后当作排空结束，否则播放器又会卡在最后一帧。 */
            if (++drain_rounds > 500) {
                LP_WARN("video", "decoder never reported end of stream, giving up");
                drained = 1;
                break;
            }
            av_usleep(2000);
        }
    }

    atomic_store(&p->video.eof, 1);
    av_packet_free(&pending);
    av_frame_free(&frame);
    filter_close(p);
    return NULL;
}

/* ------------------------------------------------------------------ API --- */

int lp_video_start(LpPlayer *p)
{
    if (p->video.stream_index < 0) {
        return LP_OK;
    }
    if (open_decoder(p) != LP_OK) {
        return LP_ERR_CODEC;
    }
    /* 同 audio.c：新解码线程必须从「未结束」开始，否则上一个线程留下的
     * video.eof=1 会让结束判定立刻成立。 */
    atomic_store(&p->video.eof, 0);
    /* 连播下一个文件时也要重新获得「开播不丢帧」的豁免：这个计数只用来
     * 判断「本片是否已经出过画面」（见 wait_for_presentation）。不在这里
     * 清零，播放列表里第二个文件之后的头两秒仍会被当成晚到丢掉。 */
    p->video.frames_decoded = 0;
    p->video.last_present_at_us = 0;
    p->video.next_present_at_us = 0;
    p->video.in_flight = 0;
    lp_pq_start(&p->video.pq);
    if (pthread_create(&p->video.thread, NULL, lp_video_thread_fn, p) != 0) {
        return LP_ERR_NOMEM;
    }
    p->video.thread_started = 1;
    return LP_OK;
}

void lp_video_stop(LpPlayer *p)
{
    lp_pq_abort(&p->video.pq);
    if (p->video.thread_started) {
        int jr = pthread_join(p->video.thread, NULL);
        if (jr != 0) {
            LP_WARN("video", "pthread_join(video) failed: %d", jr);
        }
        p->video.thread_started = 0;
    }
    if (p->video.hw) {
        lp_hw_decoder_destroy(p->video.hw);
        p->video.hw = NULL;
    }
    if (p->video.avctx) {
        avcodec_free_context(&p->video.avctx);
    }
    filter_close(p);
    lp_pq_flush(&p->video.pq);
}
