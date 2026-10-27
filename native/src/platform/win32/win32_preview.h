/*
 * Windows platform adapter entry points.
 *
 * - The preview player (native/src/app/lp_preview.c) uses blit/save_bmp.
 * - A Flutter desktop host uses the GPU surface below, so the picture reaches
 *   the engine as a shared D3D11 texture instead of a copied pixel buffer.
 *   copy_frame stays for hosts that cannot take a GPU surface.
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

/*
 * Latest picture as a shared D3D11 texture, or NULL when there is none (before
 * the first frame, or when the GPU output is unavailable and frames only exist
 * as pixels).
 *
 * The returned pointer is a legacy DXGI share handle for a BGRA texture of
 * `*width` x `*height`; a Flutter host opens it once and then samples the
 * texture on every `WM_APP+1`.  `*serial` changes whenever a new frame was
 * written into that same texture.  `*slot` must be handed back through
 * lp_win32_gpu_release() once the host is done reading.
 */
LP_EXPORT void *lp_win32_gpu_surface(int64_t *serial, int *width, int *height, int *slot);

/* 1 while frames are being published as GPU surfaces rather than pixels. */
LP_EXPORT int lp_win32_gpu_ready(void);

/* 1 once the latest frame actually went out as a GPU surface.  Distinct from
 * lp_win32_gpu_ready(): the device may exist while a stream still runs through
 * the CPU path (software decode of a format the video processor cannot eat). */
LP_EXPORT int lp_win32_gpu_active(void);

/* Releases the slot taken by lp_win32_gpu_surface().  Safe with a stale index. */
LP_EXPORT void lp_win32_gpu_release(int slot);

/* Downloads the current GPU surface into `dst` (BGRA, `*stride` bytes per row).
 * The preview player and any host without GPU surface support use this; call it
 * with dst = NULL to ask for the required size. */
LP_EXPORT int lp_win32_gpu_readback(unsigned char *dst, size_t cap, int *width, int *height,
                                   int *stride);
#endif

#ifdef __cplusplus
}
#endif

#endif /* LANPLAYER_WIN32_PREVIEW_H */
