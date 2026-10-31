/*
 * Audio decode -> resample -> optional atempo (pitch preserving speed) ->
 * float32 ring buffer -> platform sink.
 *
 * The sink pulls in realtime from the ring, and the ring's play head is what
 * defines the audio master clock (see lp_audio_clock_seconds).  Because the
 * ring is drained by the device, the decode thread naturally blocks when it
 * gets ahead: no unbounded buffering, no drift.
 */
#include <math.h>
#include <stdlib.h>

#include "player_internal.h"

static void audio_graph_free(LpPlayer *p)
{
    if (p->audio.graph) {
        avfilter_graph_free(&p->audio.graph);
        p->audio.graph = NULL;
        p->audio.filt_src = p->audio.filt_sink = NULL;
    }
    av_frame_free(&p->audio.graph_in);
    av_frame_free(&p->audio.graph_out);
}

/* Builds "abuffer -> atempo(speed) -> abuffersink".  With speed == 1 the graph
 * is removed entirely so the common case has zero filter overhead. */
static int audio_graph_build(LpPlayer *p, double speed)
{
    audio_graph_free(p);
    p->audio.applied_speed = 1.0;
    if (fabs(speed - 1.0) < 0.001) {
        return LP_OK;
    }
    /* atempo 单级只吃 0.5–100。用户能把倍速拉到 0.25，所以低于 0.5 时串两级
     * （0.25 = atempo(0.5) 接 atempo(0.5)），否则这个档位形同虚设 —— 内核
     * 把它钳回 0.5，界面显示的却是 0.25。 */
    if (speed < LP_SPEED_MIN) {
        speed = LP_SPEED_MIN;
    }
    if (speed > LP_SPEED_MAX) {
        speed = LP_SPEED_MAX;
    }
    const AVFilter *abuf = avfilter_get_by_name("abuffer");
    const AVFilter *asink = avfilter_get_by_name("abuffersink");
    if (!abuf || !asink) {
        return LP_ERR_UNSUPPORTED;
    }
    AVFilterGraph *g = avfilter_graph_alloc();
    if (!g) {
        return LP_ERR_NOMEM;
    }
    char args[256];
    snprintf(args, sizeof(args), "sample_rate=%d:sample_fmt=flt:channel_layout=stereo:time_base=1/%d",
             p->audio.out_rate, p->audio.out_rate);
    int r = avfilter_graph_create_filter(&p->audio.filt_src, abuf, "in", args, NULL, g);
    if (r >= 0) {
        r = avfilter_graph_create_filter(&p->audio.filt_sink, asink, "out", NULL, NULL, g);
    }
    if (r >= 0) {
        /* atempo 单级只吃 0.5–100。要支持 0.25 就得串两级：0.25 = 0.5 × 0.5。
         * 只写一级的时候 libavfilter 会把 0.25 拒掉，整条滤镜图建不起来，
         * 结果是有画面没声音 —— 比钳到 0.5 更糟。 */
        char spec[96];
        if (speed < 0.5) {
            snprintf(spec, sizeof(spec), "atempo=%.4f,atempo=%.4f",
                     sqrt(speed), sqrt(speed));
        } else {
            snprintf(spec, sizeof(spec), "atempo=%.4f", speed);
        }
        r = avfilter_graph_parse_ptr(g, spec, NULL, NULL, NULL);
    }
    if (r >= 0) {
        r = avfilter_graph_config(g, NULL);
    }
    if (r < 0) {
        LP_ERROR("audio", "atempo graph failed: %d", r);
        avfilter_graph_free(&g);
        p->audio.filt_src = p->audio.filt_sink = NULL;
        return LP_ERR_CODEC;
    }
    p->audio.graph = g;
    p->audio.applied_speed = speed;
    if (!p->audio.graph_in) {
        p->audio.graph_in = av_frame_alloc();
        p->audio.graph_out = av_frame_alloc();
    }
    if (!p->audio.graph_in || !p->audio.graph_out) {
        LP_ERROR("audio", "atempo graph frames could not be allocated");
        audio_graph_free(p);
        return LP_ERR_NOMEM;
    }
    LP_INFO("audio", "atempo graph built at %.2fx", speed);
    return LP_OK;
}

