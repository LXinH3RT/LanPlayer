/*
 * 缩略图提取：打开一个媒体文件，定位到靠前的位置，解码出一帧，
 * 缩放到指定宽度后以 RGBA 返回。
 *
 * 为什么不复用播放器：播放器有线程、时钟、音频设备、字幕，为一个 100ms
 * 的封面图开一整套流水线代价太大。这里是一个独立的一次性函数，自己开
 * 自己的 AVFormatContext，取完帧就把所有东西释放掉。
 *
 * 为什么返回 RAW RGBA 而不是编码成 JPEG/PNG：
 *   - 内核不用为了封面图链接编码器（Apple/Android 的 FFmpeg 是按需裁剪的，
 *     Windows 那份是全量的，三端行为要一致就必须绕开编码器）；
 *   - Dart 侧 ui.decodeImageFromPixels 要的正好是 RGBA8888，
 *     顺手避开了 BGRA/RGBA 通道顺序那个老坑（见 packages/lanplayer_video 的
 *     pixel_swizzle.h）。
 */
#include <stdlib.h>
#include <time.h>

#if defined(_WIN32)
#include <windows.h>
#endif

#include "player_internal.h"
#include "source/source_internal.h"

/* 一帧缩略图最多这么宽；调用方可以要更小的，要更大的也不给。 */
#define LP_THUMB_MAX_WIDTH 640
#define LP_THUMB_MAX_PACKETS 4000
#define LP_THUMB_SEEK_CAP_US (30LL * 1000000LL)

/* 中断标志：截图是同步调用，用户可能在 UI 上取消或者切走页面，
 * 这里只用一个本地原子标志，不牵扯播放器的 abort_request。
 *
 * 同时带一个**墙钟截止**：只有 abort 标志是不够的 —— 没有任何人会在
 * 同步调用里来置它，等于没有超时。FLV 这类容器在 open 阶段会先扫一段
 * 数据估时长，遇到慢盘/慢网络就会长时间不返回，界面表现为卡死。
 * 有了 deadline，中断回调真正能把它掐断。 */
typedef struct LpThumbCtx {
    atomic_int abort;
    int64_t deadline_ms; /* 0 = 不限 */
} LpThumbCtx;

static int64_t thumb_now_ms(void)
{
#if defined(_WIN32)
    return (int64_t)GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
}

/* 一次封面最多允许花多久。超过就放弃这一帧、退回图标 —— 宁可没有封面，
 * 也不能让「打开文件夹」卡住。 */
#define LP_THUMB_BUDGET_MS 4000

static int thumb_interrupt_cb(void *opaque)
{
    LpThumbCtx *ctx = opaque;
    if (!ctx) {
        return 0;
    }
    if (atomic_load(&ctx->abort)) {
        return 1;
    }
    if (ctx->deadline_ms > 0 && thumb_now_ms() > ctx->deadline_ms) {
        atomic_store(&ctx->abort, 1);
        return 1;
    }
    return 0;
}

/* 打开输入。返回 0 表示成功；失败时 err 里有原因。
 * io* 由调用方负责 lp_io_close；返回 0 时 fmt 一定非空。 */
