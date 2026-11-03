/*
 * Demuxing: the only place that touches AVFormatContext.
 *
 * Threads owned here: the demux thread (one) plus the per-stream decode threads
 * started through lp_video_start / lp_audio_start.  Seeks are requested from
 * the UI thread and executed here, then signalled to the decoders by bumping
 * `p->serial`.
 */
#include <libavutil/display.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "player_internal.h"
#include "source/source_internal.h"

static int player_interrupt_cb(void *opaque)
{
    LpPlayer *p = opaque;
    return lp_is_abort(p) ? 1 : 0;
}

static void hint_dict(AVDictionary **dict, const char *key, const char *value)
{
    if (value && *value) {
        av_dict_set(dict, key, value, 0);
    }
}

/* ------------------------------------------------------------- metadata --- */

/* 按显示方向看，画面还需要顺时针转多少度。
 *
 * 竖着拍的手机视频把画面存成横的，真正的朝向记在容器里的 DISPLAYMATRIX
 * 中。FFmpeg 6 把 stream 的侧数据搬到了 `codecpar->coded_side_data`（旧的
 * `av_stream_get_side_data` 已经删掉），取出来交给 `av_display_rotation_get`
 * 就能直接得到角度 —— 它返回的是逆时针角度，取负归一就是顺时针。
 *
 * 只接受 90 的整数倍：斜拍或者翻转矩阵在播放器里没有可用的表达方式，宁可
 * 不动也不要歪着。返回 0 / 90 / 180 / 270。
 */
static int stream_rotation_degrees(AVStream *st)
{
    const AVPacketSideData *sd = av_packet_side_data_get(
        st->codecpar->coded_side_data, st->codecpar->nb_coded_side_data,
        AV_PKT_DATA_DISPLAYMATRIX);
    if (!sd || sd->size < 9 * sizeof(int32_t)) {
        return 0;
    }
    int32_t matrix[9];
    memcpy(matrix, sd->data, sizeof(matrix));
    /* av_display_rotation_get 返回逆时针角度，我们这里要的是顺时针。 */
    double angle = -av_display_rotation_get(matrix);
    while (angle < 0.0) {
        angle += 360.0;
    }
    while (angle >= 360.0) {
        angle -= 360.0;
    }
    double snapped = (angle / 90.0);
    int quarter = (int)(snapped + 0.5);
    /* 距最近的 90 度超过 5 度就认为不是「单纯转了一下」，不转。 */
    if (fabs(angle - quarter * 90.0) > 5.0) {
        return 0;
    }
    quarter %= 4;
    return quarter * 90;
}

