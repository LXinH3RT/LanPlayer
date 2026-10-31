/*
 * Demuxing: the only place that touches AVFormatContext.
 *
 * Threads owned here: the demux thread (one) plus the per-stream decode threads
 * started through lp_video_start / lp_audio_start.  Seeks are requested from
 * the UI thread and executed here, then signalled to the decoders by bumping
 * `p->serial`.
 */
#include <stdlib.h>

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
    char base[1200];
    if (u.is_smb) {
        if (u.user[0]) {
            snprintf(base, sizeof(base), "smb://%s:%s@%s/%s%s", u.user, u.password, u.host,
                     u.share, parent.path);
        } else {
            snprintf(base, sizeof(base), "smb://%s/%s%s", u.host, u.share, parent.path);
        }
    } else {
        snprintf(base, sizeof(base), "file://%s", parent.path);
    }
    snprintf(parent_url, sizeof(parent_url), "%s", base);

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
        if (u.is_smb && u.user[0] && strncmp(paths[i], "smb://", 6) == 0 &&
            !strchr(paths[i] + 6, '@')) {
            cred_paths[i] = lp_str_printf("smb://%s:%s@%s", u.user, u.password, paths[i] + 6);
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
    int custom_io = u.is_smb || strcmp(u.scheme, "file") == 0;
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

    AVDictionary *ifo = NULL;
    r = avformat_find_stream_info(fmt, NULL);
    if (r < 0) {
        LP_WARN("demux", "find_stream_info failed: %s", av_err2str(r));
    }
    /* Limit decoding work for high bitrate sources. */
    hint_dict(&ifo, "discardcorrupt", "1");
    av_dict_free(&ifo);

    p->duration_us = fmt->duration != AV_NOPTS_VALUE ? fmt->duration : 0;
    p->start_us = fmt->start_time != AV_NOPTS_VALUE ? fmt->start_time : 0;
    return LP_OK;
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
            if (!lp_is_abort(p)) {
                char msg[128];
                snprintf(msg, sizeof(msg), "read error: %s", av_err2str(r));
                lp_emit_error(p, LP_ERR_IO, msg);
            }
            break;
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
    if (lp_subtitle_open(p) != LP_OK) {
        LP_WARN("demux", "subtitle init failed");
    }
    auto_load_subtitles(p);

    if (p->start_us > 0 && p->video.stream_index >= 0) {
        /* Normalise the timeline so 0 means "first frame". */
        LP_DEBUG("demux", "start_time offset %lld us", (long long)p->start_us);
    }
    lp_clock_set(&p->ac, 0, atomic_load(&p->serial));
    lp_clock_set(&p->extc, 0, atomic_load(&p->serial));

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