static int thumb_open_input(const char *url, const char *options_json, LpThumbCtx *ctx,
                            AVFormatContext **out_fmt, LpIo **out_io, char *err, size_t errlen)
{
    *out_fmt = NULL;
    *out_io = NULL;

    LpUrl parsed;
    if (lp_url_parse(url, &parsed) != LP_OK) {
        snprintf(err, errlen, "invalid url");
        return LP_ERR_ARGUMENT;
    }
    LpSourceOptions opts;
    lp_source_options_parse(options_json, &opts);
    if (parsed.user[0]) {
        snprintf(opts.user, sizeof(opts.user), "%s", parsed.user);
    }
    if (parsed.password[0]) {
        snprintf(opts.password, sizeof(opts.password), "%s", parsed.password);
    }

    AVDictionary *dict = NULL;
    av_dict_set(&dict, "rw_timeout", "8000000", 0);
    av_dict_set(&dict, "probesize", "4194304", 0);
    av_dict_set(&dict, "analyzeduration", "3000000", 0);

    AVFormatContext *fmt = NULL;
    int custom_io = parsed.is_smb || strcmp(parsed.scheme, "file") == 0;
    if (custom_io) {
        LpIo *io = lp_io_open(url, &opts, err, errlen);
        if (!io) {
            av_dict_free(&dict);
            return LP_ERR_IO;
        }
        if (lp_io_attach_avio(io, &fmt, err, errlen) != LP_OK) {
            lp_io_close(io);
            av_dict_free(&dict);
            return LP_ERR_NOMEM;
        }
        fmt->interrupt_callback.callback = thumb_interrupt_cb;
        fmt->interrupt_callback.opaque = ctx;
        /* 自定义 IO 时 url 传 NULL：fmt->pb 已经挂好了我们自己的 AVIO，
         * 再传 url 会让 FFmpeg 有机会按协议重新打开一次，绕开下面设置的
         * 超时与中断回调（demux.c 的播放路径也是这么传的）。 */
        int r = avformat_open_input(&fmt, NULL, NULL, &dict);
        av_dict_free(&dict);
        if (r < 0) {
            avformat_free_context(fmt);
            lp_io_close(io);
            snprintf(err, errlen, "avformat_open_input: %s", av_err2str(r));
            return r == AVERROR(EACCES) ? LP_ERR_AUTH : LP_ERR_IO;
        }
        *out_io = io;
    } else {
        fmt = avformat_alloc_context();
        if (!fmt) {
            av_dict_free(&dict);
            return LP_ERR_NOMEM;
        }
        fmt->interrupt_callback.callback = thumb_interrupt_cb;
        fmt->interrupt_callback.opaque = ctx;
        int r = avformat_open_input(&fmt, url, NULL, &dict);
        av_dict_free(&dict);
        if (r < 0) {
            avformat_free_context(fmt);
            snprintf(err, errlen, "avformat_open_input: %s", av_err2str(r));
            return r == AVERROR(EACCES) ? LP_ERR_AUTH : LP_ERR_IO;
        }
    }

    int r = avformat_find_stream_info(fmt, NULL);
    if (r < 0) {
        LP_WARN("thumb", "find_stream_info failed: %s", av_err2str(r));
    }
    *out_fmt = fmt;
    return LP_OK;
}

/* 把一帧转成 RGBA 并缩放到 out_w × out_h。返回 malloc 的缓冲区，失败返回 NULL。 */
static uint8_t *thumb_convert(AVFrame *frame, int out_w, int out_h)
{
    struct SwsContext *sws = sws_getContext(frame->width, frame->height,
                                            (enum AVPixelFormat)frame->format,
                                            out_w, out_h, AV_PIX_FMT_RGBA,
                                            SWS_BILINEAR, NULL, NULL, NULL);
    if (!sws) {
        return NULL;
    }
    uint8_t *pixels = malloc((size_t)out_w * (size_t)out_h * 4);
    if (!pixels) {
        sws_freeContext(sws);
        return NULL;
    }
    uint8_t *dst[4] = {pixels, NULL, NULL, NULL};
    int dst_linesize[4] = {out_w * 4, 0, 0, 0};
    int scaled = sws_scale(sws, (const uint8_t *const *)frame->data, frame->linesize,
                           0, frame->height, dst, dst_linesize);
    sws_freeContext(sws);
    if (scaled <= 0) {
        free(pixels);
        return NULL;
    }
    return pixels;
}

