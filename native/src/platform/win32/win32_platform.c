/*
 * Windows desktop platform adapter for the LanPlayer core.
 *
 * Used by the native preview player (src/app/lp_preview.c).  It provides:
 *   - video output: sws -> BGRA back buffer, the UI thread blits it with GDI
 *   - audio output: waveOut (float32 stereo), pulls from the core ring buffer
 *   - no hardware decoder on Windows yet (D3D11VA is roadmap v0.3), so the
 *     software path is used and hp fallback messaging stays identical.
 */
#if defined(_WIN32)

/* windows.h must come first: mmsystem.h and wingdi.h rely on its types. */
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <mmreg.h>
#include <mmsystem.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "player_internal.h"
#include "platform/win32/win32_preview.h"

/* ---------------------------------------------------------------- video --- */

typedef struct LpWin32Video {
    CRITICAL_SECTION lock;
    uint8_t *pixels;   /* BGRA, stride = width * 4 */
    int width;
    int height;
    int stride;
    int has_frame;
    int frame_count;
    int64_t serial;
    HWND notify;
    struct SwsContext *sws;
} LpWin32Video;

static LpWin32Video g_video;

static void video_lock_init(void)
{
    static int inited = 0;
    if (!inited) {
        InitializeCriticalSection(&g_video.lock);
        inited = 1;
    }
}

int lp_render_init(LpPlayer *p)
{
    (void)p;
    video_lock_init();
    return LP_OK;
}

int lp_render_available(void)
{
    return 1;
}

const char *lp_render_name(void)
{
    return "win32-gdi";
}

int lp_render_set_window(LpPlayer *p, void *window, int width, int height)
{
    (void)p;
    video_lock_init();
    EnterCriticalSection(&g_video.lock);
    g_video.notify = (HWND)window;
    LeaveCriticalSection(&g_video.lock);
    (void)width;
    (void)height;
    return LP_OK;
}

int lp_render_resize(LpPlayer *p, int width, int height)
{
    (void)p;
    (void)width;
    (void)height;
    return LP_OK;
}

int lp_render_draw(LpPlayer *p, AVFrame *frame)
{
    if (!frame || frame->width <= 0 || frame->height <= 0) {
        return LP_ERR_ARGUMENT;
    }
    video_lock_init();
    int w = frame->width;
    int h = frame->height;
    size_t need = (size_t)w * (size_t)h * 4;

    EnterCriticalSection(&g_video.lock);
    if (!g_video.pixels || g_video.width != w || g_video.height != h) {
        free(g_video.pixels);
        g_video.pixels = malloc(need);
        if (!g_video.pixels) {
            LeaveCriticalSection(&g_video.lock);
            return LP_ERR_NOMEM;
        }
        g_video.width = w;
        g_video.height = h;
        g_video.stride = w * 4;
        if (g_video.sws) {
            sws_freeContext(g_video.sws);
            g_video.sws = NULL;
        }
    }
    if (!g_video.sws) {
        g_video.sws = sws_getContext(w, h, (enum AVPixelFormat)frame->format, w, h,
                                     AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL, NULL, NULL);
    }
    if (!g_video.sws) {
        LeaveCriticalSection(&g_video.lock);
        return LP_ERR_CODEC;
    }
    uint8_t *dst[4] = {g_video.pixels, NULL, NULL, NULL};
    int dst_linesize[4] = {g_video.stride, 0, 0, 0};
    sws_scale(g_video.sws, (const uint8_t *const *)frame->data, frame->linesize, 0, h, dst,
              dst_linesize);
    /* Graphics subtitles (PGS / VobSub / DVB) are bitmaps, not text: blend them
     * onto the converted picture so every host that shows this buffer gets them
     * for free. */
    lp_sub_overlay_blend(p, g_video.pixels, w, h, g_video.stride);
    g_video.has_frame = 1;
    g_video.frame_count++;
    g_video.serial++;
    HWND notify = g_video.notify;
    LeaveCriticalSection(&g_video.lock);

    p->vout.frame_w = w;
    p->vout.frame_h = h;
    p->vout.frames_published++;

    if (notify) {
        PostMessageW(notify, WM_APP + 1, 0, 0);
    }
    /* Flutter desktop hosts install a "new frame" callback instead of a window. */
    LpFrameCallback frame_cb = p->vout.frame_cb;
    if (frame_cb) {
        frame_cb(p->vout.frame_cb_user);
    }
    return LP_OK;
}

/* Preview / Flutter-desktop helpers ---------------------------------------- */

int lp_win32_frame_count(void)
{
    video_lock_init();
    EnterCriticalSection(&g_video.lock);
    int n = g_video.frame_count;
    LeaveCriticalSection(&g_video.lock);
    return n;
}

int lp_win32_frame_size(int *width, int *height, int *stride)
{
    video_lock_init();
    EnterCriticalSection(&g_video.lock);
    int have = g_video.has_frame;
    if (have) {
        if (width) *width = g_video.width;
        if (height) *height = g_video.height;
        if (stride) *stride = g_video.stride;
    }
    LeaveCriticalSection(&g_video.lock);
    return have;
}

