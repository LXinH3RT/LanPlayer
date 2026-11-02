/*
 * Apple video output: publish CVPixelBufferRef frames to the Flutter texture.
 *
 * Swift owns a FlutterTexture whose copyPixelBuffer() calls
 * lp_player_copy_pixel_buffer(); the core keeps one retained frame plus a
 * "new frame" notification, which is the minimum amount of glue needed for
 * zero-copy rendering (the pixel buffer is IOSurface backed).
 */
#if defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>

#include <stdlib.h>
#include <string.h>

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
    p->vout.has_new_frame = 0;
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
    /* 上一帧还没被引擎取走就来了新帧：它被覆盖，屏幕上永远看不到。
     *
     * 交付策略是「最新一帧优先」而不是排队 —— copyPixelBuffer 是引擎在
     * raster 线程上按 vsync 调用的，那一刻该显示的就是最新帧；排队只会让
     * 画面越来越滞后。但「没被取走」这件事本身要记下来：解码与同步都按时
     * 做完了，只是交付没跟上，而原来的统计里这种情况完全隐形
     * （dropped 恒为 0、fps 满帧），「音频正常、画面卡顿」无从排查。 */
    if (p->vout.has_new_frame) {
        p->vout.frames_delivery_lost++;
    }
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
    /* 缩放上下文必须跟着源帧走。以前这里是函数级 static，只在第一次按
     * frame->width/height/format 建一次，之后永远复用 —— 连播两个分辨率不同
     * 的文件、或者同片切到像素格式不同的轨时，sws_scale 会按错误的源尺寸
     * 取样，画面被拉花或者直接读越界。win32_platform.c 一直是按尺寸重建的。 */
    static struct SwsContext *sws = NULL;
    static int sws_src_w = 0;
    static int sws_src_h = 0;
    static int sws_src_fmt = -1;
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
    int src_fmt = (int)frame->format;
    if (sws && (sws_src_w != frame->width || sws_src_h != frame->height ||
                sws_src_fmt != src_fmt)) {
        sws_freeContext(sws);
        sws = NULL;
    }
    if (!sws) {
        sws = sws_getContext(frame->width, frame->height, (enum AVPixelFormat)frame->format,
                             frame->width, frame->height, AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL,
                             NULL, NULL);
        if (sws) {
            sws_src_w = frame->width;
            sws_src_h = frame->height;
            sws_src_fmt = src_fmt;
        }
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
    /* 取帧节奏单独量一遍。
     *
     * 帧数与丢帧数都对不上观感时，剩下的解释只有一个：帧到了，但间隔不均。
     * 一秒 24 帧照样可以看起来一顿一顿的——只要其中几帧晚到了 100 ms 以上。
     * 这里记下相邻两次取帧的间隔与「超过 1.5 个帧周期」的次数，由 STATS
     * 事件带出去；桌面与 Android 不走这条路径，恒为 0。 */
    const int64_t now = av_gettime_relative();
    int64_t frame_us = 40000;
    const double dur = p->video.frame_duration;
    if (dur > 0.0) {
        frame_us = (int64_t)(dur * 1000000.0);
    }
    pthread_mutex_lock(&p->vout.mutex);
    CVPixelBufferRef image = (CVPixelBufferRef)p->vout.pixel_buffer;
    if (image && p->vout.has_new_frame) {
        CVBufferRetain(image);
        /* 只在真的交出一帧时量间隔：引擎每 vsync 都会来调用，没新帧的那些
         * 调用不算「画面上跳了一下」。 */
        if (p->vout.last_pull_at_us > 0) {
            const int64_t gap = now - p->vout.last_pull_at_us;
            if (gap > p->vout.pull_gap_max_us) {
                p->vout.pull_gap_max_us = gap;
            }
            if (gap > frame_us * 3 / 2) {
                p->vout.pull_stall_count++;
            }
        }
        p->vout.last_pull_at_us = now;
    } else {
        /* 没有新帧就别把旧帧再交一次：引擎会把同一帧画两遍，看起来是
         * 「卡住了一下」。返回 NULL 让引擎保持上一帧。 */
        image = NULL;
    }
    p->vout.has_new_frame = 0;
    pthread_mutex_unlock(&p->vout.mutex);
    return image;
}

#endif /* __APPLE__ */
