/*
 * Windows hardware-decode end-to-end test.
 *
 * Loads lanplayer.dll (the shipped Windows build) and answers two questions a
 * picture alone cannot:
 *
 *  1. Did the core really pick D3D11VA?  When the hardware path is unavailable
 *     the core falls back to software and only logs a warning, so a broken
 *     decoder still produces a perfect picture.
 *  2. Are the hardware pixels right?  The same clip is decoded twice, once with
 *     hw=sw and once with hw=auto, and the frame the texture bridge delivers is
 *     compared pixel by pixel against the software reference.
 *
 * The two runs cannot be frame-synchronised from outside: hardware decode runs
 * ahead in its own queue, so the frame that reaches the texture buffer first may
 * be a frame or two off the software run's first frame.  Comparing a single pair
 * of frames therefore compares two different moments of a moving clip and
 * reports a fake mismatch.  Instead the software run keeps a short run of
 * consecutive frames and the hardware frame is matched against the best of them;
 * the offset is printed so a shift is visible rather than hidden.
 *
 * Two independent guards, because they fail differently:
 *
 *  - Per-channel means.  A BGRA/RGBA swap or a wrong plane moves a channel mean
 *    by tens of levels; a one-frame phase offset barely touches them.
 *  - Best-frame pixel diff.  A swapped channel or corrupted decode stays wrong
 *    at every offset, while a phase offset disappears at the right one.
 *
 * The pixel comparison stays tolerant on purpose: a hardware decoder hands back
 * NV12 while the software path keeps yuv420p, and swscale samples chroma a
 * little differently for the two layouts, so a small fraction of pixels along
 * colour edges differ by design.
 *
 *   lp_hw_decode_test.exe <video> [--hw NAME] [--allow-software] [--expect-red]
 *
 * `--hw sw` is expected to FAIL without --allow-software, which proves the
 * d3d11va assertion is load-bearing rather than decorative.
 *
 * exit 0 ok, 2 usage, 3 load, 4 symbol, 5 setup, 6 assertion
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

typedef int (*fn_abi)(void);
typedef int (*fn_create)(void **out);
typedef void (*fn_destroy)(void *player);
typedef void (*fn_set_event_cb)(void *player, void *cb, void *user);
typedef int (*fn_open)(void *player, const char *url, const char *options);
typedef int (*fn_play)(void *player);
typedef int (*fn_get_option)(void *player, const char *key, char *buf, int32_t buflen);
typedef int (*fn_get_pos)(void *player, int64_t *out);
typedef int (*fn_copy_frame)(uint8_t *dst, size_t cap, int *w, int *h, int *stride);
typedef int (*fn_frame_size)(int *w, int *h, int *stride);
typedef int (*fn_frame_count)(void);

#define MAX_FRAMES 8

typedef struct Frame {
    uint8_t *pixels;
    int width;
    int height;
    int stride;
    int64_t pos_us;
} Frame;

typedef struct Core {
    HMODULE lib;
    fn_create create;
    fn_destroy destroy;
    fn_set_event_cb set_cb;
    fn_open open_media;
    fn_play play;
    fn_get_option get_option;
    fn_get_pos get_pos;
    fn_copy_frame copy;
    fn_frame_size frame_size;
    fn_frame_count frame_count;
} Core;

static void *resolve(HMODULE lib, const char *name)
{
    void *p = (void *)GetProcAddress(lib, name);
    if (!p) {
        fprintf(stderr, "missing export: %s\n", name);
    }
    return p;
}

static int core_load(Core *c)
{
    memset(c, 0, sizeof(*c));
    c->lib = LoadLibraryA("lanplayer.dll");
    if (!c->lib) {
        fprintf(stderr, "LoadLibrary(lanplayer.dll) failed: %lu\n", GetLastError());
        return 0;
    }
    c->create = (fn_create)resolve(c->lib, "lp_player_create");
    c->destroy = (fn_destroy)resolve(c->lib, "lp_player_destroy");
    c->set_cb = (fn_set_event_cb)resolve(c->lib, "lp_player_set_event_callback");
    c->open_media = (fn_open)resolve(c->lib, "lp_player_open");
    c->play = (fn_play)resolve(c->lib, "lp_player_play");
    c->get_option = (fn_get_option)resolve(c->lib, "lp_player_get_option");
    c->get_pos = (fn_get_pos)resolve(c->lib, "lp_player_get_position");
    c->copy = (fn_copy_frame)resolve(c->lib, "lp_win32_copy_frame");
    c->frame_size = (fn_frame_size)resolve(c->lib, "lp_win32_frame_size");
    c->frame_count = (fn_frame_count)resolve(c->lib, "lp_win32_frame_count");
    return c->create && c->destroy && c->set_cb && c->open_media && c->play &&
           c->get_option && c->get_pos && c->copy && c->frame_size && c->frame_count;
}

static void frames_free(Frame *f, int n)
{
    for (int i = 0; i < n; i++) {
        free(f[i].pixels);
        f[i].pixels = NULL;
    }
}

/* Opens the clip, waits for the decoder to be decided, then collects up to
 * `want` consecutive frames from the texture buffer.  Returns how many frames
 * were collected (0 on failure), and reports the decoder name and the playback
 * position once the first frames have been taken. */
