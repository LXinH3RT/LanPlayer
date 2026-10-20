/*
 * LanPlayer native core - shared types and ABI constants.
 *
 * The whole C ABI is intentionally restricted to:
 *   int32_t / int64_t / float / char* (UTF-8, NUL terminated) / void*
 * so that dart:ffi can bind it without any struct-by-value or platform
 * specific layout.  Complex payloads travel as JSON strings.
 *
 * ABI version: bump LP_ABI_VERSION on any incompatible change; the Dart
 * side asserts lp_abi_version() at load time.
 */
#ifndef LANPLAYER_LP_TYPES_H
#define LANPLAYER_LP_TYPES_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LP_ABI_VERSION 1

/* Result codes.  Every exported function returns one of these unless it is
 * documented to return a value or a pointer. */
typedef enum LpResult {
    LP_OK = 0,
    LP_ERR_ARGUMENT = -1,
    LP_ERR_STATE = -2,
    LP_ERR_IO = -3,
    LP_ERR_UNSUPPORTED = -4,
    LP_ERR_NOMEM = -5,
    LP_ERR_CODEC = -6,
    LP_ERR_AGAIN = -7,
    LP_ERR_AUTH = -8,
    LP_ERR_NOT_FOUND = -9,
    LP_ERR_TIMEOUT = -10,
    LP_ERR_INTERRUPTED = -11,
    LP_ERR_END_OF_STREAM = -12
} LpResult;

typedef enum LpState {
    LP_STATE_IDLE = 0,
    LP_STATE_OPENING = 1,
    LP_STATE_READY = 2,
    LP_STATE_PLAYING = 3,
    LP_STATE_PAUSED = 4,
    LP_STATE_STOPPED = 5,
    LP_STATE_ENDED = 6,
    LP_STATE_ERROR = 7
} LpState;

/* Event kinds pushed to the host through LpEventCallback.
 * `json` carries the payload, `value` carries a scalar shortcut (microseconds
 * for position/duration events, track index for track events). */
typedef enum LpEvent {
    LP_EVENT_STATE = 1,       /* json {"state":3,"prev":2} */
    LP_EVENT_POSITION = 2,    /* json {"pos":1234567,"dur":7200000000} */
    LP_EVENT_MEDIA_INFO = 3,  /* json: see docs/ffi-api.md */
    LP_EVENT_ERROR = 4,       /* json {"code":-6,"message":"...","fatal":true} */
    LP_EVENT_ENDED = 5,       /* json {} */
    LP_EVENT_SUBTITLE = 6,    /* json {"text":..,"start":..,"end":..,"style":{..}} */
    LP_EVENT_STATS = 7,       /* json {"fps":..,"dropped":..,"av_diff":..,"hw":..} */
    LP_EVENT_LOG = 8,         /* json {"level":..,"tag":"..","message":".."} */
    LP_EVENT_BUFFERING = 9,   /* json {"buffering":true,"percent":42} */
    LP_EVENT_TRACKS = 10      /* json: media info after a track switch */
} LpEvent;

typedef enum LpTrackType {
    LP_TRACK_VIDEO = 0,
    LP_TRACK_AUDIO = 1,
    LP_TRACK_SUBTITLE = 2
} LpTrackType;

typedef enum LpScaleMode {
    LP_SCALE_FIT = 0,    /* letterbox, keep aspect ratio (default) */
    LP_SCALE_FILL = 1,   /* crop to fill */
    LP_SCALE_STRETCH = 2 /* ignore aspect ratio */
} LpScaleMode;

typedef enum LpLogLevel {
    LP_LOG_TRACE = 0,
    LP_LOG_DEBUG = 1,
    LP_LOG_INFO = 2,
    LP_LOG_WARN = 3,
    LP_LOG_ERROR = 4,
    LP_LOG_NONE = 5
} LpLogLevel;

#ifdef __cplusplus
}
#endif

#endif /* LANPLAYER_LP_TYPES_H */
