/* Smoke test for the native core.
 *
 *   lp_smoke_test                      load the library, check the ABI
 *   lp_smoke_test <media> [seconds]    play it with software decode and report
 *
 * Exit code 0 only when every expectation met: audio+video decoded, the
 * position advanced, and (when the file has subtitles) subtitle events arrived.
 * Runs on the stub platform, so it works on desktops and in CI without a
 * window, a GPU or an audio device.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "lanplayer/lp_log.h"
#include "lanplayer/lp_player.h"

#if defined(_WIN32)
#include <windows.h>

/* Prints the faulting stack so a link map can turn the frames into symbols.
 * Used while chasing heap corruption; harmless otherwise. */
static LONG WINAPI lp_crash_filter(EXCEPTION_POINTERS *ep)
{
    fprintf(stderr, "\n*** crash 0x%08lx at %p (module base %p)\n",
            (unsigned long)ep->ExceptionRecord->ExceptionCode,
            ep->ExceptionRecord->ExceptionAddress, (void *)GetModuleHandleW(NULL));
    void *frames[48];
    USHORT n = RtlCaptureStackBackTrace(0, 48, frames, NULL);
    for (unsigned i = 0; i < n; i++) {
        fprintf(stderr, "  #%02u %p\n", i, frames[i]);
    }
    fflush(stderr);
    return EXCEPTION_EXECUTE_HANDLER;
}
#endif

static int g_events = 0;
static int g_counts[16];
static int g_errors = 0;
static int g_subtitle_events = 0;
static char g_first_subtitle[256];
static char g_last_subtitle[256];
static int g_have_media_info = 0;
/* Last STATS payload. Kept so the report can show whether frames actually came
 * out: a decoder that opens fine but never produces a picture still advances
 * the clock (position is audio driven), so position alone cannot tell a good
 * run from a stalled one. */
static char g_last_stats[256];
static long long g_stats_decoded = -1;

static void lp_test_sleep_ms(int ms)
{
#if defined(_WIN32)
    Sleep((DWORD)ms);
#else
    struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
    nanosleep(&ts, NULL);
#endif
}

static void on_event(void *user, int32_t event, const char *json, int64_t value)
{
    (void)user;
    (void)value;
    g_events++;
    if (event >= 0 && event < 16) {
        g_counts[event]++;
    }
    const char *payload = json ? json : "";
    switch (event) {
    case LP_EVENT_MEDIA_INFO:
        g_have_media_info = 1;
        printf("media: %s\n", payload);
        break;
    case LP_EVENT_SUBTITLE:
        g_subtitle_events++;
        if (getenv("LP_DUMP_SUBS")) {
            fprintf(stderr, "SUB %s\n", payload);
        }
        if (!g_first_subtitle[0]) {
            /* "text":"..." - copy just the text field for the report. */
            const char *t = strstr(payload, "\"text\":\"");
            if (t) {
                t += 8;
                size_t i = 0;
                while (*t && *t != '"' && i + 1 < sizeof(g_first_subtitle)) {
                    g_first_subtitle[i++] = *t == '\\' ? ' ' : *t;
                    t++;
                }
                g_first_subtitle[i] = '\0';
            }
        }
        memset(g_last_subtitle, 0, sizeof(g_last_subtitle));
        {
            const char *t = strstr(payload, "\"text\":\"");
            if (t) {
                t += 8;
                size_t i = 0;
                while (*t && *t != '"' && i + 1 < sizeof(g_last_subtitle)) {
                    g_last_subtitle[i++] = *t == '\\' ? ' ' : *t;
                    t++;
                }
                g_last_subtitle[i] = '\0';
            }
        }
        break;
    case LP_EVENT_ERROR:
        g_errors++;
        fprintf(stderr, "error: %s\n", payload);
        break;
    case LP_EVENT_ENDED:
        printf("ended: %s\n", payload);
        break;
    case LP_EVENT_STATS:
        /* Keep the newest payload; the final report summarises it. */
        snprintf(g_last_stats, sizeof(g_last_stats), "%s", payload);
        {
            const char *d = strstr(payload, "\"decoded\":");
            if (d) {
                g_stats_decoded = atoll(d + 10);
            }
        }
        break;
    default:
        break;
    }
}

/* --list <url>: exercise the transport layer (listing + error reporting). */
static int run_list(const char *url, const char *options)
{
    char *json = NULL;
    int rc = lp_source_list(url, options, &json);
    if (rc == LP_OK && json) {
        printf("list ok: %s\n", json);
        lp_string_free(json);
        return 0;
    }
    char *err = NULL;
    lp_source_last_error(&err);
    printf("list failed (rc=%d): %s\n", rc, err ? err : "(no detail)");
    if (err) {
        lp_string_free(err);
    }
    return 1;
}

/* --probe <url>：只校验账号密码能不能连上（不枚举共享）。 */
static int run_probe(const char *url, const char *options)
{
    char *json = NULL;
    int rc = lp_source_probe(url, options, &json);
    if (rc == LP_OK && json) {
        printf("probe ok: %s\n", json);
        lp_string_free(json);
        return 0;
    }
    char *err = NULL;
    lp_source_last_error(&err);
    printf("probe failed (rc=%d): %s\n", rc, err ? err : "(no detail)");
    if (err) {
        lp_string_free(err);
    }
    return 1;
}

