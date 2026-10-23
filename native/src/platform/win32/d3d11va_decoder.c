/*
 * Windows hardware decoding through D3D11VA.
 *
 * The decoder keeps the picture on the GPU while it is being decoded, then
 * downloads the finished frame to NV12 right before it is shown.  That copy is
 * the price of not tying the GDI back buffer (and the Flutter texture bridge,
 * which shares it) to a D3D11 texture: one readback per presented frame, while
 * the expensive part -- motion compensation and entropy decoding -- still runs
 * in the fixed-function video engine.
 *
 * Only the generic FFmpeg hardware API is used here (av_hwdevice_ctx_create,
 * AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX, av_hwframe_transfer_data), so this
 * file needs no d3d11 headers and the DLL links no extra import library.
 */
#if defined(_WIN32)

#include <stdlib.h>
#include <string.h>

#include "player_internal.h"

struct LpVideoDecoder {
    AVBufferRef *device;
    AVCodecContext *ctx;
    AVFrame *frame;   /* receives the hardware frame from avcodec */
    AVFrame *sw;      /* reusable NV12 target for the download */
    AVFrame *pending; /* handed to the core, released by present */
    AVRational tb;
    LpPlayer *player;
    int width;
    int height;
    int eos;
    /* Set once the hwaccel hands us an ordinary system-memory frame, which
     * means libavcodec silently fell back to software for this stream. */
    int sw_fallback;
};

/* The core asks for a pixel format; pick the hardware one if it is offered. */
static enum AVPixelFormat d3d11_get_format(AVCodecContext *ctx, const enum AVPixelFormat *fmts)
{
    (void)ctx;
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++) {
        if (*p == AV_PIX_FMT_D3D11) {
            return *p;
        }
    }
    return AV_PIX_FMT_NONE;
}

/* Profiles that no shipping D3D11VA decoder implements.  Handling them is not
 * a matter of speed: the hardware rejects the first frame and libavcodec falls
 * back to software *inside* the hardware codec context, where the picture has
 * to be decoded single-threaded (thread_count = 1, see init) because the codec
 * still owns a D3D11 device.  A 1080p 10-bit H.264 then decodes at well under
 * one frame per second, which the user sees as a permanent stall -- the video
 * sits on the first picture while the clock runs away from it.  The ordinary
 * software decoder does the same work on all cores and keeps up easily, so
 * these profiles must never be routed through the hardware path. */
static int profile_needs_software(int codec_id, int profile)
{
    if (codec_id == AV_CODEC_ID_H264) {
        /* High 10, High 4:2:2, High 4:4:4 and their predictive variants. */
        return profile == AV_PROFILE_H264_HIGH_10 || profile == AV_PROFILE_H264_HIGH_10_INTRA ||
               profile == AV_PROFILE_H264_HIGH_422 || profile == AV_PROFILE_H264_HIGH_422_INTRA ||
               profile == AV_PROFILE_H264_HIGH_444_PREDICTIVE ||
               profile == AV_PROFILE_H264_HIGH_444_INTRA;
    }
    return 0;
}

