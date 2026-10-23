/*
 * Apple hardware decoding through VideoToolbox.
 *
 * The decoder produces CVPixelBufferRef frames backed by IOSurfaces, which the
 * Flutter texture bridge hands to the engine without a copy.  Both the h264 and
 * hevc parameter set formats (avcC / Annex-B / hvcC) are accepted because
 * Matroska carries Annex-B while MP4 carries the boxed form.
 */
#if defined(__APPLE__)

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>

#include <stdlib.h>

#include "player_internal.h"

/* Decoded frames waiting for the display. VideoToolbox decodes ahead of the
 * clock (that is the whole point of the queue), so this must be deep enough
 * to hold the decoder's lookahead plus the reorder delay of a B-frame stream.
 * 8 was too shallow: on a 24 fps H.264 film the decoder filled it and
 * push_frame() threw away one frame in seven. */
#define LP_VT_QUEUE 32

struct LpVideoDecoder {
    VTDecompressionSessionRef session;
    CMVideoFormatDescriptionRef fmt;
    int width;
    int height;
    AVRational tb;
    LpPlayer *player;
    int eos;

    pthread_mutex_t mutex;
    pthread_cond_t cond;
    struct {
        CVPixelBufferRef image;
        int64_t pts_us;
    } queue[LP_VT_QUEUE];
    int head;
    int count;
};

static int64_t cmtime_to_us(CMTime t)
{
    if (!CMTIME_IS_VALID(t) || t.timescale == 0) {
        return -1;
    }
    return (int64_t)((double)t.value * 1000000.0 / (double)t.timescale);
}

/* ------------------------------------------------------- format description --- */

/* Copies the parameter sets for one NAL type out of an avcC / Annex-B blob. */
static int h264_param_sets(const uint8_t *ed, int size, const uint8_t **sets, size_t *set_sizes,
                           int max)
{
    int n = 0;
    if (!ed || size < 5) {
        return 0;
    }
    if (ed[0] == 1) {
        /* avcC */
        int pos = 5;
        int nsps = ed[pos++] & 0x1F;
        for (int i = 0; i < nsps && n < max && pos + 2 <= size; i++) {
            int len = (ed[pos] << 8) | ed[pos + 1];
            pos += 2;
            if (pos + len > size) {
                return n;
            }
            sets[n] = ed + pos;
            set_sizes[n] = len;
            n++;
            pos += len;
        }
        if (pos < size && n < max) {
            int npss = ed[pos++];
            for (int i = 0; i < npss && n < max && pos + 2 <= size; i++) {
                int len = (ed[pos] << 8) | ed[pos + 1];
                pos += 2;
                if (pos + len > size) {
                    return n;
                }
                sets[n] = ed + pos;
                set_sizes[n] = len;
                n++;
                pos += len;
            }
        }
        return n;
    }
    /* Annex-B: split on start codes, keep SPS (7) and PPS (8). */
    int i = 0;
    while (i + 3 < size && n < max) {
        int sc = 0;
        if (ed[i] == 0 && ed[i + 1] == 0 && ed[i + 2] == 1) {
            sc = 3;
        } else if (i + 4 < size && ed[i] == 0 && ed[i + 1] == 0 && ed[i + 2] == 0 && ed[i + 3] == 1) {
            sc = 4;
        }
        if (!sc) {
            i++;
            continue;
        }
        int start = i + sc;
        int end = start;
        while (end + 2 < size && !(ed[end] == 0 && ed[end + 1] == 0 && ed[end + 2] <= 1)) {
            end++;
        }
        if (end <= start) {
            break;
        }
        int type = ed[start] & 0x1F;
        if (type == 7 || type == 8) {
            sets[n] = ed + start;
            set_sizes[n] = end - start;
            n++;
        }
        i = end;
    }
    return n;
}

