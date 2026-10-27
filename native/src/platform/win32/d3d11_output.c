/*
 * Windows GPU output: the picture is handed to the Flutter texture bridge as a
 * D3D11 shared texture instead of a CPU pixel buffer.
 *
 * Two things happen here.
 *
 * 1. Hardware frames already live in a D3D11 texture owned by the decoder.  The
 *    old path downloaded them to NV12 in system memory (av_hwframe_transfer_data)
 *    and then converted to BGRA on the CPU with sws_scale.  We replace that with
 *    a VideoProcessorBlt on the same device: NV12 slice -> shared BGRA texture.
 *    The frame never leaves the GPU.
 *
 * 2. Software frames are ordinary system-memory pictures.  They still need one
 *    upload, but after that they are a shared texture too, so the host has a
 *    single texture kind for both decode modes.  The upload is one
 *    UpdateSubresource, the same order of cost as the memcpy it replaces, and it
 *    keeps graphics subtitles (PGS / VobSub) working because they are blended on
 *    the CPU buffer before the upload, exactly as before.
 *
 * The shared handle is what Flutter's
 * FlutterDesktopGpuSurfaceTypeDxgiSharedHandle expects: ANGLE wraps it into a GL
 * texture with EGL_ANGLE_surface_d3d_texture_2d_share_handle, so no pixels are
 * copied and no channel swizzle is needed (the descriptor carries the format).
 *
 * The engine tells us when it is done with a surface through the descriptor's
 * release callback.  We rotate through LP_GPU_SLOTS textures so the decoder can
 * keep writing while the raster thread is still sampling the previous frame.
 */
#if defined(_WIN32)

#define COBJMACROS
#define INITGUID

#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "player_internal.h"
#include "platform/win32/win32_preview.h"

/* AVD3D11VADeviceContext lives in libavutil/hwcontext_d3d11va.h, which pulls in
 * the D3D11 declarations on its own.  Included after <d3d11.h> so the two agree. */
#include <libavutil/hwcontext_d3d11va.h>

/* Enough headroom for "raster thread still holds one, decoder writes the next";
 * more would only delay the moment a slot frees up. */
#define LP_GPU_SLOTS 3

typedef struct LpGpuSlot {
    ID3D11Texture2D *tex;                 /* shared BGRA */
    ID3D11VideoProcessorOutputView *view; /* VideoProcessor output */
    HANDLE handle;                        /* legacy DXGI share handle */
    int busy;                             /* 1 while the engine samples it */
    int64_t serial;                       /* frame serial last written */
} LpGpuSlot;

typedef struct LpGpuOut {
    CRITICAL_SECTION lock;
    int inited;
    int failed; /* device creation failed: stay on the CPU pixel path */

    ID3D11Device *device;
    ID3D11DeviceContext *ctx;
    ID3D11VideoDevice *vdev;
    ID3D11VideoContext *vctx;
    ID3D11VideoProcessorEnumerator *vpe;
    ID3D11VideoProcessor *vp;

    LpGpuSlot slots[LP_GPU_SLOTS];
    int nslots;
    int width;
    int height;
    int current; /* slot the host should sample, -1 when nothing yet */
    int64_t serial;

    /* Cached input view.  The decoder reuses one array texture for the whole
     * stream, so this almost always hits. */
    ID3D11Texture2D *in_tex;
    UINT in_slice;
    DXGI_FORMAT in_fmt;
    ID3D11VideoProcessorInputView *in_view;

    /* Staging texture for hosts that read the picture back (preview player,
     * or a bridge without GPU surface support).  Allocated on first use. */
    ID3D11Texture2D *readback;
    int readback_w;
    int readback_h;

    /* Colour space of the current stream.  0 = unknown, 1 = BT.601, 2 = BT.709.
     * The video processor defaults to BT.601, which turns BT.709 reds orange;
     * those are the only two matrices SD/HD uses in practice, and everything
     * else falls back to the sequence's own resolution rule. */
    int matrix;
    int full_range;
} LpGpuOut;

static LpGpuOut g_gpu;

