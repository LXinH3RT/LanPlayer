/*
 * Minimal D3D11VA capability probe: creates the hw device and decodes a few
 * frames with the hardware decoder, then downloads one frame and prints its
 * pixel format.  Used while bringing up Windows hardware decode; the real
 * implementation lives in src/platform/win32/d3d11va_decoder.c.
 *
 *   lp_hw_probe.exe <video>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: lp_hw_probe.exe <video>\n");
        return 2;
    }
    av_log_set_level(AV_LOG_INFO);

    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, argv[1], NULL, NULL) < 0) {
        fprintf(stderr, "open failed\n");
        return 1;
    }
    if (avformat_find_stream_info(fmt, NULL) < 0) {
        fprintf(stderr, "no stream info\n");
        return 1;
    }
    int vindex = -1;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        if (fmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            vindex = (int)i;
            break;
        }
    }
    if (vindex < 0) {
        fprintf(stderr, "no video stream\n");
        return 1;
    }
    AVStream *st = fmt->streams[vindex];

    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!codec) {
        fprintf(stderr, "no decoder for %s\n", avcodec_get_name(st->codecpar->codec_id));
        return 1;
    }
    printf("codec=%s %dx%d\n", codec->name, st->codecpar->width, st->codecpar->height);

    /* Which hw configs does this decoder advertise? */
    for (int i = 0;; i++) {
        const AVCodecHWConfig *c = avcodec_get_hw_config(codec, i);
        if (!c) {
            break;
        }
        printf("  hwconfig[%d]=%s method=0x%x\n", i,
               av_hwdevice_get_type_name(c->device_type) ? av_hwdevice_get_type_name(c->device_type)
                                                         : "?",
               c->methods);
    }

    AVBufferRef *device = NULL;
    int r = av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_D3D11VA, NULL, NULL, 0);
    printf("av_hwdevice_ctx_create(d3d11va) = %d%s\n", r,
           r < 0 ? " (unavailable)" : " (ok)");
    if (r < 0) {
        return 3;
    }

    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(ctx, st->codecpar);
    ctx->pkt_timebase = st->time_base;
    ctx->hw_device_ctx = av_buffer_ref(device);
    r = avcodec_open2(ctx, codec, NULL);
    printf("avcodec_open2 = %d  pix_fmt=%s\n", r,
           av_get_pix_fmt_name(ctx->pix_fmt) ? av_get_pix_fmt_name(ctx->pix_fmt) : "?");
    if (r < 0) {
        return 3;
    }

    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int decoded = 0;
    int hw_frames = 0;
    while (av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index != vindex) {
            av_packet_unref(pkt);
            continue;
        }
        if (avcodec_send_packet(ctx, pkt) == 0) {
            while (avcodec_receive_frame(ctx, frame) == 0) {
                decoded++;
                if (frame->format == AV_PIX_FMT_D3D11 || frame->hw_frames_ctx) {
                    hw_frames++;
                }
                if (decoded == 1) {
                    printf("frame0 format=%s hw=%d sw_format=%s size=%dx%d\n",
                           av_get_pix_fmt_name((enum AVPixelFormat)frame->format), frame->hw_frames_ctx != NULL,
                           frame->hw_frames_ctx
                               ? (av_get_pix_fmt_name(
                                      ((AVHWFramesContext *)frame->hw_frames_ctx->data)->sw_format)
                                      ? av_get_pix_fmt_name(
                                            ((AVHWFramesContext *)frame->hw_frames_ctx->data)
                                                ->sw_format)
                                      : "?")
                               : "-",
                           frame->width, frame->height);
                    /* Download once to prove the readback path works. */
                    AVFrame *sw = av_frame_alloc();
                    int tr = av_hwframe_transfer_data(sw, frame, 0);
                    printf("av_hwframe_transfer_data = %d  sw=%s\n", tr,
                           tr >= 0 ? (av_get_pix_fmt_name((enum AVPixelFormat)sw->format) ? av_get_pix_fmt_name((enum AVPixelFormat)sw->format) : "?")
                                   : "-");
                    av_frame_free(&sw);
                }
                av_frame_unref(frame);
            }
        }
        av_packet_unref(pkt);
        if (decoded >= 8) {
            break;
        }
    }
    printf("decoded=%d hw_frames=%d\n", decoded, hw_frames);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    avcodec_free_context(&ctx);
    av_buffer_unref(&device);
    avformat_close_input(&fmt);
    return decoded > 0 ? 0 : 4;
}