int64_t lp_win32_frame_serial(void)
{
    video_lock_init();
    EnterCriticalSection(&g_video.lock);
    int64_t s = g_video.serial;
    LeaveCriticalSection(&g_video.lock);
    return s;
}

int lp_win32_copy_frame(uint8_t *dst, size_t cap, int *width, int *height, int *stride)
{
    if (!dst) {
        return 0;
    }
    video_lock_init();
    EnterCriticalSection(&g_video.lock);
    if (!g_video.has_frame || !g_video.pixels || cap < (size_t)g_video.stride * g_video.height) {
        LeaveCriticalSection(&g_video.lock);
        return 0;
    }
    memcpy(dst, g_video.pixels, (size_t)g_video.stride * g_video.height);
    if (width) {
        *width = g_video.width;
    }
    if (height) {
        *height = g_video.height;
    }
    if (stride) {
        *stride = g_video.stride;
    }
    LeaveCriticalSection(&g_video.lock);
    return 1;
}

/* Blits the latest frame into a device context, letterboxed to fit. */
int lp_win32_blit(HDC dc, int target_w, int target_h, int scale_mode)
{
    video_lock_init();
    EnterCriticalSection(&g_video.lock);
    if (!g_video.has_frame || !g_video.pixels) {
        LeaveCriticalSection(&g_video.lock);
        return 0;
    }
    int fw = g_video.width;
    int fh = g_video.height;
    double fit_x = (double)target_w / fw;
    double fit_y = (double)target_h / fh;
    double scale = (scale_mode == 1) ? (fit_x > fit_y ? fit_x : fit_y)
                                     : (fit_x < fit_y ? fit_x : fit_y);
    int dw = (int)(fw * scale);
    int dh = (int)(fh * scale);
    int dx = (target_w - dw) / 2;
    int dy = (target_h - dh) / 2;

    BITMAPINFO bi;
    memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = fw;
    bi.bmiHeader.biHeight = -fh; /* top-down */
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;

    SetStretchBltMode(dc, HALFTONE);
    StretchDIBits(dc, dx, dy, dw, dh, 0, 0, fw, fh, g_video.pixels, &bi, DIB_RGB_COLORS,
                  SRCCOPY);
    LeaveCriticalSection(&g_video.lock);
    return 1;
}

/* Writes the current frame as a 32-bit BMP (used by --dump). */
int lp_win32_save_bmp(const char *path)
{
    video_lock_init();
    EnterCriticalSection(&g_video.lock);
    if (!g_video.has_frame || !g_video.pixels) {
        LeaveCriticalSection(&g_video.lock);
        return -1;
    }
    int w = g_video.width;
    int h = g_video.height;
    size_t image = (size_t)w * h * 4;
    BITMAPFILEHEADER fh;
    BITMAPINFOHEADER ih;
    memset(&fh, 0, sizeof(fh));
    memset(&ih, 0, sizeof(ih));
    fh.bfType = 0x4D42;
    fh.bfOffBits = sizeof(fh) + sizeof(ih);
    fh.bfSize = (DWORD)(fh.bfOffBits + image);
    ih.biSize = sizeof(ih);
    ih.biWidth = w;
    ih.biHeight = h; /* positive: bottom-up, so rows are flipped below */
    ih.biPlanes = 1;
    ih.biBitCount = 32;
    ih.biCompression = BI_RGB;
    ih.biSizeImage = (DWORD)image;

    FILE *f = fopen(path, "wb");
    if (!f) {
        LeaveCriticalSection(&g_video.lock);
        return -1;
    }
    fwrite(&fh, sizeof(fh), 1, f);
    fwrite(&ih, sizeof(ih), 1, f);
    /* BGRA buffer is top-down; BMP wants bottom-up. */
    for (int y = h - 1; y >= 0; y--) {
        fwrite(g_video.pixels + (size_t)y * g_video.stride, 1, (size_t)w * 4, f);
    }
    fclose(f);
    LeaveCriticalSection(&g_video.lock);
    return 0;
}

void lp_render_close(LpPlayer *p)
{
    (void)p;
    video_lock_init();
    EnterCriticalSection(&g_video.lock);
    free(g_video.pixels);
    g_video.pixels = NULL;
    g_video.width = g_video.height = 0;
    g_video.has_frame = 0;
    if (g_video.sws) {
        sws_freeContext(g_video.sws);
        g_video.sws = NULL;
    }
    LeaveCriticalSection(&g_video.lock);
}

int lp_render_publish_pixel_buffer(LpPlayer *p, void *cv_pixel_buffer)
{
    (void)p;
    (void)cv_pixel_buffer;
    return LP_ERR_UNSUPPORTED;
}

void *lp_player_copy_pixel_buffer(LpPlayer *p)
{
    (void)p;
    return NULL;
}

/* ---------------------------------------------------------------- audio --- */