static void gpu_lock_init(void)
{
    if (!g_gpu.inited) {
        InitializeCriticalSection(&g_gpu.lock);
        g_gpu.inited = 1;
        g_gpu.current = -1;
    }
}

static void slot_release(LpGpuSlot *s)
{
    if (s->view) {
        ID3D11VideoProcessorOutputView_Release(s->view);
        s->view = NULL;
    }
    if (s->tex) {
        ID3D11Texture2D_Release(s->tex);
        s->tex = NULL;
    }
    s->handle = NULL;
    s->busy = 0;
}

static void engine_release(void)
{
    for (int i = 0; i < LP_GPU_SLOTS; i++) {
        slot_release(&g_gpu.slots[i]);
    }
    if (g_gpu.in_view) {
        ID3D11VideoProcessorInputView_Release(g_gpu.in_view);
        g_gpu.in_view = NULL;
    }
    g_gpu.in_tex = NULL;
    if (g_gpu.readback) {
        ID3D11Texture2D_Release(g_gpu.readback);
        g_gpu.readback = NULL;
        g_gpu.readback_w = 0;
        g_gpu.readback_h = 0;
    }
    if (g_gpu.vp) {
        ID3D11VideoProcessor_Release(g_gpu.vp);
        g_gpu.vp = NULL;
    }
    if (g_gpu.vpe) {
        ID3D11VideoProcessorEnumerator_Release(g_gpu.vpe);
        g_gpu.vpe = NULL;
    }
    if (g_gpu.vctx) {
        ID3D11VideoContext_Release(g_gpu.vctx);
        g_gpu.vctx = NULL;
    }
    if (g_gpu.vdev) {
        ID3D11VideoDevice_Release(g_gpu.vdev);
        g_gpu.vdev = NULL;
    }
    if (g_gpu.ctx) {
        ID3D11DeviceContext_Release(g_gpu.ctx);
        g_gpu.ctx = NULL;
    }
    if (g_gpu.device) {
        ID3D11Device_Release(g_gpu.device);
        g_gpu.device = NULL;
    }
    g_gpu.nslots = 0;
    g_gpu.width = 0;
    g_gpu.height = 0;
    g_gpu.current = -1;
}

/* One device for the whole player.  BGRA_SUPPORT is here because the shared
 * output texture is BGRA; VIDEO_SUPPORT because the same device is handed to the
 * decoder (see lp_gpu_d3d11va_device), so the VideoProcessor can take its
 * textures without a cross-device copy. */
static int engine_create(void)
{
    D3D_FEATURE_LEVEL level = 0;
    const D3D_FEATURE_LEVEL want[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL,
                                   D3D11_CREATE_DEVICE_BGRA_SUPPORT |
                                       D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                                   want, 2, D3D11_SDK_VERSION, &g_gpu.device, &level,
                                   &g_gpu.ctx);
    if (FAILED(hr)) {
        /* Older runtimes reject the 11_1 request; retry with 11_0 only. */
        hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL,
                               D3D11_CREATE_DEVICE_BGRA_SUPPORT |
                                   D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                               &want[1], 1, D3D11_SDK_VERSION, &g_gpu.device, &level,
                               &g_gpu.ctx);
    }
    if (FAILED(hr) || !g_gpu.device || !g_gpu.ctx) {
        LP_WARN("gpu", "D3D11CreateDevice failed (0x%08lx); using the CPU pixel path",
                (unsigned long)hr);
        return LP_ERR_UNSUPPORTED;
    }
    hr = ID3D11Device_QueryInterface(g_gpu.device, &IID_ID3D11VideoDevice,
                                     (void **)&g_gpu.vdev);
    if (FAILED(hr)) {
        LP_WARN("gpu", "no ID3D11VideoDevice (0x%08lx); using the CPU pixel path",
                (unsigned long)hr);
        engine_release();
        return LP_ERR_UNSUPPORTED;
    }
    hr = ID3D11DeviceContext_QueryInterface(g_gpu.ctx, &IID_ID3D11VideoContext,
                                            (void **)&g_gpu.vctx);
    if (FAILED(hr)) {
        LP_WARN("gpu", "no ID3D11VideoContext (0x%08lx); using the CPU pixel path",
                (unsigned long)hr);
        engine_release();
        return LP_ERR_UNSUPPORTED;
    }
    LP_INFO("gpu", "D3D11 device ready (feature level 0x%x), shared-texture output enabled",
            (unsigned)level);
    return LP_OK;
}

