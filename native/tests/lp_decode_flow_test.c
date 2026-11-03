/*
 * Decode-flow regression test.
 *
 * Asks one question about a clip played end to end: does the core keep moving,
 * or does it stop in the middle and stay there?  Three symptoms are watched,
 * because they are what a stuck video thread looks like from outside:
 *
 *  1. The position keeps advancing.  A stopped video thread leaves the master
 *     clock frozen, so a position that stops moving is exactly the symptom a
 *     user reports as "the picture froze".
 *  2. Frames keep arriving.  The texture bridge is polled and the frame counter
 *     must grow across the whole run, not just at the start.
 *  3. Playback finishes.  A clip that reaches ENDED proves both decoder threads
 *     drained their queues, which cannot happen if the video loop stopped
 *     consuming packets.
 *
 * A clip is played for its full length with both `hw=sw` and `hw=auto`, so the
 * software path and whatever hardware backend this machine has are both
 * covered.  The `hw=auto` run may legitimately fall back to software; the test
 * still asks whether the core finished, because a fallback that hangs is the
 * same bug seen from the outside.
 *
 * WHAT THIS TEST CANNOT DO
 *
 * It cannot reproduce the historic `in_flight` leak (a hardware decoder whose
 * send fails is not supposed to occupy a prefetch slot).  That leak only exists
 * on the asynchronous branch: `video.c` counts in_flight inside
 * `if (p->video.hw && lp_hw_decoder_is_async(p->video.hw))`, and the Windows
 * backend (d3d11va) reports itself as synchronous, so on this machine the
 * counter is never even touched.  `LP_HW_REJECT_FIRST=n` was added to video.c to
 * force n sends to fail, and with it the leak was measured on both the fixed and
 * the broken kernel: identical results, ENDED in both cases.  Reverting the fix
 * is therefore invisible here.
 *
 * The leak is guarded by `tool/check_all.py` (a source assertion that in_flight
 * only increments when the send succeeded) and by the iPad-side measurements
 * recorded in docs/code-review.md.  Keeping this test honest about its reach is
 * better than letting it look like coverage it does not have.
 *
 *   lp_decode_flow_test.exe <video> [--seconds N]
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
typedef int (*fn_open)(void *player, const char *url, const char *options);
typedef int (*fn_play)(void *player);
typedef int (*fn_get_state)(void *player);
typedef int (*fn_get_pos)(void *player, int64_t *out);
typedef int (*fn_get_dur)(void *player, int64_t *out);
typedef int (*fn_get_option)(void *player, const char *key, char *buf, int32_t buflen);
typedef int (*fn_copy_frame)(uint8_t *dst, size_t cap, int *w, int *h, int *stride);
typedef int (*fn_frame_count)(void);

/* Mirror of lp_types.h LpState so the test does not have to include the header
 * (it links against the DLL, not the static library).  Keep the numbers in step
 * with native/include/lanplayer/lp_types.h; a wrong table here turns every case
 * into a false failure, which is exactly what happened the first time. */
#define STATE_IDLE 0
#define STATE_OPENING 1
#define STATE_READY 2
#define STATE_PLAYING 3
#define STATE_PAUSED 4
#define STATE_STOPPED 5
#define STATE_ENDED 6
#define STATE_ERROR 7

typedef struct Core {
    HMODULE lib;
    fn_create create;
    fn_destroy destroy;
    fn_open open_media;
    fn_play play;
    fn_get_state get_state;
    fn_get_pos get_pos;
    fn_get_dur get_dur;
    fn_get_option get_option;
    fn_copy_frame copy;
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
    c->open_media = (fn_open)resolve(c->lib, "lp_player_open");
    c->play = (fn_play)resolve(c->lib, "lp_player_play");
    c->get_state = (fn_get_state)resolve(c->lib, "lp_player_get_state");
    c->get_pos = (fn_get_pos)resolve(c->lib, "lp_player_get_position");
    c->get_dur = (fn_get_dur)resolve(c->lib, "lp_player_get_duration");
    c->get_option = (fn_get_option)resolve(c->lib, "lp_player_get_option");
    c->copy = (fn_copy_frame)resolve(c->lib, "lp_win32_copy_frame");
    c->frame_count = (fn_frame_count)resolve(c->lib, "lp_win32_frame_count");
    return c->create && c->destroy && c->open_media && c->play && c->get_state &&
           c->get_pos && c->get_dur && c->get_option && c->copy && c->frame_count;
}

typedef struct Report {
    const char *hw;          /* requested decoding mode */
    char actual[32];         /* what the core settled on */
    int64_t duration_us;
    int64_t max_pos_us;
    int end_state;
    int frames_start;
    int frames_end;
    int stalled_pos;         /* seconds during which the position did not move */
    int stalled_frames;      /* ... or during which no new frame arrived */
    int samples;
    int failed;
} Report;

/* Plays the clip and samples once per 100 ms.  Returns 1 when playback reached
 * ENDED without either symptom below showing up for more than a second. */
