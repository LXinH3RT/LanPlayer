/*
 * LanPlayer preview player (Windows, native).
 *
 * A small Win32 shell around the same FFmpeg core the Flutter app uses, so the
 * decoder/sync/subtitle pipeline can be exercised - and watched - on a desktop
 * without a Flutter SDK, an Android device or Xcode.
 *
 *   lp_preview.exe <video>                     open and play
 *   lp_preview.exe --selftest 120 <video>      render 120 frames, print stats
 *   lp_preview.exe --dump out.bmp <video>      save one decoded frame to BMP
 *   lp_preview.exe --hw auto|sw|d3d11va <video>  pick the decoder
 *
 * Keys: space play/pause, left/right seek 10 s, up/down volume, +/- speed,
 *       F fit/fill, O open, Esc quit.
 *
 * Video is drawn with GDI (the D3D11VA path still ends in a CPU frame here);
 * audio goes to waveOut.  This is a preview tool, not the product UI - the
 * product UI lives in app/.
 */
/* windows.h must come first: commdlg.h (prsht.h) relies on its types. */
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <commdlg.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lanplayer/lp_log.h"
#include "lanplayer/lp_player.h"
#include "platform/win32/win32_preview.h"

static const wchar_t *kClassName = L"LanPlayerPreview";

typedef struct App {
    LpPlayer *player;
    HWND hwnd;
    wchar_t path[MAX_PATH];
    wchar_t subtitle[1024]; /* wide, empty when nothing is shown */
    wchar_t info[512];
    int scale_mode; /* 0 fit, 1 fill */
    int selftest_frames;
    int auto_close_ms;
    wchar_t dump_path[MAX_PATH];
    char hw[32]; /* "auto" (default), "sw" or a forced decoder name */
    int hw_set;  /* --hw was given on the command line */
    int opened;
    int ended;
} App;

static App g_app;

/* Open options for the core.  --hw lets a run pin the decoder so hardware and
 * software output can be compared without editing code. */
static const char *open_options(void)
{
    static char buf[128];
    snprintf(buf, sizeof(buf), "{\"auto_play\":true,\"hw\":\"%s\"}",
             g_app.hw[0] ? g_app.hw : "auto");
    return buf;
}

/* ------------------------------------------------------------- helpers --- */

static void utf8_to_wide(const char *src, wchar_t *dst, int cap)
{
    if (!dst || cap <= 0) {
        return;
    }
    dst[0] = 0;
    if (!src) {
        return;
    }
    MultiByteToWideChar(CP_UTF8, 0, src, -1, dst, cap);
    dst[cap - 1] = 0;
}

/* Copies the value of a JSON string field into out (UTF-8). */
static void json_str(const char *json, const char *key, char *out, size_t cap)
{
    out[0] = 0;
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", key);
    const char *p = strstr(json, pattern);
    if (!p) {
        return;
    }
    p += strlen(pattern);
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < cap) {
        if (*p == '\\' && p[1]) {
            p++;
            if (*p == 'n') {
                out[i++] = ' ';
                p++;
                continue;
            }
        }
        out[i++] = *p++;
    }
    out[i] = 0;
}

static void app_set_title(void)
{
    if (!g_app.hwnd) {
        return;
    }
    wchar_t title[700];
    const wchar_t *name = wcsrchr(g_app.path, L'\\');
    name = name ? name + 1 : g_app.path;
    if (g_app.info[0]) {
        swprintf(title, 700, L"%s  -  %s  -  LanPlayer preview", name, g_app.info);
    } else {
        swprintf(title, 700, L"%s  -  LanPlayer preview", name);
    }
    SetWindowTextW(g_app.hwnd, title);
}

/* -------------------------------------------------------------- events --- */

static void on_event(void *user, int32_t event, const char *json, int64_t value)
{
    (void)user;
    (void)value;
    const char *payload = json ? json : "";
    switch (event) {
    case LP_EVENT_MEDIA_INFO: {
        char codec[64] = {0}, hw[64] = {0}, fmt[64] = {0};
        json_str(payload, "format", fmt, sizeof(fmt));
        json_str(payload, "active", hw, sizeof(hw));
        /* first video codec */
        const char *v = strstr(payload, "\"video\":{");
        if (v) {
            json_str(v, "codec", codec, sizeof(codec));
        }
        wchar_t wcodec[64], whw[64], wfmt[64];
        utf8_to_wide(codec, wcodec, 64);
        utf8_to_wide(hw, whw, 64);
        utf8_to_wide(fmt, wfmt, 64);
        swprintf(g_app.info, 512, L"%s / %s / %s", wfmt, wcodec, whw);
        app_set_title();
        break;
    }
    case LP_EVENT_SUBTITLE: {
        char text[1024];
        json_str(payload, "text", text, sizeof(text));
        utf8_to_wide(text, g_app.subtitle, 1024);
        if (g_app.hwnd) {
            InvalidateRect(g_app.hwnd, NULL, FALSE);
        }
        break;
    }
    case LP_EVENT_ERROR:
        utf8_to_wide(payload, g_app.info, 512);
        app_set_title();
        break;
    case LP_EVENT_ENDED:
        g_app.ended = 1;
        break;
    default:
        break;
    }
    /* The core hands ownership of the payload to us. */
    lp_string_free((char *)json);
}

