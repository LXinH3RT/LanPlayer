/*
 * Video decode + presentation.
 *
 * One worker thread decodes and presents.  Presentation waits on the master
 * clock (driven by the audio sink), which is what produces A/V sync; the
 * bounded packet queue is the only back-pressure towards the demuxer, so the
 * decoder never runs further than one frame ahead of what is on screen.
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

/* Waits until the master clock reaches pts_us.
 * Returns 0 = present, 1 = too late (drop), <0 = interrupted. */
static int wait_for_presentation(LpPlayer *p, int64_t pts_us, int serial)
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
            return diff < -500000 ? 1 : 0;
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
    AVFrame *out = av_frame_alloc();
    if (!out) {
        return frame;
    }
    if (av_buffersink_get_frame(p->video.fg_sink, out) < 0) {
        av_frame_free(&out);
        return frame;
    }
    p->video.filtered = out;
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
            serial = atomic_load(&p->serial);
            continue;
        }

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
                av_usleep(2000);
                continue;
            }
        }

        int r;
        int again;
        if (p->video.hw) {
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
                int drop = wait_for_presentation(p, pts_us, serial);
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
            int drop = wait_for_presentation(p, pts_us, serial);
            if (drop < 0) {
                if (p->video.filtered) {
                    av_frame_free(&p->video.filtered);
                }
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
                lp_note_position(p, pts_us);
            }
            if (p->video.filtered) {
                av_frame_free(&p->video.filtered);
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
        pthread_join(p->video.thread, NULL);
        p->video.thread_started = 0;
    }
    if (p->video.hw) {
        lp_hw_decoder_destroy(p->video.hw);
        p->video.hw = NULL;
    }
    if (p->video.avctx) {
        avcodec_free_context(&p->video.avctx);
    }
    if (p->video.filtered) {
        av_frame_free(&p->video.filtered);
    }
    filter_close(p);
    lp_pq_flush(&p->video.pq);
}
