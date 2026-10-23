/*
 * Public API implementation: lifecycle, transport controls, events, the tick
 * thread (position/stats/subtitle pulses) and the option surface.
 */
#include <stdarg.h>
#include <stdlib.h>

#include "player_internal.h"

/* ---------------------------------------------------------------- events --- */

/* Event payloads cross the FFI boundary as owned strings: the core allocates,
 * the host releases with lp_string_free().  That is what makes it safe to use a
 * Dart NativeCallable.listener, which runs on the isolate's event loop long
 * after the emitting native frame has returned. */
static void emit_owned_json(LpPlayer *p, int event, int64_t value, char *json)
{
    if (!json) {
        return;
    }
    if (!p || !p->event_cb) {
        free(json);
        return;
    }
    p->event_cb(p->event_user, event, json, value);
}

void lp_emit_event(LpPlayer *p, int event, const char *fmt, ...)
{
    if (!p || !p->event_cb) {
        return;
    }
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0) {
        va_end(ap2);
        return;
    }
    char *buf = malloc((size_t)n + 1);
    if (!buf) {
        va_end(ap2);
        return;
    }
    vsnprintf(buf, (size_t)n + 1, fmt, ap2);
    va_end(ap2);
    emit_owned_json(p, event, 0, buf);
}

void lp_emit_error(LpPlayer *p, int code, const char *fmt, ...)
{
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0) {
        va_end(ap2);
        return;
    }
    char *msg = malloc((size_t)n + 1);
    if (!msg) {
        va_end(ap2);
        return;
    }
    vsnprintf(msg, (size_t)n + 1, fmt, ap2);
    va_end(ap2);
    LpStr s;
    lp_str_init(&s);
    lp_str_append(&s, "{\"code\":%d,\"message\":", code);
    lp_str_append_json_str(&s, msg);
    lp_str_append(&s, ",\"fatal\":true}");
    char *owned = lp_str_take(&s);
    emit_owned_json(p, LP_EVENT_ERROR, code, owned ? owned : lp_str_dup("{}"));
    LP_ERROR("player", "error %d: %s", code, msg);
    free(msg);
}

LpState lp_get_state(LpPlayer *p)
{
    return (LpState)atomic_load(&p->state);
}

void lp_set_state(LpPlayer *p, LpState state)
{
    LpState prev = (LpState)atomic_exchange(&p->state, state);
    if (prev == state) {
        return;
    }
    char *buf = lp_str_printf("{\"state\":%d,\"prev\":%d}", (int)state, (int)prev);
    emit_owned_json(p, LP_EVENT_STATE, (int)state, buf);
    if (state == LP_STATE_PLAYING || state == LP_STATE_PAUSED) {
        int paused = state == LP_STATE_PAUSED;
        lp_clock_pause(&p->ac, paused);
        lp_clock_pause(&p->extc, paused);
        if (p->audio.ring.buf) {
            lp_ring_set_paused(&p->audio.ring, paused);
        }
        if (p->sink) {
            lp_audio_sink_pause(p->sink, paused);
        }
    }
}

int lp_is_abort(LpPlayer *p)
{
    return p ? atomic_load(&p->abort_request) : 1;
}

void lp_emit_buffering(LpPlayer *p, int buffering, int percent)
{
    if (!p) {
        return;
    }
    if (p->buffering == buffering) {
        return;
    }
    p->buffering = buffering;
    lp_emit_event(p, LP_EVENT_BUFFERING, "{\"buffering\":%s,\"percent\":%d}",
                  buffering ? "true" : "false", percent);
}

void lp_note_position(LpPlayer *p, int64_t position_us)
{
    if (!p) {
        return;
    }
    if (position_us > p->duration_us && p->duration_us > 0) {
        position_us = p->duration_us;
    }
    if (position_us < 0) {
        position_us = 0;
    }
    atomic_store(&p->position_us, position_us);
}

