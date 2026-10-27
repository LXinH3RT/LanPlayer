/*
 * GPU 直出的颜色校验：内核把画面发布成共享 D3D11 纹理，这里像 Flutter/ANGLE 那样
 * 用 OpenSharedResource 打开它，拷到 staging 纹理读回中心像素，再和同一时刻
 * lp_win32_copy_frame 给的 CPU 像素比较。
 *
 * 光「句柄非空、serial 会走」不足以说明直出是对的：VideoProcessor 把 NV12 转 BGRA
 * 时如果颜色矩阵/通道搞反，画面会整体变色而句柄照样有效。这里直接比像素。
 *
 *   lp_win32_gpu_color_test.exe <video>
 */
#define COBJMACROS
#include <d3d11.h>
#include <dxgi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

typedef void *(*fn_create)(void **out);
typedef void (*fn_destroy)(void *player);
typedef int (*fn_open)(void *player, const char *url, const char *options);
typedef int (*fn_play)(void *player);
typedef int (*fn_copy_frame)(uint8_t *dst, size_t cap, int *w, int *h, int *stride);
typedef void *(*fn_gpu_surface)(int64_t *serial, int *w, int *h, int *slot);
typedef void (*fn_gpu_release)(int slot);

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: lp_win32_gpu_color_test.exe <video>\n");
        return 2;
    }
    HMODULE lib = LoadLibraryA("lanplayer.dll");
    if (!lib) {
        fprintf(stderr, "LoadLibrary failed: %lu\n", GetLastError());
        return 3;
    }
    fn_create create = (fn_create)GetProcAddress(lib, "lp_player_create");
    fn_destroy destroy = (fn_destroy)GetProcAddress(lib, "lp_player_destroy");
    fn_open open_media = (fn_open)GetProcAddress(lib, "lp_player_open");
    fn_play play = (fn_play)GetProcAddress(lib, "lp_player_play");
    fn_copy_frame copy = (fn_copy_frame)GetProcAddress(lib, "lp_win32_copy_frame");
    fn_gpu_surface gpu_surface = (fn_gpu_surface)GetProcAddress(lib, "lp_win32_gpu_surface");
    fn_gpu_release gpu_release = (fn_gpu_release)GetProcAddress(lib, "lp_win32_gpu_release");
    if (!create || !destroy || !open_media || !play || !copy || !gpu_surface || !gpu_release) {
        fprintf(stderr, "missing export\n");
        return 4;
    }

    /* Our own device stands in for the engine's: opening the share handle from a
     * second device is exactly what ANGLE does. */
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    D3D_FEATURE_LEVEL level = 0;
    const D3D_FEATURE_LEVEL want[] = {D3D_FEATURE_LEVEL_11_0};
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL,
                                   D3D11_CREATE_DEVICE_BGRA_SUPPORT, want, 1, D3D11_SDK_VERSION,
                                   &dev, &level, &ctx);
    if (FAILED(hr)) {
        fprintf(stderr, "D3D11CreateDevice(consumer) failed 0x%08lx\n", (unsigned long)hr);
        return 5;
    }

    void *player = NULL;
    if (create(&player) != 0 || !player) {
        return 6;
    }
    if (open_media(player, argv[1], "{\"auto_play\":true,\"hw\":\"auto\"}") != 0) {
        fprintf(stderr, "open failed\n");
        destroy(player);
        return 6;
    }
    play(player);
    Sleep(700); /* let a few frames land */

    ID3D11Texture2D *shared = NULL;
    int slot = -1;
    int gw = 0, gh = 0;
    int64_t serial = 0;
    void *handle = gpu_surface(&serial, &gw, &gh, &slot);
    if (!handle) {
        printf("FAIL: no GPU surface\n");
        destroy(player);
        return 7;
    }
    hr = ID3D11Device_OpenSharedResource(dev, handle, &IID_ID3D11Texture2D, (void **)&shared);
    if (FAILED(hr)) {
        printf("FAIL: OpenSharedResource(0x%llx) 0x%08lx\n", (unsigned long long)(uintptr_t)handle,
               (unsigned long)hr);
        gpu_release(slot);
        destroy(player);
        return 7;
    }
    D3D11_TEXTURE2D_DESC sd;
    ID3D11Texture2D_GetDesc(shared, &sd);
    printf("shared texture %ux%u fmt=%u\n", sd.Width, sd.Height, (unsigned)sd.Format);

    D3D11_TEXTURE2D_DESC st = sd;
    st.Usage = D3D11_USAGE_STAGING;
    st.BindFlags = 0;
    st.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    st.MiscFlags = 0;
    ID3D11Texture2D *staging = NULL;
    hr = ID3D11Device_CreateTexture2D(dev, &st, NULL, &staging);
    if (FAILED(hr)) {
        printf("FAIL: CreateTexture2D(staging) 0x%08lx\n", (unsigned long)hr);
        return 7;
    }
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)shared);
    D3D11_MAPPED_SUBRESOURCE map;
    hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map);
    if (FAILED(hr)) {
        printf("FAIL: Map 0x%08lx\n", (unsigned long)hr);
        return 7;
    }
    const int mx = (int)(sd.Width / 2), my = (int)(sd.Height / 2);
    uint8_t *row = (uint8_t *)map.pData + (size_t)my * map.RowPitch + (size_t)mx * 4;
    uint8_t gpu_px[4] = {row[0], row[1], row[2], row[3]};
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
    gpu_release(slot);

    /* No CPU reference on purpose: when the GPU output takes the frame,
     * lp_render_draw never runs, so g_video.pixels is never even allocated.
     * That absence is the proof the picture skipped system memory; the colours
     * are checked against the fixture instead. */
    int cw = 0, ch = 0, stride = 0;
    int have_cpu = copy(NULL, 0, &cw, &ch, &stride);
    destroy(player);

    /* core order is BGRA in the shared texture (DXGI_FORMAT_B8G8R8A8_UNORM). */
    printf("gpu_bgra=#%02X%02X%02X%02X cpu_pixels_available=%d\n", gpu_px[2], gpu_px[1],
           gpu_px[0], gpu_px[3], have_cpu);

    /* Red fixture: blue and green stay near zero, red near full.  A swapped
     * channel order or a black upload fails both branches. */
    int b = gpu_px[0], g = gpu_px[1], r = gpu_px[2], a = gpu_px[3];
    int red_ok = r > 150 && g < 90 && b < 90;
    int opaque = a == 0xFF;
    printf("VERDICT gpu colour %s (red=%d green=%d blue=%d alpha=%d)\n",
           (red_ok && opaque) ? "OK" : "MISMATCH", r, g, b, a);
    return (red_ok && opaque) ? 0 : 8;
}
