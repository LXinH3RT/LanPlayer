#ifndef LANPLAYER_LP_LOG_H
#define LANPLAYER_LP_LOG_H

#include "lanplayer/lp_types.h"

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define LP_EXPORT __declspec(dllexport)
#else
#define LP_EXPORT __attribute__((visibility("default")))
#endif

/* Optional sink; called from any thread.  Keep it non blocking. */
typedef void (*LpLogCallback)(void *user, int32_t level, const char *tag, const char *message);

LP_EXPORT void lp_log_set_level(int32_t level);
LP_EXPORT int32_t lp_log_get_level(void);
LP_EXPORT void lp_log_set_callback(LpLogCallback cb, void *user);

/* Internal use. */
void lp_log_emit(int32_t level, const char *tag, const char *fmt, ...);
void lp_log_vemit(int32_t level, const char *tag, const char *fmt, ...);

#define LP_TAG(tag, lvl, ...) lp_log_emit((lvl), (tag), __VA_ARGS__)
#define LP_TRACE(tag, ...) LP_TAG((tag), LP_LOG_TRACE, __VA_ARGS__)
#define LP_DEBUG(tag, ...) LP_TAG((tag), LP_LOG_DEBUG, __VA_ARGS__)
#define LP_INFO(tag, ...) LP_TAG((tag), LP_LOG_INFO, __VA_ARGS__)
#define LP_WARN(tag, ...) LP_TAG((tag), LP_LOG_WARN, __VA_ARGS__)
#define LP_ERROR(tag, ...) LP_TAG((tag), LP_LOG_ERROR, __VA_ARGS__)

#ifdef __cplusplus
}
#endif

#endif /* LANPLAYER_LP_LOG_H */