int64_t lp_master_clock_us(LpPlayer *p)
{
    /* 音频当主时钟的前提是「它还在往前走」。音频解码线程排空退出后，
     * 声卡环不再被写入，lp_ring_clock_seconds 会永远停在同一刻 —— 这时
     * 视频线程还在 wait_for_presentation 里等最后一个 GOP，主时钟不动它
     * 就永远等下去，video.eof 永不置位，ENDED 发不出去：表现为片尾画面
     * 停住、进度条停在最后一秒（subbed.mkv 6.0s 上必现）。
     * 音频一旦宣布收尾就回退到墙钟，让最后几帧照常走完。 */
    if (p->sync_mode == 0 && p->audio.stream_index >= 0 && !atomic_load(&p->audio.eof)) {
        double t = lp_audio_clock_seconds(p);
        if (t >= 0) {
            return (int64_t)(t * LP_TIME_BASE);
        }
    }
    double e = lp_clock_get(&p->extc);
    return (int64_t)(e * LP_TIME_BASE);
}

void lp_request_seek(LpPlayer *p, int64_t target_us)
{
    if (!p) {
        return;
    }
    if (target_us < 0) {
        target_us = 0;
    }
    if (p->duration_us > 0 && target_us > p->duration_us) {
        target_us = p->duration_us;
    }
    p->seek_target_us = target_us;
    atomic_store(&p->seek_req, 1);
    lp_note_position(p, target_us);
}

/* ------------------------------------------------------------ tick thread --- */

static void *player_tick_fn(void *arg)
{
    LpPlayer *p = arg;
    int64_t last_pos_emit = 0;
    int64_t last_stats = av_gettime_relative();
    int64_t last_frames = 0;
    int ended_reported = 0;

    while (!atomic_load(&p->quit_request)) {
        av_usleep(LP_TICK_INTERVAL_US);
        if (!p->opened) {
            continue;
        }
        int64_t now = av_gettime_relative();
        LpState st = lp_get_state(p);

        if (st == LP_STATE_PLAYING) {
            int64_t pos = lp_master_clock_us(p);
            lp_note_position(p, pos);
            lp_subtitle_tick(p, pos);
            if (now - last_pos_emit >= LP_POSITION_INTERVAL_US) {
                last_pos_emit = now;
                emit_owned_json(p, LP_EVENT_POSITION, pos,
                                lp_str_printf("{\"pos\":%lld,\"dur\":%lld}", (long long)pos,
                                              (long long)p->duration_us));
                int buffered = lp_audio_buffered_ms(p);
                int queued = lp_pq_size(&p->video.pq);
                lp_emit_buffering(p, queued == 0 && buffered == 0 && pos > 0, 0);
            }
        }

        if (now - last_stats >= LP_STATS_INTERVAL_US) {
            double dt = (double)(now - last_stats) / LP_TIME_BASE;
            double fps = dt > 0 ? (double)(p->stats_frames - last_frames) / dt : 0;
            last_frames = p->stats_frames;
            last_stats = now;
            p->stats_fps = fps;
            if (p->event_cb) {
                int64_t av = p->video.last_pts_us - lp_master_clock_us(p);
                emit_owned_json(p, LP_EVENT_STATS, 0,
                                lp_str_printf("{\"fps\":%.2f,\"dropped\":%lld,\"decoded\":%lld,"
                                              "\"av_diff\":%lld,\"hw\":\"%s\",\"queued\":%d,"
                                              "\"buffered_ms\":%d}",
                                              fps, (long long)p->stats_dropped,
                                              (long long)p->stats_frames, (long long)av,
                                              p->video.hw_name ? p->video.hw_name : "none",
                                              lp_pq_size(&p->video.pq), lp_audio_buffered_ms(p)));
            }
        }

        /* End of playback: demuxer done and both decoders drained. */
        if (st == LP_STATE_PLAYING && p->eos_demux && !ended_reported) {
            int audio_done = p->audio.stream_index < 0 || atomic_load(&p->audio.eof);
            int video_done = p->video.stream_index < 0 || atomic_load(&p->video.eof);
            if (audio_done && video_done) {
                ended_reported = 1;
                LP_INFO("trace", "playback ended at %lld us", (long long)p->position_us);
                lp_set_state(p, LP_STATE_ENDED);
                lp_emit_event(p, LP_EVENT_ENDED, "{\"pos\":%lld}", (long long)p->position_us);
            }
        }
        if (st != LP_STATE_PLAYING) {
            ended_reported = 0;
        }
    }
    return NULL;
}

/* ------------------------------------------------------------ open worker --- */

static void player_reset_media(LpPlayer *p)
{
    p->opened = 0;
    p->eos_demux = 0;
    p->stats_frames = 0;
    p->stats_dropped = 0;
    p->buffering = 0;
    p->video.stream_index = -1;
    p->audio.stream_index = -1;
    p->video.hw_active = 0;
    p->video.hw_name = NULL;
}

