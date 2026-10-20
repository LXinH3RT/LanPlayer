/*
 * Android audio output through AAudio (API 26+, the recommended NDK sink;
 * OpenSL ES is deprecated and AudioTrack needs JNI round trips).
 *
 * The callback pulls float32 stereo from the core ring buffer, which is what
 * advances the audio master clock.
 */
#if defined(__ANDROID__)

#include <aaudio/AAudio.h>
#include <stdlib.h>

#include "player_internal.h"

struct LpAudioSink {
    AAudioStream *stream;
    LpPlayer *player;
    int sample_rate;
    int channels;
    int paused;
    int started;
};

static aaudio_data_callback_result_t sink_data_cb(AAudioStream *stream, void *user,
                                                  void *audio_data, int32_t num_frames)
{
    (void)stream;
    LpAudioSink *s = user;
    if (!s || !s->player) {
        return AAUDIO_CALLBACK_RESULT_CONTINUE;
    }
    int got = lp_audio_pull_pcm(s->player, (float *)audio_data, num_frames);
    if (got < 0) {
        return AAUDIO_CALLBACK_RESULT_STOP;
    }
    return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

static void sink_error_cb(AAudioStream *stream, void *user, aaudio_result_t error)
{
    (void)stream;
    (void)user;
    LP_ERROR("aaudio", "stream error %d", (int)error);
}

LpAudioSink *lp_audio_sink_create(LpPlayer *p)
{
    LpAudioSink *s = calloc(1, sizeof(*s));
    if (!s) {
        return NULL;
    }
    s->player = p;
    return s;
}

int lp_audio_sink_start(LpAudioSink *s, int sample_rate, int channels)
{
    if (!s) {
        return LP_ERR_ARGUMENT;
    }
    s->sample_rate = sample_rate;
    s->channels = channels;
    AAudioStreamBuilder *builder = NULL;
    aaudio_result_t r = AAudio_createStreamBuilder(&builder);
    if (r != AAUDIO_OK || !builder) {
        LP_ERROR("aaudio", "createStreamBuilder failed: %d", (int)r);
        return LP_ERR_IO;
    }
    AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_OUTPUT);
    AAudioStreamBuilder_setSampleRate(builder, sample_rate);
    AAudioStreamBuilder_setChannelCount(builder, channels);
    AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_FLOAT);
    AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_SHARED);
    AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    AAudioStreamBuilder_setDataCallback(builder, sink_data_cb, s);
    AAudioStreamBuilder_setErrorCallback(builder, sink_error_cb, s);

    r = AAudioStreamBuilder_openStream(builder, &s->stream);
    AAudioStreamBuilder_delete(builder);
    if (r != AAUDIO_OK || !s->stream) {
        LP_ERROR("aaudio", "openStream failed: %d", (int)r);
        s->stream = NULL;
        return LP_ERR_IO;
    }
    int32_t actual_rate = AAudioStream_getSampleRate(s->stream);
    if (actual_rate > 0 && actual_rate != sample_rate) {
        LP_WARN("aaudio", "device rate %d differs from source %d", actual_rate, sample_rate);
    }
    r = AAudioStream_requestStart(s->stream);
    if (r != AAUDIO_OK) {
        LP_ERROR("aaudio", "requestStart failed: %d", (int)r);
        AAudioStream_close(s->stream);
        s->stream = NULL;
        return LP_ERR_IO;
    }
    s->started = 1;
    LP_INFO("aaudio", "started %dHz x%d", sample_rate, channels);
    return LP_OK;
}

void lp_audio_sink_stop(LpAudioSink *s)
{
    if (!s || !s->stream) {
        return;
    }
    AAudioStream_requestStop(s->stream);
    AAudioStream_close(s->stream);
    s->stream = NULL;
    s->started = 0;
}

void lp_audio_sink_pause(LpAudioSink *s, int paused)
{
    if (!s || !s->stream) {
        return;
    }
    if (paused && !s->paused) {
        AAudioStream_requestPause(s->stream);
    } else if (!paused && s->paused) {
        AAudioStream_requestStart(s->stream);
    }
    s->paused = paused;
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
    if (!s || !s->stream) {
        return 0;
    }
    int32_t frames = AAudioStream_getBufferSizeInFrames(s->stream);
    int32_t rate = AAudioStream_getSampleRate(s->stream);
    if (frames <= 0 || rate <= 0) {
        return 0;
    }
    return (int)((int64_t)frames * 1000000 / rate);
}

const char *lp_audio_sink_name(LpAudioSink *s)
{
    (void)s;
    return "aaudio";
}

#endif /* __ANDROID__ */
