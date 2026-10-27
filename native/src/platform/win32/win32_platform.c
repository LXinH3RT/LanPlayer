/*
 * Windows desktop platform adapter for the LanPlayer core.
 *
 * Used by the native preview player (src/app/lp_preview.c).  It provides:
 *   - video output: the decoders hand us frames; software frames are scaled to
 *     BGRA here, hardware frames are blitted on the GPU into a shared texture
 *     (see d3d11_output.c) so the Flutter host takes them without a copy
 *   - audio output: WASAPI shared mode, with waveOut as the fallback for
 *     machines where the audio service refuses to hand out a client
 */
#if defined(_WIN32)

/* windows.h must come first: the COM headers and wingdi.h rely on its types. */
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

/* INITGUID puts the CLSID/IID definitions in this translation unit instead of
 * pulling them out of libuuid, and COBJMACROS provides the C call macros for
 * the WASAPI interfaces (IMMDeviceEnumerator_*, IAudioClient_*, ...). */
#define INITGUID
#define COBJMACROS

#include <audioclient.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
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
    /* Colour description of the frames currently going through sws.  sws
     * defaults to BT.601 and happily converts a BT.709 stream with it, which
     * pushes reds towards orange.  Kept next to the context so a stream change
     * re-applies the right matrix. */
    int sws_cs;
    int sws_full;
    int sws_bt709;
    /* Set when the frame that just went out is also available as a D3D11
     * shared texture (see d3d11_output.c).  The Flutter host then samples the
     * surface instead of copying pixels. */
    int gpu_published;
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
    }    video_lock_init();
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
        g_video.sws_cs = -1;
    }
    if (!g_video.sws) {
        LeaveCriticalSection(&g_video.lock);
        return LP_ERR_CODEC;
    }
    /* Tell sws what the stream actually is.  Software decoding of a BT.709
     * clip used to come out with dull reds because sws assumed BT.601. */
    {
        int want_cs = 0;
        switch (frame->colorspace) {
        case AVCOL_SPC_BT709:
            want_cs = 1;
            break;
        case AVCOL_SPC_BT470BG:
        case AVCOL_SPC_SMPTE170M:
            want_cs = 2;
            break;
        default:
            want_cs = 0;
            break;
        }
        int want_full = frame->color_range == AVCOL_RANGE_JPEG ? 1 : 0;
        if (g_video.sws_cs != want_cs || g_video.sws_full != want_full) {
            const int *table = sws_getCoefficients(want_cs == 1   ? SWS_CS_ITU709
                                                   : want_cs == 2 ? SWS_CS_ITU601
                                                                  : SWS_CS_DEFAULT);
            if (table && sws_setColorspaceDetails(g_video.sws, table, want_full, table, 1, 0,
                                                  1 << 16, 1 << 16) >= 0) {
                g_video.sws_cs = want_cs;
                g_video.sws_full = want_full;
                g_video.sws_bt709 = want_cs == 1;
            } else {
                g_video.sws_cs = want_cs;
                g_video.sws_full = want_full;
            }
        }
    }
    uint8_t *dst[4] = {g_video.pixels, NULL, NULL, NULL};
    int dst_linesize[4] = {g_video.stride, 0, 0, 0};
    sws_scale(g_video.sws, (const uint8_t *const *)frame->data, frame->linesize, 0, h, dst,
              dst_linesize);
    /* Graphics subtitles (PGS / VobSub / DVB) are bitmaps, not text: blend them
     * onto the converted picture so every host that shows this buffer gets them
     * for free.  The same buffer is then uploaded as the shared texture, so the
     * GPU picture carries the subtitles too. */
    lp_sub_overlay_blend(p, g_video.pixels, w, h, g_video.stride);
    /* Publish the same picture as a GPU surface.  The upload is one
     * UpdateSubresource; from there on the host samples the texture and never
     * pulls pixels. */
    g_video.gpu_published =
        lp_gpu_output_upload(p, g_video.pixels, w, h, g_video.stride) == LP_OK;
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