int32_t lp_source_thumbnail(const char *url, const char *options_json, int32_t max_width,
                            void **out_pixels, int32_t *out_width, int32_t *out_height)
{
    if (!url || !out_pixels || !out_width || !out_height) {
        return LP_ERR_ARGUMENT;
    }
    *out_pixels = NULL;
    *out_width = 0;
    *out_height = 0;
    if (max_width <= 0) {
        max_width = 320;
    }
    if (max_width > LP_THUMB_MAX_WIDTH) {
        max_width = LP_THUMB_MAX_WIDTH;
    }

    LpThumbCtx ctx;
    atomic_init(&ctx.abort, 0);
    ctx.deadline_ms = thumb_now_ms() + LP_THUMB_BUDGET_MS;

    char err[256] = {0};
    AVFormatContext *fmt = NULL;
    LpIo *io = NULL;
    int rc = thumb_open_input(url, options_json, &ctx, &fmt, &io, err, sizeof(err));
    if (rc != LP_OK) {
        lp_source_set_last_error(err[0] ? err : "open failed");
        return rc;
    }

    int vindex = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vindex < 0) {
        lp_source_set_last_error("no video stream");
        avformat_close_input(&fmt);
        lp_io_close(io);
        return LP_ERR_UNSUPPORTED;
    }
    AVStream *st = fmt->streams[vindex];

    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) {
        char msg[128];
        snprintf(msg, sizeof(msg), "no decoder for %s",
                 avcodec_get_name(st->codecpar->codec_id));
        lp_source_set_last_error(msg);
        avformat_close_input(&fmt);
        lp_io_close(io);
        return LP_ERR_UNSUPPORTED;
    }
    AVCodecContext *avctx = avcodec_alloc_context3(codec);
    if (!avctx) {
        avformat_close_input(&fmt);
        lp_io_close(io);
        return LP_ERR_NOMEM;
    }
    if (avcodec_parameters_to_context(avctx, st->codecpar) < 0) {
        avcodec_free_context(&avctx);
        avformat_close_input(&fmt);
        lp_io_close(io);
        return LP_ERR_CODEC;
    }
    avctx->pkt_timebase = st->time_base;
    avctx->thread_count = 1; /* 只要一帧，多线程解码反而是纯开销 */
    LP_DEBUG("thumb", "stage=codec %s %dx%d", codec->name,
             st->codecpar->width, st->codecpar->height);
    if (avcodec_open2(avctx, codec, NULL) < 0) {
        char msg[128];
        snprintf(msg, sizeof(msg), "avcodec_open2(%s) failed", codec->name);
        lp_source_set_last_error(msg);
        avcodec_free_context(&avctx);
        avformat_close_input(&fmt);
        lp_io_close(io);
        return LP_ERR_CODEC;
    }

    /* 跳到片头之后一点：第 0 帧常常是黑场/台标，10% 处更像"内容"。
     * 片长未知或很短就老实从头解。 */
    int64_t duration_us = fmt->duration != AV_NOPTS_VALUE ? fmt->duration : 0;
    int64_t target_us = duration_us > 0 ? duration_us / 10 : 0;
    if (target_us > LP_THUMB_SEEK_CAP_US) {
        target_us = LP_THUMB_SEEK_CAP_US;
    }
    LP_DEBUG("thumb", "stage=seek target=%lld us", (long long)target_us);
    if (target_us > 0) {
        /* av_seek_frame 的第 3 个参数是 **stream 时间基**，不是微秒。
         *
         * 以前直接把微秒传进去：对 time_base = 1/1000（mp4 常见）的流，
         * 30 秒的位置会被当成 30000000 个 tick（≈ 8.3 小时），seek 于是
         * 落到文件末尾，一帧都解不出来；FLV 的 time_base 是 1/1000 且没有
         * 索引，av_seek_frame 只能按字节粗略估算，于是跳到 242 MB 的
         * offset（文件总长正好也是 242 MB），返回 rc=-12「no decodable
         * frame」—— 用户看到的就是「这个文件夹里的视频都没有封面」。 */
        int64_t ts = av_rescale_q(target_us, (AVRational){1, 1000000}, st->time_base);
        if (fmt->start_time != AV_NOPTS_VALUE) {
            int64_t start_ts =
                av_rescale_q(fmt->start_time, (AVRational){1, 1000000}, st->time_base);
            ts += start_ts;
        }
        LP_DEBUG("thumb", "seek ts=%lld (tb=%d/%d)", (long long)ts,
                 st->time_base.num, st->time_base.den);
        if (av_seek_frame(fmt, vindex, ts, AVSEEK_FLAG_BACKWARD) >= 0) {
            avcodec_flush_buffers(avctx);
        } else {
            /* 没有索引的容器（FLV 常见）seek 可能直接失败：老实从头解，
             * 封面会偏片头一点，但总比没有强。 */
            LP_DEBUG("thumb", "seek failed, decoding from start");
            av_seek_frame(fmt, -1, 0, AVSEEK_FLAG_BACKWARD);
            avcodec_flush_buffers(avctx);
        }
    }

    AVFrame *frame = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    uint8_t *pixels = NULL;
    int out_w = 0, out_h = 0;
    int packets = 0;
    int draining = 0;

    if (!frame || !pkt) {
        av_frame_free(&frame);
        av_packet_free(&pkt);
        avcodec_free_context(&avctx);
        avformat_close_input(&fmt);
        lp_io_close(io);
        return LP_ERR_NOMEM;
    }

    /* guard：draining 阶段 packets 不再递增，光靠它做上限会变成死循环。
     * FLV（以及任何「解码器要吃掉多个包才吐一帧」的容器）一旦在 drain 时
     * 反复拿到 AVERROR(EAGAIN)，这里就会空转 —— 实测本地 66 KB 的小 flv
     * 也能卡满 25 秒以上不返回，用户看到的就是「打开文件夹卡死」。
     * 所以再加一个硬迭代上限，保证这个函数一定会返回。 */
    const int max_iters = LP_THUMB_MAX_PACKETS * 2;
    int iters = 0;
    LP_DEBUG("thumb", "stage=decode-loop begin");

    while (!atomic_load(&ctx.abort) && packets < LP_THUMB_MAX_PACKETS &&
           iters++ < max_iters) {
        int send_rc;
        if (draining) {
            send_rc = avcodec_send_packet(avctx, NULL);
            /* drain 阶段再送 EOF 就是「解码器已经空了」，没有更多帧可拿。 */
            if (send_rc == AVERROR_EOF) {
                break;
            }
        } else {
            int r = av_read_frame(fmt, pkt);
            if (r < 0) {
                draining = 1;
                continue;
            }
            if (pkt->stream_index != vindex) {
                av_packet_unref(pkt);
                continue;
            }
            packets++;
            send_rc = avcodec_send_packet(avctx, pkt);
            av_packet_unref(pkt);
        }

        if (send_rc < 0 && send_rc != AVERROR(EAGAIN) && send_rc != AVERROR_EOF) {
            if (draining) {
                break;
            }
            continue;
        }

        int recv_rc = avcodec_receive_frame(avctx, frame);
        if (recv_rc == 0) {
            /* 只接受有像素的帧；某些容器会先吐一帧空的。 */
            if (frame->width > 0 && frame->height > 0 && frame->data[0]) {
                out_w = frame->width < max_width ? frame->width : max_width;
                out_h = (int)((int64_t)frame->height * out_w / frame->width);
                if (out_h < 1) {
                    out_h = 1;
                }
                pixels = thumb_convert(frame, out_w, out_h);
                av_frame_unref(frame);
                break;
            }
            av_frame_unref(frame);
        } else if (recv_rc == AVERROR_EOF) {
            break;
        } else if (recv_rc != AVERROR(EAGAIN)) {
            break;
        }

        /* draining 且这一轮既没送出包也没取到帧：再转下去也没有意义。 */
        if (draining && send_rc == AVERROR_EOF) {
            break;
        }
    }

    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&avctx);
    avformat_close_input(&fmt);
    lp_io_close(io);

    if (!pixels) {
        lp_source_set_last_error("no decodable frame");
        return LP_ERR_END_OF_STREAM;
    }
    *out_pixels = pixels;
    *out_width = out_w;
    *out_height = out_h;
    return LP_OK;
}

void lp_pixels_free(void *pixels)
{
    free(pixels);
}
