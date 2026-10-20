/*
 * Portable reference implementation of the platform adapters.
 *
 * Used for desktop builds, unit tests and CI: there is no hardware decoder and
 * no window, but the audio sink runs a real pull thread so the master clock,
 * A/V sync and subtitle timing can be exercised without any device.
 */
#include <stdlib.h>

#include "player_internal.h"

/* ------------------------------------------------------------- audio sink --- */

struct LpAudioSink {
    LpPlayer *player;
    pthread_t thread;
    atomic_int run;
    atomic_int paused;
    int sample_rate;
    int channels;
    int started;
};

static void *stub_sink_thread(void *arg)
{
    LpAudioSink *s = arg;
    float buf[512 * 2];
    while (atomic_load(&s->run)) {
        if (atomic_load(&s->paused)) {
            av_usleep(10000);
            continue;
        }
        lp_audio_pull_pcm(s->player, buf, 480);
        av_usleep(10000); /* 480 frames @48k = 10 ms of audio */
    }
    return NULL;
}

LpAudioSink *lp_audio_sink_create(LpPlayer *p)
{
    LpAudioSink *s = calloc(1, sizeof(*s));
    if (!s) {
        return NULL;
    }
    s->player = p;
    atomic_init(&s->run, 0);
    atomic_init(&s->paused, 0);
    return s;
}

int lp_audio_sink_start(LpAudioSink *s, int sample_rate, int channels)
{
    if (!s) {
        return LP_ERR_ARGUMENT;
    }
    s->sample_rate = sample_rate;
    s->channels = channels;
    atomic_store(&s->run, 1);
    if (pthread_create(&s->thread, NULL, stub_sink_thread, s) != 0) {
        atomic_store(&s->run, 0);
        return LP_ERR_IO;
    }
    s->started = 1;
    return LP_OK;
}

void lp_audio_sink_stop(LpAudioSink *s)
{
    if (!s || !s->started) {
        return;
    }
    atomic_store(&s->run, 0);
    pthread_join(s->thread, NULL);
    s->started = 0;
}

void lp_audio_sink_pause(LpAudioSink *s, int paused)
{
    if (s) {
        atomic_store(&s->paused, paused != 0);
    }
}

void lp_audio_sink_destroy(LpAudioSink *s)
{
    if (!s) {
        return;
    }
    lp_audio_sink_stop(s);
    free(s);
}

int lp_audio_sink_latency_us(LpAudioSink *s)
{
    (void)s;
    return 10000;
}

const char *lp_audio_sink_name(LpAudioSink *s)
{
    (void)s;
    return "null";
}

/* --------------------------------------------------------- hardware decode --- */

LpVideoDecoder *lp_hw_decoder_create(void)
{
    return NULL;
}

int lp_hw_decoder_init(LpVideoDecoder *d, const LpVideoDecoderConfig *cfg, char *err, size_t errlen)
{
    (void)d;
    (void)cfg;
    if (err && errlen) {
        snprintf(err, errlen, "no hardware decoder on this platform");
    }
    return LP_ERR_UNSUPPORTED;
}

int lp_hw_decoder_available(void)
{
    return 0;
}

const char *lp_hw_decoder_name(void)
{
    return "none";
}

int lp_hw_decoder_send(LpVideoDecoder *d, const AVPacket *pkt)
{
    (void)d;
    (void)pkt;
    return LP_ERR_UNSUPPORTED;
}

int lp_hw_decoder_receive(LpVideoDecoder *d, LpDecodedFrame *out)
{
    (void)d;
    (void)out;
    return LP_ERR_UNSUPPORTED;
}

int lp_hw_decoder_present(LpVideoDecoder *d, LpDecodedFrame *f)
{
    (void)d;
    (void)f;
    return LP_ERR_UNSUPPORTED;
}

void lp_hw_decoder_flush(LpVideoDecoder *d)
{
    (void)d;
}

void lp_hw_decoder_destroy(LpVideoDecoder *d)
{
    free(d);
}

/* ------------------------------------------------------------ video output --- */

int lp_render_init(LpPlayer *p)
{
    (void)p;
    return LP_OK;
}

void lp_render_close(LpPlayer *p)
{
    (void)p;
}

int lp_render_set_window(LpPlayer *p, void *window, int width, int height)
{
    (void)p;
    (void)window;
    (void)width;
    (void)height;
    return LP_ERR_UNSUPPORTED;
}

int lp_render_resize(LpPlayer *p, int width, int height)
{
    (void)p;
    (void)width;
    (void)height;
    return LP_ERR_UNSUPPORTED;
}

int lp_render_draw(LpPlayer *p, AVFrame *frame)
{
    (void)p;
    (void)frame;
    return LP_ERR_UNSUPPORTED;
}

int lp_render_publish_pixel_buffer(LpPlayer *p, void *cv_pixel_buffer)
{
    (void)p;
    (void)cv_pixel_buffer;
    return LP_ERR_UNSUPPORTED;
}

int lp_render_available(void)
{
    return 0;
}

const char *lp_render_name(void)
{
    return "none";
}

void *lp_player_copy_pixel_buffer(LpPlayer *p)
{
    (void)p;
    return NULL;
}