static int apply_open_options(LpPlayer *p)
{
    const char *opts = p->options_json;
    char v[128];
    if (opts) {
        if (lp_json_get_str(opts, "hw", v, sizeof(v)) == 0) {
            if (!strcmp(v, "sw") || !strcmp(v, "software")) {
                p->hw_mode = LP_HW_SOFTWARE;
                p->hw_forced_name[0] = '\0';
            } else if (!strcmp(v, "auto")) {
                p->hw_mode = LP_HW_AUTO;
            } else {
                p->hw_mode = LP_HW_FORCED;
                snprintf(p->hw_forced_name, sizeof(p->hw_forced_name), "%s", v);
            }
        }
        int64_t n = 0;
        int b = 0;
        if (lp_json_get_bool(opts, "deinterlace", &b) == 0) {
            p->deinterlace = b;
        }
        if (lp_json_get_int(opts, "scale_mode", &n) == 0) {
            p->vout.scale_mode = (int)n;
        }
        if (lp_json_get_int(opts, "start_us", &n) == 0 && n > 0) {
            p->seek_start_us = n;
        }
        char sv[32];
        if (lp_json_get_str(opts, "sync", sv, sizeof(sv)) == 0 && !strcmp(sv, "external")) {
            p->sync_mode = 1;
        }
        double speed = 1.0;
        if (lp_json_get_str(opts, "speed", sv, sizeof(sv)) == 0) {
            speed = atof(sv);
        }
        if (speed > 0.4 && speed < 2.1) {
            p->speed = speed;
            lp_clock_set_speed(&p->ac, speed);
            lp_clock_set_speed(&p->extc, speed);
        }
        if (lp_json_get_str(opts, "volume", sv, sizeof(sv)) == 0) {
            p->volume = (float)atof(sv);
            if (p->volume < 0) p->volume = 0;
            if (p->volume > 2) p->volume = 2;
            /* 打开时带进来的音量（设置里存的上次值）也记一条：这条日志是
             * 「设置里的音量真的到了内核」的唯一运行时证据 —— 界面上只有
             * 一个百分比，截图看不出 gain 有没有生效。 */
            LP_INFO("audio", "volume %.2f (%d%%) from settings", (double)p->volume,
                    (int)(p->volume * 100.0f + 0.5f));
        }
    }
    return LP_OK;
}

static void open_worker_cleanup(LpPlayer *p)
{
    pthread_mutex_lock(&p->lock);
    free(p->url);
    p->url = NULL;
    free(p->options_json);
    p->options_json = NULL;
    pthread_mutex_unlock(&p->lock);
}

static void *player_open_fn(void *arg)
{
    LpPlayer *p = arg;
    lp_render_init(p);
    int r = lp_demux_open(p);
    if (r != LP_OK) {
        lp_set_state(p, LP_STATE_ERROR);
        open_worker_cleanup(p);
        return NULL;
    }
    p->opened = 1;
    LP_INFO("trace", "open: demux ok");
    lp_set_state(p, LP_STATE_READY);
    LP_INFO("trace", "open: state ready");
    char *info = lp_media_info_json(p);
    LP_INFO("trace", "open: media json built");
    if (info) {
        emit_owned_json(p, LP_EVENT_MEDIA_INFO, 0, info);
    }
    /* LP_EVENT_TRACKS carries the same media JSON as MEDIA_INFO (the host parses
     * both with the same code). It used to be an empty "{}", which the host
     * faithfully parsed into "this file has no audio and no subtitles tracks" --
     * the track sheets then said "0 embedded subtitles" on a file that had one,
     * because nothing re-sent the real list unless a track switch happened. */
    char *tracks_info = lp_media_info_json(p);
    if (tracks_info) {
        emit_owned_json(p, LP_EVENT_TRACKS, 0, tracks_info);
    }
    LP_INFO("trace", "open: tracks emitted");

    int autoplay = 1;
    if (p->options_json) {
        int b = 1;
        if (lp_json_get_bool(p->options_json, "auto_play", &b) == 0) {
            autoplay = b;
        }
    }
    if (autoplay) {
        lp_player_play(p);
    }
    return NULL;
}

/* ------------------------------------------------------------- lifecycle --- */