/* Hardware path: the decoder still owns a D3D11 NV12 texture.  Rather than
 * downloading it, ask the GPU output to convert it into a shared BGRA surface
 * with the video processor.  Graphics subtitles cannot be blended onto it (that
 * would need a CPU buffer), so a stream that currently has bitmap subtitles on
 * screen reports LP_ERR_UNSUPPORTED and the caller falls back to the download --
 * correctness first, and only for the streams that actually use PGS/VobSub. */
int lp_render_draw_hw(LpPlayer *p, void *d3d_texture, unsigned slice, int width, int height)
{
    LpColorInfo color;
    memset(&color, 0, sizeof(color));
    return lp_render_draw_hw_ex(p, d3d_texture, slice, width, height, color);
}

int lp_render_draw_hw_ex(LpPlayer *p, void *d3d_texture, unsigned slice, int width, int height,
                         LpColorInfo color)
{
    if (!p || !d3d_texture || width <= 0 || height <= 0) {
        return LP_ERR_ARGUMENT;
    }
    lp_gpu_output_set_color(color.matrix, color.full_range);
    if (!lp_render_graphics_sub_active(p)) {
        if (lp_gpu_output_blit(p, d3d_texture, slice, width, height) == LP_OK) {
            video_lock_init();
            EnterCriticalSection(&g_video.lock);
            g_video.gpu_published = 1;
            g_video.has_frame = 1;
            /* The geometry has to be published even though there is no CPU
             * buffer: host code asks frame_size() whether a picture exists and
             * how big it is before deciding to sample the shared texture. */
            g_video.width = width;
            g_video.height = height;
            g_video.stride = width * 4;
            /* Drop any CPU buffer left over from a software-decoded stream:
             * copy_frame() must not hand a stale picture to a host that still
             * asks for pixels while the GPU surface is the live one. */
            free(g_video.pixels);
            g_video.pixels = NULL;
            g_video.frame_count++;
            g_video.serial++;
            HWND notify = g_video.notify;
            LeaveCriticalSection(&g_video.lock);

            p->vout.frame_w = width;
            p->vout.frame_h = height;
            p->vout.frames_published++;
            if (notify) {
                PostMessageW(notify, WM_APP + 1, 0, 0);
            }
            LpFrameCallback frame_cb = p->vout.frame_cb;
            if (frame_cb) {
                frame_cb(p->vout.frame_cb_user);
            }
            return LP_OK;
        }
    }
    return LP_ERR_UNSUPPORTED;
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
    int gpu = g_video.gpu_published;
    int w = g_video.width;
    int h = g_video.height;
    int have = g_video.has_frame;
    LeaveCriticalSection(&g_video.lock);
    /* On the GPU path there is deliberately no CPU copy of the picture, so a
     * host that still asks for pixels gets an on-demand download instead of a
     * silent failure.  Never hold the video lock across it: the readback takes
     * the GPU lock, and the decoder thread takes them in the opposite order. */
    if (gpu && have) {
        int rc = lp_gpu_output_readback(dst, cap, width, height, stride);
        return rc == LP_OK ? 1 : 0;
    }
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

/* True once the latest frame went out as a GPU surface; the host then samples
 * that texture instead of calling copy_frame. */
int lp_win32_gpu_active(void)
{
    video_lock_init();
    EnterCriticalSection(&g_video.lock);
    int on = g_video.gpu_published;
    LeaveCriticalSection(&g_video.lock);
    return on;
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
    g_video.gpu_published = 0;
    LeaveCriticalSection(&g_video.lock);
    /* The shared textures belong to the GPU output, not to one player, but they
     * are sized for the picture this player was showing: drop them so the next
     * open does not inherit a stale surface size. */
    lp_gpu_output_close();
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

/*
 * Two backends live here.  WASAPI is used whenever it can be opened, because
 * it shares the device with the rest of the system properly (per-app volume,
 * device changes, no 16 ms timer granularity) and lets us keep the buffer
 * short.  waveOut stays as the fallback: it works on every Windows since 95
 * and covers machines where the audio service is disabled or WASAPI refuses
 * our format.
 *
 * Both backends pull float32 interleaved stereo straight from the player's
 * ring buffer, so switching between them changes nothing above this file.
 */

#define LP_WO_BUFFERS 4
#define LP_WO_FRAMES 960 /* 20 ms at 48 kHz */
#define LP_WASAPI_CHUNKS 2
#define LP_WASAPI_MAX_CHUNKS 8

struct LpAudioSink {
    int backend; /* 0 = none, 1 = WASAPI, 2 = waveOut */
    LpPlayer *player;
    int sample_rate;
    int channels;
    int frames_per_buffer;
    int started;
    int paused;

    /* WASAPI --- */
    IMMDeviceEnumerator *was_enum;
    IMMDevice *was_device;
    IAudioClient *was_client;
    IAudioRenderClient *was_render;
    HANDLE was_event;
    UINT32 was_buffer_frames;
    pthread_t was_thread;
    atomic_int was_quit;
    int was_com_init;

    /* waveOut --- */
    HWAVEOUT handle;
    WAVEHDR headers[LP_WO_BUFFERS];
    short *data[LP_WO_BUFFERS];
};

/* --------------------------------------------------------------- wasapi --- */

static void was_release(LpAudioSink *s)
{
    if (s->was_client) {
        IAudioClient_Stop(s->was_client);
        IAudioClient_Release(s->was_client);
        s->was_client = NULL;
    }
    if (s->was_render) {
        IAudioRenderClient_Release(s->was_render);
        s->was_render = NULL;
    }
    if (s->was_device) {
        IMMDevice_Release(s->was_device);
        s->was_device = NULL;
    }
    if (s->was_enum) {
        IMMDeviceEnumerator_Release(s->was_enum);
        s->was_enum = NULL;
    }
    if (s->was_event) {
        CloseHandle(s->was_event);
        s->was_event = NULL;
    }
    s->was_buffer_frames = 0;
    if (s->was_com_init) {
        CoUninitialize();
        s->was_com_init = 0;
    }
}

static void *was_thread(void *arg)
{
    LpAudioSink *s = (LpAudioSink *)arg;
    while (!atomic_load(&s->was_quit)) {
        DWORD wait = WaitForSingleObject(s->was_event, 100);
        if (atomic_load(&s->was_quit)) {
            break;
        }
        if (wait != WAIT_OBJECT_0 || s->paused) {
            continue;
        }
        UINT32 padding = 0;
        if (FAILED(IAudioClient_GetCurrentPadding(s->was_client, &padding))) {
            continue;
        }
        UINT32 avail = s->was_buffer_frames > padding ? s->was_buffer_frames - padding : 0;
        if (avail < (UINT32)s->frames_per_buffer) {
            /* Keep a full chunk of headroom: waking up for a partially empty
             * buffer costs more than the latency it pretends to save. */
            continue;
        }
        if (avail > (UINT32)(s->frames_per_buffer * LP_WASAPI_MAX_CHUNKS)) {
            avail = (UINT32)(s->frames_per_buffer * LP_WASAPI_MAX_CHUNKS);
        }
        BYTE *dst = NULL;
        if (FAILED(IAudioRenderClient_GetBuffer(s->was_render, avail, &dst)) || !dst) {
            continue;
        }
        int frames = (int)avail;
        if (atomic_load(&s->was_quit)) {
            IAudioRenderClient_ReleaseBuffer(s->was_render, avail, AUDCLNT_BUFFERFLAGS_SILENT);
            break;
        }
        lp_audio_pull_pcm(s->player, (float *)dst, frames);
        IAudioRenderClient_ReleaseBuffer(s->was_render, (UINT32)frames, 0);
    }
    return NULL;
}

static int was_start(LpAudioSink *s, int sample_rate, int channels)
{
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (SUCCEEDED(hr)) {
        s->was_com_init = 1;
    } else if (hr == RPC_E_CHANGED_MODE) {
        /* Another apartment is already up on this thread; COM is usable. */
        s->was_com_init = 0;
    } else {
        return LP_ERR_IO;
    }

    hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
                          &IID_IMMDeviceEnumerator, (void **)&s->was_enum);
    if (FAILED(hr) || !s->was_enum) {
        LP_WARN("wasapi", "CoCreateInstance(MMDeviceEnumerator): 0x%08lx", (unsigned long)hr);
        goto fail;
    }
    hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(s->was_enum, eRender, eConsole, &s->was_device);
    if (FAILED(hr) || !s->was_device) {
        LP_WARN("wasapi", "no default render endpoint: 0x%08lx (no audio device?)", (unsigned long)hr);
        goto fail;
    }
    hr = IMMDevice_Activate(s->was_device, &IID_IAudioClient, CLSCTX_ALL, NULL,
                            (void **)&s->was_client);
    if (FAILED(hr) || !s->was_client) {
        LP_WARN("wasapi", "IAudioClient activate: 0x%08lx", (unsigned long)hr);
        goto fail;
    }

    /* Ask for exactly what the rest of the engine produces.  AUTOCONVERTPCM
     * makes the audio engine resample/interleave to whatever the endpoint is
     * running at, so we never have to match the mix format. */
    WAVEFORMATEXTENSIBLE wf;
    memset(&wf, 0, sizeof(wf));
    wf.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    wf.Format.nChannels = (WORD)channels;
    wf.Format.nSamplesPerSec = (DWORD)sample_rate;
    wf.Format.wBitsPerSample = 32;
    wf.Format.nBlockAlign = (WORD)(channels * 4);
    wf.Format.nAvgBytesPerSec = wf.Format.nSamplesPerSec * wf.Format.nBlockAlign;
    wf.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    wf.Samples.wValidBitsPerSample = 32;
    wf.dwChannelMask = channels == 1 ? SPEAKER_FRONT_CENTER : SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
    wf.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;

    REFERENCE_TIME dur = (REFERENCE_TIME)s->frames_per_buffer * LP_WASAPI_CHUNKS * 10000000LL /
                         (REFERENCE_TIME)sample_rate;
    hr = IAudioClient_Initialize(s->was_client, AUDCLNT_SHAREMODE_SHARED,
                                 AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                     AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                                 dur, 0, &wf.Format, NULL);
    if (FAILED(hr)) {
        LP_WARN("wasapi", "Initialize(shared, %d Hz x%d, %lld us): 0x%08lx", sample_rate, channels,
                (long long)(dur / 10), (unsigned long)hr);
        goto fail;
    }
    s->was_event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!s->was_event || FAILED(IAudioClient_SetEventHandle(s->was_client, s->was_event))) {
        LP_WARN("wasapi", "SetEventHandle failed");
        goto fail;
    }
    hr = IAudioClient_GetBufferSize(s->was_client, &s->was_buffer_frames);
    if (FAILED(hr) || s->was_buffer_frames < (UINT32)s->frames_per_buffer) {
        LP_WARN("wasapi", "GetBufferSize: 0x%08lx (%u frames)", (unsigned long)hr,
                (unsigned)s->was_buffer_frames);
        goto fail;
    }
    hr = IAudioClient_GetService(s->was_client, &IID_IAudioRenderClient, (void **)&s->was_render);
    if (FAILED(hr) || !s->was_render) {
        LP_WARN("wasapi", "GetService(IAudioRenderClient): 0x%08lx", (unsigned long)hr);
        goto fail;
    }

    /* Prime the first chunk so the engine does not start on a hole. */
    BYTE *dst = NULL;
    if (SUCCEEDED(IAudioRenderClient_GetBuffer(s->was_render, (UINT32)s->frames_per_buffer, &dst)) && dst) {
        lp_audio_pull_pcm(s->player, (float *)dst, s->frames_per_buffer);
        IAudioRenderClient_ReleaseBuffer(s->was_render, (UINT32)s->frames_per_buffer, 0);
    }

    atomic_store(&s->was_quit, 0);
    if (pthread_create(&s->was_thread, NULL, was_thread, s) != 0) {
        LP_WARN("wasapi", "render thread did not start");
        goto fail;
    }
    hr = IAudioClient_Start(s->was_client);
    if (FAILED(hr)) {
        LP_WARN("wasapi", "IAudioClient::Start: 0x%08lx", (unsigned long)hr);
        atomic_store(&s->was_quit, 1);
        pthread_join(s->was_thread, NULL);
        goto fail;
    }
    s->backend = 1;
    LP_INFO("wasapi", "started %d Hz x%d, buffer %u frames (%u ms), chunk %d frames (%d ms)",
            sample_rate, channels, (unsigned)s->was_buffer_frames,
            (unsigned)(s->was_buffer_frames * 1000u / (unsigned)sample_rate), s->frames_per_buffer,
            s->frames_per_buffer * 1000 / sample_rate);
    return LP_OK;

fail:
    was_release(s);
    return LP_ERR_IO;
}