static int grab(Core *c, const char *video, const char *hw_opt, Frame *out, int want,
                char *hw_name, size_t hw_len, int *frames_drawn, int64_t *pos_us)
{
    memset(out, 0, sizeof(*out) * (size_t)want);
    hw_name[0] = 0;
    *frames_drawn = 0;
    *pos_us = 0;

    void *player = NULL;
    if (c->create(&player) != 0 || !player) {
        fprintf(stderr, "create failed\n");
        return 0;
    }
    c->set_cb(player, NULL, NULL); /* no UI events needed here */

    char opts[128];
    snprintf(opts, sizeof(opts), "{\"auto_play\":true,\"hw\":\"%s\"}", hw_opt);
    if (c->open_media(player, video, opts) != 0) {
        fprintf(stderr, "open failed\n");
        c->destroy(player);
        return 0;
    }
    c->play(player);

    /* The decoder name is only settled once the video thread has opened the
     * codec, so wait for it before trusting the answer. */
    for (int i = 0; i < 300; i++) {
        Sleep(10);
        hw_name[0] = 0;
        c->get_option(player, "hw", hw_name, (int32_t)hw_len);
        if (hw_name[0] && strcmp(hw_name, "none") != 0) {
            break;
        }
    }

    int got = 0;
    int width = 0, height = 0, stride = 0;
    for (int i = 0; i < 500 && got < want; i++) { /* up to 5 s */
        Sleep(10);
        if (width == 0) {
            if (!c->frame_size(&width, &height, &stride) || width <= 0) {
                continue;
            }
            for (int k = 0; k < want; k++) {
                out[k].pixels = malloc((size_t)stride * (size_t)height);
                if (!out[k].pixels) {
                    frames_free(out, want);
                    c->destroy(player);
                    return 0;
                }
                out[k].width = width;
                out[k].height = height;
                out[k].stride = stride;
            }
        }
        /* copy_frame() only reports success for a frame the bridge has not
         * handed out yet, so this collects distinct consecutive frames. */
        if (c->copy(out[got].pixels, (size_t)stride * (size_t)height, &width, &height,
                    &stride)) {
            out[got].width = width;
            out[got].height = height;
            out[got].stride = stride;
            c->get_pos(player, &out[got].pos_us);
            got++;
        }
    }
    *frames_drawn = c->frame_count();
    c->get_pos(player, pos_us);
    c->destroy(player);
    return got;
}

/* Per-channel mean: a channel swap moves these by tens of levels, a one-frame
 * phase offset of a moving clip barely touches them. */