char *lp_media_info_json(LpPlayer *p)
{
    LpStr s;
    lp_str_init(&s);
    AVFormatContext *fmt = p->fmt;
    if (!fmt) {
        lp_str_append(&s, "{}");
        return lp_str_take(&s);
    }
    pthread_mutex_lock(&p->lock);
    lp_str_append(&s, "{\"duration_us\":%lld,\"format\":", (long long)p->duration_us);
    lp_str_append_json_str(&s, fmt->iformat ? fmt->iformat->name : "unknown");
    lp_str_append(&s, ",\"bitrate\":%lld,\"hw\":{", (long long)fmt->bit_rate);
    lp_str_append(&s, "\"active\":");
    lp_str_append_json_str(&s, p->video.hw_name ? p->video.hw_name : "none");
    lp_str_append(&s, ",\"requested\":%d}", p->hw_mode);

    if (p->video.stream_index >= 0) {
        AVStream *st = fmt->streams[p->video.stream_index];
        AVRational fr = st->avg_frame_rate.num > 0 ? st->avg_frame_rate : st->r_frame_rate;
        lp_str_append(&s, ",\"video\":{\"index\":%d,\"codec\":", p->video.stream_index);
        lp_str_append_json_str(&s, avcodec_get_name(st->codecpar->codec_id));
        lp_str_append(&s, ",\"width\":%d,\"height\":%d,\"fps\":%.3f,\"bitrate\":%lld",
                      st->codecpar->width, st->codecpar->height, av_q2d(fr),
                      (long long)st->codecpar->bit_rate);
        lp_str_append(&s, ",\"pix_fmt\":");
        lp_str_append_json_str(&s, av_get_pix_fmt_name((enum AVPixelFormat)st->codecpar->format));
        /* 竖着拍的手机视频把画面存成横的，真正的朝向记在 DISPLAYMATRIX 里。
         * 不读它，画面就是躺倒的；只按 codecpar 的宽高算长宽比，宽高也会反。
         * 这里给出的是「按显示方向看，画面还需要顺时针转多少度」，只会是
         * 0/90/180/270 之一。 */
        lp_str_append(&s, ",\"rotation\":%d", stream_rotation_degrees(st));
        lp_str_append(&s, ",\"color\":{\"primaries\":%d,\"transfer\":%d,\"space\":%d}}",
                      st->codecpar->color_primaries, st->codecpar->color_trc,
                      st->codecpar->color_space);
    } else {
        lp_str_append(&s, ",\"video\":null");
    }

    lp_str_append(&s, ",\"audio\":[");
    int first = 1;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream *st = fmt->streams[i];
        if (st->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
            continue;
        }
        if (!first) lp_str_append(&s, ",");
        first = 0;
        const AVDictionaryEntry *lang = av_dict_get(st->metadata, "language", NULL, 0);
        const AVDictionaryEntry *title = av_dict_get(st->metadata, "title", NULL, 0);
        lp_str_append(&s, "{\"index\":%u,\"codec\":", i);
        lp_str_append_json_str(&s, avcodec_get_name(st->codecpar->codec_id));
        lp_str_append(&s, ",\"channels\":%d,\"rate\":%d,\"lang\":",
                      st->codecpar->ch_layout.nb_channels, st->codecpar->sample_rate);
        lp_str_append_json_str(&s, lang ? lang->value : "");
        lp_str_append(&s, ",\"title\":");
        lp_str_append_json_str(&s, title ? title->value : "");
        /* 容器里的「默认音轨」标记。没有它，界面只能按「第一条就是默认」
         * 猜 —— 而 MKV 里默认音轨常常排在第二条。 */
        lp_str_append(&s, ",\"default\":%s",
                      (st->disposition & AV_DISPOSITION_DEFAULT) ? "true" : "false");
        lp_str_append(&s, "}");
    }
    lp_str_append(&s, "],\"subtitle\":[");
    pthread_mutex_lock(&p->subs.mutex);
    for (int i = 0; i < p->subs.nb_tracks; i++) {
        LpSubtitleTrack *t = &p->subs.tracks[i];
        if (i) lp_str_append(&s, ",");
        lp_str_append(&s, "{\"index\":%d,\"codec\":", t->index);
        lp_str_append_json_str(&s, t->embedded ? "embedded" : "external");
        lp_str_append(&s, ",\"lang\":");
        lp_str_append_json_str(&s, t->lang);
        lp_str_append(&s, ",\"title\":");
        lp_str_append_json_str(&s, t->title);
        lp_str_append(&s, ",\"external\":%s,\"selected\":%s,\"bitmap\":%s}",
                      t->is_external ? "true" : "false",
                      p->subs.selected == i ? "true" : "false",
                      t->bitmap ? "true" : "false");
    }
    pthread_mutex_unlock(&p->subs.mutex);
    lp_str_append(&s, "]}");
    pthread_mutex_unlock(&p->lock);
    return lp_str_take(&s);
}

/* --------------------------------------------------------- auto subtitles --- */

static void stem_of(const char *path, char *out, size_t outlen)
{
    const char *base = path;
    for (const char *q = path; *q; q++) {
        if (*q == '/' || *q == '\\') {
            base = q + 1;
        }
    }
    const char *dot = strrchr(base, '.');
    size_t n = dot ? (size_t)(dot - base) : strlen(base);
    if (n >= outlen) {
        n = outlen - 1;
    }
    for (size_t i = 0; i < n; i++) {
        out[i] = (char)tolower((unsigned char)base[i]);
    }
    out[n] = '\0';
}