/* ---------------------------------------------------------------- paint --- */

static void draw_osd(HDC dc, int w, int h, HWND hwnd)
{
    int64_t pos = 0, dur = 0;
    lp_player_get_position(g_app.player, &pos);
    lp_player_get_duration(g_app.player, &dur);
    int state = lp_player_get_state(g_app.player);

    /* progress bar */
    RECT bar = {0, h - 6, w, h};
    HBRUSH bg = CreateSolidBrush(RGB(40, 44, 52));
    FillRect(dc, &bar, bg);
    DeleteObject(bg);
    if (dur > 0) {
        double frac = (double)pos / (double)dur;
        if (frac < 0) frac = 0;
        if (frac > 1) frac = 1;
        RECT fill = {0, h - 6, (LONG)(w * frac), h};
        HBRUSH fg = CreateSolidBrush(RGB(79, 195, 247));
        FillRect(dc, &fill, fg);
        DeleteObject(fg);
    }

    wchar_t osd[256];
    swprintf(osd, 256, L"%02d:%02d / %02d:%02d    %s%s",
             (int)(pos / 60000000), (int)((pos / 1000000) % 60),
             (int)(dur / 60000000), (int)((dur / 1000000) % 60),
             state == LP_STATE_PLAYING ? L"playing" : (state == LP_STATE_PAUSED ? L"paused" : L""),
             g_app.ended ? L" (ended)" : L"");
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, RGB(200, 205, 212));
    TextOutW(dc, 14, h - 34, osd, (int)wcslen(osd));

    if (g_app.path[0]) {
        RECT top = {0, 0, w, h};
        const wchar_t *name = wcsrchr(g_app.path, L'\\');
        name = name ? name + 1 : g_app.path;
        SetTextColor(dc, RGB(120, 128, 140));
        DrawTextW(dc, name, -1, &top, DT_TOP | DT_LEFT | DT_SINGLELINE | DT_NOPREFIX);
    }
    (void)hwnd;
}

static void draw_subtitle(HDC dc, int w, int h)
{
    if (!g_app.subtitle[0]) {
        return;
    }
    HFONT font = CreateFontW(-28, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                             OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                             DEFAULT_PITCH | FF_DONTCARE, L"Microsoft YaHei");
    HGDIOBJ old = SelectObject(dc, font);
    SetBkMode(dc, TRANSPARENT);

    RECT box = {40, h - 130, w - 40, h - 40};
    /* outline: draw the text 8 times in black, then once in white */
    SetTextColor(dc, RGB(0, 0, 0));
    for (int dx = -2; dx <= 2; dx += 2) {
        for (int dy = -2; dy <= 2; dy += 2) {
            RECT r = box;
            OffsetRect(&r, dx, dy);
            DrawTextW(dc, g_app.subtitle, -1, &r,
                      DT_CENTER | DT_BOTTOM | DT_WORDBREAK | DT_NOPREFIX);
        }
    }
    SetTextColor(dc, RGB(255, 255, 255));
    DrawTextW(dc, g_app.subtitle, -1, &box,
              DT_CENTER | DT_BOTTOM | DT_WORDBREAK | DT_NOPREFIX);

    SelectObject(dc, old);
    DeleteObject(font);
}

static void on_paint(HWND hwnd)
{
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(hwnd, &ps);
    RECT rc;
    GetClientRect(hwnd, &rc);
    int w = rc.right - rc.left;
    int h = rc.bottom - rc.top;

    HBRUSH black = CreateSolidBrush(RGB(0, 0, 0));
    FillRect(dc, &rc, black);
    DeleteObject(black);

    if (!lp_win32_blit(dc, w, h, g_app.scale_mode)) {
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(150, 156, 166));
        const wchar_t *hint =
            L"Drag a video onto the window, or press O to open a file   (space play/pause, "
            L"arrows seek/volume, F fit/fill)";
        DrawTextW(dc, hint, -1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    }
    draw_subtitle(dc, w, h);
    draw_osd(dc, w, h, hwnd);
    EndPaint(hwnd, &ps);
}

