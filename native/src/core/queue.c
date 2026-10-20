/* Packet queue, frame queue and the master clock. */
#include <stdlib.h>

#include "player_internal.h"

/* ------------------------------------------------------------- packets --- */



void lp_pq_init(LpPacketQueue *q, int64_t max_bytes)
{
    memset(q, 0, sizeof(*q));
    const char *limit = getenv("LP_PQ_MAX_KB");  /* debug: shrink the read-ahead window */
    if (limit && atoi(limit) > 0) {
        max_bytes = (int64_t)atoi(limit) * 1024;
    }
    q->max_bytes = max_bytes > 0 ? max_bytes : LP_MAX_PACKET_BYTES;
    pthread_mutex_init(&q->mutex, NULL);
    pthread_cond_init(&q->cond, NULL);
}

void lp_pq_destroy(LpPacketQueue *q)
{
    lp_pq_flush(q);
    pthread_mutex_destroy(&q->mutex);
    pthread_cond_destroy(&q->cond);
}

void lp_pq_flush(LpPacketQueue *q)
{
    pthread_mutex_lock(&q->mutex);
    LpPacketNode *n = q->head;
    while (n) {
        LpPacketNode *next = n->next;
        av_packet_free(&n->pkt);
        free(n);
        n = next;
    }
    q->head = q->tail = NULL;
    q->nb_packets = 0;
    q->bytes = 0;
    q->eof = 0;
    pthread_cond_broadcast(&q->cond);
    pthread_mutex_unlock(&q->mutex);
}

void lp_pq_abort(LpPacketQueue *q)
{
    pthread_mutex_lock(&q->mutex);
    q->abort_request = 1;
    q->eof = 1;
    pthread_cond_broadcast(&q->cond);
    pthread_mutex_unlock(&q->mutex);
}

void lp_pq_start(LpPacketQueue *q)
{
    pthread_mutex_lock(&q->mutex);
    q->abort_request = 0;
    q->eof = 0;
    pthread_cond_broadcast(&q->cond);
    pthread_mutex_unlock(&q->mutex);
}

/*
 * Takes ownership of |pkt|: on success it is queued, on failure it has already
 * been freed and the caller must not free it again (this used to be a double
 * free whenever the queue was aborted while the demuxer was blocked on it).
 */
int lp_pq_put(LpPacketQueue *q, AVPacket *pkt, int serial)
{
    if (!pkt) {
        return LP_ERR_ARGUMENT;
    }
    LpPacketNode *node = calloc(1, sizeof(*node));
    if (!node) {
        av_packet_free(&pkt);
        return LP_ERR_NOMEM;
    }
    node->pkt = pkt;

    pthread_mutex_lock(&q->mutex);
    if (q->abort_request) {
        pthread_mutex_unlock(&q->mutex);
        av_packet_free(&node->pkt);
        free(node);
        return LP_ERR_IO;
    }
    /* Back-pressure: the demux thread blocks here while the queue is full, so
     * memory stays bounded no matter how fast the share can be read. */
    while (!q->abort_request && q->nb_packets > 8 && q->bytes >= q->max_bytes) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_nsec += 20 * 1000 * 1000;
        if (ts.tv_nsec >= 1000000000) {
            ts.tv_sec++;
            ts.tv_nsec -= 1000000000;
        }
        pthread_cond_timedwait(&q->cond, &q->mutex, &ts);
    }
    if (q->abort_request) {
        pthread_mutex_unlock(&q->mutex);
        av_packet_free(&node->pkt);
        free(node);
        return LP_ERR_IO;
    }
    if (q->tail) {
        q->tail->next = node;
    } else {
        q->head = node;
    }
    q->tail = node;
    q->nb_packets++;
    q->bytes += pkt->size;
    q->serial = serial;
    pthread_cond_broadcast(&q->cond);
    pthread_mutex_unlock(&q->mutex);
    return 0;
}