/* Finds sibling subtitle files whose stem matches the video file, e.g.
 *   Movies/S01E01.mkv + Movies/S01E01.zh-CN.srt  -> auto loaded. */
static void auto_load_subtitles(LpPlayer *p)
{
    LpUrl u;
    if (lp_url_parse(p->url, &u) != LP_OK) {
        return;
    }
    char video_stem[256];
    stem_of(u.path, video_stem, sizeof(video_stem));
    if (!video_stem[0]) {
        return;
    }

    LpUrl parent = u;
    lp_path_parent(u.path, parent.path, sizeof(parent.path));
    char parent_url[2048];
    /* authority 与 scheme 名由 url.c 统一拼（以前手写 "smb://%s:%s@%s/%s%s"
     * 与 "file://%s" 两个分支，加一种源类型就得改这里）。 */
    char parent_base[1200];
    lp_url_build(&parent, parent_base, sizeof(parent_base));
    lp_url_insert_credentials(&u, parent_base, parent_url, sizeof(parent_url));

    if (getenv("LP_NO_SUB_SCAN")) {  /* debug switch: isolate the nested listing */
        LP_DEBUG("demux", "subtitle auto-load disabled by LP_NO_SUB_SCAN");
        return;
    }
    LP_DEBUG("demux", "auto subtitle scan in %s (video stem \"%s\")", parent_url, video_stem);
    char *json = NULL;
    /* Credentials live in the URL (or options_json) so the listing can read the
     * parent directory of an SMB share without a second login. */
    if (lp_source_list(parent_url, p->options_json, &json) != LP_OK || !json) {
        LP_DEBUG("demux", "subtitle auto-load skipped: cannot list %s", parent_url);
        return;
    }
    char *paths[64];
    int n = lp_json_collect_strings(json, "path", paths, 64);
    int added = 0;
    /* The listing never carries credentials, so a sidecar URL built from it
     * needs the login of the video URL re-inserted; otherwise the SMB open
     * fails with STATUS_INVALID_PARAMETER instead of reading the subtitle. */
    char *cred_paths[64] = {0};
    for (int i = 0; i < n; i++) {
        if (!u.is_hosted || !u.user[0]) {
            continue;
        }
        char buffer[LP_URL_MAX];
        lp_url_insert_credentials(&u, paths[i], buffer, sizeof(buffer));
        if (strcmp(buffer, paths[i]) != 0) {
            cred_paths[i] = lp_str_printf("%s", buffer);
        }
    }
    LP_DEBUG("demux", "subtitle scan: %d path(s) in listing; json=%.300s", n, json);
    for (int i = 0; i < n && added < LP_MAX_EXTERNAL_SUBS; i++) {
        const char *path = cred_paths[i] ? cred_paths[i] : paths[i];
        const char *dot = strrchr(path, '.');
        if (!dot || !lp_is_subtitle_name(path)) {
            continue;
        }
        char stem[256];
        char name[512];
        const char *base2 = path;
        for (const char *q = path; *q; q++) {
            if (*q == '/' || *q == '\\') base2 = q + 1;
        }
        snprintf(name, sizeof(name), "%s", base2);
        /* Directory part removed: "<stem><suffix>.<ext>" */
        stem_of(name, stem, sizeof(stem));
        LP_DEBUG("demux", "subtitle candidate %s (stem \"%s\" vs \"%s\")", path, stem, video_stem);
        /* 近似匹配：同主干、同集数、或去掉发布组/语言标签后对得上都算。
         * 规则本身在 submatch.c，和 Dart 侧的列表分组共用同一套判定。 */
        if (!lp_sub_match_related(video_stem, stem)) {
            continue;
        }
        if (lp_subtitle_add_file(p, path, p->options_json) >= 0) {
            added++;
        }
    }
    for (int i = 0; i < n; i++) {
        free(paths[i]);
        free(cred_paths[i]);
    }
    free(json);
    if (added) {
        LP_INFO("demux", "auto loaded %d external subtitle file(s)", added);
        pthread_mutex_lock(&p->subs.mutex);
        p->subs.dirty = 1;
        pthread_mutex_unlock(&p->subs.mutex);
    }
}