int32_t lp_abi_version(void)
{
    return LP_ABI_VERSION;
}

int32_t lp_player_create(LpPlayer **out)
{
    if (!out) {
        return LP_ERR_ARGUMENT;
    }
    LpPlayer *p = calloc(1, sizeof(*p));
    if (!p) {
        return LP_ERR_NOMEM;
    }
    pthread_mutex_init(&p->lock, NULL);
    atomic_init(&p->state, LP_STATE_IDLE);
    atomic_init(&p->abort_request, 0);
    atomic_init(&p->quit_request, 0);
    atomic_init(&p->seek_req, 0);
    atomic_init(&p->position_us, (int64_t)0);
    atomic_init(&p->serial, 0);
    atomic_init(&p->audio.graph_dirty, 0);
    p->video.stream_index = -1;
    p->audio.stream_index = -1;
    p->hw_mode = LP_HW_AUTO;
    p->speed = 1.0;
    p->volume = 1.0f;
    p->read_timeout_ms = 8000;
    p->sync_mode = 0;
    p->vout.kind = LP_VOUT_NONE;
    p->vout.scale_mode = LP_SCALE_FIT;
    pthread_mutex_init(&p->vout.mutex, NULL);
    /* 字幕状态的锁随播放器对象创建/销毁，不随开片关片。这样关片之后
     * setOption("subtitle_delay") 仍然锁得住（以前关片会 destroy 掉它，
     * 再锁就是 FORTIFY abort）。 */
    pthread_mutex_init(&p->subs.mutex, NULL);
    p->subs_inited = 1;
    /* 音频环的锁同样归播放器对象所有：tick 线程每 20ms 读一次音频主时钟，
     * 关片时若把锁毁掉，它就撞上 destroyed mutex（安卓上必崩）。 */
    lp_ring_setup(&p->audio.ring);
    lp_clock_init(&p->ac);
    lp_clock_init(&p->extc);
    lp_pq_init(&p->video.pq, LP_MAX_PACKET_BYTES);
    lp_pq_init(&p->audio.pq, LP_MAX_PACKET_BYTES / 2);
    lp_source_options_default(&p->sopts);
    if (pthread_create(&p->tick_thread, NULL, player_tick_fn, p) == 0) {
        p->tick_started = 1;
    }
    *out = p;
    return LP_OK;
}

void lp_player_destroy(LpPlayer *p)
{
    if (!p) {
        return;
    }
    atomic_store(&p->abort_request, 1);
    lp_player_close(p);
    /* lp_player_close 会把 abort_request 清回去（它要能再次开片），所以 tick
     * 线程的退出不能看 abort_request，得看这个专用标志。 */
    atomic_store(&p->quit_request, 1);
    if (p->tick_started) {
        pthread_join(p->tick_thread, NULL);
        p->tick_started = 0;
    }
    lp_pq_destroy(&p->video.pq);
    lp_pq_destroy(&p->audio.pq);
    lp_ring_teardown(&p->audio.ring);
    lp_render_close(p);
    lp_clock_destroy(&p->ac);
    lp_clock_destroy(&p->extc);
    pthread_mutex_destroy(&p->vout.mutex);
    pthread_mutex_destroy(&p->subs.mutex);
    p->subs_inited = 0;
    pthread_mutex_destroy(&p->lock);
    free(p->url);
    free(p->options_json);
    free(p);
}

void lp_player_set_event_callback(LpPlayer *p, LpEventCallback cb, void *user)
{
    if (!p) {
        return;
    }
    p->event_cb = cb;
    p->event_user = user;
}

int32_t lp_player_open(LpPlayer *p, const char *url, const char *options_json)
{
    if (!p || !url || !*url) {
        return LP_ERR_ARGUMENT;
    }
    lp_player_close(p);
    atomic_store(&p->abort_request, 0);
    player_reset_media(p);
    pthread_mutex_lock(&p->lock);
    free(p->url);
    p->url = lp_str_dup(url);
    free(p->options_json);
    p->options_json = options_json && *options_json ? lp_str_dup(options_json) : NULL;
    lp_source_options_parse(p->options_json, &p->sopts);
    pthread_mutex_unlock(&p->lock);
    apply_open_options(p);

    lp_set_state(p, LP_STATE_OPENING);
    if (pthread_create(&p->open_thread, NULL, player_open_fn, p) != 0) {
        lp_set_state(p, LP_STATE_ERROR);
        return LP_ERR_NOMEM;
    }
    p->open_started = 1;
    return LP_OK;
}