static int hevc_param_sets(const uint8_t *ed, int size, const uint8_t **sets, size_t *set_sizes,
                           int max)
{
    int n = 0;
    if (!ed || size < 23 || ed[0] != 1) {
        return 0;
    }
    int pos = 22;
    int arrays = ed[pos++];
    for (int a = 0; a < arrays && pos + 3 <= size; a++) {
        int nal_type = ed[pos] & 0x3F;
        pos++;
        int num = (ed[pos] << 8) | ed[pos + 1];
        pos += 2;
        for (int k = 0; k < num && pos + 2 <= size; k++) {
            int len = (ed[pos] << 8) | ed[pos + 1];
            pos += 2;
            if (pos + len > size) {
                return n;
            }
            if ((nal_type == 32 || nal_type == 33 || nal_type == 34) && n < max) {
                sets[n] = ed + pos;
                set_sizes[n] = len;
                n++;
            }
            pos += len;
        }
    }
    return n;
}

/* Profiles VideoToolbox accepts but decodes far slower than the software
 * decoder.  Measured on an M-series Mac over SMB, 8 s each:
 *
 *   [anime-05] Hi10P 1440x1080    VT 50 frames, fps 0.00, 5.6 s behind
 *                                    software 185 frames, fps 23.5, 45 ms
 *   anime-06 10-bit 1080p  VT 139 frames, 27 dropped
 *                                    software 147 frames, 0 dropped
 *
 * The clock is audio driven, so a decoder that cannot keep up makes the video
 * thread fall further behind every second (wait_for_presentation never returns
 * early) until nothing is drawn at all -- the user sees a frozen picture and a
 * progress bar that keeps walking.  Routing these profiles to software costs
 * CPU but plays, so refuse them up front; open_decoder() then falls back. */
static int profile_needs_software(int codec_id, int profile)
{
    if (codec_id == AV_CODEC_ID_H264) {
        return profile == AV_PROFILE_H264_HIGH_10 || profile == AV_PROFILE_H264_HIGH_10_INTRA ||
               profile == AV_PROFILE_H264_HIGH_422 || profile == AV_PROFILE_H264_HIGH_422_INTRA ||
               profile == AV_PROFILE_H264_HIGH_444_PREDICTIVE ||
               profile == AV_PROFILE_H264_HIGH_444_INTRA;
    }
    if (codec_id == AV_CODEC_ID_HEVC) {
        /* 10-bit HEVC: the hardware path accepts the format and then either
         * rejects every frame (-12909) or decodes at a few frames per second.
         * Measured on the same machine over SMB, 6 s each:
         *
         *   anime-02a.mkv   VT  11.9 fps, 3 dropped      software 23.8 fps
         *   anime-02b.mkv   VT   0.0 fps, 2 decoded       software 24.5 fps
         *   anime-03    VT   0.0 fps, 3 decoded       software 24.0 fps
         *   anime-04 19     VT   0.0 fps                  software 24.0 fps
         *
         * 8-bit HEVC stays on the hardware path (23.6 fps, no drops). */
        return profile == AV_PROFILE_HEVC_MAIN_10 || profile == AV_PROFILE_HEVC_MAIN_STILL_PICTURE ||
               profile == AV_PROFILE_HEVC_REXT;
    }
    return 0;
}

static int build_format_description(LpVideoDecoder *d, const LpVideoDecoderConfig *cfg, char *err,
                                    size_t errlen)
{
    const uint8_t *sets[16];
    size_t sizes[16];
    int n = 0;
    if (cfg->codec_id == AV_CODEC_ID_H264) {
        n = h264_param_sets(cfg->par->extradata, cfg->par->extradata_size, sets, sizes, 16);
        if (n < 2) {
            snprintf(err, errlen, "h264 parameter sets missing");
            return -1;
        }
        OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            kCFAllocatorDefault, (size_t)n, sets, sizes, 4, &d->fmt);
        if (st != noErr) {
            snprintf(err, errlen, "CreateFromH264ParameterSets: %d", (int)st);
            return -1;
        }
    } else if (cfg->codec_id == AV_CODEC_ID_HEVC) {
        n = hevc_param_sets(cfg->par->extradata, cfg->par->extradata_size, sets, sizes, 16);
        if (n < 2) {
            snprintf(err, errlen, "hevc parameter sets missing");
            return -1;
        }
        OSStatus st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            kCFAllocatorDefault, (size_t)n, sets, sizes, 4, NULL, &d->fmt);
        if (st != noErr) {
            snprintf(err, errlen, "CreateFromHEVCParameterSets: %d", (int)st);
            return -1;
        }
    } else {
        snprintf(err, errlen, "codec %s not supported by VideoToolbox path",
                 avcodec_get_name(cfg->codec_id));
        return -1;
    }
    CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(d->fmt);
    d->width = dim.width;
    d->height = dim.height;
    return 0;
}

