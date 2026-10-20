/*
 * Pre-flight test for the Flutter desktop texture bridge.
 *
 * It loads lanplayer.dll at runtime (exactly like the Windows plugin does),
 * resolves the same symbols with GetProcAddress, installs a frame callback and
 * pulls BGRA frames through lp_win32_copy_frame.  If this passes, the plugin's
 * only remaining dependency is Flutter's own build.
 *
 * It also runs the plugin's BGRA->RGBA conversion over the copied frame and
 * checks the colour does not change identity: a red fixture must stay red in
 * RGBA space.  That is the regression guard for the blue-cast picture, which
 * was caused by the engine interpreting BGRA as RGBA.
 *
 *   lp_win32_texture_test.exe <video> [ffmpeg-root] [--expect-red]
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

/* Same header the plugin compiles against. */
#include "lanplayer_video/pixel_swizzle.h"

typedef void *(*fn_create)(void **out);
typedef void (*fn_destroy)(void *player);
typedef void (*fn_set_event_cb)(void *player, void *cb, void *user);
typedef int (*fn_open)(void *player, const char *url, const char *options);
typedef int (*fn_play)(void *player);
typedef int (*fn_get_pos)(void *player, int64_t *out);
typedef int (*fn_install_frame_cb)(void *player, void *cb, void *user);
typedef int (*fn_copy_frame)(uint8_t *dst, size_t cap, int *w, int *h, int *stride);
typedef int64_t (*fn_serial)(void);
typedef int (*fn_abi)(void);
typedef int (*fn_frame_size)(int *w, int *h, int *stride);

static volatile LONG g_frames = 0;

static void on_frame(void *user)
{
    (void)user;
    InterlockedIncrement(&g_frames);
}

static void *resolve(HMODULE lib, const char *name)
{
    void *p = (void *)GetProcAddress(lib, name);
    if (!p) {
        fprintf(stderr, "missing export: %s\n", name);
    }
    return p;
}