int32_t lp_player_close(LpPlayer *p)
{
    if (!p) {
        return LP_ERR_ARGUMENT;
    }
    atomic_store(&p->abort_request, 1);
    lp_pq_abort(&p->video.pq);
    lp_pq_abort(&p->audio.pq);
    if (p->audio.ring.buf) {
        lp_ring_abort(&p->audio.ring);
    }
    if (p->io) {
        lp_io_abort(p->io);
    }
    if (p->open_started) {
        pthread_join(p->open_thread, NULL);
        p->open_started = 0;
    }
    if (p->demux_started) {
        pthread_join(p->demux_thread, NULL);
        p->demux_started = 0;
    }
    /* The open worker and the demux thread share the same pthread handle; when
     * open failed early the thread already exited, join is still safe because
     * we only set demux_started once the demux loop started. */
    lp_video_stop(p);
    lp_audio_stop(p);
    if (p->subs_inited) {
        lp_subtitle_close(p);
    }
    if (p->fmt) {
        if (p->io) {
            avformat_free_context(p->fmt);
        } else {
            avformat_close_input(&p->fmt);
        }
        p->fmt = NULL;
    }
    if (p->io) {
        lp_io_close(p->io);
        p->io = NULL;
    }
    free(p->url);
    p->url = NULL;
    free(p->options_json);
    p->options_json = NULL;
    p->opened = 0;
    atomic_store(&p->abort_request, 0);
    if (lp_get_state(p) != LP_STATE_IDLE) {
        lp_set_state(p, LP_STATE_IDLE);
    }
    return LP_OK;
}

int32_t lp_player_play(LpPlayer *p)
{
    if (!p) {
        return LP_ERR_ARGUMENT;
    }
    LpState st = lp_get_state(p);
    if (st == LP_STATE_OPENING) {
        return LP_OK; /* auto started when ready */
    }
    if (st != LP_STATE_READY && st != LP_STATE_PAUSED && st != LP_STATE_ENDED &&
        st != LP_STATE_STOPPED) {
        return LP_ERR_STATE;
    }
    if (st == LP_STATE_ENDED || st == LP_STATE_STOPPED) {
        lp_request_seek(p, 0);
    }
    lp_set_state(p, LP_STATE_PLAYING);
    return LP_OK;
}

int32_t lp_player_pause(LpPlayer *p)
{
    if (!p) {
        return LP_ERR_ARGUMENT;
    }
    if (lp_get_state(p) != LP_STATE_PLAYING) {
        return LP_ERR_STATE;
    }
    lp_set_state(p, LP_STATE_PAUSED);
    return LP_OK;
}

int32_t lp_player_stop(LpPlayer *p)
{
    if (!p) {
        return LP_ERR_ARGUMENT;
    }
    if (!p->opened) {
        return LP_OK;
    }
    lp_set_state(p, LP_STATE_STOPPED);
    lp_audio_sink_pause(p->sink, 1);
    lp_request_seek(p, 0);
    return LP_OK;
}

int32_t lp_player_seek(LpPlayer *p, int64_t position_us)
{
    if (!p) {
        return LP_ERR_ARGUMENT;
    }
    if (!p->opened) {
        return LP_ERR_STATE;
    }
    lp_request_seek(p, position_us);
    return LP_OK;
}

int32_t lp_player_set_speed(LpPlayer *p, float speed)
{
    if (!p) {
        return LP_ERR_ARGUMENT;
    }
    if (speed < 0.5f) speed = 0.5f;
    if (speed > 2.0f) speed = 2.0f;
    p->speed = speed;
    lp_clock_set_speed(&p->ac, speed);
    lp_clock_set_speed(&p->extc, speed);
    lp_audio_rebuild_graph(p);
    return LP_OK;
}

int32_t lp_player_get_speed(LpPlayer *p, float *out_speed)
{
    if (!p || !out_speed) {
        return LP_ERR_ARGUMENT;
    }
    *out_speed = (float)p->speed;
    return LP_OK;
}