static void push_frame(LpVideoDecoder *d, CVPixelBufferRef image, int64_t pts_us)
{
    pthread_mutex_lock(&d->mutex);
    if (d->count >= LP_VT_QUEUE) {
        /* Drop the oldest frame: the display is behind. */
        LP_INFO("videotoolbox", "queue full (%d), dropping oldest pts=%lld", d->count,
                (long long)d->queue[d->head].pts_us);
        CVPixelBufferRelease(d->queue[d->head].image);
        d->queue[d->head].image = NULL;
        d->head = (d->head + 1) % LP_VT_QUEUE;
        d->count--;
    }
    int slot = (d->head + d->count) % LP_VT_QUEUE;
    d->queue[slot].image = (CVPixelBufferRef)CVBufferRetain(image);
    d->queue[slot].pts_us = pts_us;
    d->count++;
    pthread_cond_signal(&d->cond);
    pthread_mutex_unlock(&d->mutex);
}

LpVideoDecoder *lp_hw_decoder_create(void)
{
    LpVideoDecoder *d = calloc(1, sizeof(*d));
    if (!d) {
        return NULL;
    }
    pthread_mutex_init(&d->mutex, NULL);
    pthread_cond_init(&d->cond, NULL);
    return d;
}

int lp_hw_decoder_available(void)
{
    return 1;
}

const char *lp_hw_decoder_name(void)
{
    return "videotoolbox";
}

int lp_hw_decoder_init(LpVideoDecoder *d, const LpVideoDecoderConfig *cfg, char *err, size_t errlen)
{
    if (!d || !cfg) {
        return LP_ERR_ARGUMENT;
    }
    d->tb = cfg->time_base;
    d->player = cfg->player;
    if (profile_needs_software(cfg->codec_id, cfg->par->profile)) {
        snprintf(err, errlen, "%s profile %d is decoded better in software",
                 avcodec_get_name(cfg->codec_id), cfg->par->profile);
        return LP_ERR_UNSUPPORTED;
    }
    if (build_format_description(d, cfg, err, errlen) != 0) {
        return LP_ERR_UNSUPPORTED;
    }

    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int format = kCVPixelFormatType_32BGRA;
    CFNumberRef fmt_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &format);
    CFDictionarySetValue(attrs, kCVPixelBufferPixelFormatTypeKey, fmt_num);
    CFRelease(fmt_num);
    CFMutableDictionaryRef iosurf = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, iosurf);
    CFRelease(iosurf);

    /* 6 个参数：allocator, format, decoderSpec, destinationAttrs, outputCallback,
     * sessionOut。之前多传了一个 NULL，Xcode 15 起是硬错误（expected 6, have 7）。
     * 回调改用下面的 VTDecompressionSessionDecodeFrameWithOutputHandler（按帧传
     * block），所以这里 outputCallback 传 NULL。 */
    OSStatus st = VTDecompressionSessionCreate(kCFAllocatorDefault, d->fmt, NULL, attrs, NULL,
                                               &d->session);
    CFRelease(attrs);
    if (st != noErr || !d->session) {
        snprintf(err, errlen, "VTDecompressionSessionCreate: %d", (int)st);
        return LP_ERR_CODEC;
    }
    LP_INFO("videotoolbox", "session ready %dx%d (%s)", d->width, d->height,
            avcodec_get_name(cfg->codec_id));
    /* 实时优先：播放器本来就是实时场景，让 VideoToolbox 别为了吞吐攒批。
     * 注意这条**单独并不解决**丢帧（实测开与不开都是 18.5 fps / 丢 88 帧），
     * 真正的原因是 wait_for_presentation 的 250 ms 阈值误伤了硬解的管线延迟
     * —— 见 native/src/core/video.c。这里保留它是因为它表达的意图正确，
     * 且对低延迟场景无副作用。 */
    OSStatus rt = VTSessionSetProperty(d->session, kVTDecompressionPropertyKey_RealTime,
                                       kCFBooleanTrue);
    if (rt != noErr) {
        LP_WARN("videotoolbox", "cannot ask for real-time decoding: %d", (int)rt);
    }
    return LP_OK;
}

