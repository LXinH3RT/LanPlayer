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
    /* 首帧诊断：确认回调真的跑起来了、且拿到的是非静音数据。之后不再打。 */
    int reported_first;
    float peak;
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
    if ((float *)buffer->mAudioData) {
        const float *pcm = (const float *)buffer->mAudioData;
        for (int i = 0; i < got * s->channels; i++) {
            float v = pcm[i] < 0 ? -pcm[i] : pcm[i];
            if (v > s->peak) {
                s->peak = v;
            }
        }
    }
    /* 首帧留一条证据：真机上「有画面没声音」时要能分清是回调根本没跑、
     * 还是跑起来了但喂进去的全是静音。之后不再打，免得刷屏。 */
    if (!s->reported_first) {
        s->reported_first = 1;
        LP_INFO("audioqueue", "first cb got %d peak %.3f", got, (double)s->peak);
    }
    s->peak = 0.0f;
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
    s->reported_first = 0;
    s->peak = 0.0f;
    /* AudioQueue 自己也有一级音量，默认是 1.0，但会话切换类别之后它会被重置成
     * 系统媒体音量。显式读到并把非零值固定住：真机上「有数据没声音」时，
     * 这条日志能把「队列音量是 0」和「系统音量是 0」分开。 */
    Float32 qvol = -1.0f;
    if (AudioQueueGetParameter(s->queue, kAudioQueueParam_Volume, &qvol) == noErr && qvol <= 0.0f) {
        AudioQueueSetParameter(s->queue, kAudioQueueParam_Volume, 1.0f);
        qvol = 1.0f;
    }
    LP_INFO("audioqueue", "started %dHz x%d volume %.2f", sample_rate, channels, (double)qvol);
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
    s->reported_first = 0;
    s->peak = 0.0f;
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
