/*
 * Windows platform adapter entry points.
 *
 * - The preview player (native/src/app/lp_preview.c) uses blit/save_bmp.
 * - A Flutter desktop host uses copy_frame through its texture bridge, so the
 *   same core feeds a Flutter texture instead of a GDI surface.
 *
 * Everything exported here is part of lanplayer.dll on Windows.
 */
#ifndef LANPLAYER_WIN32_PREVIEW_H
#define LANPLAYER_WIN32_PREVIEW_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#include <windows.h>
#endif

#ifndef LP_EXPORT
#if defined(_WIN32)
#define LP_EXPORT __declspec(dllexport)
#else
#define LP_EXPORT __attribute__((visibility("default")))
#endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Number of frames handed to the renderer so far. */
LP_EXPORT int lp_win32_frame_count(void);

/* Size of the latest frame (1 when a frame is available, 0 before the first). */
LP_EXPORT int lp_win32_frame_size(int *width, int *height, int *stride);

/* Monotonic frame counter; lets a consumer detect "a new frame arrived". */
LP_EXPORT int64_t lp_win32_frame_serial(void);

/*
 * Copies the latest BGRA frame into `dst` (capacity `cap` bytes).
 * Returns 1 on success and fills width/height/stride, 0 when there is no frame
 * or the buffer is too small.  Thread-safe: the video thread may be writing.
 */
LP_EXPORT int lp_win32_copy_frame(uint8_t *dst, size_t cap, int *width, int *height, int *stride);

#if defined(_WIN32)
/* Letterboxes the latest frame into `dc`; returns 1 when a frame was drawn. */
LP_EXPORT int lp_win32_blit(HDC dc, int target_w, int target_h, int scale_mode);

/* Saves the latest frame as 32-bit BMP (used by --dump / --selftest). */
LP_EXPORT int lp_win32_save_bmp(const char *path);
#endif

#ifdef __cplusplus
}
#endif

#endif /* LANPLAYER_WIN32_PREVIEW_H */
