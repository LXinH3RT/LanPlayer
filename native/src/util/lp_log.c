/* Minimal leveled logger with an optional host sink. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#include "player_internal.h"

#if defined(__ANDROID__)
#include <android/log.h>
#endif

static atomic_int g_level = LP_LOG_INFO;
static LpLogCallback g_cb = NULL;
static void *g_cb_user = NULL;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

void lp_log_set_level(int32_t level)
{
    if (level < LP_LOG_TRACE) level = LP_LOG_TRACE;
    if (level > LP_LOG_NONE) level = LP_LOG_NONE;
    atomic_store(&g_level, level);
}

int32_t lp_log_get_level(void)
{
    return atomic_load(&g_level);
}

void lp_log_set_callback(LpLogCallback cb, void *user)
{
    pthread_mutex_lock(&g_lock);
    g_cb = cb;
    g_cb_user = user;
    pthread_mutex_unlock(&g_lock);
}

static const char *level_name(int level)
{
    switch (level) {
    case LP_LOG_TRACE: return "T";
    case LP_LOG_DEBUG: return "D";
    case LP_LOG_INFO: return "I";
    case LP_LOG_WARN: return "W";
    case LP_LOG_ERROR: return "E";
    default: return "?";
    }
}

void lp_log_emit(int level, const char *tag, const char *fmt, ...)
{
    if (level < atomic_load(&g_level)) {
        return;
    }
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    pthread_mutex_lock(&g_lock);
    LpLogCallback cb = g_cb;
    void *user = g_cb_user;
    pthread_mutex_unlock(&g_lock);
    if (cb) {
        cb(user, level, tag ? tag : "core", msg);
        return;
    }
#if defined(__ANDROID__)
    __android_log_print(level >= LP_LOG_ERROR ? ANDROID_LOG_ERROR
                          : level == LP_LOG_WARN ? ANDROID_LOG_WARN
                          : level == LP_LOG_INFO ? ANDROID_LOG_INFO
                                                 : ANDROID_LOG_DEBUG,
                        "LanPlayer/%s", tag ? tag : "core", "%s", msg);
#else
    fprintf(stderr, "[LanPlayer %s %s] %s\n", level_name(level), tag ? tag : "core", msg);
#endif
}