int32_t lp_player_set_volume(LpPlayer *p, float volume)
{
    if (!p) {
        return LP_ERR_ARGUMENT;
    }
    if (volume < 0) volume = 0;
    if (volume > 2) volume = 2;
    p->volume = volume;
    if (p->audio.ring.buf) {
        lp_ring_set_gain(&p->audio.ring, p->muted ? 0.0 : (double)volume);
    }
    /* 打一条 info 级日志：音量是用户可感知但看不见的状态，出问题时
     * 「到底有没有调下去」只能靠日志判断（UI 上只显示百分比）。 */
    LP_INFO("audio", "volume %.2f (%d%%)%s", (double)volume,
            (int)(volume * 100.0f + 0.5f), p->muted ? " [muted]" : "");
    return LP_OK;
}

int32_t lp_player_set_mute(LpPlayer *p, int32_t muted)
{
    if (!p) {
        return LP_ERR_ARGUMENT;
    }
    p->muted = muted != 0;
    if (p->audio.ring.buf) {
        lp_ring_set_gain(&p->audio.ring, p->muted ? 0.0 : (double)p->volume);
    }
    return LP_OK;
}

int32_t lp_player_select_track(LpPlayer *p, int32_t stream_type, int32_t index)
{
    if (!p || !p->opened) {
        return LP_ERR_STATE;
    }
    if (stream_type == LP_TRACK_SUBTITLE) {
        lp_subtitle_select(p, index);
        char *info = lp_media_info_json(p);
        if (info) {
            emit_owned_json(p, LP_EVENT_TRACKS, 0, info);
        }
        return LP_OK;
    }
    if (stream_type == LP_TRACK_AUDIO) {
        if (index < 0 || (unsigned)index >= p->fmt->nb_streams) {
            return LP_ERR_ARGUMENT;
        }
        if (p->fmt->streams[index]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
            return LP_ERR_ARGUMENT;
        }
        if (index == p->audio.stream_index) {
            return LP_OK;
        }
        int64_t pos = lp_master_clock_us(p);
        lp_audio_stop(p);
        p->audio.stream_index = index;
        if (lp_audio_start(p) == LP_OK) {
            lp_pq_start(&p->audio.pq);
            lp_request_seek(p, pos);
        }
        char *info = lp_media_info_json(p);
        if (info) {
            emit_owned_json(p, LP_EVENT_TRACKS, 0, info);
        }
        return LP_OK;
    }
    return LP_ERR_UNSUPPORTED;
}

int32_t lp_player_add_subtitle(LpPlayer *p, const char *url, const char *options_json)
{
    if (!p || !url) {
        return LP_ERR_ARGUMENT;
    }
    return lp_subtitle_add_file(p, url, options_json && *options_json ? options_json : p->options_json);
}

int32_t lp_player_set_subtitle_delay(LpPlayer *p, int64_t delay_ms)
{
    if (!p) {
        return LP_ERR_ARGUMENT;
    }
    lp_subtitle_set_delay(p, delay_ms);
    return LP_OK;
}

int32_t lp_player_get_state(LpPlayer *p)
{
    return p ? (int32_t)lp_get_state(p) : LP_STATE_IDLE;
}

int32_t lp_player_get_position(LpPlayer *p, int64_t *out_us)
{
    if (!p || !out_us) {
        return LP_ERR_ARGUMENT;
    }
    *out_us = atomic_load(&p->position_us);
    return LP_OK;
}

int32_t lp_player_get_duration(LpPlayer *p, int64_t *out_us)
{
    if (!p || !out_us) {
        return LP_ERR_ARGUMENT;
    }
    *out_us = p->duration_us;
    return LP_OK;
}

int32_t lp_player_get_media_info(LpPlayer *p, char **out_json)
{
    if (!p || !out_json) {
        return LP_ERR_ARGUMENT;
    }
    *out_json = lp_media_info_json(p);
    return *out_json ? LP_OK : LP_ERR_NOMEM;
}

/* ---------------------------------------------------------- video output --- */

