/*
 * Android hardware decoding through NDK MediaCodec.
 *
 * Frames are decoded straight into the ANativeWindow owned by the Flutter
 * platform view (zero copy): only the output buffer index is kept, and the
 * buffer is released with render=true exactly when the master clock reaches its
 * presentation time.  That is what makes the pacing identical to a native
 * player while leaving YUV conversion to the GPU.
 */
#if defined(__ANDROID__)

#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>

#include <stdlib.h>

#include "player_internal.h"

struct LpVideoDecoder {
    AMediaCodec *codec;
    AMediaFormat *format;
    int width;
    int height;
    int input_eos;
    int output_eos;
    int configured;
    AVRational tb;
    const char *mime;
    int64_t queued_frames;
};

static const char *mime_for_codec(enum AVCodecID id)
{
    switch (id) {
    case AV_CODEC_ID_H264: return "video/avc";
    case AV_CODEC_ID_HEVC: return "video/hevc";
    case AV_CODEC_ID_VP8: return "video/x-vnd.on2.vp8";
    case AV_CODEC_ID_VP9: return "video/x-vnd.on2.vp9";
    case AV_CODEC_ID_AV1: return "video/av01";
    case AV_CODEC_ID_MPEG4: return "video/mp4v-es";
    case AV_CODEC_ID_MPEG2VIDEO: return "video/mpeg2";
    case AV_CODEC_ID_H263: return "video/3gpp";
    default: return NULL;
    }
}

LpVideoDecoder *lp_hw_decoder_create(void)
{
    LpVideoDecoder *d = calloc(1, sizeof(*d));
    return d;
}

int lp_hw_decoder_available(void)
{
    return 1;
}

const char *lp_hw_decoder_name(void)
{
    return "mediacodec";
}

int lp_hw_decoder_init(LpVideoDecoder *d, const LpVideoDecoderConfig *cfg, char *err, size_t errlen)
{
    if (!d || !cfg) {
        return LP_ERR_ARGUMENT;
    }
    d->mime = mime_for_codec(cfg->codec_id);
    if (!d->mime) {
        snprintf(err, errlen, "no MediaCodec MIME for %s", avcodec_get_name(cfg->codec_id));
        return LP_ERR_UNSUPPORTED;
    }
    if (!cfg->native_window) {
        /* Without a surface MediaCodec would hand back ByteBuffers; the software
         * path is cheaper than converting them. */
        snprintf(err, errlen, "no surface available");
        return LP_ERR_UNSUPPORTED;
    }
    d->codec = AMediaCodec_createDecoderByType(d->mime);
    if (!d->codec) {
        snprintf(err, errlen, "AMediaCodec_createDecoderByType(%s) failed", d->mime);
        return LP_ERR_CODEC;
    }
    d->format = AMediaFormat_new();
    AMediaFormat_setString(d->format, AMEDIAFORMAT_KEY_MIME, d->mime);
    AMediaFormat_setInt32(d->format, AMEDIAFORMAT_KEY_WIDTH, cfg->width);
    AMediaFormat_setInt32(d->format, AMEDIAFORMAT_KEY_HEIGHT, cfg->height);
    if (cfg->par && cfg->par->extradata && cfg->par->extradata_size > 0) {
        AMediaFormat_setBuffer(d->format, "csd-0", cfg->par->extradata, (size_t)cfg->par->extradata_size);
        if (cfg->par->extradata_size > 0) {
            /* Some decoders want the parameter sets split; csd-0 with the full
             * avcC/hvcC box is accepted by every AOSP and vendor codec we target. */
        }
    }
    media_status_t st =
        AMediaCodec_configure(d->codec, d->format, (ANativeWindow *)cfg->native_window, NULL, 0);
    if (st != AMEDIA_OK) {
        snprintf(err, errlen, "AMediaCodec_configure failed: %d", (int)st);
        AMediaCodec_delete(d->codec);
        d->codec = NULL;
        AMediaFormat_delete(d->format);
        d->format = NULL;
        return LP_ERR_CODEC;
    }
    st = AMediaCodec_start(d->codec);
    if (st != AMEDIA_OK) {
        snprintf(err, errlen, "AMediaCodec_start failed: %d", (int)st);
        AMediaCodec_delete(d->codec);
        d->codec = NULL;
        return LP_ERR_CODEC;
    }
    d->width = cfg->width;
    d->height = cfg->height;
    d->tb = cfg->time_base;
    d->configured = 1;
    LP_INFO("mediacodec", "configured %s %dx%d", d->mime, d->width, d->height);
    return LP_OK;
}