int lp_gpu_output_init(void)
{
    gpu_lock_init();
    EnterCriticalSection(&g_gpu.lock);
    int rc = LP_OK;
    if (g_gpu.failed) {
        rc = LP_ERR_UNSUPPORTED;
    } else if (!g_gpu.device) {
        rc = engine_create();
        if (rc != LP_OK) {
            g_gpu.failed = 1;
        }
    }
    LeaveCriticalSection(&g_gpu.lock);
    return rc;
}

int lp_gpu_output_ready(void)
{
    gpu_lock_init();
    return g_gpu.device != NULL;
}

/* Called per frame from the video thread.  Cheap and idempotent: the values
 * only change when the stream switches, and the actual matrix is applied when
 * the processor is created (engine_prepare) or right before the blit. */
int lp_gpu_output_set_color(int matrix, int full_range)
{
    gpu_lock_init();
    EnterCriticalSection(&g_gpu.lock);
    g_gpu.matrix = matrix;
    g_gpu.full_range = full_range ? 1 : 0;
    LeaveCriticalSection(&g_gpu.lock);
    return LP_OK;
}

/* Applies the recorded colour space to the processor.  Must be called with the
 * GPU lock held, after the processor exists. */
static void apply_color_space(void)
{
    if (!g_gpu.vctx || !g_gpu.vp) {
        return;
    }
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE in;
    memset(&in, 0, sizeof(in));
    in.Usage = 0; /* playback, not video processing for editing */
    /* YCbCr_Matrix: 0 = BT.601, 1 = BT.709.  Unknown streams use the same rule
     * ffmpeg does: HD and up is BT.709, SD is BT.601. */
    int bt709 = g_gpu.matrix == 2 || (g_gpu.matrix == 0 && g_gpu.height >= 720);
    in.YCbCr_Matrix = bt709 ? 1 : 0;
    in.Nominal_Range = g_gpu.full_range ? D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_0_255
                                        : D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
    ID3D11VideoContext_VideoProcessorSetStreamColorSpace(g_gpu.vctx, g_gpu.vp, 0, &in);

    /* The output is an untagged RGB surface that the engine samples as sRGB, so
     * it must be full range; telling the processor otherwise would double the
     * range conversion. */
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE out;
    memset(&out, 0, sizeof(out));
    out.Usage = 0;
    out.RGB_Range = 0; /* 0 = full (0-255) */
    out.YCbCr_Matrix = 1;
    out.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_0_255;
    ID3D11VideoContext_VideoProcessorSetOutputColorSpace(g_gpu.vctx, g_gpu.vp, &out);
}

/* Build an hwdevice context backed by our own device, so the decoder and the
 * output share one D3D11 device and a VideoProcessor input view can reference
 * the decoded textures directly. */
int lp_gpu_d3d11va_device(AVBufferRef **out)
{
    if (!out) {
        return LP_ERR_ARGUMENT;
    }
    if (lp_gpu_output_init() != LP_OK) {
        return LP_ERR_UNSUPPORTED;
    }
    AVBufferRef *ref = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA);
    if (!ref) {
        return LP_ERR_NOMEM;
    }
    AVHWDeviceContext *dev = (AVHWDeviceContext *)ref->data;
    AVD3D11VADeviceContext *hw = (AVD3D11VADeviceContext *)dev->hwctx;
    ID3D11Device_AddRef(g_gpu.device);
    hw->device = g_gpu.device;
    int r = av_hwdevice_ctx_init(ref);
    if (r < 0) {
        LP_WARN("gpu", "av_hwdevice_ctx_init on the shared device failed (%d); "
                       "falling back to a private decoder device", r);
        /* av_hwdevice_ctx_free releases the interface we added above. */
        av_buffer_unref(&ref);
        return LP_ERR_UNSUPPORTED;
    }
    *out = ref;
    return LP_OK;
}