/* Pushes converted PCM through the filter graph and writes the results to the
 * ring, keeping content-time bookkeeping exact across the stretch. */
static int audio_push_through_graph(LpPlayer *p, const float *pcm, int samples,
                                    double content_start)
{
    /* 两个 AVFrame 与它们的缓冲区都常驻在 LpAudioStream 里。以前每个音频帧
     * 都要 av_frame_alloc 两次、av_frame_get_buffer 一次、再 free 两次，
     * 变调播放时这段开销直接落在解码线程的实时路径上。 */
    if (!p->audio.graph_in || !p->audio.graph_out) {
        return LP_ERR_STATE;
    }
    AVFrame *in = p->audio.graph_in;
    AVFrame *out = p->audio.graph_out;
    av_frame_unref(in);
    in->format = AV_SAMPLE_FMT_FLT;
    in->sample_rate = p->audio.out_rate;
    av_channel_layout_default(&in->ch_layout, 2);
    in->nb_samples = samples;
    int r = av_frame_get_buffer(in, 0);
    if (r < 0) {
        return LP_ERR_NOMEM;
    }
    memcpy(in->data[0], pcm, (size_t)samples * 2 * sizeof(float));
    in->pts = (int64_t)(content_start * p->audio.out_rate);

    r = av_buffersrc_add_frame(p->audio.filt_src, in);
    if (r < 0) {
        return LP_ERR_CODEC;
    }
    double cursor = content_start;
    while ((r = av_buffersink_get_frame(p->audio.filt_sink, out)) >= 0) {
        int written = lp_ring_write(&p->audio.ring, (const float *)out->data[0], out->nb_samples,
                                    cursor, p->audio.applied_speed);
        if (written < 0) {
            av_frame_unref(out);
            return LP_ERR_INTERRUPTED;
        }
        cursor += (double)out->nb_samples * p->audio.applied_speed / (double)p->audio.out_rate;
        av_frame_unref(out);
    }
    return LP_OK;
}

static int audio_flush_graph(LpPlayer *p)
{
    if (!p->audio.graph) {
        return LP_OK;
    }
    AVFrame *out = p->audio.graph_out;
    if (!out) {
        return LP_ERR_NOMEM;
    }
    /* 传 NULL 给 buffersrc 表示 EOF。av_buffersrc_add_frame 带
     * av_warn_unused_result（GCC 下等价于 warn_unused_result），单纯写
     * (void)函数调用 在 GCC 上压不住警告，必须先落到变量里再 (void)。
     * flush 路径上失败也没有可补救的动作，所以是故意忽略返回值。 */
    int flush_rc = av_buffersrc_add_frame(p->audio.filt_src, NULL);
    (void)flush_rc;
    double cursor = -1;
    while (av_buffersink_get_frame(p->audio.filt_sink, out) >= 0) {
        double start = cursor >= 0 ? cursor : 0;
        lp_ring_write(&p->audio.ring, (const float *)out->data[0], out->nb_samples, start,
                      p->audio.applied_speed);
        cursor = start + (double)out->nb_samples * p->audio.applied_speed / (double)p->audio.out_rate;
        av_frame_unref(out);
    }
    av_frame_free(&out);
    return LP_OK;
}