int lp_hw_decoder_send(LpVideoDecoder *d, const AVPacket *pkt)
{
    if (!d || !d->codec) {
        return LP_ERR_STATE;
    }
    ssize_t idx = AMediaCodec_dequeueInputBuffer(d->codec, 5 * 1000);
    if (idx == AMEDIACODEC_INFO_TRY_AGAIN_LATER || idx < 0) {
        return LP_ERR_AGAIN;
    }
    size_t cap = 0;
    uint8_t *buf = AMediaCodec_getInputBuffer(d->codec, (size_t)idx, &cap);
    if (!buf) {
        return LP_ERR_CODEC;
    }
    if (!pkt) {
        AMediaCodec_queueInputBuffer(d->codec, (size_t)idx, 0, 0, 0,
                                     AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
        d->input_eos = 1;
        return LP_OK;
    }
    size_t size = (size_t)pkt->size;
    if (size > cap) {
        /* Should not happen for video packets, but never overflow the buffer. */
        size = cap;
    }
    memcpy(buf, pkt->data, size);
    int64_t pts_us = 0;
    if (pkt->pts != AV_NOPTS_VALUE) {
        pts_us = av_rescale_q(pkt->pts, d->tb, AV_TIME_BASE_Q);
    }
    AMediaCodec_queueInputBuffer(d->codec, (size_t)idx, 0, size, (uint64_t)pts_us, 0);
    d->queued_frames++;
    return LP_OK;
}

int lp_hw_decoder_receive(LpVideoDecoder *d, LpDecodedFrame *out)
{
    if (!d || !d->codec || !out) {
        return LP_ERR_STATE;
    }
    for (;;) {
        AMediaCodecBufferInfo info;
        memset(&info, 0, sizeof(info));
        ssize_t idx = AMediaCodec_dequeueOutputBuffer(d->codec, &info, 10 * 1000);
        if (idx == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
            AMediaFormat *fmt = AMediaCodec_getOutputFormat(d->codec);
            if (fmt) {
                AMediaFormat_delete(fmt);
            }
            continue;
        }
        if (idx == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED ||
            idx == AMEDIACODEC_INFO_TRY_AGAIN_LATER) {
            if (d->output_eos) {
                return LP_ERR_END_OF_STREAM;
            }
            return LP_ERR_AGAIN;
        }
        if (idx < 0) {
            return LP_ERR_CODEC;
        }
        if (info.flags & AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG) {
            AMediaCodec_releaseOutputBuffer(d->codec, (size_t)idx, false);
            continue;
        }
        if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) {
            AMediaCodec_releaseOutputBuffer(d->codec, (size_t)idx, false);
            d->output_eos = 1;
            return LP_ERR_END_OF_STREAM;
        }
        out->kind = LP_DEC_SURFACE;
        out->index = (int)idx;
        out->handle = NULL;
        out->pts_us = info.presentationTimeUs;
        out->width = d->width;
        out->height = d->height;
        return LP_OK;
    }
}

int lp_hw_decoder_present(LpVideoDecoder *d, LpDecodedFrame *f)
{
    if (!d || !d->codec || !f) {
        return LP_ERR_ARGUMENT;
    }
    /* render=true: the codec copies the frame into the surface right now. */
    media_status_t st = AMediaCodec_releaseOutputBuffer(d->codec, (size_t)f->index, true);
    return st == AMEDIA_OK ? LP_OK : LP_ERR_CODEC;
}

void lp_hw_decoder_flush(LpVideoDecoder *d)
{
    if (!d || !d->codec) {
        return;
    }
    AMediaCodec_flush(d->codec);
    d->input_eos = 0;
    d->output_eos = 0;
    d->queued_frames = 0;
}

void lp_hw_decoder_destroy(LpVideoDecoder *d)
{
    if (!d) {
        return;
    }
    if (d->codec) {
        AMediaCodec_stop(d->codec);
        AMediaCodec_delete(d->codec);
        d->codec = NULL;
    }
    if (d->format) {
        AMediaFormat_delete(d->format);
        d->format = NULL;
    }
    free(d);
}

#endif /* __ANDROID__ */