/* --------------------------------------------------------------- input --- */

static int open_input(LpPlayer *p, char *err, size_t errlen)
{
    LpUrl u;
    if (lp_url_parse(p->url, &u) != LP_OK) {
        snprintf(err, errlen, "invalid url");
        return LP_ERR_ARGUMENT;
    }
    AVDictionary *opts = NULL;
    hint_dict(&opts, "rw_timeout", "8000000");
    hint_dict(&opts, "probesize", "8388608");
    hint_dict(&opts, "analyzeduration", "6000000");
    hint_dict(&opts, "fpsprobesize", "4");

    AVFormatContext *fmt = NULL;
    int r;
    int custom_io = lp_transport_custom_io(u.scheme);
    if (custom_io) {
        p->io = lp_io_open(p->url, &p->sopts, err, errlen);
        if (!p->io) {
            av_dict_free(&opts);
            /* 传输层分得出「密码错」「共享名不存在」「连不上」「超时」，
             * 这里以前一律折成 LP_ERR_IO，于是 UI 上四种情况同一句话，
             * 用户照着「连接超时或服务器不可达」去查网络是白费力气。 */
            return lp_io_last_result();
        }
        p->io->external_abort = &p->abort_request;
        if (lp_io_attach_avio(p->io, &fmt, err, errlen) != LP_OK) {
            av_dict_free(&opts);
            return LP_ERR_NOMEM;
        }
        r = avformat_open_input(&fmt, p->url, NULL, &opts);
    } else {
        /* Native FFmpeg protocols (http/tcp...). */
        fmt = avformat_alloc_context();
        if (!fmt) {
            av_dict_free(&opts);
            return LP_ERR_NOMEM;
        }
        fmt->interrupt_callback.callback = player_interrupt_cb;
        fmt->interrupt_callback.opaque = p;
        r = avformat_open_input(&fmt, p->url, NULL, &opts);
    }
    av_dict_free(&opts);
    if (r < 0) {
        snprintf(err, errlen, "avformat_open_input: %s", av_err2str(r));
        if (fmt) {
            if (!custom_io) avformat_close_input(&fmt);
            else avformat_free_context(fmt);
        }
        return r == AVERROR(EACCES) ? LP_ERR_AUTH : LP_ERR_IO;
    }
    p->fmt = fmt;

    /* Limit decoding work for high bitrate sources. The dictionary has to be
     * built before find_stream_info and handed to it — building it afterwards
     * and freeing it unread (as this used to do) changed nothing. */
    AVDictionary *ifo = NULL;
    hint_dict(&ifo, "discardcorrupt", "1");
    r = avformat_find_stream_info(fmt, &ifo);
    av_dict_free(&ifo);
    if (r < 0) {
        LP_WARN("demux", "find_stream_info failed: %s", av_err2str(r));
    }

    p->duration_us = fmt->duration != AV_NOPTS_VALUE ? fmt->duration : 0;
    p->start_us = fmt->start_time != AV_NOPTS_VALUE ? fmt->start_time : 0;
    return LP_OK;
}

/* 记下视频轨的真实帧周期。
 *
 * 视频线程原本把帧周期写死成 0.04 秒（25 fps），节拍控制据此推导最小间隔；
 * 24 fps 的片子会算快 4%、23.976 的会算快 4.3%，长期跑下来每十几秒就要
 * 多吐一帧。这里按容器报的帧率覆盖一次，读不出来就保留缺省值。 */
static void note_frame_duration(LpPlayer *p)
{
    if (!p->fmt || p->video.stream_index < 0) {
        return;
    }
    AVStream *st = p->fmt->streams[p->video.stream_index];
    AVRational fr = st->avg_frame_rate.num > 0 ? st->avg_frame_rate : st->r_frame_rate;
    const double fps = av_q2d(fr);
    /* 有些分轨不给帧率（可变帧率、裸流），宁可少做一次平滑也不要按 0 去算。 */
    if (fps > 0.1 && fps < 200.0) {
        p->video.frame_duration = 1.0 / fps;
    }
}