static int open_audio_decoder(LpPlayer *p)
{
    AVStream *st = p->fmt->streams[p->audio.stream_index];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) {
        LP_ERROR("audio", "no decoder for %s", avcodec_get_name(st->codecpar->codec_id));
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
    if (avcodec_open2(ctx, codec, NULL) < 0) {
        LP_ERROR("audio", "avcodec_open2(%s) failed", codec->name);
        avcodec_free_context(&ctx);
        return LP_ERR_CODEC;
    }
    p->audio.avctx = ctx;
    p->audio.out_rate = ctx->sample_rate > 0 ? ctx->sample_rate : 48000;
    if (p->audio.out_rate < 8000) {
        p->audio.out_rate = 8000;
    }
    if (p->audio.out_rate > 192000) {
        p->audio.out_rate = 192000;
    }
    p->audio.out_channels = 2;

    AVChannelLayout out_layout;
    av_channel_layout_default(&out_layout, p->audio.out_channels);
    int r = swr_alloc_set_opts2(&p->audio.swr, &out_layout, AV_SAMPLE_FMT_FLT, p->audio.out_rate,
                                &ctx->ch_layout, ctx->sample_fmt, ctx->sample_rate, 0, NULL);
    av_channel_layout_uninit(&out_layout);
    if (r < 0 || !p->audio.swr || swr_init(p->audio.swr) < 0) {
        LP_ERROR("audio", "swr init failed");
        avcodec_free_context(&p->audio.avctx);
        return LP_ERR_CODEC;
    }

    if (lp_ring_init(&p->audio.ring, p->audio.out_channels, p->audio.out_rate,
                     LP_DEFAULT_AUDIO_LATENCY_MS) != LP_OK) {
        return LP_ERR_NOMEM;
    }
    p->sink = lp_audio_sink_create(p);
    if (!p->sink || lp_audio_sink_start(p->sink, p->audio.out_rate, p->audio.out_channels) != LP_OK) {
        LP_ERROR("audio", "audio sink start failed");
        return LP_ERR_IO;
    }
    lp_ring_set_gain(&p->audio.ring, p->muted ? 0.0 : (double)p->volume);
    LP_INFO("audio", "decode %s %dHz ch=%d -> float stereo %dHz (%s)", codec->name,
            ctx->sample_rate, ctx->ch_layout.nb_channels, p->audio.out_rate,
            lp_audio_sink_name(p->sink));
    return LP_OK;
}

static int convert_and_write(LpPlayer *p, AVFrame *frame)
{
    int cap = swr_get_out_samples(p->audio.swr, frame->nb_samples);
    if (cap <= 0) {
        return 0;
    }
    /* PCM 暂存区常驻在 LpAudioStream 里，按需扩容。以前每个音频帧都
     * malloc/free 一次（AAC 一帧 1024 采样，一小时片子约 17 万次）。 */
    if (p->audio.pcm_cap < cap) {
        float *grown = realloc(p->audio.pcm, (size_t)cap * 2 * sizeof(float));
        if (!grown) {
            return LP_ERR_NOMEM;
        }
        p->audio.pcm = grown;
        p->audio.pcm_cap = cap;
    }
    float *pcm = p->audio.pcm;
    uint8_t *out_planes[1] = {(uint8_t *)pcm};
    int got = swr_convert(p->audio.swr, out_planes, cap, (const uint8_t **)frame->extended_data,
                          frame->nb_samples);
    if (got <= 0) {
        return 0;
    }
    double tb = av_q2d(p->audio.avctx->pkt_timebase);
    if (tb <= 0) {
        tb = 1.0 / (double)p->audio.out_rate;
    }
    double content_start = frame->pts != AV_NOPTS_VALUE
                               ? (double)frame->pts * tb
                               : lp_clock_get(&p->extc);
    int rc;
    if (p->audio.graph) {
        rc = audio_push_through_graph(p, pcm, got, content_start);
    } else {
        int written = lp_ring_write(&p->audio.ring, pcm, got, content_start, 1.0);
        rc = written < 0 ? LP_ERR_INTERRUPTED : LP_OK;
    }
    p->audio.frames_decoded++;
    return rc;
}