/* Does this codec expose a d3d11va hwaccel that takes our device context? */
static int codec_supports_d3d11(const AVCodec *codec)
{
    for (int i = 0;; i++) {
        const AVCodecHWConfig *c = avcodec_get_hw_config(codec, i);
        if (!c) {
            return 0;
        }
        if (c->device_type == AV_HWDEVICE_TYPE_D3D11VA &&
            (c->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
            return 1;
        }
    }
}

LpVideoDecoder *lp_hw_decoder_create(void)
{
    LpVideoDecoder *d = calloc(1, sizeof(*d));
    return d;
}

/* Cached because creating a D3D11 device costs tens of milliseconds and the
 * core asks once per opened stream. */
int lp_hw_decoder_available(void)
{
    static int cached = -1;
    if (cached < 0) {
        AVBufferRef *dev = NULL;
        int r = av_hwdevice_ctx_create(&dev, AV_HWDEVICE_TYPE_D3D11VA, NULL, NULL, 0);
        cached = r == 0 ? 1 : 0;
        av_buffer_unref(&dev);
        if (!cached) {
            LP_INFO("d3d11va", "no hardware device: %d", r);
        }
    }
    return cached;
}

const char *lp_hw_decoder_name(void)
{
    return "d3d11va";
}

int lp_hw_decoder_init(LpVideoDecoder *d, const LpVideoDecoderConfig *cfg, char *err, size_t errlen)
{
    if (!d || !cfg || !cfg->par) {
        return LP_ERR_ARGUMENT;
    }
    d->tb = cfg->time_base;
    d->player = cfg->player;

    const AVCodec *codec = avcodec_find_decoder(cfg->codec_id);
    if (!codec) {
        snprintf(err, errlen, "no decoder for %s", avcodec_get_name(cfg->codec_id));
        return LP_ERR_UNSUPPORTED;
    }
    if (!codec_supports_d3d11(codec)) {
        snprintf(err, errlen, "%s has no d3d11va support", codec->name);
        return LP_ERR_UNSUPPORTED;
    }
    if (profile_needs_software(cfg->codec_id, cfg->par->profile)) {
        snprintf(err, errlen, "%s profile %d is not decoded by hardware",
                 avcodec_get_name(cfg->codec_id), cfg->par->profile);
        return LP_ERR_UNSUPPORTED;
    }

    int r = av_hwdevice_ctx_create(&d->device, AV_HWDEVICE_TYPE_D3D11VA, NULL, NULL, 0);
    if (r < 0) {
        snprintf(err, errlen, "no D3D11 device (%d)", r);
        return LP_ERR_UNSUPPORTED;
    }

    d->ctx = avcodec_alloc_context3(codec);
    if (!d->ctx) {
        snprintf(err, errlen, "out of memory");
        return LP_ERR_NOMEM;
    }
    if (avcodec_parameters_to_context(d->ctx, cfg->par) < 0) {
        snprintf(err, errlen, "cannot copy codec parameters");
        return LP_ERR_CODEC;
    }
    d->ctx->pkt_timebase = cfg->time_base;
    d->ctx->hw_device_ctx = av_buffer_ref(d->device);
    d->ctx->get_format = d3d11_get_format;
    d->ctx->thread_count = 1; /* one decode thread; more would serialise on the device */
    r = avcodec_open2(d->ctx, codec, NULL);
    if (r < 0) {
        snprintf(err, errlen, "avcodec_open2(%s): %d", codec->name, r);
        return LP_ERR_CODEC;
    }

    d->frame = av_frame_alloc();
    d->sw = av_frame_alloc();
    d->pending = av_frame_alloc();
    if (!d->frame || !d->sw || !d->pending) {
        snprintf(err, errlen, "out of memory");
        return LP_ERR_NOMEM;
    }
    d->width = cfg->width;
    d->height = cfg->height;
    LP_INFO("d3d11va", "device ready %dx%d (%s) profile=%d fmt=%s", d->width, d->height,
            codec->name, cfg->par->profile, av_get_pix_fmt_name((enum AVPixelFormat)cfg->par->format)
                ? av_get_pix_fmt_name((enum AVPixelFormat)cfg->par->format)
                : "?");
    return LP_OK;
}

int lp_hw_decoder_send(LpVideoDecoder *d, const AVPacket *pkt)
{
    if (!d || !d->ctx) {
        return LP_ERR_STATE;
    }
    if (!pkt) {
        d->eos = 1;
        avcodec_send_packet(d->ctx, NULL);
        return LP_OK;
    }
    int r = avcodec_send_packet(d->ctx, pkt);
    if (r == AVERROR(EAGAIN)) {
        return LP_ERR_AGAIN;
    }
    if (r == AVERROR_EOF) {
        d->eos = 1;
        return LP_ERR_END_OF_STREAM;
    }
    if (r < 0) {
        LP_WARN("d3d11va", "send_packet: %d", r);
        return LP_ERR_CODEC;
    }
    return LP_OK;
}

int lp_hw_decoder_receive(LpVideoDecoder *d, LpDecodedFrame *out)
{
    if (!d || !d->ctx || !out) {
        return LP_ERR_ARGUMENT;
    }
    av_frame_unref(d->frame);
    int r = avcodec_receive_frame(d->ctx, d->frame);
    if (r == AVERROR(EAGAIN)) {
        return LP_ERR_AGAIN;
    }
    if (r == AVERROR_EOF) {
        return LP_ERR_END_OF_STREAM;
    }
    if (r < 0) {
        LP_WARN("d3d11va", "receive_frame: %d", r);
        return LP_ERR_CODEC;
    }

    int64_t pts = d->frame->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE) {
        pts = d->frame->pts;
    }
    int64_t pts_us = -1;
    if (pts != AV_NOPTS_VALUE && d->tb.num > 0 && d->tb.den > 0) {
        pts_us = av_rescale_q(pts, d->tb, AV_TIME_BASE_Q);
    }

    /* The core waits on the master clock between receive and present, so the
     * picture has to outlive the call: move it into the pending slot. */
    int fw = d->frame->width > 0 ? d->frame->width : d->width;
    int fh = d->frame->height > 0 ? d->frame->height : d->height;
    av_frame_unref(d->pending);
    av_frame_move_ref(d->pending, d->frame);

    out->kind = LP_DEC_HW_FRAME;
    out->handle = d->pending;
    out->pts_us = pts_us;
    out->width = fw;
    out->height = fh;
    return LP_OK;
}