/* 按码率折算预读窗口。
 *
 * 定长的 24 MB 对两端都不合适：4 Mbps 的老片能预读 48 秒（SMB 抖动早就
 * 过去了，多出来的只是内存），80 Mbps 的蓝光只有 2.4 秒（一次目录扫描
 * 就能把它耗光）。这里按「LP_READAHEAD_SECONDS 秒的数据量」算，夹在
 * [LP_MIN_PACKET_BYTES, 缺省值] 之间 —— 码率读不出来（AVFMT_NO_BITRATE
 * 的容器、裸流）就保持缺省。 */
static void apply_readahead(LpPlayer *p)
{
    int64_t bit_rate = p->fmt ? p->fmt->bit_rate : 0;
    if (bit_rate <= 0) {
        /* 有些容器整体不给码率，但分轨给了。取所有分轨的字节速率之和。 */
        if (p->fmt) {
            for (unsigned i = 0; i < p->fmt->nb_streams; i++) {
                AVStream *st = p->fmt->streams[i];
                if (st->codecpar && st->codecpar->bit_rate > 0 &&
                    st->disposition != AV_DISPOSITION_ATTACHED_PIC) {
                    bit_rate += st->codecpar->bit_rate;
                }
            }
        }
    }
    if (bit_rate <= 0) {
        return;
    }
    int64_t want = bit_rate / 8 * LP_READAHEAD_SECONDS;
    if (want < LP_MIN_PACKET_BYTES) {
        want = LP_MIN_PACKET_BYTES;
    }
    /* 音视频分开算：视频队列拿 2/3，音频拿 1/3，与缺省配比一致。 */
    int64_t video_bytes = want * 2 / 3;
    int64_t audio_bytes = want / 3;
    if (video_bytes > LP_MAX_PACKET_BYTES) {
        video_bytes = LP_MAX_PACKET_BYTES;
    }
    if (audio_bytes > LP_AUDIO_PACKET_BYTES) {
        audio_bytes = LP_AUDIO_PACKET_BYTES;
    }
    lp_pq_resize(&p->video.pq, video_bytes);
    lp_pq_resize(&p->audio.pq, audio_bytes);
    LP_DEBUG("demux", "read-ahead %lld KiB video / %lld KiB audio for %lld bps",
             (long long)(video_bytes / 1024), (long long)(audio_bytes / 1024),
             (long long)bit_rate);
}