static void channel_means(const Frame *f, double *b, double *g, double *r)
{
    long long sb = 0, sg = 0, sr = 0;
    size_t n = (size_t)f->width * (size_t)f->height;
    for (int y = 0; y < f->height; y++) {
        const uint8_t *p = f->pixels + (size_t)y * f->stride;
        for (int x = 0; x < f->width; x++) {
            const uint8_t *q = p + (size_t)x * 4;
            sb += q[0];
            sg += q[1];
            sr += q[2];
        }
    }
    *b = n ? (double)sb / (double)n : 0.0;
    *g = n ? (double)sg / (double)n : 0.0;
    *r = n ? (double)sr / (double)n : 0.0;
}

/* Mean absolute difference over all channels plus the share of pixels that
 * differ by more than a visible amount. */
static void frame_diff(const Frame *a, const Frame *b, double *mean, double *share,
                       int *max_delta)
{
    int n = 0;
    long long total = 0;
    int worst = 0;
    if (a->width != b->width || a->height != b->height) {
        *mean = 1e9;
        *share = 1.0;
        *max_delta = 255;
        return;
    }
    for (int y = 0; y < a->height; y++) {
        const uint8_t *pa = a->pixels + (size_t)y * a->stride;
        const uint8_t *pb = b->pixels + (size_t)y * b->stride;
        for (int x = 0; x < a->width; x++) {
            const uint8_t *qa = pa + (size_t)x * 4;
            const uint8_t *qb = pb + (size_t)x * 4;
            int d = 0;
            for (int k = 0; k < 3; k++) { /* B,G,R; alpha is asserted separately */
                int v = qa[k] - qb[k];
                if (v < 0) {
                    v = -v;
                }
                if (v > d) {
                    d = v;
                }
                total += v;
            }
            if (d > worst) {
                worst = d;
            }
            if (d > 16) {
                n++;
            }
        }
    }
    *mean = (double)total / (3.0 * (double)a->width * (double)a->height);
    *share = (double)n / ((double)a->width * (double)a->height);
    *max_delta = worst;
}

static double dabs(double v)
{
    return v < 0 ? -v : v;
}

