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
#include <sys/system_properties.h>

#include <stdlib.h>

#include "player_internal.h"

/* 诊断开关：`adb shell setprop debug.lanplayer.noout 1` 之后重开片，解码器
 * 不接 surface，走 ByteBuffer 输出，并在日志里数出真实产出的帧数。
 *
 * 只用来区分两种「硬解零渲染」：
 *   - 改成 ByteBuffer 就能出帧  -> 输入流没问题，是渲染到 surface 那一步坏了；
 *   - 改成 ByteBuffer 还是 0 帧 -> 码流/参数集根本没被解码器吃进去。
 * 平时不设这个属性，行为与正式版完全一致。 */
static int noout_prop_set(void)
{
    char v[8] = {0};
    int n = __system_property_get("debug.lanplayer.noout", v);
    return n > 0 && v[0] == '1';
}

/* 把 avcC / hvcC 拆成 Annex-B 的 SPS、PPS 交给 csd-0 / csd-1。
 *
 * 直接拿 FFmpeg 的 extradata 塞进 csd-0 在 AOSP 的软件解码器上能跑，但高通
 * 的 c2.qti.avc.decoder 不认：它把这 40 字节当成「配置记录」却解析不出参数
 * 集，系统日志就会打 `MiMediaCodec: The CSD is not calculated`，接着所有
 * 输入都被吃进去又吐不出来（dumpsys 里 Qin 涨、DQout 恒 0），画面全黑。
 * NDK 文档要求的正是 Annex-B：csd-0 放 SPS、csd-1 放 PPS，都带 00 00 00 01
 * 起始码。 */
static int apply_csd(AMediaFormat *fmt, const uint8_t *extra, int n)
{
    if (!fmt || !extra || n < 7) {
        return 0;
    }
    /* avcC 与 hvcC 都以 configurationVersion = 1 开头。 */
    if (extra[0] != 1) {
        return 0;
    }
    int num_sps = extra[5] & 0x1f;
    int off = 6;
    int idx = 0;
    int sets = 0;
    while (num_sps-- > 0 && off + 2 <= n) {
        int len = (extra[off] << 8) | extra[off + 1];
        off += 2;
        if (len <= 0 || off + len > n) {
            return sets;
        }
        if (idx < 2) {
            uint8_t *buf = malloc((size_t)len + 4);
            if (buf) {
                buf[0] = 0;
                buf[1] = 0;
                buf[2] = 0;
                buf[3] = 1;
                memcpy(buf + 4, extra + off, (size_t)len);
                char key[8];
                snprintf(key, sizeof(key), "csd-%d", idx);
                AMediaFormat_setBuffer(fmt, key, buf, (size_t)len + 4);
                /* AMediaFormat_setBuffer 复制内容，这块临时缓冲可以立刻放掉。 */
                free(buf);
                idx++;
                sets++;
            }
        }
        off += len;
    }
    if (off >= n) {
        return sets;
    }
    int num_pps = extra[off++];
    while (num_pps-- > 0 && off + 2 <= n) {
        int len = (extra[off] << 8) | extra[off + 1];
        off += 2;
        if (len <= 0 || off + len > n) {
            break;
        }
        if (idx < 2) {
            uint8_t *buf = malloc((size_t)len + 4);
            if (buf) {
                buf[0] = 0;
                buf[1] = 0;
                buf[2] = 0;
                buf[3] = 1;
                memcpy(buf + 4, extra + off, (size_t)len);
                char key[8];
                snprintf(key, sizeof(key), "csd-%d", idx);
                AMediaFormat_setBuffer(fmt, key, buf, (size_t)len + 4);
                free(buf);
                idx++;
                sets++;
            }
        }
        off += len;
    }
    return sets;
}

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
    int64_t presented;
    int64_t send_again;
    int64_t recv_again;
    int64_t byte_frames;
    int byte_mode;
    size_t byte_bytes;
    int avcc; /* 1 = 码流是 AVCC 长度前缀，进解码器前要转 Annex-B */
    int avcc_checked;
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

/* 这些 profile 厂商的 MediaCodec 要么直接报错、要么慢到跟不上时钟。
 * Android 手机（c2.qti.avc.decoder）实测 1280x720 Hi10P：hardware decode 后第一帧
 * 就 `hw receive: -6`，整路播放变成连续错误事件；同一文件软解 24 fps 正常。
 * 与其让它失败后再回退，不如按 profile 提前拒绝，open_decoder() 会走软解。 */
