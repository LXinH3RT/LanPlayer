/*
 * Apple video output: publish CVPixelBufferRef frames to the Flutter texture.
 *
 * Swift owns a FlutterTexture whose copyPixelBuffer() calls
 * lp_player_copy_pixel_buffer(); the core keeps one retained frame plus a
 * "new frame" notification, which is the minimum amount of glue needed for
 * zero-copy rendering (the pixel buffer is IOSurface backed).
 */
#if defined(__APPLE__)

#include <CoreVideo/CoreVideo.h>

#include <stdlib.h>

#include "player_internal.h"

int lp_render_available(void)
{
    return 1;
}

const char *lp_render_name(void)
{
    return "flutter-texture";
}

int lp_render_init(LpPlayer *p)
{
    pthread_mutex_lock(&p->vout.mutex);
    p->vout.kind = LP_VOUT_APPLE_TEXTURE;
    pthread_mutex_unlock(&p->vout.mutex);
    return LP_OK;
}

void lp_render_close(LpPlayer *p)
{
    pthread_mutex_lock(&p->vout.mutex);
    if (p->vout.pixel_buffer) {
        CVPixelBufferRelease((CVPixelBufferRef)p->vout.pixel_buffer);
        p->vout.pixel_buffer = NULL;
    }
    pthread_mutex_unlock(&p->vout.mutex);
}

int lp_render_set_window(LpPlayer *p, void *window, int width, int height)
{
    (void)p;
    (void)window;
    (void)width;
    (void)height;
    return LP_ERR_UNSUPPORTED; /* iOS uses the texture bridge, not a window */
}

int lp_render_resize(LpPlayer *p, int width, int height)
{
    (void)p;
    (void)width;
    (void)height;
    return LP_OK; /* the texture is laid out by Flutter */
}

int lp_render_publish_pixel_buffer(LpPlayer *p, void *cv_pixel_buffer)
{
    if (!p || !cv_pixel_buffer) {
        return LP_ERR_ARGUMENT;
    }
    CVPixelBufferRef image = (CVPixelBufferRef)cv_pixel_buffer;
    LpFrameCallback cb = NULL;
    void *user = NULL;

    pthread_mutex_lock(&p->vout.mutex);
    if (p->vout.pixel_buffer) {
        CVPixelBufferRelease((CVPixelBufferRef)p->vout.pixel_buffer);
    }
    p->vout.pixel_buffer = CVBufferRetain(image);
    p->vout.has_new_frame = 1;
    p->vout.frames_published++;
    p->vout.frame_w = (int)CVPixelBufferGetWidth(image);
    p->vout.frame_h = (int)CVPixelBufferGetHeight(image);
    cb = p->vout.frame_cb;
    user = p->vout.frame_cb_user;
    pthread_mutex_unlock(&p->vout.mutex);

    if (cb) {
        cb(user);
    }
    return LP_OK;
}

/* Software decode fallback: convert the AVFrame to BGRA into a new
 * CVPixelBuffer so the texture path stays identical. */
int lp_render_draw(LpPlayer *p, AVFrame *frame)
{
    if (!p || !frame) {
        return LP_ERR_ARGUMENT;
    }
    static struct SwsContext *sws = NULL;
    CVPixelBufferRef image = NULL;
    CFDictionaryRef empty = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, empty);
    int fmt = kCVPixelFormatType_32BGRA;
    CFNumberRef fmt_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &fmt);
    CFDictionarySetValue(attrs, kCVPixelBufferPixelFormatTypeKey, fmt_num);
    CFRelease(fmt_num);

    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, (size_t)frame->width,
                                     (size_t)frame->height, kCVPixelFormatType_32BGRA, attrs,
                                     &image);
    CFRelease(attrs);
    CFRelease(empty);
    if (r != kCVReturnSuccess || !image) {
        return LP_ERR_NOMEM;
    }
    CVPixelBufferLockBaseAddress(image, 0);
    uint8_t *dst[4] = {(uint8_t *)CVPixelBufferGetBaseAddress(image), NULL, NULL, NULL};
    int dst_linesize[4] = {(int)CVPixelBufferGetBytesPerRow(image), 0, 0, 0};
    if (!sws) {
        sws = sws_getContext(frame->width, frame->height, (enum AVPixelFormat)frame->format,
                             frame->width, frame->height, AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL,
                             NULL, NULL);
    }
    if (sws) {
        sws_scale(sws, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, dst,
                  dst_linesize);
        /* Graphics subtitles are bitmaps: blend them onto the BGRA picture so
         * the texture already carries them. */
        lp_sub_overlay_blend(p, dst[0], frame->width, frame->height, dst_linesize[0]);
    }
    CVPixelBufferUnlockBaseAddress(image, 0);
    lp_render_publish_pixel_buffer(p, image);
    CVPixelBufferRelease(image);
    return LP_OK;
}

void *lp_player_copy_pixel_buffer(LpPlayer *p)
{
    if (!p) {
        return NULL;
    }
    pthread_mutex_lock(&p->vout.mutex);
    CVPixelBufferRef image = (CVPixelBufferRef)p->vout.pixel_buffer;
    if (image) {
        CVBufferRetain(image);
    }
    p->vout.has_new_frame = 0;
    pthread_mutex_unlock(&p->vout.mutex);
    return image;
}

#endif /* __APPLE__ */