int main(int argc, char **argv)
{
    int expect_red = 0;
    const char *video = NULL;
    const char *ffmpeg_root = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--expect-red") == 0) {
            expect_red = 1;
        } else if (!video) {
            video = argv[i];
        } else if (!ffmpeg_root) {
            ffmpeg_root = argv[i];
        }
    }
    if (!video) {
        fprintf(stderr,
                "usage: lp_win32_texture_test.exe <video> [ffmpeg-root] [--expect-red]\n");
        return 2;
    }
    /* ffmpeg dlls live next to the exe; make sure they are found. */
    if (ffmpeg_root) {
        SetDllDirectoryA(ffmpeg_root);
    }

    HMODULE lib = LoadLibraryA("lanplayer.dll");
    if (!lib) {
        fprintf(stderr, "LoadLibrary(lanplayer.dll) failed: %lu\n", GetLastError());
        return 3;
    }
    fn_abi abi = (fn_abi)resolve(lib, "lp_abi_version");
    fn_create create = (fn_create)resolve(lib, "lp_player_create");
    fn_destroy destroy = (fn_destroy)resolve(lib, "lp_player_destroy");
    fn_set_event_cb set_cb = (fn_set_event_cb)resolve(lib, "lp_player_set_event_callback");
    fn_open open_media = (fn_open)resolve(lib, "lp_player_open");
    fn_play play = (fn_play)resolve(lib, "lp_player_play");
    fn_get_pos get_pos = (fn_get_pos)resolve(lib, "lp_player_get_position");
    fn_install_frame_cb install_cb =
        (fn_install_frame_cb)resolve(lib, "lp_player_install_frame_callback");
    fn_copy_frame copy = (fn_copy_frame)resolve(lib, "lp_win32_copy_frame");
    fn_serial serial = (fn_serial)resolve(lib, "lp_win32_frame_serial");
    fn_frame_size frame_size = (fn_frame_size)resolve(lib, "lp_win32_frame_size");
    if (!abi || !create || !destroy || !set_cb || !open_media || !play || !get_pos ||
        !install_cb || !copy || !serial || !frame_size) {
        return 4;
    }
    printf("abi=%d\n", abi());
    const char *props[] = {"lp_player_pause", "lp_player_close", "lp_player_select_track",
                           "lp_player_add_subtitle", "lp_player_set_volume",
                           "lp_player_set_subtitle_delay", "lp_player_get_media_info",
                           "lp_win32_frame_count"};
    int missing = 0;
    for (size_t i = 0; i < sizeof(props) / sizeof(props[0]); i++) {
        if (!GetProcAddress(lib, props[i])) {
            fprintf(stderr, "missing export: %s\n", props[i]);
            missing++;
        }
    }
    if (missing) {
        return 4;
    }

    void *player = NULL;
    if (create(&player) != 0 || !player) {
        fprintf(stderr, "create failed\n");
        return 5;
    }
    set_cb(player, NULL, NULL); /* no UI events needed here */
    install_cb(player, (void *)on_frame, NULL);

    if (open_media(player, video, "{\"auto_play\":true,\"hw\":\"sw\"}") != 0) {
        fprintf(stderr, "open failed\n");
        destroy(player);
        return 5;
    }
    play(player);

    int width = 0, height = 0, stride = 0;
    uint8_t *buffer = NULL;
    size_t cap = 0;
    int copied = 0;
    int64_t first_serial = 0, last_serial = 0;

    for (int i = 0; i < 400; i++) { /* up to 4 s */
        Sleep(10);
        if (width == 0) {
            if (!frame_size(&width, &height, &stride) || width <= 0) {
                continue;
            }
            cap = (size_t)stride * height + 64;
            buffer = malloc(cap);
            if (!buffer) {
                break;
            }
        }
        if (copy(buffer, cap, &width, &height, &stride)) {
            int64_t s = serial();
            if (!first_serial) {
                first_serial = s;
            }
            last_serial = s;
            copied++;
        }
        if (copied >= 30) {
            break;
        }
    }

    int64_t pos = 0;
    get_pos(player, &pos);
    printf("frames_cb=%ld copies=%d size=%dx%d stride=%d serial=%lld->%lld pos=%.2fs\n",
           (long)g_frames, copied, width, height, stride, (long long)first_serial,
           (long long)last_serial, pos / 1e6);

    int colour_ok = 1;
    if (buffer) {
        /* The middle pixel in core order is BGRA; report it the way the BMP
         * writer does so the value is comparable with the preview dumps. */
        uint8_t *mid = buffer + (size_t)(height / 2) * stride + (size_t)(width / 2) * 4;
        printf("mid_pixel=#%02X%02X%02X%02X\n", mid[3], mid[2], mid[1], mid[0]);

        /* Now run the plugin's conversion, exactly as Copy() does, and read the
         * same pixel back as RGBA (R, G, B). */
        lp_bgra_to_rgba(buffer, width, height, stride);
        uint8_t r = mid[0], g = mid[1], b = mid[2], a = mid[3];
        printf("mid_rgba=#%02X%02X%02X%02X\n", r, g, b, a);
        if (a != 0xFF) {
            printf("FAIL: alpha is %u, expected 255 (video must be opaque)\n", a);
            colour_ok = 0;
        }
        if (expect_red && !(r > 200 && g < 60 && b < 60)) {
            printf("FAIL: expected red after swizzle, got R=%u G=%u B=%u\n", r, g, b);
            colour_ok = 0;
        }
        if (!expect_red) {
            /* No fixture-specific expectation: at least prove the swap is not
             * the identity by re-running it and comparing. */
            uint8_t r2 = r, b2 = b;
            lp_bgra_to_rgba(buffer, width, height, stride);
            if (r2 != mid[2] || b2 != mid[0]) {
                printf("FAIL: conversion is not an involution (R<->B broken)\n");
                colour_ok = 0;
            }
        }
    }
    free(buffer);
    destroy(player);
    FreeLibrary(lib);

    int ok = copied >= 1 && width > 0 && height > 0 && (int64_t)g_frames >= 1 &&
             colour_ok;
    printf(ok ? "texture path OK\n" : "texture path FAILED\n");
    return ok ? 0 : 6;
}