static int profile_needs_software(enum AVCodecID id, int profile)
{
    if (id == AV_CODEC_ID_H264) {
        return profile == AV_PROFILE_H264_HIGH_10 || profile == AV_PROFILE_H264_HIGH_10_INTRA ||
               profile == AV_PROFILE_H264_HIGH_422 || profile == AV_PROFILE_H264_HIGH_422_INTRA ||
               profile == AV_PROFILE_H264_HIGH_444_PREDICTIVE ||
               profile == AV_PROFILE_H264_HIGH_444_INTRA;
    }
    if (id == AV_CODEC_ID_HEVC) {
        /* Android 手机 的 c2.qti.hevc.decoder 对 10-bit 是「吃下去但不出画面」：
         * 播放 1080p HEVC-10bit 时 `MediaCodec` 自己的统计是
         *   Qin:456 DQin:456/456 Render:0 Drop:0 DQout:0/456
         * 也就是 456 个输入缓冲全被收下，却一个都没 dequeue 出来，
         * 屏幕上一直是黑帧、进度条照走（用户看到的就是「卡住」）。
         * 同一个文件软解 24 fps 正常，所以按 profile 提前拒绝。 */
        return profile == AV_PROFILE_HEVC_MAIN_10 || profile == AV_PROFILE_HEVC_MAIN_STILL_PICTURE ||
               profile == AV_PROFILE_HEVC_REXT;
    }
    return 0;
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
    if (cfg->par && profile_needs_software(cfg->codec_id, cfg->par->profile)) {
        snprintf(err, errlen, "%s profile %d is decoded better in software",
                 avcodec_get_name(cfg->codec_id), cfg->par->profile);
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
        const unsigned char *e = (const unsigned char *)cfg->par->extradata;
        int n = cfg->par->extradata_size;
        int sets = apply_csd(d->format, e, n);
        if (sets > 0) {
            LP_INFO("mediacodec", "csd: %d parameter set(s) as annex-b from %d bytes avcC", sets, n);
        } else {
            /* 拆不开就退回原样贴上，至少不比之前更差。 */
            AMediaFormat_setBuffer(d->format, "csd-0", e, (size_t)n);
            LP_INFO("mediacodec", "extradata %d bytes: %02x %02x %02x %02x %02x %02x %02x %02x", n,
                    n > 0 ? e[0] : 0, n > 1 ? e[1] : 0, n > 2 ? e[2] : 0, n > 3 ? e[3] : 0,
                    n > 4 ? e[4] : 0, n > 5 ? e[5] : 0, n > 6 ? e[6] : 0, n > 7 ? e[7] : 0);
        }
    }
    /* ByteBuffer 诊断模式：不接 surface，直接读解码输出。 */
    d->byte_mode = noout_prop_set();
    media_status_t st = AMediaCodec_configure(
        d->codec, d->format, d->byte_mode ? NULL : (ANativeWindow *)cfg->native_window, NULL, 0);
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
    /* mp4/mkv 的 AVC 码流是 AVCC（4 字节长度前缀），MediaCodec 只吃
     * Annex-B。这里先乐观置 1，首包到达时再用 needs_annexb() 确认。 */
    d->avcc = 1;
    d->avcc_checked = 0;
    LP_INFO("mediacodec", "configured %s %dx%d", d->mime, d->width, d->height);
    return LP_OK;
}

/* 把 MP4/MKV 里的 AVCC（每帧前面是 4 字节长度）转换成 MediaCodec 要求的
 * Annex-B（每帧前面是 00 00 00 01 起始码）。
 *
 * 这是硬解全黑的真正原因：FFmpeg 解 mp4 交给我们的包是 AVCC 格式，而
 * MediaCodec 的 AVC 解码器按 Annex-B 解析。长度前缀被当成 NAL 头，数据全
 * 错位 —— 输入照单全收（dumpsys 里 Qin 一直涨），却永远输出不了帧
 * （DQout 恒 0、Render 0），换成 ByteBuffer 输出也一样。FTYP/AVCC 的 mp4
 * 在 FFmpeg 里由 `h264_mp4toannexb` 位流过滤器负责这件事，我们手写等价逻辑。 */