/* Make sure we have an enumerator/processor and a set of shared BGRA textures
 * for this picture size. */
static int engine_prepare(int w, int h)
{
    if (g_gpu.width == w && g_gpu.height == h && g_gpu.nslots > 0) {
        return LP_OK;
    }
    for (int i = 0; i < LP_GPU_SLOTS; i++) {
        slot_release(&g_gpu.slots[i]);
    }
    if (g_gpu.vp) {
        ID3D11VideoProcessor_Release(g_gpu.vp);
        g_gpu.vp = NULL;
    }
    if (g_gpu.vpe) {
        ID3D11VideoProcessorEnumerator_Release(g_gpu.vpe);
        g_gpu.vpe = NULL;
    }
    g_gpu.width = 0;
    g_gpu.height = 0;
    g_gpu.nslots = 0;
    g_gpu.current = -1;

    D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd;
    memset(&cd, 0, sizeof(cd));
    cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    cd.InputWidth = (UINT)w;
    cd.InputHeight = (UINT)h;
    cd.OutputWidth = (UINT)w;
    cd.OutputHeight = (UINT)h;
    cd.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
    HRESULT hr = ID3D11VideoDevice_CreateVideoProcessorEnumerator(g_gpu.vdev, &cd,
                                                                 &g_gpu.vpe);
    if (FAILED(hr)) {
        LP_WARN("gpu", "CreateVideoProcessorEnumerator(%dx%d) failed 0x%08lx", w, h,
                (unsigned long)hr);
        return LP_ERR_UNSUPPORTED;
    }
    hr = ID3D11VideoDevice_CreateVideoProcessor(g_gpu.vdev, g_gpu.vpe, 0, &g_gpu.vp);
    if (FAILED(hr)) {
        LP_WARN("gpu", "CreateVideoProcessor failed 0x%08lx", (unsigned long)hr);
        return LP_ERR_UNSUPPORTED;
    }

    D3D11_TEXTURE2D_DESC td;
    memset(&td, 0, sizeof(td));
    td.Width = (UINT)w;
    td.Height = (UINT)h;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    /* A legacy share handle is what EGL_ANGLE_surface_d3d_texture_2d_share_handle
     * consumes; a keyed-mutex texture would need ANGLE to take the key too. */
    td.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

    for (int i = 0; i < LP_GPU_SLOTS; i++) {
        LpGpuSlot *s = &g_gpu.slots[i];
        hr = ID3D11Device_CreateTexture2D(g_gpu.device, &td, NULL, &s->tex);
        if (FAILED(hr)) {
            LP_WARN("gpu", "CreateTexture2D(shared %dx%d) failed 0x%08lx", w, h,
                    (unsigned long)hr);
            goto fail;
        }
        IDXGIResource *res = NULL;
        hr = ID3D11Texture2D_QueryInterface(s->tex, &IID_IDXGIResource, (void **)&res);
        if (FAILED(hr) || !res) {
            LP_WARN("gpu", "IDXGIResource failed 0x%08lx", (unsigned long)hr);
            goto fail;
        }
        hr = IDXGIResource_GetSharedHandle(res, &s->handle);
        IDXGIResource_Release(res);
        if (FAILED(hr) || !s->handle) {
            LP_WARN("gpu", "GetSharedHandle failed 0x%08lx", (unsigned long)hr);
            goto fail;
        }
        D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd;
        memset(&ovd, 0, sizeof(ovd));
        ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
        hr = ID3D11VideoDevice_CreateVideoProcessorOutputView(
            g_gpu.vdev, (ID3D11Resource *)s->tex, g_gpu.vpe, &ovd, &s->view);
        if (FAILED(hr)) {
            LP_WARN("gpu", "CreateVideoProcessorOutputView failed 0x%08lx",
                    (unsigned long)hr);
            goto fail;
        }
        s->busy = 0;
    }
    g_gpu.width = w;
    g_gpu.height = h;
    g_gpu.nslots = LP_GPU_SLOTS;
    apply_color_space();
    LP_INFO("gpu", "shared surfaces ready %dx%d (%d slots, %s range %s)", w, h, LP_GPU_SLOTS,
            g_gpu.matrix == 2 || (g_gpu.matrix == 0 && h >= 720) ? "BT.709" : "BT.601",
            g_gpu.full_range ? "full" : "limited");
    return LP_OK;

fail:
    for (int i = 0; i < LP_GPU_SLOTS; i++) {
        slot_release(&g_gpu.slots[i]);
    }
    g_gpu.nslots = 0;
    if (g_gpu.vp) {
        ID3D11VideoProcessor_Release(g_gpu.vp);
        g_gpu.vp = NULL;
    }
    if (g_gpu.vpe) {
        ID3D11VideoProcessorEnumerator_Release(g_gpu.vpe);
        g_gpu.vpe = NULL;
    }
    return LP_ERR_UNSUPPORTED;
}