/* Converts Annex-B start codes to 4-byte length prefixes (VT wants AVCC).
 *
 * The framing test is not "does the first byte look like a start code": a
 * length-prefixed packet whose first NAL is ~0x000100xx bytes long starts with
 * 00 00 01 too, and converting it corrupts every NAL (see lp_nal_is_annexb). */
static AVPacket *to_avcc(LpVideoDecoder *d, const AVPacket *pkt)
{
    (void)d;
    const uint8_t *src = pkt->data;
    int size = pkt->size;
    if (size < 4) {
        return NULL;
    }
    if (!lp_nal_is_annexb(src, (size_t)size)) {
        return NULL; /* already length prefixed */
    }
    AVPacket *out = av_packet_alloc();
    if (!out) {
        return NULL;
    }
    if (av_new_packet(out, size + 16) < 0) {
        av_packet_free(&out);
        return NULL;
    }
    int o = 0;
    int i = 0;
    while (i + 3 < size) {
        int sc = 0;
        if (src[i] == 0 && src[i + 1] == 0 && src[i + 2] == 1) {
            sc = 3;
        } else if (i + 4 < size && src[i] == 0 && src[i + 1] == 0 && src[i + 2] == 0 &&
                   src[i + 3] == 1) {
            sc = 4;
        }
        if (!sc) {
            i++;
            continue;
        }
        int start = i + sc;
        int end = start;
        while (end + 2 < size && !(src[end] == 0 && src[end + 1] == 0 && src[end + 2] <= 1)) {
            end++;
        }
        int len = end - start;
        if (len <= 0 || o + 4 + len > out->size) {
            break;
        }
        out->data[o++] = (uint8_t)(len >> 24);
        out->data[o++] = (uint8_t)(len >> 16);
        out->data[o++] = (uint8_t)(len >> 8);
        out->data[o++] = (uint8_t)len;
        memcpy(out->data + o, src + start, (size_t)len);
        o += len;
        i = end;
    }
    if (o == 0) {
        av_packet_free(&out);
        return NULL;
    }
    out->size = o;
    return out;
}

int lp_hw_decoder_send(LpVideoDecoder *d, const AVPacket *pkt)
{
    if (!d || !d->session) {
        return LP_ERR_STATE;
    }
    if (!pkt) {
        d->eos = 1;
        VTDecompressionSessionWaitForAsynchronousFrames(d->session);
        return LP_OK;
    }
    AVPacket *converted = to_avcc(d, pkt);
    const AVPacket *use = converted ? converted : pkt;
    if (use->size <= 0) {        /* A zero sized sample carries nothing to decode; some mkv files hand
         * one out around a discontinuity.  Feeding it to VideoToolbox just
         * wastes a session round trip, so drop it here. */
        av_packet_free(&converted);
        return LP_OK;
    }

    CMBlockBufferRef block = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL,
                                                     (size_t)use->size, kCFAllocatorDefault, NULL, 0,
                                                     (size_t)use->size, 0, &block);
    if (st != kCMBlockBufferNoErr) {
        av_packet_free(&converted);
        return LP_ERR_CODEC;
    }
    CMBlockBufferReplaceDataBytes(use->data, block, 0, (size_t)use->size);

    double seconds = 0;
    if (use->pts != AV_NOPTS_VALUE) {
        seconds = (double)use->pts * av_q2d(d->tb);
    }
    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(1, 90000);
    timing.presentationTimeStamp = CMTimeMakeWithSeconds(seconds, 90000);
    timing.decodeTimeStamp = kCMTimeInvalid;
    size_t sample_size = (size_t)use->size;
    CMSampleBufferRef sb = NULL;
    st = CMSampleBufferCreateReady(kCFAllocatorDefault, block, d->fmt, 1, 1, &timing, 1,
                                   &sample_size, &sb);
    CFRelease(block);
    av_packet_free(&converted);
    if (st != noErr || !sb) {
        return LP_ERR_CODEC;
    }
    /* kVTDecodeFrame_EnableAsynchronousDecompression: 让解码发生在 VideoToolbox
     * 自己的线程上，DecodeFrame 立刻返回，视频线程再从 push_frame/receive 的
     * 队列里按主时钟节奏取帧 —— 队列本来就是为这个设计的。
     * 坦白说这条**没有**改善丢帧（实测开与不开都是 18.5–17.9 fps、丢 88 帧），
     * 真正的原因在 wait_for_presentation 的阈值（见 native/src/core/video.c）；
     * 保留它是为了不把解码串行到播放线程上。 */
    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    VTDecodeInfoFlags info = 0;
    LpVideoDecoder *dec = d;
    st = VTDecompressionSessionDecodeFrameWithOutputHandler(
        d->session, sb, flags, &info,
        ^(OSStatus status, VTDecodeInfoFlags flags2, CVImageBufferRef image, CMTime pts,
          CMTime dur) {
          (void)flags2;
          (void)dur;
          if (status != noErr || !image) {
              return;
          }
          int64_t pts_us = cmtime_to_us(pts);
          push_frame(dec, (CVPixelBufferRef)image, pts_us);
        });
    CFRelease(sb);
    if (st != noErr) {
        LP_WARN("videotoolbox", "decode frame rejected: status %d", (int)st);
    }
    return st == noErr ? LP_OK : LP_ERR_CODEC;
}