#define LP_WO_BUFFERS 4
#define LP_WO_FRAMES 960 /* 20 ms at 48 kHz */

struct LpAudioSink {
    HWAVEOUT handle;
    WAVEHDR headers[LP_WO_BUFFERS];
    short *data[LP_WO_BUFFERS];
    LpPlayer *player;
    int sample_rate;
    int channels;
    int frames_per_buffer;
    int started;
    int paused;
};

static void wo_fill(LpAudioSink *s, WAVEHDR *hdr)
{
    int frames = s->frames_per_buffer;
    float *dst = (float *)hdr->lpData;
    int got = lp_audio_pull_pcm(s->player, dst, frames);
    if (got <= 0) {
        memset(dst, 0, (size_t)frames * 2 * sizeof(float));
    }
    hdr->dwBufferLength = (DWORD)(frames * 2 * sizeof(float));
}

static void CALLBACK wo_callback(HWAVEOUT h, UINT msg, DWORD_PTR user, DWORD_PTR param1,
                                 DWORD_PTR param2)
{
    (void)param2;
    if (msg != WOM_DONE) {
        return;
    }
    LpAudioSink *s = (LpAudioSink *)user;
    WAVEHDR *hdr = (WAVEHDR *)param1;
    if (!s || !hdr || !s->started) {
        return;
    }
    wo_fill(s, hdr);
    waveOutWrite(h, hdr, sizeof(WAVEHDR));
}

LpAudioSink *lp_audio_sink_create(LpPlayer *p)
{
    LpAudioSink *s = calloc(1, sizeof(*s));
    if (s) {
        s->player = p;
    }
    return s;
}

int lp_audio_sink_start(LpAudioSink *s, int sample_rate, int channels)
{
    if (!s) {
        return LP_ERR_ARGUMENT;
    }
    s->sample_rate = sample_rate;
    s->channels = channels;
    s->frames_per_buffer = sample_rate / 50 > 0 ? sample_rate / 50 : LP_WO_FRAMES;

    WAVEFORMATEX wf;
    memset(&wf, 0, sizeof(wf));
    wf.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
    wf.nChannels = (WORD)channels;
    wf.nSamplesPerSec = (DWORD)sample_rate;
    wf.wBitsPerSample = 32;
    wf.nBlockAlign = (WORD)(channels * 4);
    wf.nAvgBytesPerSec = wf.nSamplesPerSec * wf.nBlockAlign;

    MMRESULT r = waveOutOpen(&s->handle, WAVE_MAPPER, &wf, (DWORD_PTR)wo_callback, (DWORD_PTR)s,
                             CALLBACK_FUNCTION);
    if (r != MMSYSERR_NOERROR) {
        LP_ERROR("waveout", "waveOutOpen failed: %u (no audio device?)", (unsigned)r);
        s->handle = NULL;
        return LP_ERR_IO;
    }
    for (int i = 0; i < LP_WO_BUFFERS; i++) {
        s->data[i] = malloc((size_t)s->frames_per_buffer * 2 * sizeof(float));
        if (!s->data[i]) {
            return LP_ERR_NOMEM;
        }
        memset(&s->headers[i], 0, sizeof(WAVEHDR));
        s->headers[i].lpData = (LPSTR)s->data[i];
        s->headers[i].dwBufferLength = (DWORD)(s->frames_per_buffer * 2 * sizeof(float));
        wo_fill(s, &s->headers[i]);
        waveOutPrepareHeader(s->handle, &s->headers[i], sizeof(WAVEHDR));
        waveOutWrite(s->handle, &s->headers[i], sizeof(WAVEHDR));
    }
    s->started = 1;
    LP_INFO("waveout", "started %d Hz x%d", sample_rate, channels);
    return LP_OK;
}

void lp_audio_sink_stop(LpAudioSink *s)
{
    if (!s || !s->handle) {
        return;
    }
    s->started = 0;
    waveOutReset(s->handle);
    for (int i = 0; i < LP_WO_BUFFERS; i++) {
        waveOutUnprepareHeader(s->handle, &s->headers[i], sizeof(WAVEHDR));
        free(s->data[i]);
        s->data[i] = NULL;
    }
    waveOutClose(s->handle);
    s->handle = NULL;
}

void lp_audio_sink_pause(LpAudioSink *s, int paused)
{
    if (!s || !s->handle) {
        return;
    }
    if (paused) {
        waveOutPause(s->handle);
    } else {
        waveOutRestart(s->handle);
    }
    s->paused = paused;
}

void lp_audio_sink_destroy(LpAudioSink *s)
{
    if (!s) {
        return;
    }
    lp_audio_sink_stop(s);
    free(s);
}

int lp_audio_sink_latency_us(LpAudioSink *s)
{
    if (!s || !s->sample_rate) {
        return 0;
    }
    return s->frames_per_buffer * 1000000 / s->sample_rate * (LP_WO_BUFFERS - 1);
}

const char *lp_audio_sink_name(LpAudioSink *s)
{
    (void)s;
    return "waveout";
}

#endif /* _WIN32 */