static int needs_annexb(const AVPacket *pkt, const uint8_t *extra, int extralen)
{
    (void)extra;
    (void)extralen;
    if (pkt->size < 4) {
        return 0;
    }
    /* 不能只看包头：长度前缀的包里，第一个 NAL 的长度字段可能正好长得像起始码
     * （movie-03.mkv 就是 00 00 01 e5 = 485 字节的切片），那种包会被误判成已经是
     * Annex-B 而跳过转换，解码器于是从第二帧起全部报错。共用嗅探器会把整条
     * 长度链走一遍来区分，详见 src/core/nal.c。 */
    return !lp_nal_is_annexb(pkt->data, (size_t)pkt->size);
}

/* 返回转换后写入的长度；0 表示无需/无法转换。dst 至少要有 size*3/2+64 字节。 */
static size_t to_annexb(const uint8_t *src, size_t size, uint8_t *dst, size_t cap)
{
    size_t out = 0;
    size_t i = 0;
    while (i + 4 <= size) {
        size_t len = ((size_t)src[i] << 24) | ((size_t)src[i + 1] << 16) |
                     ((size_t)src[i + 2] << 8) | (size_t)src[i + 3];
        i += 4;
        if (len == 0 || len > size - i || out + 4 + len > cap) {
            return 0;
        }
        dst[out] = 0;
        dst[out + 1] = 0;
        dst[out + 2] = 0;
        dst[out + 3] = 1;
        memcpy(dst + out + 4, src + i, len);
        out += 4 + len;
        i += len;
    }
    return out;
}

int lp_hw_decoder_send(LpVideoDecoder *d, const AVPacket *pkt)
{
    if (!d || !d->codec) {
        return LP_ERR_STATE;
    }
    if (pkt && d->avcc && !d->avcc_checked) {
        d->avcc_checked = 1;
        if (needs_annexb(pkt, NULL, 0)) {
            d->avcc = 1;
            LP_INFO("mediacodec", "stream is AVCC, converting each packet to annex-b");
        } else {
            d->avcc = 0;
        }
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
        /* 只能发一次 EOS。以前这里是「每轮循环都发」，draining 阶段 receive
         * 一直返 TRY_AGAIN 就再来一轮，于是 EOS 被反复塞进解码器 —— 系统日志
         * 里刷满 `CCodecBufferChannel: buffers after EOS ignored`，解码器直接
         * 不再产出任何帧。 */
        if (d->input_eos) {
            /* 已经排空过：让出 CPU，别让上层循环空转。 */
            usleep(2000);
            return LP_ERR_AGAIN;
        }
        AMediaCodec_queueInputBuffer(d->codec, (size_t)idx, 0, 0, 0,
                                     AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
        d->input_eos = 1;
        return LP_OK;
    }
    size_t size = (size_t)pkt->size;
    const uint8_t *src = pkt->data;
    uint8_t *conv = NULL;
    if (d->avcc && size >= 4) {
        /* 转换后最多比原来多 1 字节/帧（4 字节长度前缀换成 4 字节起始码），
         * 多留 64 字节余量。 */
        size_t need = size + size / 2 + 64;
        conv = malloc(need);
        if (conv) {
            size_t n = to_annexb(pkt->data, size, conv, need);
            if (n > 0) {
                src = conv;
                size = n;
            } else {
                free(conv);
                conv = NULL;
            }
        }
    }
    if (size > cap) {
        /* Should not happen for video packets, but never overflow the buffer. */
        size = cap;
    }
    memcpy(buf, src, size);
    free(conv);
    int64_t pts_us = 0;
    if (pkt->pts != AV_NOPTS_VALUE) {
        pts_us = av_rescale_q(pkt->pts, d->tb, AV_TIME_BASE_Q);
    }
    media_status_t qst = AMediaCodec_queueInputBuffer(d->codec, (size_t)idx, 0, size,
                                                      (uint64_t)pts_us, 0);
    d->queued_frames++;
    return qst == AMEDIA_OK ? LP_OK : LP_ERR_CODEC;
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
                LP_INFO("mediacodec", "output format changed");
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
        if (d->byte_mode) {
            /* 诊断用：ByteBuffer 输出真的产出帧了，数出来立刻释放。 */
            d->byte_frames++;
            d->byte_bytes += (size_t)(info.size > 0 ? info.size : 0);
            AMediaCodec_releaseOutputBuffer(d->codec, (size_t)idx, false);
            continue;
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
    d->presented++;
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
