/* Decode a PGS/.sup (or any bitmap-subtitle) file and dump what libavcodec
 * hands back: rect geometry, the palette and a few index bytes.  Used while
 * implementing graphics subtitles, to pin down the palette byte order before
 * writing the compositor.
 *
 *   build/pgs_probe.exe <file.sup>
 */
#include <stdio.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <subtitle-file>\n", argv[0]);
        return 2;
    }
    avformat_network_init();
    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, argv[1], NULL, NULL) < 0) {
        fprintf(stderr, "cannot open %s\n", argv[1]);
        return 1;
    }
    if (avformat_find_stream_info(fmt, NULL) < 0) {
        fprintf(stderr, "no stream info\n");
        return 1;
    }
    int si = -1;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        if (fmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
            si = (int)i;
            break;
        }
    }
    if (si < 0) {
        fprintf(stderr, "no subtitle stream\n");
        return 1;
    }
    AVCodecParameters *par = fmt->streams[si]->codecpar;
    printf("stream #%d codec=%s %dx%d\n", si, avcodec_get_name(par->codec_id), par->width,
           par->height);
    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (!codec) {
        fprintf(stderr, "no decoder\n");
        return 1;
    }
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx || avcodec_parameters_to_context(ctx, par) < 0 || avcodec_open2(ctx, codec, NULL) < 0) {
        fprintf(stderr, "cannot open decoder\n");
        return 1;
    }
    AVPacket *pkt = av_packet_alloc();
    int shown = 0;
    while (av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index != si) {
            av_packet_unref(pkt);
            continue;
        }
        AVSubtitle sub;
        memset(&sub, 0, sizeof(sub));
        int got = 0;
        if (avcodec_decode_subtitle2(ctx, &sub, &got, pkt) >= 0 && got) {
            printf("packet pts=%lld rects=%u start=%u end=%u\n", (long long)pkt->pts, sub.num_rects,
                   sub.start_display_time, sub.end_display_time);
            for (unsigned i = 0; i < sub.num_rects; i++) {
                AVSubtitleRect *r = sub.rects[i];
                printf("  rect %u type=%d x=%d y=%d w=%d h=%d stride=%d nb_colors=%d\n", i,
                       (int)r->type, r->x, r->y, r->w, r->h, r->linesize[0], r->nb_colors);
                if (r->type != SUBTITLE_BITMAP || !r->data[0] || !r->data[1]) {
                    continue;
                }
                const uint32_t *pal = (const uint32_t *)r->data[1];
                for (int k = 0; k < 4; k++) {
                    printf("    pal[%d]=%08X\n", k, pal[k]);
                }
                for (int y = 0; y < r->h && y < 3; y++) {
                    printf("    idx[y=%d]:", y);
                    for (int x = 0; x < r->w && x < 12; x++) {
                        printf(" %3d", r->data[0][y * r->linesize[0] + x]);
                    }
                    printf("\n");
                }
            }
            avsubtitle_free(&sub);
            if (++shown >= 6) {
                av_packet_unref(pkt);
                break;
            }
        }
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    avcodec_free_context(&ctx);
    avformat_close_input(&fmt);
    return 0;
}