static int select_streams(LpPlayer *p)
{
    p->video.stream_index = av_find_best_stream(p->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    p->audio.stream_index =
        av_find_best_stream(p->fmt, AVMEDIA_TYPE_AUDIO, -1, p->video.stream_index, NULL, 0);
    if (p->video.stream_index < 0 && p->audio.stream_index < 0) {
        LP_ERROR("demux", "no audio or video stream in %s", p->url);
        return LP_ERR_UNSUPPORTED;
    }
    if (p->duration_us <= 0 && p->video.stream_index >= 0) {
        AVStream *st = p->fmt->streams[p->video.stream_index];
        if (st->duration != AV_NOPTS_VALUE) {
            p->duration_us = av_rescale_q(st->duration, st->time_base, AV_TIME_BASE_Q);
        }
    }
    return LP_OK;
}

/* --------------------------------------------------------------- thread --- */

static void perform_seek(LpPlayer *p, int64_t target_us)
{
    int64_t ts = target_us + p->start_us;
    int r = avformat_seek_file(p->fmt, -1, INT64_MIN, ts, INT64_MAX, 0);
    if (r < 0) {
        r = av_seek_frame(p->fmt, -1, ts, AVSEEK_FLAG_BACKWARD);
    }
    if (r < 0) {
        LP_WARN("demux", "seek to %lld us failed", (long long)target_us);
    }
    /* serial 是原子量，必须走原子读改写。以前这里写成 `p->serial++`：
     * 读-改-写不是一次操作，而 video.c/audio.c 里同时在裸读它来判断
     * 「这次 seek 之后包是不是作废了」。C11 意义上是数据竞争（UB），
     * 编译器完全可以把解码线程里那两次读缓存在一次 flush 之前，于是
     * seek 之后解码器仍按旧串号处理，画面会闪一下旧的。 */
    int new_serial = atomic_fetch_add(&p->serial, 1) + 1;
    lp_pq_flush(&p->video.pq);
    lp_pq_flush(&p->audio.pq);
    lp_ring_flush(&p->audio.ring);
    atomic_store(&p->eos_demux, 0);
    atomic_store(&p->video.eof, 0);
    atomic_store(&p->audio.eof, 0);
    lp_clock_set(&p->ac, (double)target_us / LP_TIME_BASE, new_serial);
    lp_clock_set(&p->extc, (double)target_us / LP_TIME_BASE, new_serial);
    lp_subtitle_seek(p, target_us);
    lp_emit_buffering(p, 1, 0);
    LP_DEBUG("demux", "seek -> %lld us (serial %d, rc %d)", (long long)target_us, new_serial, r);
}

void *lp_demux_thread_fn(void *arg)
{
    LpPlayer *p = arg;
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) {
        return NULL;
    }
    int waiting_eof = 0;
    long long read_ok = 0;
    int discard_checked = 0;
    int discard_only = 0;

    while (!lp_is_abort(p)) {
        if (atomic_exchange(&p->seek_req, 0)) {
            int64_t target = p->seek_target_us;
            perform_seek(p, target);
            waiting_eof = 0;
            continue;
        }
        if (waiting_eof) {
            if (atomic_load(&p->seek_req)) {
                continue;
            }
            av_usleep(20000);
            continue;
        }

        av_packet_unref(pkt);
        int r = av_read_frame(p->fmt, pkt);
        if (r == AVERROR(EAGAIN)) {
            av_usleep(2000);
            continue;
        }
        if (r == AVERROR_EOF) {
            atomic_store(&p->eos_demux, 1);
            int eof_serial = atomic_load(&p->serial);
            lp_pq_signal_eof(&p->video.pq, eof_serial);
            lp_pq_signal_eof(&p->audio.pq, eof_serial);
            waiting_eof = 1;
            LP_INFO("demux", "end of stream after %lld packet(s), pos %lld us",
                    read_ok, (long long)p->fmt->pb->pos);
            continue;
        }
        if (r < 0) {
            /* 读失败必须走和 EOF 一样的收尾：解码线程等的是队列上的 EOF 信号，
             * 不是「读线程退出了」。以前这里只发一个错误事件就 break ——
             * 两个解码线程永远停在 lp_pq_wait_more，video/audio 的 eof 都不置位，
             * ENDED 判定 `audio_done && video_done` 永远为假，进度条定在最后一
             * 个位置、主时钟冻结，界面上既不报结束也不再往前走。
             * SMB 掉线、共享被踢、U 盘拔出都走这条分支，不是罕见情况。 */
            if (!lp_is_abort(p)) {
                char msg[128];
                snprintf(msg, sizeof(msg), "read error: %s", av_err2str(r));
                lp_emit_error(p, LP_ERR_IO, msg);
            }
            atomic_store(&p->eos_demux, 1);
            int eof_serial = atomic_load(&p->serial);
            lp_pq_signal_eof(&p->video.pq, eof_serial);
            lp_pq_signal_eof(&p->audio.pq, eof_serial);
            waiting_eof = 1;
            LP_INFO("demux", "read failed after %lld packet(s), signalling end of stream",
                    read_ok);
            continue;
        }

        /* 调试开关只在第一次进循环时读一次环境变量。以前这里每读一个包都
         * 调 getenv()，而 getenv 是对 environ 的线性扫描 —— 4K 片源一次播放
         * 就是几百万次字符串比较，白白占掉 demux 线程的时间。 */
        if (!discard_checked) {
            discard_checked = 1;
            discard_only = getenv("LP_DEMUX_DISCARD") != NULL;
        }
        if (discard_only) {  /* debug: read-only loop, no queues */
            av_packet_unref(pkt);
            continue;
        }
        if (pkt->stream_index == p->video.stream_index) {
            read_ok++;
            if (lp_pq_put(&p->video.pq, pkt, atomic_load(&p->serial)) != 0) {
                /* 队列已放掉这个包，不能重复释放。切轨会先 abort 队列再
                 * restart，这时推包失败不代表播放结束 —— 以前直接 break 会
                 * 让 demux 线程永久退出，之后没有任何线程喂包：播放停在切轨
                 * 那一刻，q 恒为 0，主时钟空转到片尾也不结束（安卓上必现）。 */
                pkt = av_packet_alloc();
                if (!pkt || lp_is_abort(p)) {
                    break;
                }
                av_usleep(2000);
                continue;
            }
            pkt = av_packet_alloc();
        } else if (pkt->stream_index == p->audio.stream_index) {
            if (lp_pq_put(&p->audio.pq, pkt, atomic_load(&p->serial)) != 0) {
                pkt = av_packet_alloc();
                if (!pkt || lp_is_abort(p)) {
                    break;
                }
                av_usleep(2000);
                continue;
            }
            pkt = av_packet_alloc();
        } else {
            lp_subtitle_feed_packet(p, pkt->stream_index, pkt);
        }
        if (!pkt) {
            break;
        }
    }
    av_packet_free(&pkt);
    return NULL;
}