/* ---------------------------------------------------------------- input --- */

static void open_file_dialog(HWND hwnd)
{
    wchar_t file[MAX_PATH] = L"";
    OPENFILENAMEW ofn;
    memset(&ofn, 0, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = hwnd;
    ofn.lpstrFilter =
        L"Video files\0*.mp4;*.mkv;*.avi;*.mov;*.ts;*.m2ts;*.flv;*.webm;*.wmv\0All files\0*.*\0";
    ofn.lpstrFile = file;
    ofn.nMaxFile = MAX_PATH;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;
    if (!GetOpenFileNameW(&ofn)) {
        return;
    }
    wcscpy_s(g_app.path, MAX_PATH, file);
    g_app.ended = 0;
    g_app.info[0] = 0;
    g_app.subtitle[0] = 0;
    char url[MAX_PATH * 4];
    WideCharToMultiByte(CP_UTF8, 0, file, -1, url, sizeof(url), NULL, NULL);
    lp_player_open(g_app.player, url, open_options());
    app_set_title();
}

static void on_key(HWND hwnd, WPARAM key)
{
    switch (key) {
    case VK_SPACE:
        if (lp_player_get_state(g_app.player) == LP_STATE_PLAYING) {
            lp_player_pause(g_app.player);
        } else {
            if (g_app.ended) {
                lp_player_seek(g_app.player, 0);
                g_app.ended = 0;
            }
            lp_player_play(g_app.player);
        }
        break;
    case VK_LEFT:
    case VK_RIGHT: {
        int64_t pos = 0;
        lp_player_get_position(g_app.player, &pos);
        pos += (key == VK_LEFT ? -10 : 10) * 1000000LL;
        if (pos < 0) pos = 0;
        lp_player_seek(g_app.player, pos);
        break;
    }
    case VK_UP:
    case VK_DOWN: {
        char buf[32];
        lp_player_get_option(g_app.player, "volume", buf, sizeof(buf));
        double v = atof(buf);
        v += (key == VK_UP ? 0.1 : -0.1);
        if (v < 0) v = 0;
        if (v > 2) v = 2;
        lp_player_set_volume(g_app.player, (float)v);
        break;
    }
    case 'F':
        g_app.scale_mode = g_app.scale_mode ? 0 : 1;
        break;
    case 'O':
        open_file_dialog(hwnd);
        break;
    case VK_ADD:
    case VK_OEM_PLUS: {
        float s = 1.0f;
        lp_player_get_speed(g_app.player, &s);
        lp_player_set_speed(g_app.player, s + 0.25f);
        break;
    }
    case VK_SUBTRACT:
    case VK_OEM_MINUS: {
        float s = 1.0f;
        lp_player_get_speed(g_app.player, &s);
        lp_player_set_speed(g_app.player, s - 0.25f);
        break;
    }
    case VK_ESCAPE:
        DestroyWindow(hwnd);
        return;
    default:
        break;
    }
    InvalidateRect(hwnd, NULL, FALSE);
}

/* --------------------------------------------------------------- window --- */

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_PAINT:
        on_paint(hwnd);
        return 0;
    case WM_APP + 2: /* launched without a file: ask for one */
        open_file_dialog(hwnd);
        return 0;
    case WM_APP + 1: /* new video frame */
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    case WM_TIMER:
        if (wp == 2) {
            printf("auto-close fired, exiting window test\n");
            DestroyWindow(hwnd);
            return 0;
        }
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    case WM_KEYDOWN:
        on_key(hwnd, wp);
        return 0;
    case WM_ERASEBKGND:
        return 1;
    case WM_SIZE:
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    case WM_DROPFILES: {
        HDROP drop = (HDROP)wp;
        UINT n = DragQueryFileW(drop, 0, g_app.path, MAX_PATH);
        DragFinish(drop);
        if (n > 0 && g_app.player) {
            g_app.ended = 0;
            g_app.info[0] = 0;
            g_app.subtitle[0] = 0;
            char url[MAX_PATH * 4];
            WideCharToMultiByte(CP_UTF8, 0, g_app.path, -1, url, sizeof(url), NULL, NULL);
            lp_player_open(g_app.player, url, open_options());
            app_set_title();
        }
        return 0;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
}

static int run_gui(void)
{
    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = CreateSolidBrush(RGB(0, 0, 0));
    wc.lpszClassName = kClassName;
    if (!RegisterClassExW(&wc)) {
        fprintf(stderr, "RegisterClassEx failed: %lu\n", GetLastError());
        return 1;
    }

    HWND hwnd = CreateWindowExW(WS_EX_ACCEPTFILES, kClassName, L"LanPlayer preview",
                                WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1280, 720, NULL,
                                NULL, wc.hInstance, NULL);
    if (!hwnd) {
        fprintf(stderr, "CreateWindowEx failed: %lu\n", GetLastError());
        return 1;
    }
    g_app.hwnd = hwnd;
    /* Public API: hands the window to the platform renderer. */
    lp_player_set_surface(g_app.player, hwnd, 0, 0);
    printf("window created: hwnd=0x%p\n", (void *)hwnd);
    SetTimer(hwnd, 1, 100, NULL);
    if (!g_app.path[0]) {
        PostMessageW(hwnd, WM_APP + 2, 0, 0);
    }
    if (g_app.auto_close_ms > 0) {
        SetTimer(hwnd, 2, (UINT)g_app.auto_close_ms, NULL);
    }
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}

/* ------------------------------------------------------------- selftest --- */

static int run_selftest(int want_frames, const wchar_t *path, const wchar_t *dump)
{
    char url[MAX_PATH * 4];
    WideCharToMultiByte(CP_UTF8, 0, path, -1, url, sizeof(url), NULL, NULL);
    if (lp_player_open(g_app.player, url, open_options()) != LP_OK) {
        fprintf(stderr, "open failed\n");
        return 2;
    }
    int waited_ms = 0;
    while (waited_ms < 20000 && lp_win32_frame_count() < want_frames) {
        Sleep(10);
        waited_ms += 10;
    }
    int frames = lp_win32_frame_count();
    int64_t pos = 0, dur = 0;
    lp_player_get_position(g_app.player, &pos);
    lp_player_get_duration(g_app.player, &dur);
    printf("frames=%d position=%.2fs duration=%.2fs state=%d\n", frames, pos / 1e6, dur / 1e6,
           lp_player_get_state(g_app.player));
    if (dump && dump[0]) {
        char narrow[MAX_PATH * 4];
        WideCharToMultiByte(CP_UTF8, 0, dump, -1, narrow, sizeof(narrow), NULL, NULL);
        if (lp_win32_save_bmp(narrow) == 0) {
            printf("dumped %s\n", narrow);
        } else {
            fprintf(stderr, "dump failed\n");
        }
    }
    return frames >= want_frames ? 0 : 3;
}

/* ----------------------------------------------------------------- main --- */

int main(int argc, char **argv)
{
    lp_log_set_level(LP_LOG_INFO);
    if (lp_abi_version() != LP_ABI_VERSION) {
        fprintf(stderr, "ABI mismatch: %d\n", lp_abi_version());
        return 2;
    }

    const wchar_t *file = NULL;
    int selftest = 0;
    wchar_t dump[MAX_PATH] = L"";

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--selftest") == 0 && i + 1 < argc) {
            selftest = atoi(argv[++i]);
            if (selftest <= 0) selftest = 60;
        } else if (strcmp(argv[i], "--auto-close") == 0 && i + 1 < argc) {
            g_app.auto_close_ms = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--dump") == 0 && i + 1 < argc) {
            MultiByteToWideChar(CP_UTF8, 0, argv[++i], -1, dump, MAX_PATH);
        } else if (strcmp(argv[i], "--hw") == 0 && i + 1 < argc) {
            snprintf(g_app.hw, sizeof(g_app.hw), "%s", argv[++i]);
            g_app.hw_set = 1;
        } else {
            MultiByteToWideChar(CP_UTF8, 0, argv[i], -1, g_app.path, MAX_PATH);
            file = g_app.path;
        }
    }

    if (lp_player_create(&g_app.player) != LP_OK) {
        fprintf(stderr, "lp_player_create failed\n");
        return 2;
    }
    lp_player_set_event_callback(g_app.player, on_event, NULL);

    int rc;
    if (selftest > 0) {
        if (!file) {
            fprintf(stderr, "--selftest needs a media file\n");
            lp_player_destroy(g_app.player);
            return 2;
        }
        /* Frame counts are only comparable when the decoder is fixed, so a
         * selftest run stays on the software path unless --hw says otherwise. */
        if (!g_app.hw_set) {
            snprintf(g_app.hw, sizeof(g_app.hw), "sw");
        }
        rc = run_selftest(selftest, file, dump);
    } else {
        if (file) {
            char url[MAX_PATH * 4];
            WideCharToMultiByte(CP_UTF8, 0, file, -1, url, sizeof(url), NULL, NULL);
            lp_player_open(g_app.player, url, open_options());
        }
        rc = run_gui();
    }
    lp_player_destroy(g_app.player);
    return rc;
}