int lp_hw_decoder_present(LpVideoDecoder *d, LpDecodedFrame *f)
{
    if (!d || !f) {
        return LP_ERR_ARGUMENT;
    }
    AVFrame *hf = (AVFrame *)f->handle;
    f->handle = NULL;
    if (!hf) {
        return LP_OK;
    }
    if (!d->player || !d->sw) {
        av_frame_unref(hf);
        return LP_ERR_STATE;
    }
    /* The decoder can quietly fall back to software mid-stream: a profile the
     * GPU does not implement (10-bit H.264 High 10 is the common one) makes the
     * hwaccel reject the first frame, after which libavcodec keeps decoding in
     * software and hands us ordinary system-memory frames.  Downloading those
     * returns EINVAL and throws away every frame, which looks exactly like a
     * decoder that never produces pictures.  Software frames are already where
     * the render path wants them: draw them directly. */
    if (hf->format != AV_PIX_FMT_D3D11 && !hf->hw_frames_ctx) {
        if (!d->sw_fallback) {
            d->sw_fallback = 1;
            LP_WARN("d3d11va", "hardware decoder fell back to software frames (%s); "
                               "the hwaccel does not implement this profile",
                    av_get_pix_fmt_name((enum AVPixelFormat)hf->format)
                        ? av_get_pix_fmt_name((enum AVPixelFormat)hf->format)
                        : "?");
        }
        lp_render_draw(d->player, hf);
        av_frame_unref(hf);
        return LP_OK;
    }
    /* Hardware -> NV12 in system memory, then the normal render path (which
     * also blends graphics subtitles and notifies the Flutter texture). */
    int r = av_hwframe_transfer_data(d->sw, hf, 0);
    if (r < 0) {
        LP_WARN("d3d11va", "hwframe_transfer_data: %d", r);
        av_frame_unref(d->sw);
        av_frame_unref(hf);
        return LP_ERR_CODEC;
    }
    lp_render_draw(d->player, d->sw);
    av_frame_unref(d->sw);
    av_frame_unref(hf);
    return LP_OK;
}

void lp_hw_decoder_flush(LpVideoDecoder *d)
{
    if (!d) {
        return;
    }
    if (d->ctx) {
        avcodec_flush_buffers(d->ctx);
    }
    if (d->frame) {
        av_frame_unref(d->frame);
    }
    if (d->pending) {
        av_frame_unref(d->pending);
    }
    if (d->sw) {
        av_frame_unref(d->sw);
    }
    d->eos = 0;
}

void lp_hw_decoder_destroy(LpVideoDecoder *d)
{
    if (!d) {
        return;
    }
    lp_hw_decoder_flush(d);
    av_frame_free(&d->frame);
    av_frame_free(&d->sw);
    av_frame_free(&d->pending);
    if (d->ctx) {
        avcodec_free_context(&d->ctx);
    }
    av_buffer_unref(&d->device);
    free(d);
}

#endif /* _WIN32 */
