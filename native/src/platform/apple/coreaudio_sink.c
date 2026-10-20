/*
 * Apple audio output through AudioQueue (AudioToolbox).
 *
 * Three ~20 ms buffers are kept in flight; the callback pulls float32 stereo
 * from the core ring buffer, so the device clock drives the master clock.
 */
#if defined(__APPLE__)

#include <AudioToolbox/AudioToolbox.h>
#include <stdlib.h>

#include "player_internal.h"

#define LP_AQ_BUFFERS 3
#define LP_AQ_FRAMES 960 /* 20 ms at 48 kHz */

struct LpAudioSink {
    AudioQueueRef queue;
    AudioQueueBufferRef buffers[LP_AQ_BUFFERS];
    int nbuf;
    LpPlayer *player;
    int sample_rate;
    int channels;
    int paused;
    int started;
};

static void aq_callback(void *user, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
    LpAudioSink *s = user;
    if (!s || !s->player) {
        return;
    }
    int frames = (int)(buffer->mAudioDataBytesCapacity / (sizeof(float) * (size_t)s->channels));
    int got = lp_audio_pull_pcm(s->player, (float *)buffer->mAudioData, frames);
    if (got < 0) {
        got = 0;
    }
    buffer->mAudioDataByteSize = (UInt32)got * (UInt32)s->channels * (UInt32)sizeof(float);
    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
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

    AudioStreamBasicDescription desc;
    memset(&desc, 0, sizeof(desc));
    desc.mSampleRate = sample_rate;
    desc.mFormatID = kAudioFormatLinearPCM;
    desc.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    desc.mChannelsPerFrame = (UInt32)channels;
    desc.mBitsPerChannel = 32;
    desc.mFramesPerPacket = 1;
    desc.mBytesPerFrame = (UInt32)(channels * sizeof(float));
    desc.mBytesPerPacket = desc.mBytesPerFrame;

    OSStatus st = AudioQueueNewOutput(&desc, aq_callback, s, NULL, NULL, 0, &s->queue);
    if (st != noErr || !s->queue) {
        LP_ERROR("audioqueue", "AudioQueueNewOutput failed: %d", (int)st);
        s->queue = NULL;
        return LP_ERR_IO;
    }
    for (int i = 0; i < LP_AQ_BUFFERS; i++) {
        st = AudioQueueAllocateBuffer(s->queue, LP_AQ_FRAMES * desc.mBytesPerFrame,
                                     &s->buffers[i]);
        if (st != noErr) {
            LP_ERROR("audioqueue", "allocate buffer failed: %d", (int)st);
            lp_audio_sink_stop(s);
            return LP_ERR_IO;
        }
        s->buffers[i]->mAudioDataByteSize = s->buffers[i]->mAudioDataBytesCapacity;
        memset(s->buffers[i]->mAudioData, 0, s->buffers[i]->mAudioDataByteSize);
        AudioQueueEnqueueBuffer(s->queue, s->buffers[i], 0, NULL);
        s->nbuf++;
    }
    st = AudioQueueStart(s->queue, NULL);
    if (st != noErr) {
        LP_ERROR("audioqueue", "AudioQueueStart failed: %d", (int)st);
        return LP_ERR_IO;
    }
    s->started = 1;
    LP_INFO("audioqueue", "started %dHz x%d", sample_rate, channels);
    return LP_OK;
}

void lp_audio_sink_stop(LpAudioSink *s)
{
    if (!s) {
        return;
    }
    if (s->queue) {
        AudioQueueStop(s->queue, true);
        AudioQueueDispose(s->queue, true);
        s->queue = NULL;
    }
    s->nbuf = 0;
    s->started = 0;
}

void lp_audio_sink_pause(LpAudioSink *s, int paused)
{
    if (!s || !s->queue) {
        return;
    }
    if (paused) {
        AudioQueuePause(s->queue);
    } else {
        AudioQueueStart(s->queue, NULL);
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
    if (!s || s->sample_rate <= 0) {
        return 0;
    }
    return LP_AQ_FRAMES * 1000000 / s->sample_rate * (LP_AQ_BUFFERS - 1);
}

const char *lp_audio_sink_name(LpAudioSink *s)
{
    (void)s;
    return "audioqueue";
}

#endif /* __APPLE__ */
