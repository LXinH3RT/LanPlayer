/* Float32 audio ring buffer that decouples the decode thread from the sink's
 * realtime callback, plus the sample-index -> media-time mapping that gives us
 * the audio master clock. */
#include <stdlib.h>

#include "player_internal.h"

static void prune_markers(LpAudioRing *r, int keep_one_before)
{
    while (r->marker_count > 1) {
        int idx = r->marker_head;
        LpAudioMarker *m = &r->markers[idx];
        if (m->sample <= r->sample_index) {
            r->marker_head = (r->marker_head + 1) % LP_AUDIO_MARKERS;
            r->marker_count--;
        } else {
            break;
        }
    }
    (void)keep_one_before;
}

int lp_ring_init(LpAudioRing *r, int channels, int sample_rate, int latency_ms)
{
    memset(r, 0, sizeof(*r));
    if (channels <= 0 || channels > 8 || sample_rate <= 0) {
        return LP_ERR_ARGUMENT;
    }
    if (latency_ms < 40) {
        latency_ms = 40;
    }
    if (latency_ms > 1000) {
        latency_ms = 1000;
    }
    r->channels = channels;
    r->sample_rate = sample_rate;
    r->capacity_frames = sample_rate * latency_ms / 1000;
    if (r->capacity_frames < 512) {
        r->capacity_frames = 512;
    }
    r->buf = calloc((size_t)r->capacity_frames * (size_t)channels, sizeof(float));
    if (!r->buf) {
        return LP_ERR_NOMEM;
    }
    r->gain = 1.0;
    pthread_mutex_init(&r->mutex, NULL);
    pthread_cond_init(&r->cond, NULL);
    return LP_OK;
}

void lp_ring_destroy(LpAudioRing *r)
{
    pthread_mutex_lock(&r->mutex);
    r->abort_request = 1;
    pthread_cond_broadcast(&r->cond);
    pthread_mutex_unlock(&r->mutex);
    pthread_mutex_destroy(&r->mutex);
    pthread_cond_destroy(&r->cond);
    free(r->buf);
    r->buf = NULL;
}

void lp_ring_flush(LpAudioRing *r)
{
    pthread_mutex_lock(&r->mutex);
    r->read_pos = r->write_pos = 0;
    r->count = 0;
    r->marker_count = 0;
    r->marker_head = 0;
    pthread_cond_broadcast(&r->cond);
    pthread_mutex_unlock(&r->mutex);
}

void lp_ring_abort(LpAudioRing *r)
{
    pthread_mutex_lock(&r->mutex);
    r->abort_request = 1;
    pthread_cond_broadcast(&r->cond);
    pthread_mutex_unlock(&r->mutex);
}

void lp_ring_set_paused(LpAudioRing *r, int paused)
{
    pthread_mutex_lock(&r->mutex);
    r->paused = paused;
    pthread_cond_broadcast(&r->cond);
    pthread_mutex_unlock(&r->mutex);
}

void lp_ring_set_gain(LpAudioRing *r, double gain)
{
    pthread_mutex_lock(&r->mutex);
    r->gain = gain < 0 ? 0 : gain;
    pthread_mutex_unlock(&r->mutex);
}