int main(int argc, char **argv)
{
    int expect_red = 0;
    int allow_software = 0;
    const char *hw_opt = "auto";
    const char *video = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--expect-red") == 0) {
            expect_red = 1;
        } else if (strcmp(argv[i], "--allow-software") == 0) {
            allow_software = 1;
        } else if (strcmp(argv[i], "--hw") == 0 && i + 1 < argc) {
            hw_opt = argv[++i];
        } else if (!video) {
            video = argv[i];
        }
    }
    if (!video) {
        fprintf(stderr, "usage: lp_hw_decode_test.exe <video> [--hw NAME] "
                        "[--allow-software] [--expect-red]\n");
        return 2;
    }

    Core core;
    if (!core_load(&core)) {
        return 4;
    }
    printf("abi=%d\n", ((fn_abi)resolve(core.lib, "lp_abi_version"))());

    Frame hw_frame[MAX_FRAMES];
    char hw_name[32];
    int hw_drawn = 0;
    int64_t hw_pos = 0;
    int hw_got = grab(&core, video, hw_opt, hw_frame, 1, hw_name, sizeof(hw_name),
                      &hw_drawn, &hw_pos);
    if (hw_got < 1) {
        frames_free(hw_frame, 1);
        FreeLibrary(core.lib);
        return 5;
    }
    printf("hw=%s\n", hw_name[0] ? hw_name : "?");
    printf("hw frames=%d size=%dx%d stride=%d pos=%.2fs\n", hw_drawn,
           hw_frame[0].width, hw_frame[0].height, hw_frame[0].stride,
           hw_pos / 1e6);

    int ok = 1;
    int hardware = strcmp(hw_name, "d3d11va") == 0;
    if (!hardware && !allow_software) {
        printf("FAIL: expected d3d11va, the core reported '%s' "
               "(silent software fallback)\n", hw_name[0] ? hw_name : "?");
        ok = 0;
    }

    if (ok && hw_drawn < 1) {
        printf("FAIL: no frames reached the texture buffer\n");
        ok = 0;
    }

    /* Colour of the delivered frame, printed in R,G,B,A order like the BMP
     * writer so it compares with the preview dumps. */
    unsigned mid_r = 0, mid_g = 0, mid_b = 0;
    if (ok) {
        uint8_t *mid = hw_frame[0].pixels +
                       (size_t)(hw_frame[0].height / 2) * hw_frame[0].stride +
                       (size_t)(hw_frame[0].width / 2) * 4;
        unsigned b = mid[0], g = mid[1], r = mid[2], a = mid[3];
        mid_r = r;
        mid_g = g;
        mid_b = b;
        if (a != 0xFF) {
            printf("FAIL: alpha is %u, expected 255 (video must be opaque)\n", a);
            ok = 0;
        }
        if (r < 8 && g < 8 && b < 8) {
            printf("FAIL: decoded frame is black\n");
            ok = 0;
        }
        if (expect_red && !(r > 200 && g < 60 && b < 60)) {
            printf("FAIL: expected red, got R=%u G=%u B=%u\n", r, g, b);
            ok = 0;
        }
    }

    /* Software reference: a short run of consecutive frames, matched against the
     * hardware frame so a queue offset cannot masquerade as corruption. */
    if (ok && hardware) {
        Frame sw_frame[MAX_FRAMES];
        char sw_name[32];
        int sw_drawn = 0;
        int64_t sw_pos = 0;
        int sw_got = grab(&core, video, "sw", sw_frame, MAX_FRAMES, sw_name,
                          sizeof(sw_name), &sw_drawn, &sw_pos);
        if (sw_got < 1) {
            printf("FAIL: software reference decode failed\n");
            frames_free(sw_frame, MAX_FRAMES);
            ok = 0;
        } else {
            double best_mean = 1e9, best_share = 1.0;
            int best_worst = 255, best_at = -1;
            for (int i = 0; i < sw_got; i++) {
                double mean = 0, share = 0;
                int worst = 0;
                frame_diff(&sw_frame[i], &hw_frame[0], &mean, &share, &worst);
                if (mean < best_mean) {
                    best_mean = mean;
                    best_share = share;
                    best_worst = worst;
                    best_at = i;
                }
            }

            double hb = 0, hg = 0, hr = 0, sb = 0, sg = 0, sr = 0;
            channel_means(&hw_frame[0], &hb, &hg, &hr);
            channel_means(&sw_frame[best_at], &sb, &sg, &sr);
            printf("hw   mean: b=%.1f g=%.1f r=%.1f\n", hb, hg, hr);
            printf("sw   mean: b=%.1f g=%.1f r=%.1f (frame %d of %d)\n", sb, sg, sr,
                   best_at, sw_got);
            printf("vs software: mean_delta=%.2f differing=%.1f%% max_delta=%d\n",
                   best_mean, best_share * 100.0, best_worst);

            /* Order matters: check the channel means first, because that is the
             * signature of a colour-order bug and its message is the useful one. */
            double worst_channel = 0;
            worst_channel = dabs(hb - sb) > worst_channel ? dabs(hb - sb) : worst_channel;
            worst_channel = dabs(hg - sg) > worst_channel ? dabs(hg - sg) : worst_channel;
            worst_channel = dabs(hr - sr) > worst_channel ? dabs(hr - sr) : worst_channel;
            if (worst_channel > 12.0) {
                printf("FAIL: channel means differ by %.1f levels (BGR/RGB swap or "
                       "wrong plane)\n", worst_channel);
                ok = 0;
            } else if (best_mean > 4.0 || best_share > 0.40) {
                printf("FAIL: hardware picture does not match any of the %d software "
                       "frames (decode corruption)\n", sw_got);
                ok = 0;
            }
            frames_free(sw_frame, MAX_FRAMES);
        }
    }

    printf("mid_pixel=#%02X%02X%02X\n", mid_r, mid_g, mid_b);
    frames_free(hw_frame, 1);
    FreeLibrary(core.lib);
    printf(ok ? "hw decode OK\n" : "hw decode FAILED\n");
    return ok ? 0 : 6;
}