/* Pick a slot the host is not sampling.  When every slot is still held (the
 * raster thread fell behind), take the one published longest ago: showing a
 * newer picture beats freezing, and it matches what the pixel-buffer path does
 * after a run of drops. */
static LpGpuSlot *slot_acquire(int *reused)
{
    for (int i = 0; i < g_gpu.nslots; i++) {
        if (!g_gpu.slots[i].busy) {
            *reused = 0;
            return &g_gpu.slots[i];
        }
    }
    int best = 0;
    for (int i = 1; i < g_gpu.nslots; i++) {
        if (g_gpu.slots[i].serial < g_gpu.slots[best].serial) {
            best = i;
        }
    }
    *reused = 1;
    return &g_gpu.slots[best];
}

static int publish(LpGpuSlot *slot, int slot_index, int w, int h)
{
    slot->serial = ++g_gpu.serial;
    g_gpu.current = slot_index;
    slot->busy = 1;
    (void)w;
    (void)h;
    return LP_OK;
}

int lp_gpu_output_upload(LpPlayer *p, const uint8_t *bgra, int w, int h, int stride)
{
    if (!bgra || w <= 0 || h <= 0 || stride < w * 4) {
        return LP_ERR_ARGUMENT;
    }
    if (lp_gpu_output_init() != LP_OK) {
        return LP_ERR_UNSUPPORTED;
    }
    EnterCriticalSection(&g_gpu.lock);
    int rc = engine_prepare(w, h);
    if (rc != LP_OK) {
        LeaveCriticalSection(&g_gpu.lock);
        return rc;
    }
    int reused = 0;
    LpGpuSlot *slot = slot_acquire(&reused);
    int slot_index = (int)(slot - &g_gpu.slots[0]);
    ID3D11DeviceContext_UpdateSubresource(g_gpu.ctx, (ID3D11Resource *)slot->tex, 0, NULL,
                                          bgra, (UINT)stride, 0);
    rc = publish(slot, slot_index, w, h);
    LeaveCriticalSection(&g_gpu.lock);
    if (reused) {
        LP_DEBUG("gpu", "upload reused a busy slot (host is behind)");
    }
    (void)p;
    return rc;
}