int lp_ring_write(LpAudioRing *r, const float *interleaved, int frames, double chunk_pts_seconds,
                  double scale)
{
    if (!r->buf || frames <= 0) {
        return 0;
    }
    int written = 0;
    pthread_mutex_lock(&r->mutex);
    if (r->marker_count == LP_AUDIO_MARKERS) {
        r->marker_head = (r->marker_head + 1) % LP_AUDIO_MARKERS;
        r->marker_count--;
    }
    int slot = (r->marker_head + r->marker_count) % LP_AUDIO_MARKERS;
    r->markers[slot].sample = r->sample_index + r->count;
    r->markers[slot].pts_seconds = chunk_pts_seconds;
    r->markers[slot].scale = scale > 0.0 ? scale : 1.0;
    r->marker_count++;

    while (written < frames) {
        if (r->abort_request) {
            pthread_mutex_unlock(&r->mutex);
            return LP_ERR_INTERRUPTED;
        }
        if (r->count >= r->capacity_frames) {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_nsec += 20 * 1000 * 1000;
            if (ts.tv_nsec >= 1000000000) {
                ts.tv_sec++;
                ts.tv_nsec -= 1000000000;
            }
            pthread_cond_timedwait(&r->cond, &r->mutex, &ts);
            continue;
        }
        int room = r->capacity_frames - r->count;
        int chunk = frames - written;
        if (chunk > room) {
            chunk = room;
        }
        /* Two-segment copy to handle wrap-around. */
        int first = r->capacity_frames - r->write_pos;
        if (first > chunk) {
            first = chunk;
        }
        memcpy(r->buf + (size_t)r->write_pos * (size_t)r->channels,
               interleaved + (size_t)written * (size_t)r->channels,
               (size_t)first * (size_t)r->channels * sizeof(float));
        int rest = chunk - first;
        if (rest > 0) {
            memcpy(r->buf, interleaved + (size_t)(written + first) * (size_t)r->channels,
                   (size_t)rest * (size_t)r->channels * sizeof(float));
        }
        r->write_pos = (r->write_pos + chunk) % r->capacity_frames;
        r->count += chunk;
        written += chunk;
    }
    pthread_cond_broadcast(&r->cond);
    pthread_mutex_unlock(&r->mutex);
    return written;
}

int lp_ring_read(LpAudioRing *r, float *out, int frames)
{
    if (!r->buf || frames <= 0) {
        return 0;
    }
    int total = frames * r->channels;
    pthread_mutex_lock(&r->mutex);
    if (r->paused || r->count == 0) {
        memset(out, 0, (size_t)total * sizeof(float));
        pthread_mutex_unlock(&r->mutex);
        return frames; /* silence, clock does not advance */
    }
    int n = frames;
    if (n > r->count) {
        n = r->count;
    }
    int first = r->capacity_frames - r->read_pos;
    if (first > n) {
        first = n;
    }
    memcpy(out, r->buf + (size_t)r->read_pos * (size_t)r->channels,
           (size_t)first * (size_t)r->channels * sizeof(float));
    int rest = n - first;
    if (rest > 0) {
        memcpy(out + (size_t)first * (size_t)r->channels, r->buf,
               (size_t)rest * (size_t)r->channels * sizeof(float));
    }
    r->read_pos = (r->read_pos + n) % r->capacity_frames;
    r->count -= n;
    r->sample_index += n;

    double g = r->gain;
    if (g != 1.0) {
        int samples = n * r->channels;
        for (int i = 0; i < samples; i++) {
            float v = (float)(out[i] * g);
            if (v > 1.0f) v = 1.0f;
            if (v < -1.0f) v = -1.0f;
            out[i] = v;
        }
    }
    if (n < frames) {
        memset(out + (size_t)n * (size_t)r->channels, 0,
               (size_t)(frames - n) * (size_t)r->channels * sizeof(float));
    }
    prune_markers(r, 1);
    pthread_cond_broadcast(&r->cond);
    pthread_mutex_unlock(&r->mutex);
    return frames;
}

double lp_ring_clock_seconds(LpAudioRing *r)
{
    pthread_mutex_lock(&r->mutex);
    if (r->marker_count == 0) {
        pthread_mutex_unlock(&r->mutex);
        return -1.0;
    }
    /* Last marker at or before the play head. */
    int best = r->marker_head;
    for (int i = 0; i < r->marker_count; i++) {
        int idx = (r->marker_head + i) % LP_AUDIO_MARKERS;
        if (r->markers[idx].sample <= r->sample_index) {
            best = idx;
        } else {
            break;
        }
    }
    double t = r->markers[best].pts_seconds +
               (double)(r->sample_index - r->markers[best].sample) / (double)r->sample_rate *
                   r->markers[best].scale;
    pthread_mutex_unlock(&r->mutex);
    return t;
}

int lp_ring_buffered_ms(LpAudioRing *r, int sample_rate)
{
    pthread_mutex_lock(&r->mutex);
    int frames = r->count;
    pthread_mutex_unlock(&r->mutex);
    if (sample_rate <= 0) {
        return 0;
    }
    return frames * 1000 / sample_rate;
}