static int run_once(Core *c, const char *video, const char *hw, int budget_seconds,
                    Report *rep)
{
    memset(rep, 0, sizeof(*rep));
    rep->hw = hw;

    void *player = NULL;
    if (c->create(&player) != 0 || !player) {
        fprintf(stderr, "%s: create failed\n", hw);
        rep->failed = 1;
        return 0;
    }

    char opts[128];
    snprintf(opts, sizeof(opts), "{\"auto_play\":true,\"hw\":\"%s\"}", hw);
    if (c->open_media(player, video, opts) != 0) {
        fprintf(stderr, "%s: open failed\n", hw);
        c->destroy(player);
        rep->failed = 1;
        return 0;
    }
    c->play(player);

    /* Leave room for opening and for the tail of the clip. */
    int budget = budget_seconds > 0 ? budget_seconds : 30;
    int limit = budget * 10;

    int64_t last_pos = -1;
    int last_frames = -1;
    int still_pos = 0;
    int still_frames = 0;

    uint8_t *scratch = NULL;
    int scratch_cap = 0;

    for (int i = 0; i < limit; i++) {
        Sleep(100);
        int state = c->get_state(player);
        int64_t pos = 0;
        c->get_pos(player, &pos);
        int frames = c->frame_count();

        /* Pull the delivered frame so the bridge keeps handing out new ones; the
         * counter above is what the assertions look at. */
        int w = 0, h = 0, stride = 0;
        if (c->copy(NULL, 0, &w, &h, &stride) == 0 && w > 0) {
            size_t need = (size_t)stride * (size_t)h;
            if ((int)need > scratch_cap) {
                uint8_t *grown = (uint8_t *)realloc(scratch, need);
                if (grown) {
                    scratch = grown;
                    scratch_cap = (int)need;
                }
            }
            if (scratch) {
                c->copy(scratch, (size_t)scratch_cap, &w, &h, &stride);
            }
        }

        if (i == 0) {
            rep->frames_start = frames;
        }
        rep->frames_end = frames;
        rep->samples++;
        if (pos > rep->max_pos_us) {
            rep->max_pos_us = pos;
        }

        /* A frozen clock is the first sign the video thread stopped; a frame
         * counter that stops growing is the same thing seen from the texture
         * side.  Both are counted per second and the test allows one. */
        if (last_pos >= 0 && pos == last_pos && state == STATE_PLAYING) {
            still_pos++;
        } else {
            still_pos = 0;
        }
        if (last_frames >= 0 && frames == last_frames && state == STATE_PLAYING) {
            still_frames++;
        } else {
            still_frames = 0;
        }
        if (still_pos >= 10) {
            rep->stalled_pos++;
            still_pos = 0;
        }
        if (still_frames >= 10) {
            rep->stalled_frames++;
            still_frames = 0;
        }

        last_pos = pos;
        last_frames = frames;

        if (state == STATE_ENDED) {
            rep->end_state = state;
            break;
        }
        if (state == STATE_STOPPED) {
            rep->end_state = state;
            break;
        }
    }

    if (rep->end_state == 0) {
        rep->end_state = c->get_state(player);
    }
    /* Duration is only known once the demuxer has parsed the header, so it has
     * to be read after playback started, not straight after play(). */
    c->get_dur(player, &rep->duration_us);
    c->get_option(player, "hw", rep->actual, (int32_t)sizeof(rep->actual));
    free(scratch);
    c->destroy(player);

    int progressed = rep->max_pos_us > 0;
    int finished = rep->end_state == STATE_ENDED;
    int steady = rep->stalled_pos == 0 && rep->stalled_frames == 0;
    if (!progressed || !finished || !steady) {
        rep->failed = 1;
    }
    return !rep->failed;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr,
                "usage: lp_decode_flow_test.exe <video> [--seconds N]\n"
                "Playing a short clip is enough; the assertion is that playback\n"
                "keeps moving and reaches the end.\n");
        return 2;
    }
    const char *video = argv[1];
    int budget = 30;
    for (int i = 2; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--seconds") == 0) {
            budget = atoi(argv[i + 1]);
        }
    }

    Core c;
    if (!core_load(&c)) {
        return 3;
    }
    if (!c.create || !c.get_option) {
        return 4;
    }

    const char *modes[] = { "sw", "auto" };
    int failures = 0;
    for (int i = 0; i < 2; i++) {
        Report rep;
        int ok = run_once(&c, video, modes[i], budget, &rep);
        printf("%-5s -> hw=%-12s duration=%.2fs reached=%.2fs frames=%d->%d "
               "stalled(pos=%d frames=%d) end_state=%d samples=%d : %s\n",
               modes[i], rep.actual[0] ? rep.actual : "?",
               (double)rep.duration_us / 1e6, (double)rep.max_pos_us / 1e6,
               rep.frames_start, rep.frames_end, rep.stalled_pos, rep.stalled_frames,
               rep.end_state, rep.samples, ok ? "ok" : "FAILED");
        if (!ok) {
            failures++;
        }
    }

    if (failures) {
        fprintf(stderr,
                "\n%d of 2 decoding modes did not play through.  A frozen position\n"
                "or a frame counter that stops growing means the video thread is no\n"
                "longer consuming packets.\n",
                failures);
        return 6;
    }
    printf("\nall decode-flow cases passed\n");
    return 0;
}
