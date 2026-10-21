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

#include "player_internal.h"
#include "source/source_internal.h"

/* 一帧缩略图最多这么宽；调用方可以要更小的，要更大的也不给。 */
#define LP_THUMB_MAX_WIDTH 640
#define LP_THUMB_MAX_PACKETS 4000
#define LP_THUMB_SEEK_CAP_US (30LL * 1000000LL)

/* 中断标志：截图是同步调用，用户可能在 UI 上取消或者切走页面，
 * 这里只用一个本地原子标志，不牵扯播放器的 abort_request。 */
typedef struct LpThumbCtx {
    atomic_int abort;
} LpThumbCtx;

static int thumb_interrupt_cb(void *opaque)
{
    LpThumbCtx *ctx = opaque;
    return ctx && atomic_load(&ctx->abort) ? 1 : 0;
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
        int r = avformat_open_input(&fmt, url, NULL, &dict);
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
    if (target_us > 0) {
        int64_t ts = target_us;
        if (fmt->start_time != AV_NOPTS_VALUE) {
            ts += fmt->start_time;
        }
        if (av_seek_frame(fmt, vindex, ts, AVSEEK_FLAG_BACKWARD) >= 0) {
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

    while (!atomic_load(&ctx.abort) && packets < LP_THUMB_MAX_PACKETS) {
        int send_rc;
        if (draining) {
            send_rc = avcodec_send_packet(avctx, NULL);
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
        if (draining && packets >= LP_THUMB_MAX_PACKETS) {
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