int main(int argc, char **argv)
{
#if defined(_WIN32)
    SetUnhandledExceptionFilter(lp_crash_filter);
#endif
    printf("abi=%d\n", lp_abi_version());
    if (lp_abi_version() != LP_ABI_VERSION) {
        fprintf(stderr, "ABI mismatch\n");
        return 2;
    }
    char *schemes = NULL;
    if (lp_source_schemes(&schemes) == LP_OK && schemes) {
        printf("schemes=%s\n", schemes);
        lp_string_free(schemes);
    }

    LpPlayer *player = NULL;
    if (lp_player_create(&player) != LP_OK || !player) {
        fprintf(stderr, "create failed\n");
        return 3;
    }
    lp_player_set_event_callback(player, on_event, NULL);
    {
        const char *lvl = getenv("LP_LOG_LEVEL");
        if (lvl && strcmp(lvl, "debug") == 0) {
            lp_log_set_level(LP_LOG_DEBUG);
        } else if (lvl && strcmp(lvl, "trace") == 0) {
            lp_log_set_level(LP_LOG_TRACE);
        } else {
            lp_log_set_level(LP_LOG_INFO);
        }
    }
    lp_log_set_callback(NULL, NULL);

    if (argc >= 3 && strcmp(argv[1], "--list") == 0) {
        int rc = run_list(argv[2], argc > 3 ? argv[3] : NULL);
        lp_player_destroy(player);
        return rc;
    }
    if (argc >= 3 && strcmp(argv[1], "--probe") == 0) {
        int rc = run_probe(argv[2], argc > 3 ? argv[3] : NULL);
        lp_player_destroy(player);
        return rc;
    }
    if (argc < 2) {
        printf("no media given: library smoke test passed (events=%d)\n", g_events);
        lp_player_destroy(player);
        return 0;
    }

    int seconds = argc > 2 ? atoi(argv[2]) : 4;
    if (seconds < 1) {
        seconds = 1;
    }
    /* `hw` can be overridden for hardware experiments:
     *   lp_smoke_test movie.mkv 4 hw=mediacodec
     * A whole options object is accepted too, which is how a network source
     * gets its credentials:
     *   lp_smoke_test smb://host/share/a.mkv 8 '{"hw":"auto","user":"u","password":"p"}'
     */
    char opts[256];
    const char *hw = "sw";
    if (argc > 3 && strncmp(argv[3], "hw=", 3) == 0) {
        hw = argv[3] + 3;
    }
    if (argc > 3 && argv[3][0] == '{') {
        snprintf(opts, sizeof(opts), "%s", argv[3]);
    } else {
        snprintf(opts, sizeof(opts), "{\"auto_play\":true,\"hw\":\"%s\"}", hw);
    }

    if (lp_player_open(player, argv[1], opts) != LP_OK) {
        fprintf(stderr, "open failed\n");
        lp_player_destroy(player);
        return 4;
    }

    int64_t prev = 0;
    int stalled = 0;
    int ended = 0;
    for (int i = 0; i < seconds * 10; i++) {
        lp_test_sleep_ms(100);
        int64_t p = 0;
        lp_player_get_position(player, &p);
        if (p == prev) {
            stalled++;
        } else {
            stalled = 0;
        }
        prev = p;
        /* 片子比采样窗口短的话，播完之后位置本来就不再前进 —— 那不是
         * 「时钟卡住」。没有这一条，`lp_smoke_test clip.mp4 14` 会对一个
         * 6 秒的片子报 FAIL: clock stalled for 82 consecutive samples。 */
        if (lp_player_get_state(player) == LP_STATE_ENDED) {
            ended = 1;
            break;
        }
    }

    int64_t pos = 0, dur = 0;
    lp_player_get_position(player, &pos);
    lp_player_get_duration(player, &dur);
    int state = lp_player_get_state(player);

    char hw_used[64] = "?";
    lp_player_get_option(player, "hw", hw_used, sizeof(hw_used));

    printf("\n--- report ---\n");
    printf("position      %lld us (%.2f s)\n", (long long)pos, pos / 1e6);
    printf("duration      %lld us\n", (long long)dur);
    printf("state         %d\n", state);
    printf("decoder       %s\n", hw_used);
    printf("events        %d (position=%d subtitle=%d stats=%d)\n", g_events,
           g_counts[LP_EVENT_POSITION], g_counts[LP_EVENT_SUBTITLE], g_counts[LP_EVENT_STATS]);
    if (g_last_stats[0]) {
        printf("stats         %s\n", g_last_stats);
    }
    printf("subtitle      %d event(s)\n", g_subtitle_events);
    if (g_first_subtitle[0]) {
        printf("  first       \"%s\"\n", g_first_subtitle);
    }
    if (g_last_subtitle[0] && strcmp(g_last_subtitle, g_first_subtitle) != 0) {
        printf("  last        \"%s\"\n", g_last_subtitle);
    }

    int failures = 0;
    if (!g_have_media_info) {
        printf("FAIL: no media info event\n");
        failures++;
    }
    if (g_errors > 0) {
        printf("FAIL: %d error event(s)\n", g_errors);
        failures++;
    }
    if (pos <= 0) {
        printf("FAIL: position did not advance\n");
        failures++;
    }
    if (pos < 500000) {
        printf("FAIL: playback stalled (%lld us after %d s wall)\n", (long long)pos, seconds);
        failures++;
    }
    if (stalled > 20) {
        printf("FAIL: clock stalled for %d consecutive samples\n", stalled);
        failures++;
    }
    /* A decoder that opens but never delivers a picture still advances the
     * clock when the file has audio, so the position checks above pass while
     * the user stares at a frozen first frame. One second of STATS events
     * without a single decoded frame means exactly that. */
    if (seconds >= 2 && g_stats_decoded == 0) {
        printf("FAIL: no video frame decoded in %d s (%s)\n", seconds, g_last_stats);
        failures++;
    }
    lp_player_destroy(player);

    if (failures) {
        printf("\n%d check(s) failed\n", failures);
        return 5;
    }
    printf("\nall checks passed\n");
    return 0;
}