int lp_gpu_output_blit(LpPlayer *p, void *d3d_texture, unsigned slice, int w, int h)
{
    if (!d3d_texture || w <= 0 || h <= 0) {
        return LP_ERR_ARGUMENT;
    }
    if (lp_gpu_output_init() != LP_OK) {
        return LP_ERR_UNSUPPORTED;
    }
    ID3D11Texture2D *tex = (ID3D11Texture2D *)d3d_texture;

    EnterCriticalSection(&g_gpu.lock);
    int rc = engine_prepare(w, h);
    if (rc != LP_OK) {
        LeaveCriticalSection(&g_gpu.lock);
        return rc;
    }

    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc(tex, &td);
    /* The VideoProcessor converts NV12 only; P010 (10-bit) and anything else is
     * left to the download path, which knows how to unpack it. */
    if (td.Format != DXGI_FORMAT_NV12) {
        LeaveCriticalSection(&g_gpu.lock);
        return LP_ERR_UNSUPPORTED;
    }

    if (g_gpu.in_view && g_gpu.in_tex == tex && g_gpu.in_slice == slice &&
        g_gpu.in_fmt == td.Format) {
        /* cached */
    } else {
        if (g_gpu.in_view) {
            ID3D11VideoProcessorInputView_Release(g_gpu.in_view);
            g_gpu.in_view = NULL;
        }
        D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd;
        memset(&ivd, 0, sizeof(ivd));
        ivd.FourCC = 0;
        ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
        ivd.Texture2D.MipSlice = 0;
        ivd.Texture2D.ArraySlice = slice;
        HRESULT hr = ID3D11VideoDevice_CreateVideoProcessorInputView(
            g_gpu.vdev, (ID3D11Resource *)tex, g_gpu.vpe, &ivd, &g_gpu.in_view);
        if (FAILED(hr)) {
            LP_WARN("gpu", "CreateVideoProcessorInputView failed 0x%08lx",
                    (unsigned long)hr);
            g_gpu.in_tex = NULL;
            LeaveCriticalSection(&g_gpu.lock);
            return LP_ERR_UNSUPPORTED;
        }
        g_gpu.in_tex = tex;
        g_gpu.in_slice = slice;
        g_gpu.in_fmt = td.Format;
    }

    int reused = 0;
    LpGpuSlot *slot = slot_acquire(&reused);
    int slot_index = (int)(slot - &g_gpu.slots[0]);

    D3D11_VIDEO_PROCESSOR_STREAM stream;
    memset(&stream, 0, sizeof(stream));
    stream.Enable = TRUE;
    stream.pInputSurface = g_gpu.in_view;
    apply_color_space();
    HRESULT hr = ID3D11VideoContext_VideoProcessorBlt(g_gpu.vctx, g_gpu.vp, slot->view, 0, 1,
                                                      &stream);
    if (FAILED(hr)) {
        LP_WARN("gpu", "VideoProcessorBlt failed 0x%08lx", (unsigned long)hr);
        LeaveCriticalSection(&g_gpu.lock);
        return LP_ERR_CODEC;
    }
    rc = publish(slot, slot_index, w, h);
    LeaveCriticalSection(&g_gpu.lock);
    if (reused) {
        LP_DEBUG("gpu", "blit reused a busy slot (host is behind)");
    }
    (void)p;
    return rc;
}

/* Called by the host from the raster thread. */
void *lp_win32_gpu_surface(int64_t *serial, int *width, int *height, int *slot)
{
    gpu_lock_init();
    EnterCriticalSection(&g_gpu.lock);
    void *handle = NULL;
    if (g_gpu.current >= 0 && g_gpu.current < g_gpu.nslots) {
        LpGpuSlot *s = &g_gpu.slots[g_gpu.current];
        s->busy = 1;
        handle = (void *)s->handle;
        if (serial) {
            *serial = s->serial;
        }
        if (width) {
            *width = g_gpu.width;
        }
        if (height) {
            *height = g_gpu.height;
        }
        if (slot) {
            *slot = g_gpu.current;
        }
    }
    LeaveCriticalSection(&g_gpu.lock);
    return handle;
}

int lp_win32_gpu_ready(void)
{
    return lp_gpu_output_ready();
}

/* Reads the current shared surface back into a CPU buffer.  Hosts that show the
 * picture themselves (the preview player, or a texture bridge on a machine
 * without GPU surface support) have no other way to reach it, so provide the
 * download on demand instead of keeping a CPU copy alive for every frame. */