int32_t lp_player_set_surface(LpPlayer *p, void *native_window, int32_t width, int32_t height)
{
    if (!p) {
        return LP_ERR_ARGUMENT;
    }
    int had_window = p->vout.window != NULL;
    p->vout.window = native_window;
    p->vout.window_w = width;
    p->vout.window_h = height;
    p->vout.kind = native_window ? LP_VOUT_ANDROID_WINDOW : LP_VOUT_NONE;
    if (native_window) {
        lp_render_set_window(p, native_window, width, height);
    }
    /* A hardware decoder must be configured with the surface; if it started
     * without one, restart the video pipeline now. */
    if (!had_window && native_window && p->opened && p->video.hw_active &&
        p->video.thread_started) {
        int64_t pos = lp_master_clock_us(p);
        lp_video_stop(p);
        p->video.stream_index = av_find_best_stream(p->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
        if (lp_video_start(p) == LP_OK) {
            lp_pq_start(&p->video.pq);
            lp_request_seek(p, pos);
        }
    }
    return LP_OK;
}

int32_t lp_player_set_surface_size(LpPlayer *p, int32_t width, int32_t height)
{
    if (!p) {
        return LP_ERR_ARGUMENT;
    }
    p->vout.window_w = width;
    p->vout.window_h = height;
    return lp_render_resize(p, width, height);
}

int32_t lp_player_set_scale_mode(LpPlayer *p, int32_t mode)
{
    if (!p) {
        return LP_ERR_ARGUMENT;
    }
    if (mode < LP_SCALE_FIT || mode > LP_SCALE_STRETCH) {
        return LP_ERR_ARGUMENT;
    }
    p->vout.scale_mode = mode;
    return LP_OK;
}

int32_t lp_player_install_frame_callback(LpPlayer *p, LpFrameCallback cb, void *user)
{
    if (!p) {
        return LP_ERR_ARGUMENT;
    }
    pthread_mutex_lock(&p->vout.mutex);
    p->vout.frame_cb = cb;
    p->vout.frame_cb_user = user;
    p->vout.kind = LP_VOUT_APPLE_TEXTURE;
    pthread_mutex_unlock(&p->vout.mutex);
    return LP_OK;
}

/* -------------------------------------------------------------- options --- */

int32_t lp_player_set_option(LpPlayer *p, const char *key, const char *value)
{
    if (!p || !key) {
        return LP_ERR_ARGUMENT;
    }
    if (!strcmp(key, "volume")) {
        return lp_player_set_volume(p, (float)atof(value));
    }
    if (!strcmp(key, "speed")) {
        return lp_player_set_speed(p, (float)atof(value));
    }
    if (!strcmp(key, "scale_mode")) {
        return lp_player_set_scale_mode(p, atoi(value));
    }
    if (!strcmp(key, "deinterlace")) {
        p->deinterlace = value && (atoi(value) || !strcmp(value, "true"));
        return LP_OK;
    }
    if (!strcmp(key, "subtitle_delay")) {
        return lp_player_set_subtitle_delay(p, atoll(value ? value : "0"));
    }
    if (!strcmp(key, "hw")) {
        if (p->opened) {
            return LP_ERR_STATE; /* requires reopening the media */
        }
        if (!strcmp(value, "sw") || !strcmp(value, "software")) {
            p->hw_mode = LP_HW_SOFTWARE;
            p->hw_forced_name[0] = '\0';
        } else if (!strcmp(value, "auto")) {
            p->hw_mode = LP_HW_AUTO;
        } else {
            p->hw_mode = LP_HW_FORCED;
            snprintf(p->hw_forced_name, sizeof(p->hw_forced_name), "%s", value);
        }
        return LP_OK;
    }
    return LP_ERR_UNSUPPORTED;
}

int32_t lp_player_get_option(LpPlayer *p, const char *key, char *buf, int32_t buflen)
{
    if (!p || !key || !buf || buflen <= 0) {
        return LP_ERR_ARGUMENT;
    }
    if (!strcmp(key, "hw")) {
        snprintf(buf, (size_t)buflen, "%s", p->video.hw_name ? p->video.hw_name : "none");
        return LP_OK;
    }
    if (!strcmp(key, "speed")) {
        snprintf(buf, (size_t)buflen, "%.2f", p->speed);
        return LP_OK;
    }
    if (!strcmp(key, "volume")) {
        snprintf(buf, (size_t)buflen, "%.2f", p->volume);
        return LP_OK;
    }
    if (!strcmp(key, "state")) {
        snprintf(buf, (size_t)buflen, "%d", (int)lp_get_state(p));
        return LP_OK;
    }
    if (!strcmp(key, "duration")) {
        snprintf(buf, (size_t)buflen, "%lld", (long long)p->duration_us);
        return LP_OK;
    }
    return LP_ERR_UNSUPPORTED;
}