void *lp_audio_thread_fn(void *arg)
{
    LpPlayer *p = arg;
    AVFrame *frame = av_frame_alloc();
    AVPacket *pending = NULL;
    if (!frame) {
        return NULL;
    }
    int serial = atomic_load(&p->serial);

    while (!lp_is_abort(p)) {
        if (serial != atomic_load(&p->serial)) {
            avcodec_flush_buffers(p->audio.avctx);
            swr_close(p->audio.swr);
            swr_init(p->audio.swr);
            lp_ring_flush(&p->audio.ring);
            audio_graph_free(p);
            atomic_store(&p->audio.graph_dirty, 1);
            av_packet_free(&pending);
            p->audio.draining = 0;
            atomic_store(&p->audio.eof, 0);
            serial = atomic_load(&p->serial);
            continue;
        }
        if (atomic_exchange(&p->audio.graph_dirty, 0)) {
            audio_graph_build(p, p->speed);
        }

        if (!pending && !p->audio.draining) {
            int qserial = serial;
            pending = lp_pq_get(&p->audio.pq, &qserial, 0);
            if (pending) {
                serial = qserial;
            } else if (lp_pq_aborted(&p->audio.pq)) {
                /* 停止或切轨：队列还压着包也直接退出，否则 lp_audio_stop
                 * 的 pthread_join 会永远等下去（Dart 侧同步 FFI 调用，
                 * 后果是整个 UI 线程卡死）。 */
                break;
            } else if (lp_pq_eof(&p->audio.pq)) {
                p->audio.draining = 1;
            } else {
                lp_pq_wait_more(&p->audio.pq, 0);
                continue;
            }
        }

        int r = avcodec_send_packet(p->audio.avctx, p->audio.draining ? NULL : pending);
        if (r == 0 || r == AVERROR_EOF) {
            av_packet_free(&pending);
        } else if (r != AVERROR(EAGAIN)) {
            LP_WARN("audio", "send_packet: %d", r);
            av_packet_free(&pending);
        }

        for (;;) {
            r = avcodec_receive_frame(p->audio.avctx, frame);
            if (r == AVERROR(EAGAIN)) {
                break;
            }
            if (r == AVERROR_EOF) {
                atomic_store(&p->audio.eof, 1);
                break;
            }
            if (r < 0) {
                LP_WARN("audio", "receive_frame: %d", r);
                break;
            }
            int rc = convert_and_write(p, frame);
            av_frame_unref(frame);
            if (rc == LP_ERR_INTERRUPTED) {
                goto done;
            }
            if (!p->audio.draining) {
                break; /* pull the next packet before draining further */
            }
        }

        if (p->audio.draining && !pending && !p->audio.eof) {
            continue;
        }
        if (p->audio.eof) {
            audio_flush_graph(p);
            break;
        }
    }

done:
    av_packet_free(&pending);
    av_frame_free(&frame);
    return NULL;
}

double lp_audio_clock_seconds(LpPlayer *p)
{
    return lp_ring_clock_seconds(&p->audio.ring);
}

int lp_audio_pull_pcm(LpPlayer *p, float *out, int frames)
{
    return lp_ring_read(&p->audio.ring, out, frames);
}

int lp_audio_buffered_ms(LpPlayer *p)
{
    return lp_ring_buffered_ms(&p->audio.ring, p->audio.out_rate);
}

void lp_audio_rebuild_graph(LpPlayer *p)
{
    atomic_store(&p->audio.graph_dirty, 1);
}

int lp_audio_start(LpPlayer *p)
{
    if (p->audio.stream_index < 0) {
        return LP_OK;
    }
    if (open_audio_decoder(p) != LP_OK) {
        return LP_ERR_CODEC;
    }
    /* 切轨 = 先 lp_audio_stop 再 lp_audio_start。上一个线程可能是「播到结尾
     * 排空后自然退出」的，会把 draining/eof 留在 1；新线程一进来就当成已经
     * 结束，直接退出，于是切轨之后整条音频链路静默（安卓上表现为切完音轨
     * 立刻 end of stream、没有声音）。新开一个解码线程时必须清干净。 */
    p->audio.draining = 0;
    atomic_store(&p->audio.eof, 0);
    lp_pq_start(&p->audio.pq);
    if (pthread_create(&p->audio.thread, NULL, lp_audio_thread_fn, p) != 0) {
        return LP_ERR_NOMEM;
    }
    p->audio.thread_started = 1;
    return LP_OK;
}

void lp_audio_stop(LpPlayer *p)
{
    lp_pq_abort(&p->audio.pq);
    if (p->audio.ring.buf) {
        lp_ring_abort(&p->audio.ring);
    }
    if (p->audio.thread_started) {
        pthread_join(p->audio.thread, NULL);
        p->audio.thread_started = 0;
    }
    if (p->sink) {
        lp_audio_sink_stop(p->sink);
        lp_audio_sink_destroy(p->sink);
        p->sink = NULL;
    }
    if (p->audio.swr) {
        swr_free(&p->audio.swr);
    }
    if (p->audio.avctx) {
        avcodec_free_context(&p->audio.avctx);
    }
    audio_graph_free(p);
    free(p->audio.pcm);
    p->audio.pcm = NULL;
    p->audio.pcm_cap = 0;
    if (p->audio.ring.buf) {
        lp_ring_destroy(&p->audio.ring);
    }
    lp_pq_flush(&p->audio.pq);
}