AVPacket *lp_pq_get(LpPacketQueue *q, int *serial, int block)
{
    pthread_mutex_lock(&q->mutex);
    for (;;) {
        if (q->abort_request) {
            pthread_mutex_unlock(&q->mutex);
            return NULL;
        }
        if (q->head) {
            LpPacketNode *n = q->head;
            q->head = n->next;
            if (!q->head) {
                q->tail = NULL;
            }
            q->nb_packets--;
            q->bytes -= n->pkt->size;
            AVPacket *pkt = n->pkt;
            if (serial) {
                *serial = q->serial;
            }
            free(n);
            pthread_cond_broadcast(&q->cond);
            pthread_mutex_unlock(&q->mutex);
            return pkt;
        }
        if (q->eof || !block) {
            if (serial) {
                *serial = q->serial;
            }
            pthread_mutex_unlock(&q->mutex);
            return NULL;
        }
        pthread_cond_wait(&q->cond, &q->mutex);
    }
}

void lp_pq_signal_eof(LpPacketQueue *q, int serial)
{
    pthread_mutex_lock(&q->mutex);
    q->eof = 1;
    q->serial = serial;
    pthread_cond_broadcast(&q->cond);
    pthread_mutex_unlock(&q->mutex);
}

int lp_pq_size(LpPacketQueue *q)
{
    pthread_mutex_lock(&q->mutex);
    int n = q->nb_packets;
    pthread_mutex_unlock(&q->mutex);
    return n;
}

int lp_pq_eof(LpPacketQueue *q)
{
    pthread_mutex_lock(&q->mutex);
    int eof = q->eof && q->nb_packets == 0;
    pthread_mutex_unlock(&q->mutex);
    return eof;
}

/* --------------------------------------------------------------- clock --- */

static double now_seconds(void)
{
    return (double)av_gettime_relative() / (double)LP_TIME_BASE;
}

void lp_clock_init(LpClock *c)
{
    memset(c, 0, sizeof(*c));
    c->speed = 1.0;
    c->serial = -1;
    pthread_mutex_init(&c->mutex, NULL);
}

void lp_clock_destroy(LpClock *c)
{
    pthread_mutex_destroy(&c->mutex);
}

void lp_clock_set(LpClock *c, double pts_seconds, int serial)
{
    pthread_mutex_lock(&c->mutex);
    double now = now_seconds();
    c->pts = pts_seconds;
    c->pts_drift = pts_seconds - now;
    c->last_updated = now;
    c->serial = serial;
    pthread_mutex_unlock(&c->mutex);
}

void lp_clock_set_speed(LpClock *c, double speed)
{
    pthread_mutex_lock(&c->mutex);
    double now = now_seconds();
    /* Keep the current position continuous across a speed change. */
    c->pts = c->paused ? c->pts : c->pts_drift + now * c->speed;
    c->pts_drift = c->pts - now * speed;
    c->speed = speed;
    c->last_updated = now;
    pthread_mutex_unlock(&c->mutex);
}

double lp_clock_get_raw(LpClock *c)
{
    pthread_mutex_lock(&c->mutex);
    double now = now_seconds();
    double t = c->paused ? c->pts : c->pts_drift + now * c->speed;
    pthread_mutex_unlock(&c->mutex);
    return t;
}

double lp_clock_get(LpClock *c)
{
    double t = lp_clock_get_raw(c);
    /* Clamp: the clock must never go backwards or jump ahead of the media. */
    if (t < 0) {
        t = 0;
    }
    return t;
}

void lp_clock_sync(LpClock *c, double pts_seconds)
{
    pthread_mutex_lock(&c->mutex);
    double now = now_seconds();
    double cur = c->paused ? c->pts : c->pts_drift + now * c->speed;
    double diff = pts_seconds - cur;
    double absdiff = diff < 0 ? -diff : diff;
    if (absdiff > 0.5) {
        /* Large error: hard reset to avoid a long drift chase. */
        c->pts = pts_seconds;
        c->pts_drift = pts_seconds - now * c->speed;
    } else {
        /* Small error: move only a fraction of the way per update. */
        c->pts_drift += diff * 0.05;
    }
    c->last_updated = now;
    pthread_mutex_unlock(&c->mutex);
}

void lp_clock_pause(LpClock *c, int paused)
{
    pthread_mutex_lock(&c->mutex);
    if (paused == c->paused) {
        pthread_mutex_unlock(&c->mutex);
        return;
    }
    if (paused) {
        c->pts = c->pts_drift + now_seconds() * c->speed;
        c->paused = 1;
    } else {
        c->pts_drift = c->pts - now_seconds() * c->speed;
        c->paused = 0;
    }
    c->last_updated = now_seconds();
    pthread_mutex_unlock(&c->mutex);
}