int lp_hw_decoder_receive(LpVideoDecoder *d, LpDecodedFrame *out)
{
    if (!d || !out) {
        return LP_ERR_ARGUMENT;
    }
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_nsec += 10 * 1000 * 1000;
    if (ts.tv_nsec >= 1000000000) {
        ts.tv_sec++;
        ts.tv_nsec -= 1000000000;
    }
    pthread_mutex_lock(&d->mutex);
    while (d->count == 0) {
        if (d->eos) {
            pthread_mutex_unlock(&d->mutex);
            return LP_ERR_END_OF_STREAM;
        }
        if (pthread_cond_timedwait(&d->cond, &d->mutex, &ts) != 0 && d->count == 0) {
            pthread_mutex_unlock(&d->mutex);
            return LP_ERR_AGAIN;
        }
    }
    out->kind = LP_DEC_PIXEL_BUFFER;
    out->handle = d->queue[d->head].image;
    out->pts_us = d->queue[d->head].pts_us;
    out->width = d->width;
    out->height = d->height;
    d->queue[d->head].image = NULL;
    d->head = (d->head + 1) % LP_VT_QUEUE;
    d->count--;
    pthread_mutex_unlock(&d->mutex);
    return LP_OK;
}

int lp_hw_decoder_present(LpVideoDecoder *d, LpDecodedFrame *f)
{
    if (!d || !f) {
        return LP_ERR_ARGUMENT;
    }
    CVPixelBufferRef image = (CVPixelBufferRef)f->handle;
    if (image && d->player) {
        lp_render_publish_pixel_buffer(d->player, image);
    }
    if (image) {
        CVPixelBufferRelease(image);
    }
    f->handle = NULL;
    return LP_OK;
}

void lp_hw_decoder_flush(LpVideoDecoder *d)
{
    if (!d || !d->session) {
        return;
    }
    VTDecompressionSessionWaitForAsynchronousFrames(d->session);
    pthread_mutex_lock(&d->mutex);
    for (int i = 0; i < d->count; i++) {
        int slot = (d->head + i) % LP_VT_QUEUE;
        if (d->queue[slot].image) {
            CVPixelBufferRelease(d->queue[slot].image);
            d->queue[slot].image = NULL;
        }
    }
    d->count = 0;
    d->head = 0;
    d->eos = 0;
    pthread_mutex_unlock(&d->mutex);
}

void lp_hw_decoder_destroy(LpVideoDecoder *d)
{
    if (!d) {
        return;
    }
    lp_hw_decoder_flush(d);
    if (d->session) {
        VTDecompressionSessionInvalidate(d->session);
        CFRelease(d->session);
        d->session = NULL;
    }
    if (d->fmt) {
        CFRelease(d->fmt);
        d->fmt = NULL;
    }
    pthread_mutex_destroy(&d->mutex);
    pthread_cond_destroy(&d->cond);
    free(d);
}

#endif /* __APPLE__ */