/* ------------------------------------------------------------------ API --- */

int lp_demux_open(LpPlayer *p)
{
    char err[256] = {0};
    int open_rc = open_input(p, err, sizeof(err));
    if (open_rc != LP_OK) {
        char msg[384];
        snprintf(msg, sizeof(msg), "%s", err[0] ? err : "cannot open media");
        /* 错误码一路透到 LP_EVENT_ERROR，UI 才能说「密码不对」而不是
         * 「连接超时或服务器不可达」——四种失败的处置方式完全不同。 */
        lp_emit_error(p, open_rc, msg);
        return open_rc;
    }
    if (select_streams(p) != LP_OK) {
        lp_emit_error(p, LP_ERR_UNSUPPORTED, "no playable stream found");
        return LP_ERR_UNSUPPORTED;
    }
    note_frame_duration(p);
    apply_readahead(p);
    if (lp_subtitle_open(p) != LP_OK) {
        LP_WARN("demux", "subtitle init failed");
    }
    auto_load_subtitles(p);

    /* 媒体时间轴的零点不是 0，而是 start_time（TS 流常见 1.4 s 的
     * 前置填充）。以前这里只打一行日志、两个时钟仍从 0 起，而包的 pts
     * 带着 start_time —— 主时钟要「走到 pts」才上屏，第一个 GOP 的 pts
     * 是 1.4 s，于是开片先黑屏 1.4 秒；无音轨或 sync=external 时（主时钟
     * 就是这一个）必现。seek 那边早就算上了 start_us，两边本该同一个口径。 */
    if (p->start_us > 0) {
        LP_DEBUG("demux", "start_time offset %lld us", (long long)p->start_us);
    }
    double start_seconds = (double)p->start_us / LP_TIME_BASE;
    lp_clock_set(&p->ac, start_seconds, atomic_load(&p->serial));
    lp_clock_set(&p->extc, start_seconds, atomic_load(&p->serial));

    /* LP_NO_VIDEO / LP_NO_AUDIO: debugging switches to bisect pipeline faults. */
    if (getenv("LP_NO_VIDEO")) {
        LP_WARN("demux", "video pipeline disabled by LP_NO_VIDEO");
    } else if (lp_video_start(p) != LP_OK) {
        LP_WARN("demux", "video pipeline failed to start");
    }
    if (getenv("LP_NO_AUDIO")) {
        LP_WARN("demux", "audio pipeline disabled by LP_NO_AUDIO");
    } else if (lp_audio_start(p) != LP_OK) {
        LP_WARN("demux", "audio pipeline failed to start");
    }
    atomic_store(&p->eos_demux, 0);
    lp_pq_start(&p->video.pq);
    lp_pq_start(&p->audio.pq);

    if (pthread_create(&p->demux_thread, NULL, lp_demux_thread_fn, p) != 0) {
        return LP_ERR_NOMEM;
    }
    p->demux_started = 1;

    if (p->seek_start_us > 0) {
        lp_request_seek(p, p->seek_start_us);
    }
    return LP_OK;
}