static void was_stop(LpAudioSink *s)
{
    if (s->backend != 1) {
        return;
    }
    s->started = 0;
    atomic_store(&s->was_quit, 1);
    if (s->was_event) {
        SetEvent(s->was_event);
    }
    pthread_join(s->was_thread, NULL);
    if (s->was_client) {
        IAudioClient_Stop(s->was_client);
    }
    was_release(s);
    s->backend = 0;
}

/* -------------------------------------------------------------- waveout --- */

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

static int wo_start(LpAudioSink *s, int sample_rate, int channels)
{
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
    s->backend = 2;
    LP_INFO("waveout", "started %d Hz x%d", sample_rate, channels);
    return LP_OK;
}

static void wo_stop(LpAudioSink *s)
{
    if (s->backend != 2 || !s->handle) {
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
    s->backend = 0;
}

/* -------------------------------------------------------------- dispatch --- */

LpAudioSink *lp_audio_sink_create(LpPlayer *p)
{
    LpAudioSink *s = calloc(1, sizeof(*s));
    if (s) {
        s->player = p;
        atomic_store(&s->was_quit, 0);
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
    s->paused = 0;

    if (was_start(s, sample_rate, channels) == LP_OK) {
        s->started = 1;
        return LP_OK;
    }
    LP_WARN("audio", "WASAPI unavailable, falling back to waveOut");
    if (wo_start(s, sample_rate, channels) == LP_OK) {
        s->started = 1;
        return LP_OK;
    }
    return LP_ERR_IO;
}

void lp_audio_sink_stop(LpAudioSink *s)
{
    if (!s) {
        return;
    }
    was_stop(s);
    wo_stop(s);
}

void lp_audio_sink_pause(LpAudioSink *s, int paused)
{
    if (!s || !s->started) {
        return;
    }
    if (s->backend == 1 && s->was_client) {
        if (paused) {
            IAudioClient_Stop(s->was_client);
        } else {
            IAudioClient_Start(s->was_client);
        }
    } else if (s->handle) {
        if (paused) {
            waveOutPause(s->handle);
        } else {
            waveOutRestart(s->handle);
        }
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
    if (s->backend == 1 && s->was_buffer_frames) {
        return (int)((int64_t)s->was_buffer_frames * 1000000 / s->sample_rate);
    }
    return s->frames_per_buffer * 1000000 / s->sample_rate * (LP_WO_BUFFERS - 1);
}

const char *lp_audio_sink_name(LpAudioSink *s)
{
    if (s && s->backend == 1) {
        return "wasapi";
    }
    return "waveout";
}

#endif /* _WIN32 */