int lp_gpu_output_readback(unsigned char *dst, size_t cap, int *width, int *height, int *stride)
{
    (void)dst;
    (void)cap;
    (void)width;
    (void)height;
    (void)stride;
    if (lp_gpu_output_init() != LP_OK) {
        return LP_ERR_UNSUPPORTED;
    }
    EnterCriticalSection(&g_gpu.lock);
    if (g_gpu.current < 0 || g_gpu.current >= g_gpu.nslots) {
        LeaveCriticalSection(&g_gpu.lock);
        return LP_ERR_UNSUPPORTED;
    }
    if (!g_gpu.readback || g_gpu.readback_w != g_gpu.width || g_gpu.readback_h != g_gpu.height) {
        if (g_gpu.readback) {
            ID3D11Texture2D_Release(g_gpu.readback);
            g_gpu.readback = NULL;
        }
        D3D11_TEXTURE2D_DESC rd;
        memset(&rd, 0, sizeof(rd));
        rd.Width = (UINT)g_gpu.width;
        rd.Height = (UINT)g_gpu.height;
        rd.MipLevels = 1;
        rd.ArraySize = 1;
        rd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        rd.SampleDesc.Count = 1;
        rd.Usage = D3D11_USAGE_STAGING;
        rd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        HRESULT hr = ID3D11Device_CreateTexture2D(g_gpu.device, &rd, NULL, &g_gpu.readback);
        if (FAILED(hr)) {
            g_gpu.readback = NULL;
            LeaveCriticalSection(&g_gpu.lock);
            return LP_ERR_IO;
        }
        g_gpu.readback_w = g_gpu.width;
        g_gpu.readback_h = g_gpu.height;
    }
    LpGpuSlot *s = &g_gpu.slots[g_gpu.current];
    ID3D11DeviceContext_CopyResource(g_gpu.ctx, (ID3D11Resource *)g_gpu.readback,
                                     (ID3D11Resource *)s->tex);
    D3D11_MAPPED_SUBRESOURCE map;
    HRESULT hr = ID3D11DeviceContext_Map(g_gpu.ctx, (ID3D11Resource *)g_gpu.readback, 0,
                                         D3D11_MAP_READ, 0, &map);
    if (FAILED(hr)) {
        LeaveCriticalSection(&g_gpu.lock);
        return LP_ERR_IO;
    }
    size_t need = (size_t)map.RowPitch * (size_t)g_gpu.height;
    int rc = LP_OK;
    if (!dst || cap < need) {
        rc = LP_ERR_ARGUMENT;
    } else {
        memcpy(dst, map.pData, need);
    }
    ID3D11DeviceContext_Unmap(g_gpu.ctx, (ID3D11Resource *)g_gpu.readback, 0);
    if (width) {
        *width = g_gpu.width;
    }
    if (height) {
        *height = g_gpu.height;
    }
    if (stride) {
        *stride = (int)map.RowPitch;
    }
    LeaveCriticalSection(&g_gpu.lock);
    return rc;
}

/* Public entry point, declared in win32_preview.h.  The internal function above
 * keeps its historical name because copy_frame() calls it directly; this thin
 * wrapper exists so script/check_symbols.py sees the exported declaration
 * satisfied and so the calling convention matches the header exactly. */
int lp_win32_gpu_readback(unsigned char *dst, size_t cap, int *width, int *height, int *stride)
{
    if (!dst) {
        /* Size query: report the current surface geometry so the caller can
         * allocate.  Returning LP_ERR_ARGUMENT here would make the size probe
         * indistinguishable from a real failure. */
        gpu_lock_init();
        EnterCriticalSection(&g_gpu.lock);
        int ready = g_gpu.inited && g_gpu.current >= 0 && g_gpu.current < g_gpu.nslots;
        int w = g_gpu.width;
        int h = g_gpu.height;
        LeaveCriticalSection(&g_gpu.lock);
        if (!ready) {
            return LP_ERR_UNSUPPORTED;
        }
        if (width) {
            *width = w;
        }
        if (height) {
            *height = h;
        }
        if (stride) {
            *stride = w * 4;
        }
        return LP_OK;
    }
    return lp_gpu_output_readback(dst, cap, width, height, stride);
}

/* Called by the host through the descriptor's release callback once the engine
 * has finished sampling that surface. */
void lp_win32_gpu_release(int slot)
{
    gpu_lock_init();
    if (slot < 0 || slot >= LP_GPU_SLOTS) {
        return;
    }
    EnterCriticalSection(&g_gpu.lock);
    if (slot < g_gpu.nslots) {
        g_gpu.slots[slot].busy = 0;
    }
    LeaveCriticalSection(&g_gpu.lock);
}

void lp_gpu_output_close(void)
{
    if (!g_gpu.inited) {
        return;
    }
    EnterCriticalSection(&g_gpu.lock);
    engine_release();
    LeaveCriticalSection(&g_gpu.lock);
}

#endif /* _WIN32 */
