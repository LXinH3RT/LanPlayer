/*
 * BGRA -> RGBA conversion for Flutter desktop textures.
 *
 * The core renders BGRA because that is the pixel order GDI's
 * StretchDIBits wants (and what lp_win32_save_bmp and the subtitle overlay
 * blender both assume).  FlutterDesktopPixelBuffer carries no format field and
 * the engine always reads a pixel-buffer texture as RGBA8888, so the plugin has
 * to swap the channels on the way out.
 *
 * Getting this wrong is not subtle: skipping it turns the picture blue, because
 * every red becomes blue and vice versa.
 *
 * This lives in a header shared by the plugin and the standalone test so the
 * conversion can be checked without a Flutter build.
 */
#ifndef LANPLAYER_VIDEO_PIXEL_SWIZZLE_H_
#define LANPLAYER_VIDEO_PIXEL_SWIZZLE_H_

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

/* Swaps R and B in place and forces the alpha channel opaque.
 *
 * `stride` is the byte pitch of a row and must be >= width * 4; the trailing
 * padding bytes of a row are left untouched.  Returns non-zero when the
 * arguments describe a buffer that can be converted. */
static int lp_bgra_to_rgba(uint8_t *data, int width, int height, int stride)
{
    if (!data || width <= 0 || height <= 0) {
        return 0;
    }
    if (stride < width * 4) {
        return 0;
    }
    for (int y = 0; y < height; ++y) {
        uint8_t *row = data + (size_t)y * (size_t)stride;
        for (int x = 0; x < width; ++x) {
            uint8_t b = row[0];
            row[0] = row[2];   /* R lands where the engine expects R */
            row[2] = b;        /* B lands where the engine expects B */
            row[3] = 0xFF;     /* video is opaque; sws leaves junk here */
            row += 4;
        }
    }
    return 1;
}

#if defined(__cplusplus)
} /* extern "C" */
#endif

/* The plugin is C++, where a plain `static` in a header trips -Wunused-function
 * when a translation unit includes it without calling it.  `inline` keeps the
 * symbol local and silences that warning. */
#if defined(__cplusplus)
static inline void lp_bgra_to_rgba_cpp(uint8_t *data, int width, int height,
                                       int stride)
{
    (void)lp_bgra_to_rgba(data, width, height, stride);
}
#endif

#endif /* LANPLAYER_VIDEO_PIXEL_SWIZZLE_H_ */
