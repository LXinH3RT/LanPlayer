/*
 * LanPlayer native core - public player API (dart:ffi surface).
 *
 * Threading contract: every function may be called from any thread.  Calls are
 * serialised internally; only `lp_player_open` is asynchronous (it returns
 * immediately and reports progress through LP_EVENT_STATE).
 *
 * Events are delivered on the player's own worker thread; the Dart side hops
 * them to the UI isolate through the NativePort callback registered in
 * app/lib/core/player_controller.dart.
 */
#ifndef LANPLAYER_LP_PLAYER_H
#define LANPLAYER_LP_PLAYER_H

#include "lanplayer/lp_types.h"
#include "lanplayer/lp_source.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LpPlayer LpPlayer;

/*
 * OWNERSHIP: `json` is a malloc'd UTF-8 string owned by the callback.  The
 * host must release it with lp_string_free() once copied.  This is what makes
 * the callback safe to marshal across threads (Dart's NativeCallable.listener
 * runs on the isolate's event loop, after the emitting native frame is gone).
 * `value` carries the scalar shortcut documented on LpEvent.
 */
typedef void (*LpEventCallback)(void *user, int32_t event, const char *json, int64_t value);

/* Called when a new Apple video frame is ready.  Host must hop to its own
 * thread and pull the frame with lp_player_copy_pixel_buffer(). */
typedef void (*LpFrameCallback)(void *user);

LP_EXPORT int32_t lp_abi_version(void);

LP_EXPORT int32_t lp_player_create(LpPlayer **out);
LP_EXPORT void lp_player_destroy(LpPlayer *player);
LP_EXPORT void lp_player_set_event_callback(LpPlayer *player, LpEventCallback cb, void *user);

/*
 * Open a media source.  options_json keys:
 *   "user","password","domain","timeout_ms"   transport credentials
 *   "hw":"auto"|"sw"|"mediacodec"|"videotoolbox"
 *   "scale_mode":0|1|2        "deinterlace":bool        "brightness"/"contrast"
 *   "start_us":int            "audio_index":int         "subtitle_index":int
 *   "auto_play":bool          "external_subtitles":["smb://..|file://.."]
 *   "render_backend":"auto"|"gl"        "sync":"audio"|"external"
 */
LP_EXPORT int32_t lp_player_open(LpPlayer *player, const char *url, const char *options_json);
LP_EXPORT int32_t lp_player_close(LpPlayer *player);

LP_EXPORT int32_t lp_player_play(LpPlayer *player);
LP_EXPORT int32_t lp_player_pause(LpPlayer *player);
LP_EXPORT int32_t lp_player_stop(LpPlayer *player);
LP_EXPORT int32_t lp_player_seek(LpPlayer *player, int64_t position_us);

/* 0.5 .. 2.0 (clamped).  Audio stays in pitch through an atempo chain. */
LP_EXPORT int32_t lp_player_set_speed(LpPlayer *player, float speed);
LP_EXPORT int32_t lp_player_get_speed(LpPlayer *player, float *out_speed);

/* 0.0 .. 2.0, linear gain, applied on the PCM mix stage. */
LP_EXPORT int32_t lp_player_set_volume(LpPlayer *player, float volume);
LP_EXPORT int32_t lp_player_set_mute(LpPlayer *player, int32_t muted);

/* stream_type: LpTrackType; index: -1 disables, -2 keeps current. */
LP_EXPORT int32_t lp_player_select_track(LpPlayer *player, int32_t stream_type, int32_t index);

/* Load an additional SRT/ASS/SMI/VTT file.  Returns the synthetic track index
 * (> 0) or a negative LpResult. */
LP_EXPORT int32_t lp_player_add_subtitle(LpPlayer *player, const char *url, const char *options_json);
/* Shift subtitle timing; positive values show subtitles later. */
LP_EXPORT int32_t lp_player_set_subtitle_delay(LpPlayer *player, int64_t delay_ms);

LP_EXPORT int32_t lp_player_get_state(LpPlayer *player);
LP_EXPORT int32_t lp_player_get_position(LpPlayer *player, int64_t *out_us);
LP_EXPORT int32_t lp_player_get_duration(LpPlayer *player, int64_t *out_us);
/* JSON: {"duration_us":..,"format":..,"bitrate":..,"video":{..},"audio":[..],
 *        "subtitle":[..],"hw":{"active":"mediacodec","fallback_reason":null}} */
LP_EXPORT int32_t lp_player_get_media_info(LpPlayer *player, char **out_json);

/* ---- video output ------------------------------------------------------ */

/* Android: ANativeWindow* from the SurfaceTexture owned by the Flutter
 * platform view.  Passing NULL detaches the output. */
LP_EXPORT int32_t lp_player_set_surface(LpPlayer *player, void *native_window,
                                        int32_t width, int32_t height);
/* Called on rotation / resize. */
LP_EXPORT int32_t lp_player_set_surface_size(LpPlayer *player, int32_t width, int32_t height);
LP_EXPORT int32_t lp_player_set_scale_mode(LpPlayer *player, int32_t mode);

/* Apple: FlutterTexture bridge. */
LP_EXPORT int32_t lp_player_install_frame_callback(LpPlayer *player, LpFrameCallback cb, void *user);
/* Returns a retained CVPixelBufferRef (release with CFRelease) or NULL. */
LP_EXPORT void *lp_player_copy_pixel_buffer(LpPlayer *player);

/* ---- advanced options -------------------------------------------------- */

LP_EXPORT int32_t lp_player_set_option(LpPlayer *player, const char *key, const char *value);
LP_EXPORT int32_t lp_player_get_option(LpPlayer *player, const char *key, char *buf, int32_t buflen);

#ifdef __cplusplus
}
#endif

#endif /* LANPLAYER_LP_PLAYER_H */
