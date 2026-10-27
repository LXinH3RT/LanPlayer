/*
 * Subtitles: embedded text tracks (decoded through libavcodec) plus external
 * SRT / ASS / SSA / WebVTT files read through the same transport layer as the
 * video (so SMB sidecar subtitles work without a local copy).
 *
 * Rendering happens in Flutter: the core emits styled text runs, which keeps
 * typography crisp at any resolution and lets the UI scale with the system font
 * settings.  Graphics subtitles (PGS / VobSub / DVB) carry no text at all: their
 * rectangles are decoded into RGBA and blended onto the converted video picture
 * by the platform renderer, so every host that shows the picture gets them.
 */
#include <ctype.h>
#include <limits.h>
#include <stdlib.h>
#include <strings.h>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

#if defined(LP_HAVE_ICONV)
#include <iconv.h>
#endif

#include "player_internal.h"

#define LP_SUB_MAX_CUES 200000

/* --------------------------------------------------------------- helpers --- */

/* Context needed to turn ASS script coordinates into something the UI can
 * position: PlayResX/PlayResY from the [Script Info] header. */
typedef struct AssCtx {
    double play_w;
    double play_h;
    const LpSubStyle *base;
} AssCtx;

static int sub_compile_text(const char *in, LpSubCue *cue, const AssCtx *ctx);
static int track_add_cue_full(LpSubtitleTrack *t, LpSubCue *src);


/* -------------------------------------------------------- graphics overlay --- */

/* The overlay owns copies of the rects so that history trimming, a seek or a
 * track switch can free cues without the render thread ever reading freed
 * memory.  subtitle.c updates it under p->subs.mutex; the renderer takes the
 * same lock, reads what it needs and blends outside of it. */
static void overlay_reset(LpSubOverlay *ov)
{
    for (int i = 0; i < ov->nb; i++) {
        free(ov->rects[i].rgba);
        ov->rects[i].rgba = NULL;
    }
    ov->nb = 0;
    ov->first = -1;
    ov->count = 0;
    ov->version++;
}

static void cue_free(LpSubCue *c)
{
    free(c->text);
    c->text = NULL;
    for (int i = 0; i < c->nb_runs; i++) {
        free(c->runs[i].text);
    }
    free(c->runs);
    c->runs = NULL;
    c->nb_runs = 0;
    for (int i = 0; i < c->nb_bitmaps; i++) {
        free(c->bitmaps[i].rgba);
    }
    free(c->bitmaps);
    c->bitmaps = NULL;
    c->nb_bitmaps = 0;
}

/* Copies a cue's rectangles into the overlay so the renderer stays valid
 * while cues come and go. */
static int overlay_add(LpSubOverlay *ov, LpSubCue *c)
{
    int added = 0;
    for (int i = 0; i < c->nb_bitmaps; i++) {
        if (ov->nb >= LP_SUB_OVERLAY_MAX) {
            break;
        }
        LpSubBitmap *b = &c->bitmaps[i];
        if (b->w <= 0 || b->h <= 0 || !b->rgba) {
            continue;
        }
        size_t bytes = (size_t)b->w * (size_t)b->h * 4;
        uint8_t *copy = malloc(bytes);
        if (!copy) {
            return -1;
        }
        memcpy(copy, b->rgba, bytes);
        LpSubOverlayRect *r = &ov->rects[ov->nb];
        r->x = b->x;
        r->y = b->y;
        r->w = b->w;
        r->h = b->h;
        r->rgba = copy;
        ov->nb++;
        added++;
    }
    if (added) {
        ov->version++;
    }
    return 0;
}

/* Rebuilds the overlay from the cues that are on screen at t_now.  Called with
 * p->subs.mutex held. */
static void overlay_update(LpPlayer *p, LpSubtitleTrack *t, int64_t t_now)
{
    LpSubOverlay *ov = &p->subs.overlay;
    int want = 0;
    for (int i = 0; i < t->nb_cues; i++) {
        LpSubCue *c = &t->cues[i];
        if (c->start_us > t_now) {
            break;
        }
        if (t_now < c->end_us && c->nb_bitmaps > 0) {
            want++;
        }
    }
    if (want == 0) {
        ov->first = -1;
        ov->count = 0;
        if (ov->nb > 0) {
            overlay_reset(ov);
        }
        return;
    }
    int first = -1;
    for (int i = 0; i < t->nb_cues; i++) {
        LpSubCue *c = &t->cues[i];
        if (c->start_us > t_now) {
            break;
        }
        if (t_now < c->end_us && c->nb_bitmaps > 0) {
            first = i;
            break;
        }
    }
    /* The tick runs on every frame; rebuilding the overlay (and copying every
     * rectangle) only when the active set actually changes keeps a 2 hour movie
     * cheap. */
    if (first == ov->first && want == ov->count && ov->ref_w == t->ref_w &&
        ov->ref_h == t->ref_h) {
        return;
    }
    overlay_reset(ov);
    ov->first = first;
    ov->count = want;
    ov->ref_w = t->ref_w;
    ov->ref_h = t->ref_h;
    for (int i = 0; i < t->nb_cues; i++) {
        LpSubCue *c = &t->cues[i];
        if (c->start_us > t_now) {
            break;
        }
        if (t_now >= c->end_us || c->nb_bitmaps == 0) {
            continue;
        }
        if (overlay_add(ov, c) != 0) {
            overlay_reset(ov);
            return;
        }
    }
    LP_DEBUG("subtitle", "graphics overlay: %d rect(s)", ov->nb);
}

/* Straight-alpha blend of the graphics overlay onto a BGRA picture.  The video
 * frame is letterbox-scaled by the host, so the rects are scaled by the same
 * factor here: they arrive in the decoder's reference grid. */
/* True when a graphics subtitle is on screen right now.  The GPU output path
 * cannot blend those (they are CPU bitmaps), so it asks for the download path
 * instead while this returns non-zero. */
int lp_render_graphics_sub_active(LpPlayer *p)
{
    if (!p || p->subs_inited == 0) {
        return 0;
    }
    int active;
    pthread_mutex_lock(&p->subs.mutex);
    active = p->subs.overlay.nb > 0 ? 1 : 0;
    pthread_mutex_unlock(&p->subs.mutex);
    return active;
}

void lp_sub_overlay_blend(LpPlayer *p, uint8_t *bgra, int w, int h, int stride)
{
    if (!bgra || w <= 0 || h <= 0 || stride < w * 4 || p->subs_inited == 0) {
        return;
    }
    if (getenv("LP_NO_GRAPHIC_SUB")) { /* debug switch: A/B the compositor */
        return;
    }
    LpSubOverlayRect snap[LP_SUB_OVERLAY_MAX];
    int nb = 0;
    int ref_w = 0, ref_h = 0;
    int64_t painted = 0;
    pthread_mutex_lock(&p->subs.mutex);
    LpSubOverlay *ov = &p->subs.overlay;
    if (ov->nb > 0) {
        nb = ov->nb < LP_SUB_OVERLAY_MAX ? ov->nb : LP_SUB_OVERLAY_MAX;
        ref_w = ov->ref_w;
        ref_h = ov->ref_h;
        for (int i = 0; i < nb; i++) {
            snap[i] = ov->rects[i]; /* deep copy by hand below */
            snap[i].rgba = malloc((size_t)ov->rects[i].w * ov->rects[i].h * 4);
            if (!snap[i].rgba) {
                nb = i;
                break;
            }
            memcpy(snap[i].rgba, ov->rects[i].rgba,
                   (size_t)ov->rects[i].w * ov->rects[i].h * 4);
        }
    }
    pthread_mutex_unlock(&p->subs.mutex);
    if (nb == 0) {
        return;
    }
    double sx = ref_w > 0 ? (double)w / ref_w : 1.0;
    double sy = ref_h > 0 ? (double)h / ref_h : 1.0;
    for (int k = 0; k < nb; k++) {
        LpSubOverlayRect *r = &snap[k];
        int dw = (int)(r->w * sx + 0.5);
        int dh = (int)(r->h * sy + 0.5);
        int dx = (int)(r->x * sx + 0.5);
        int dy = (int)(r->y * sy + 0.5);
        if (dw <= 0 || dh <= 0) {
            free(r->rgba);
            continue;
        }
        for (int y = 0; y < dh; y++) {
            int ty = dy + y;
            if (ty < 0 || ty >= h) {
                continue;
            }
            int syi = (int)((int64_t)y * r->h / dh);
            if (syi >= r->h) syi = r->h - 1;
            uint8_t *dst_row = bgra + (size_t)ty * stride;
            const uint8_t *src_row = r->rgba + (size_t)syi * r->w * 4;
            for (int x = 0; x < dw; x++) {
                int tx = dx + x;
                if (tx < 0 || tx >= w) {
                    continue;
                }
                int sxi = (int)((int64_t)x * r->w / dw);
                if (sxi >= r->w) sxi = r->w - 1;
                const uint8_t *s = src_row + (size_t)sxi * 4;
                unsigned a = s[3];
                if (a == 0) {
                    continue;
                }
                painted++;
                uint8_t *d = dst_row + (size_t)tx * 4;
                if (a == 255) {
                    d[0] = s[2];
                    d[1] = s[1];
                    d[2] = s[0];
                    d[3] = 255;
                } else {
                    d[0] = (uint8_t)((s[2] * a + d[0] * (255 - a)) / 255);
                    d[1] = (uint8_t)((s[1] * a + d[1] * (255 - a)) / 255);
                    d[2] = (uint8_t)((s[0] * a + d[2] * (255 - a)) / 255);
                    d[3] = (uint8_t)(a + (d[3] * (255 - a)) / 255);
                }
            }
        }
        free(r->rgba);
    }
    LP_DEBUG("subtitle", "blended %d rect(s), %lld px onto %dx%d", nb,
             (long long)painted, w, h);
}

/* Graphics subtitle rectangles arrive as an 8-bit palette index plane plus a
 * 0xAARRGGBB palette.  Flatten one rect into the RGBA form the compositor
 * needs; the alpha channel is what makes the picture show through. */
static int bitmap_from_rect(const AVSubtitleRect *r, LpSubBitmap *out)
{
    if (!r || r->type != SUBTITLE_BITMAP || !r->data[0] || !r->data[1]) {
        return -1;
    }
    if (r->w <= 0 || r->h <= 0 || r->linesize[0] < r->w) {
        return -1;
    }
    size_t bytes = (size_t)r->w * (size_t)r->h * 4;
    uint8_t *rgba = malloc(bytes);
    if (!rgba) {
        return -1;
    }
    const uint8_t *pal = r->data[1];
    for (int y = 0; y < r->h; y++) {
        const uint8_t *src = r->data[0] + (size_t)y * r->linesize[0];
        uint8_t *dst = rgba + (size_t)y * r->w * 4;
        for (int x = 0; x < r->w; x++) {
            const uint8_t *e = pal + (size_t)src[x] * 4;
            /* palette entries are 0xAARRGGBB in little-endian byte order */
            dst[0] = e[2];
            dst[1] = e[1];
            dst[2] = e[0];
            dst[3] = e[3];
            dst += 4;
        }
    }
    out->x = r->x;
    out->y = r->y;
    out->w = r->w;
    out->h = r->h;
    out->rgba = rgba;
    return 0;
}

static int cue_add_bitmap(LpSubCue *c, LpSubBitmap *b)
{
    int cap = c->nb_bitmaps;
    LpSubBitmap *grown = realloc(c->bitmaps, (size_t)(cap + 1) * sizeof(LpSubBitmap));
    if (!grown) {
        return -1;
    }
    c->bitmaps = grown;
    c->bitmaps[cap] = *b;
    c->nb_bitmaps = cap + 1;
    return 0;
}

static void track_reset(LpSubtitleTrack *t)
{
    for (int i = 0; i < t->nb_cues; i++) {
        cue_free(&t->cues[i]);
    }
    t->nb_cues = 0;
    t->current_cue = -1;
    free(t->styles);
    t->styles = NULL;
    t->nb_styles = 0;
}

static int track_ensure_style(LpSubtitleTrack *t, int need)
{
    if (t->nb_styles >= need) {
        return 0;
    }
    int cap = need + 4;
    LpSubStyle *grown = realloc(t->styles, (size_t)cap * sizeof(LpSubStyle));
    if (!grown) {
        return -1;
    }
    t->styles = grown;
    return 0;
}

static void style_default(LpSubStyle *s)
{
    memset(s, 0, sizeof(*s));
    snprintf(s->name, sizeof(s->name), "Default");
    s->color = 0xFFFFFFFF;
    s->outline_color = 0xFF000000;
    s->back_color = 0xFF000000;
    s->outline_width = 1;
    s->shadow = 0;
    s->border_style = 1;
    s->spacing = 0.0;
    s->scale_x = 100.0;
    s->scale_y = 100.0;
    s->angle = 0.0;
    s->margin_l = 0.0;
    s->margin_r = 0.0;
    s->margin_v = 0.0;
    s->align = 2;
    s->pos_x = -1.0;
    s->pos_y = -1.0;
    s->font_scale = 0.05;
    s->play_res_y = 1080.0;
    snprintf(s->font_name, sizeof(s->font_name), "sans-serif");
}

static LpSubStyle *track_style(LpSubtitleTrack *t, int idx)
{
    if (t->nb_styles == 0) {
        if (track_ensure_style(t, 1) != 0) {
            return NULL;
        }
        style_default(&t->styles[0]);
        t->nb_styles = 1;
    }
    if (idx < 0 || idx >= t->nb_styles) {
        return &t->styles[0];
    }
    return &t->styles[idx];
}

/* Appends a pre-compiled cue: text, styled runs and bitmaps are moved out of
 * *src.  A graphics cue (bitmaps only) is valid without any text. */
static int track_add_cue_full(LpSubtitleTrack *t, LpSubCue *src)
{
    int has_text = src->text && *src->text;
    if (!has_text && src->nb_bitmaps == 0) {
        return -1;
    }
    if (src->end_us <= src->start_us) {
        return -1;
    }
    if (t->nb_cues >= LP_SUB_MAX_CUES) {
        return -1;
    }
    if (t->nb_cues == t->cap_cues) {
        int cap = t->cap_cues ? t->cap_cues * 2 : 64;
        LpSubCue *grown = realloc(t->cues, (size_t)cap * sizeof(LpSubCue));
        if (!grown) {
            return -1;
        }
        t->cues = grown;
        t->cap_cues = cap;
    }
    t->cues[t->nb_cues++] = *src;
    memset(src, 0, sizeof(*src));
    return 0;
}

static int cue_cmp(const void *a, const void *b)
{
    const LpSubCue *ca = a;
    const LpSubCue *cb = b;
    if (ca->start_us != cb->start_us) {
        return ca->start_us < cb->start_us ? -1 : 1;
    }
    return ca->end_us < cb->end_us ? -1 : (ca->end_us > cb->end_us ? 1 : 0);
}

/* UTF-16 -> UTF-8 (BOM already consumed). */
static char *utf16_to_utf8(const uint8_t *data, size_t len, int big_endian)
{
    LpStr out;
    lp_str_init(&out);
    for (size_t i = 0; i + 1 < len; i += 2) {
        unsigned u = big_endian ? ((unsigned)data[i] << 8) | data[i + 1]
                                : ((unsigned)data[i + 1] << 8) | data[i];
        if (u == 0) {
            continue;
        }
        if (u >= 0xD800 && u <= 0xDBFF && i + 3 < len) {
            unsigned lo = big_endian ? ((unsigned)data[i + 2] << 8) | data[i + 3]
                                     : ((unsigned)data[i + 3] << 8) | data[i + 2];
            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
                i += 2;
            }
        }
        char buf[8] = {0};
        if (u < 0x80) {
            buf[0] = (char)u;
        } else if (u < 0x800) {
            buf[0] = (char)(0xC0 | (u >> 6));
            buf[1] = (char)(0x80 | (u & 0x3F));
        } else if (u < 0x10000) {
            buf[0] = (char)(0xE0 | (u >> 12));
            buf[1] = (char)(0x80 | ((u >> 6) & 0x3F));
            buf[2] = (char)(0x80 | (u & 0x3F));
        } else {
            buf[0] = (char)(0xF0 | (u >> 18));
            buf[1] = (char)(0x80 | ((u >> 12) & 0x3F));
            buf[2] = (char)(0x80 | ((u >> 6) & 0x3F));
            buf[3] = (char)(0x80 | (u & 0x3F));
        }
        lp_str_append(&out, "%s", buf);
    }
    return lp_str_take(&out);
}

static int is_valid_utf8(const uint8_t *s, size_t len)
{
    size_t i = 0;
    while (i < len) {
        uint8_t c = s[i];
        if (c < 0x80) {
            i++;
            continue;
        }
        int need;
        if ((c & 0xE0) == 0xC0) {
            need = 1;
        } else if ((c & 0xF0) == 0xE0) {
            need = 2;
        } else if ((c & 0xF8) == 0xF0) {
            need = 3;
        } else {
            return 0;
        }
        if (i + (size_t)need >= len) {
            return 0;
        }
        for (int k = 1; k <= need; k++) {
            if ((s[i + (size_t)k] & 0xC0) != 0x80) {
                return 0;
            }
        }
        i += (size_t)need + 1;
    }
    return 1;
}

#if defined(LP_HAVE_ICONV)
static char *iconv_to_utf8(const char *from, const uint8_t *data, size_t len, size_t *out_len)
{
    iconv_t cd = iconv_open("UTF-8", from);
    if (cd == (iconv_t)-1) {
        return NULL;
    }
    size_t cap = len * 4 + 16;
    char *out = malloc(cap);
    if (!out) {
        iconv_close(cd);
        return NULL;
    }
    char *inp = (char *)data;
    size_t inleft = len;
    char *outp = out;
    size_t outleft = cap - 1;
    size_t r = iconv(cd, &inp, &inleft, &outp, &outleft);
    iconv_close(cd);
    if (r == (size_t)-1 && inleft > 0) {
        /* Keep the prefix that converted; caller sees a warning. */
        LP_WARN("subtitle", "charset conversion from %s stopped at %zu bytes", from, inleft);
    }
    *outp = '\0';
    *out_len = (size_t)(outp - out);
    return out;
}
#endif

#if defined(_WIN32)
/* Windows without iconv: MultiByteToWideChar covers the legacy subtitle
 * encodings that actually show up in the wild (GBK from Chinese releases,
 * Shift-JIS from Japanese ones, CP949 from Korean ones) plus the Windows
 * ANSI code page. */
static char *win_codepage_to_utf8(UINT cp, const uint8_t *data, size_t len, size_t *out_len)
{
    if (len == 0 || len > (size_t)INT_MAX / 2) {
        return NULL;
    }
    int wlen = MultiByteToWideChar(cp, 0, (const char *)data, (int)len, NULL, 0);
    if (wlen <= 0) {
        return NULL;
    }
    wchar_t *wbuf = malloc(((size_t)wlen + 1) * sizeof(wchar_t));
    if (!wbuf) {
        return NULL;
    }
    if (MultiByteToWideChar(cp, 0, (const char *)data, (int)len, wbuf, wlen) != wlen) {
        free(wbuf);
        return NULL;
    }
    int ulen = WideCharToMultiByte(CP_UTF8, 0, wbuf, wlen, NULL, 0, NULL, NULL);
    if (ulen <= 0) {
        free(wbuf);
        return NULL;
    }
    char *out = malloc((size_t)ulen + 1);
    if (!out) {
        free(wbuf);
        return NULL;
    }
    WideCharToMultiByte(CP_UTF8, 0, wbuf, wlen, out, ulen, NULL, NULL);
    free(wbuf);
    out[ulen] = '\0';
    *out_len = (size_t)ulen;
    return out;
}
#endif

/* Returns a NUL terminated UTF-8 buffer (malloc). */
static char *decode_text(const uint8_t *raw, size_t len, size_t *out_len, int *charset_ok)
{
    if (charset_ok) {
        *charset_ok = 1;
    }
    if (len >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF) {
        raw += 3;
        len -= 3;
    } else if (len >= 2 && raw[0] == 0xFF && raw[1] == 0xFE) {
        return utf16_to_utf8(raw + 2, len - 2, 0);
    } else if (len >= 2 && raw[0] == 0xFE && raw[1] == 0xFF) {
        return utf16_to_utf8(raw + 2, len - 2, 1);
    }
    if (!is_valid_utf8(raw, len)) {
#if defined(LP_HAVE_ICONV)
        size_t n = 0;
        char *conv = iconv_to_utf8("GB18030", raw, len, &n);
        if (conv) {
            return conv;
        }
        conv = iconv_to_utf8("WINDOWS-1252", raw, len, &n);
        if (conv) {
            return conv;
        }
#elif defined(_WIN32)
        /* Ordered by how often each shows up in downloaded subtitles.  The
         * result is accepted when the round trip is lossless enough: a
         * successful conversion always yields valid UTF-8, so the only risk is
         * picking the wrong legacy code page for a file that happens to be
         * ambiguous; GBK is by far the most likely for this app's audience. */
        static const UINT pages[] = {54936 /* GB18030 */, 936 /* GBK */, 950 /* Big5 */,
                                     932 /* Shift-JIS */, 949 /* Korean */, 0 /* ANSI */};
        for (size_t i = 0; i < sizeof(pages) / sizeof(pages[0]); i++) {
            size_t n = 0;
            char *conv = win_codepage_to_utf8(pages[i], raw, len, &n);
            if (conv) {
                if (n > 0 && is_valid_utf8((const uint8_t *)conv, n)) {
                    LP_DEBUG("subtitle", "decoded %zu bytes with code page %u", len,
                             (unsigned)pages[i]);
                    return conv;
                }
                free(conv);
            }
        }
#endif
        if (charset_ok) {
            *charset_ok = 0;
        }
    }
    char *out = malloc(len + 1);
    if (!out) {
        return NULL;
    }
    memcpy(out, raw, len);
    out[len] = '\0';
    if (out_len) {
        *out_len = len;
    }
    return out;
}

/* ------------------------------------------------------------- rich text --- */

static uint32_t ass_color(const char *v);

/* ASS override tags are inline style switches: {\b1}bold{\b0}normal.  Rather
 * than throwing them away (v1 behaviour) we compile a cue into a list of
 * styled runs, which the Flutter overlay renders as TextSpans.  Everything
 * that only affects layout we cannot reproduce (rotation, clipping, blur) is
 * parsed and ignored, which keeps the text itself correct. */

typedef struct SubRunState {
    unsigned flags;
    uint32_t color;         /* 0 = inherit the cue style */
    uint32_t outline_color; /* 0 = inherit; \3c targets this slot */
    uint32_t back_color;    /* 0 = inherit; \4c targets this slot */
    double font_scale; /* 0 = inherit the cue style */
    double scale_x;    /* percent, 0 = inherit */
    double scale_y;    /* percent, 0 = inherit */
    double spacing;    /* script units, 0 = inherit */
    double angle;      /* degrees, 0 = inherit */
    int border;        /* script units, -1 = inherit */
    int shadow;        /* script units, -1 = inherit */
    char font_name[64]; /* empty = inherit the cue style */
} SubRunState;

typedef struct SubRich {
    LpSubCue *cue;
    LpStr plain;
    LpSubRun *runs;
    int nb;
    int cap;
    SubRunState st;
    int drawing; /* inside {\p1} vector drawing: text is coordinates */
} SubRich;

static void sub_rich_init(SubRich *b, LpSubCue *cue)
{
    memset(b, 0, sizeof(*b));
    b->cue = cue;
    /* -1 means "inherit the cue style" for the numeric decorations, so an
     * absent {\bord} cannot be confused with an explicit {\bord0}. */
    b->st.border = -1;
    b->st.shadow = -1;
    lp_str_init(&b->plain);
}

static void sub_rich_free(SubRich *b)
{
    lp_str_free(&b->plain);
    for (int i = 0; i < b->nb; i++) {
        free(b->runs[i].text);
    }
    free(b->runs);
    b->runs = NULL;
    b->nb = b->cap = 0;
}

static int sub_rich_append(SubRich *b, const char *text, size_t len)
{
    if (len == 0) {
        return 0;
    }
    if (b->plain.len >= LP_MAX_TEXT_BYTES) {
        return 0;
    }
    if (b->plain.len + (int)len > LP_MAX_TEXT_BYTES) {
        len = (size_t)(LP_MAX_TEXT_BYTES - b->plain.len);
    }
    lp_str_append(&b->plain, "%.*s", (int)len, text);
    if (b->nb > 0) {
        LpSubRun *last = &b->runs[b->nb - 1];
        if (last->flags == b->st.flags && last->color == b->st.color &&
            last->outline_color == b->st.outline_color &&
            last->back_color == b->st.back_color &&
            last->font_scale == b->st.font_scale &&
            !strcmp(last->font_name, b->st.font_name)) {
            size_t old = strlen(last->text);
            char *grown = realloc(last->text, old + len + 1);
            if (!grown) {
                return -1;
            }
            memcpy(grown + old, text, len);
            grown[old + len] = '\0';
            last->text = grown;
            return 0;
        }
    }
    if (b->nb == b->cap) {
        int cap = b->cap ? b->cap * 2 : 8;
        LpSubRun *grown = realloc(b->runs, (size_t)cap * sizeof(LpSubRun));
        if (!grown) {
            return -1;
        }
        b->runs = grown;
        b->cap = cap;
    }
    LpSubRun *r = &b->runs[b->nb];
    memset(r, 0, sizeof(*r));
    r->text = malloc(len + 1);
    if (!r->text) {
        return -1;
    }
    memcpy(r->text, text, len);
    r->text[len] = '\0';
    r->flags = b->st.flags;
    r->color = b->st.color;
    r->outline_color = b->st.outline_color;
    r->back_color = b->st.back_color;
    r->font_scale = b->st.font_scale;
    r->scale_x = b->st.scale_x;
    r->scale_y = b->st.scale_y;
    r->spacing = b->st.spacing;
    r->angle = b->st.angle;
    r->border = b->st.border;
    r->shadow = b->st.shadow;
    snprintf(r->font_name, sizeof(r->font_name), "%s", b->st.font_name);
    b->nb++;
    return 0;
}

/* Reads an optional decimal number.  Returns 0 and sets *out, or -1 when the
 * tag has no argument (ASS treats a bare \b as bold). */
static int tag_number(const char **pp, double *out)
{
    const char *p = *pp;
    while (*p == ' ') {
        p++;
    }
    char buf[32];
    size_t n = 0;
    if ((*p == '-' || *p == '+') && n + 1 < sizeof(buf)) {
        buf[n++] = *p++;
    }
    while ((isdigit((unsigned char)*p) || *p == '.') && n + 1 < sizeof(buf)) {
        buf[n++] = *p++;
    }
    buf[n] = '\0';
    *pp = p;
    if (n == 0) {
        return -1;
    }
    *out = atof(buf);
    return 0;
}

static int tag_has_arg(const char *p)
{
    return isdigit((unsigned char)*p) || *p == '-' || *p == '+' || *p == '.';
}

/* {\b1\i1\c&H0000FF&\fs48\an8\pos(960,80)} -> run state / cue overrides. */
static void apply_override(const char *tags, const AssCtx *ctx, SubRich *b)
{
    const char *p = tags;
    while (*p) {
        if (*p == '{' || *p == '}') {
            p++;
            continue;
        }
        if (*p != '\\') {
            p++;
            continue;
        }
        p++;
        /* \1c, \2c, \3c, \4c carry a channel digit before the command letter;
         * each one targets a different colour slot, so the digit has to be
         * remembered rather than skipped.  \1a..\4a work the same way. */
        int channel = 0;
        if (isdigit((unsigned char)*p) && (p[1] == 'c' || p[1] == 'a')) {
            channel = *p - '0';
            p++;
        }
        char cmd = *p;
        if (cmd == '\0') {
            break;
        }
        p++;
        double num = 0;
        switch (cmd) {
        case 'b':
            /* \b1 bold; \bord<w> outline width; \blur is unsupported. */
            if (!strncmp(p, "ord", 3)) {
                p += 3;
                if (tag_number(&p, &num) == 0 && num >= 0) {
                    b->st.border = (int)(num + 0.5);
                }
            } else if (!strncmp(p, "lur", 3)) {
                p += 3;
                double ignored = 0;
                tag_number(&p, &ignored);
            } else {
                b->st.flags = tag_number(&p, &num) == 0 && num == 0
                                  ? (b->st.flags & ~LP_SUB_BOLD)
                                  : (b->st.flags | LP_SUB_BOLD);
            }
            break;
        case 'i':
            b->st.flags = tag_number(&p, &num) == 0 && num == 0
                              ? (b->st.flags & ~LP_SUB_ITALIC)
                              : (b->st.flags | LP_SUB_ITALIC);
            break;
        case 'u':
            b->st.flags = tag_number(&p, &num) == 0 && num == 0
                              ? (b->st.flags & ~LP_SUB_UNDERLINE)
                              : (b->st.flags | LP_SUB_UNDERLINE);
            break;
        case 's':
            /* \s0 / \s1 is strikeout; \shad<d> is the shadow offset. */
            if (!strncmp(p, "had", 3)) {
                p += 3;
                if (tag_number(&p, &num) == 0 && num >= 0) {
                    b->st.shadow = (int)(num + 0.5);
                }
            } else if (!strncmp(p, "pacing", 6)) {
                p += 6;
                if (tag_number(&p, &num) == 0) {
                    b->st.spacing = num;
                }
            } else if (tag_has_arg(p)) {
                if (tag_number(&p, &num) == 0) {
                    b->st.flags = num == 0 ? (b->st.flags & ~LP_SUB_STRIKEOUT)
                                           : (b->st.flags | LP_SUB_STRIKEOUT);
                }
            } else {
                while (*p && *p != '\\' && *p != '}') {
                    p++;
                }
            }
            break;
        case 'c': {
            const char *start = p;
            while (*p && *p != '\\' && *p != '}') {
                p++;
            }
            char color[32];
            size_t n = (size_t)(p - start);
            if (n >= sizeof(color)) {
                n = sizeof(color) - 1;
            }
            memcpy(color, start, n);
            color[n] = '\0';
            /* ASS 的四个通道各有归属：\1c 主色、\2c 次色、\3c 描边、
             * \4c 背景（\3c 最常用，写成 {\3c&H...&} 是给描边上色的标准
             * 做法，不能被当成主色）。 */
            uint32_t parsed = n ? ass_color(color) : 0;
            if (parsed == 0xFFFFFFFF) {
                parsed = 0; /* \c&HFFFFFF& is the default: inherit */
            }
            switch (channel) {
            case 2:
                /* \2c is the "secondary colour" used by karaoke fills; the
                 * renderer has nowhere to put it, so it must not touch the
                 * text colour. */
                break;
            case 3:
                b->st.outline_color = parsed;
                break;
            case 4:
                b->st.back_color = parsed;
                break;
            default:
                b->st.color = parsed;
                break;
            }
            break;
        }
        case 'f':
            /* \fs48 (size), \fscx/\fscy (scale), \fn<name> (family),
             * \frz/\frx/\fry (rotation) */
            if (!strncmp(p, "scx", 3)) {
                p += 3;
                if (tag_number(&p, &num) == 0 && num > 0) {
                    b->st.scale_x = num;
                }
            } else if (!strncmp(p, "scy", 3)) {
                p += 3;
                if (tag_number(&p, &num) == 0 && num > 0) {
                    b->st.scale_y = num;
                }
            } else if (!strncmp(p, "rz", 2) || !strncmp(p, "rx", 2) ||
                       !strncmp(p, "ry", 2)) {
                /* Only the in-plane rotation (\frz / \fr) can be honoured by a
                 * 2D text layout; \frx / \fry tilt out of plane and are read
                 * only to keep the parser in sync. */
                int planar = p[1] == 'z';
                p += 2;
                if (tag_number(&p, &num) == 0 && planar) {
                    b->st.angle = num;
                }
            } else if (!strncmp(p, "r", 1) && !tag_has_arg(p + 1)) {
                /* \fr without a suffix is the same as \frz. */
                p += 1;
                if (tag_number(&p, &num) == 0) {
                    b->st.angle = num;
                }
            } else if (*p == 's' && tag_has_arg(p + 1)) {
                p++;
                if (tag_number(&p, &num) == 0 && num > 0 && ctx->play_h > 0) {
                    b->st.font_scale = num / ctx->play_h;
                }
            } else if (*p == 'n') {
                /* \fnArial / \fn新宋体: the family runs to the next tag or the
                 * end of the override block.  A bare \fn resets to the style. */
                p++;
                const char *start = p;
                while (*p && *p != '\\' && *p != '}') {
                    p++;
                }
                size_t n = (size_t)(p - start);
                if (n >= sizeof(b->st.font_name)) {
                    n = sizeof(b->st.font_name) - 1;
                }
                memcpy(b->st.font_name, start, n);
                b->st.font_name[n] = '\0';
            } else {
                while (*p && *p != '\\' && *p != '}' && *p != '(') {
                    p++;
                }
            }
            break;
        case 'a':
            /* \an1..9 (alignment), \alpha (transparency), \a (legacy) */
            if (*p == 'n') {
                p++;
                if (tag_number(&p, &num) == 0) {
                    int a = (int)num;
                    if (a >= 1 && a <= 9) {
                        b->cue->align_override = a;
                    }
                }
            } else {
                while (*p && *p != '\\' && *p != '}') {
                    p++;
                }
            }
            break;
        case 'p':
            if (!strncmp(p, "os(", 3)) {
                /* \pos(x,y) in script resolution units. */
                p += 3;
                double x = 0, y = 0;
                if (tag_number(&p, &x) == 0 && *p == ',') {
                    p++;
                    if (tag_number(&p, &y) == 0 && ctx->play_w > 0 && ctx->play_h > 0) {
                        b->cue->pos_x = x / ctx->play_w;
                        b->cue->pos_y = y / ctx->play_h;
                    }
                }
                while (*p && *p != ')' && *p != '\\' && *p != '}') {
                    p++;
                }
                if (*p == ')') {
                    p++;
                }
                break;
            }
            if (tag_number(&p, &num) == 0) {
                b->drawing = num != 0;
            }
            break;
        case 'r': {
            /* \r resets to the line style, \rStyle to a named style. */
            const char *start = p;
            while (*p && *p != '\\' && *p != '}') {
                p++;
            }
            size_t n = (size_t)(p - start);
            char name[64];
            if (n >= sizeof(name)) {
                n = sizeof(name) - 1;
            }
            memcpy(name, start, n);
            name[n] = '\0';
            b->st.flags = 0;
            b->st.color = 0;
            b->st.outline_color = 0;
            b->st.back_color = 0;
            b->st.font_scale = 0;
            b->st.scale_x = 0;
            b->st.scale_y = 0;
            b->st.spacing = 0;
            b->st.angle = 0;
            b->st.border = -1;
            b->st.shadow = -1;
            b->st.font_name[0] = '\0';
            b->cue->align_override = 0;
            (void)name; /* named style switching is left to the cue style */
            break;
        }
        default:
            /* \move, \t, \clip and friends: skip their argument so the
             * digits are not mistaken for a tag. */
            while (*p && *p != '\\' && *p != '}') {
                if (*p == '(') {
                    int depth = 0;
                    while (*p) {
                        if (*p == '(') depth++;
                        if (*p == ')') {
                            depth--;
                            if (depth == 0) {
                                p++;
                                break;
                            }
                        }
                        p++;
                    }
                    continue;
                }
                p++;
            }
            break;
        }
    }
}


/* Compiles one dialogue body into cue->text plus (when the line actually
 * changes style mid-sentence) cue->runs.  Returns 0, or -1 on OOM. */
static int sub_compile_text(const char *in, LpSubCue *cue, const AssCtx *ctx)
{
    SubRich b;
    sub_rich_init(&b, cue);
    int rc = 0;
    const char *p = in;
    while (*p) {
        if (*p == '{') {
            const char *close = strchr(p, '}');
            if (close) {
                char *tags = malloc((size_t)(close - p) + 2);
                if (!tags) {
                    rc = -1;
                    break;
                }
                tags[0] = '{';
                memcpy(tags + 1, p, (size_t)(close - p));
                tags[close - p + 1] = '\0';
                apply_override(tags, ctx, &b);
                free(tags);
                p = close + 1;
                continue;
            }
            p++;
            continue;
        }
        if (*p == '\\' && (p[1] == 'N' || p[1] == 'n' || p[1] == 'h')) {
            char ch = p[1] == 'h' ? ' ' : '\n';
            if (!b.drawing && sub_rich_append(&b, &ch, 1) != 0) {
                rc = -1;
                break;
            }
            p += 2;
            continue;
        }
        if (*p == '<') {
            /* WebVTT/HTML style tags: <i>, <b>, </i>, <font ...>. */
            const char *close = strchr(p, '>');
            if (close) {
                size_t n = (size_t)(close - p);
                const char *tg = p + 1;
                int closing = n > 1 && tg[0] == '/';
                if (closing) {
                    tg++;
                }
                if (!strncmp(tg, "i", 1)) {
                    b.st.flags = closing ? (b.st.flags & ~LP_SUB_ITALIC)
                                         : (b.st.flags | LP_SUB_ITALIC);
                } else if (!strncmp(tg, "b", 1)) {
                    b.st.flags = closing ? (b.st.flags & ~LP_SUB_BOLD)
                                         : (b.st.flags | LP_SUB_BOLD);
                } else if (!strncmp(tg, "u", 1)) {
                    b.st.flags = closing ? (b.st.flags & ~LP_SUB_UNDERLINE)
                                         : (b.st.flags | LP_SUB_UNDERLINE);
                }
                p = close + 1;
                continue;
            }
        }
        if (*p == '&' && !strncmp(p, "&nbsp;", 6)) {
            if (!b.drawing && sub_rich_append(&b, " ", 1) != 0) {
                rc = -1;
                break;
            }
            p += 6;
            continue;
        }
        if (*p == '\r' || *p == '\n') {
            if (!b.drawing && sub_rich_append(&b, "\n", 1) != 0) {
                rc = -1;
                break;
            }
            p++;
            continue;
        }
        const char *start = p;
        while (*p && *p != '{' && *p != '\\' && *p != '<' && *p != '&' &&
               *p != '\r' && *p != '\n') {
            p++;
        }
        if (p > start) {
            if (!b.drawing && sub_rich_append(&b, start, (size_t)(p - start)) != 0) {
                rc = -1;
                break;
            }
        } else {
            /* A lone backslash (not \N, \n, \h): keep the byte. */
            if (!b.drawing && sub_rich_append(&b, p, 1) != 0) {
                rc = -1;
                break;
            }
            p++;
        }
    }
    if (rc == 0) {
        /* Trailing blanks before a line break are invisible; dropping them
         * keeps the rendered block from growing a phantom gap. */
        for (int i = 0; i < b.nb; i++) {
            char *t = b.runs[i].text;
            size_t n = strlen(t);
            size_t w = 0;
            for (size_t k = 0; k < n; k++) {
                if (t[k] == '\n') {
                    while (w > 0 && (t[w - 1] == ' ' || t[w - 1] == '\t')) {
                        w--;
                    }
                }
                t[w++] = t[k];
            }
            while (w > 0 && (t[w - 1] == ' ' || t[w - 1] == '\t')) {
                w--;
            }
            t[w] = '\0';
        }
        /* Drop the runs entirely when nothing overrides the cue style. */
        int styled = 0;
        for (int i = 0; i < b.nb; i++) {
            if (b.runs[i].flags || b.runs[i].color || b.runs[i].outline_color ||
                b.runs[i].back_color || b.runs[i].font_scale != 0 ||
                b.runs[i].font_name[0]) {
                styled = 1;
                break;
            }
        }
        cue->text = lp_str_take(&b.plain);
        if (styled) {
            cue->runs = b.runs;
            cue->nb_runs = b.nb;
            b.runs = NULL;
            b.nb = b.cap = 0;
        }
    }
    sub_rich_free(&b);
    if (rc != 0) {
        free(cue->text);
        cue->text = NULL;
    }
    return rc;
}

/* Appends an already compiled cue to a builder that is collecting several
 * rectangles (an ASS packet can carry more than one line). */
static int merge_cue_into(SubRich *dst, LpSubCue *src)
{
    if (dst->plain.len > 0) {
        if (sub_rich_append(dst, "\n", 1) != 0) {
            return -1;
        }
    }
    if (src->nb_runs > 0 && src->runs) {
        for (int i = 0; i < src->nb_runs; i++) {
            dst->st.flags = src->runs[i].flags;
            dst->st.color = src->runs[i].color;
            dst->st.outline_color = src->runs[i].outline_color;
            dst->st.back_color = src->runs[i].back_color;
            dst->st.font_scale = src->runs[i].font_scale;
            snprintf(dst->st.font_name, sizeof(dst->st.font_name), "%s",
                     src->runs[i].font_name);
            if (sub_rich_append(dst, src->runs[i].text, strlen(src->runs[i].text)) != 0) {
                return -1;
            }
        }
    } else if (src->text) {
        dst->st.flags = 0;
        dst->st.color = 0;
        dst->st.outline_color = 0;
        dst->st.back_color = 0;
        dst->st.font_scale = 0;
        dst->st.font_name[0] = '\0';
        if (sub_rich_append(dst, src->text, strlen(src->text)) != 0) {
            return -1;
        }
    }
    dst->st.flags = 0;
    dst->st.color = 0;
    dst->st.outline_color = 0;
    dst->st.back_color = 0;
    dst->st.font_scale = 0;
    dst->st.font_name[0] = '\0';
    return 0;
}

static int parse_clock(const char *s, int64_t *us, char sep)
{
    int hh = 0, mm = 0, ss = 0, frac = 0, digits = 0;
    if (sscanf(s, "%d:%d:%d%c%d", &hh, &mm, &ss, &sep, &frac) < 5) {
        /* WebVTT allows the short "mm:ss.mmm" form. */
        hh = 0;
        mm = 0;
        ss = 0;
        frac = 0;
        if (sscanf(s, "%d:%d%c%d", &mm, &ss, &sep, &frac) < 4) {
            return -1;
        }
    }
    /* Count the fraction digits to know the scale. */
    const char *dot = s;
    while (*dot && *dot != '.' && *dot != ',') {
        dot++;
    }
    if (*dot) {
        for (const char *q = dot + 1; *q && isdigit((unsigned char)*q); q++) {
            digits++;
        }
    }
    int64_t ms = frac;
    if (digits == 2) {
        ms *= 10;
    } else if (digits == 3) {
        /* as is */
    } else if (digits > 3) {
        for (int i = 3; i < digits; i++) {
            ms /= 10;
        }
    }
    *us = ((int64_t)hh * 3600 + (int64_t)mm * 60 + ss) * 1000000 + ms * 1000;
    return 0;
}

/* ---------------------------------------------------------------- parsers --- */

/* Reads one line (without its terminator) and advances *pp past it. */
static int srt_next_line(const char **pp, char *buf, size_t cap)
{
    const char *p = *pp;
    if (!p || !*p) {
        return 0;
    }
    size_t n = 0;
    while (*p && *p != '\n' && *p != '\r') {
        if (n + 1 < cap) {
            buf[n++] = *p;
        }
        p++;
    }
    buf[n] = '\0';
    if (*p == '\r') {
        p++;
    }
    if (*p == '\n') {
        p++;
    }
    *pp = p;
    return 1;
}

static char *trim_ws(char *s)
{
    while (*s == ' ' || *s == '\t') {
        s++;
    }
    char *end = s + strlen(s);
    while (end > s && (end[-1] == ' ' || end[-1] == '\t')) {
        *--end = '\0';
    }
    return s;
}

/* SRT (and WebVTT, which shares the shape): a timing line followed by one or
 * more text lines, blank line terminated.  Index lines are simply skipped. */
static int parse_srt(const char *text, LpSubtitleTrack *t, char *err, size_t errlen)
{
    const char *p = text;
    char line[2048];
    LpStr body;
    lp_str_init(&body);
    int count = 0;

    while (srt_next_line(&p, line, sizeof(line))) {
        char *s = trim_ws(line);
        if (!*s || !strstr(s, "-->")) {
            continue;
        }
        char s1[64] = {0}, s2[64] = {0};
        int64_t start = 0, end = 0;
        if (sscanf(s, "%63s --> %63s", s1, s2) != 2) {
            continue;
        }
        if (parse_clock(s1, &start, ',') != 0 || parse_clock(s2, &end, ',') != 0) {
            LP_WARN("subtitle", "cannot parse timing line: %s", s);
            continue;
        }
        lp_str_reset(&body);
        while (srt_next_line(&p, line, sizeof(line))) {
            char *txt = trim_ws(line);
            if (!*txt) {
                break;
            }
            lp_str_append(&body, "%s\n", txt);
        }
        if (body.len > 0) {
            AssCtx ctx;
            memset(&ctx, 0, sizeof(ctx));
            ctx.base = track_style(t, 0);
            LpSubCue cue;
            memset(&cue, 0, sizeof(cue));
            cue.start_us = start;
            cue.end_us = end;
            cue.pos_x = -1.0;
            cue.pos_y = -1.0;
            cue.margin_l = -1.0;
            cue.margin_r = -1.0;
            cue.margin_v = -1.0;
            if (sub_compile_text(body.p ? body.p : "", &cue, &ctx) == 0 &&
                track_add_cue_full(t, &cue) == 0) {
                count++;
            } else {
                cue_free(&cue);
            }
        }
    }
    lp_str_free(&body);
    if (count == 0) {
        snprintf(err, errlen, "no subtitle cues parsed (SRT)");
        return -1;
    }
    return count;
}
static uint32_t ass_color(const char *v)
{
    /* &HAABBGGRR or decimal (BGR order, AA = alpha inverted).
     *
     * strtoul, not strtol: on Windows long is 32 bits, so every colour with an
     * alpha byte (everything from &H80000000 up, which is most of them) used to
     * overflow to LONG_MAX and come back as half-transparent white. */
    unsigned long raw = 0;
    if (!v || !*v) {
        return 0xFFFFFFFF;
    }
    if (v[0] == '&') {
        /* "&HAABBGGRR" and the shorter "&HBBGGRR": the H is part of the
         * literal, so it has to be skipped before strtoul sees hex digits. */
        const char *digits = v + 1;
        if (*digits == 'H' || *digits == 'h') {
            digits++;
        }
        char *end = NULL;
        raw = strtoul(digits, &end, 16);
        if (end == digits) {
            raw = 0;
        }
    } else {
        raw = strtoul(v, NULL, 10);
    }
    unsigned a = (unsigned)((raw >> 24) & 0xFF);
    unsigned b = (unsigned)((raw >> 16) & 0xFF);
    unsigned g = (unsigned)((raw >> 8) & 0xFF);
    unsigned r = (unsigned)(raw & 0xFF);
    unsigned alpha = 255 - a;
    return (alpha << 24) | (r << 16) | (g << 8) | b;
}

static void split_fields(char *line, char sep, char **fields, int max)
{
    int n = 0;
    fields[n++] = line;
    for (char *p = line; *p && n < max; p++) {
        if (*p == sep) {
            *p = '\0';
            fields[n++] = p + 1;
        }
    }
    for (int i = n; i < max; i++) {
        fields[i] = (char *)"";
    }
}

static int parse_ass(const char *text, LpSubtitleTrack *t, char *err, size_t errlen)
{
    char *copy = lp_str_dup(text);
    if (!copy) {
        return -1;
    }
    /* Style format map. */
    int f_name = -1, f_font = -1, f_size = -1, f_color = -1, f_bold = -1, f_italic = -1;
    int f_outline = -1, f_outcolor = -1, f_align = -1;
    int f_backcolor = -1, f_shadow = -1, f_border = -1, f_spacing = -1;
    int f_scalex = -1, f_scaley = -1, f_angle = -1;
    int f_ml = -1, f_mr = -1, f_mv = -1;
    char *e_name = NULL, *e_start = NULL, *e_end = NULL, *e_text = NULL, *e_style = NULL;
    int e_count = 0;
    int in_styles = 0, in_events = 0, count = 0;
    double play_w = 1920.0;
    double play_h = 1080.0;

    char *save = NULL;
    for (char *line = strtok_r(copy, "\r\n", &save); line; line = strtok_r(NULL, "\r\n", &save)) {
        while (*line == ' ' || *line == '\t') line++;
        if (!*line || *line == ';') {
            continue;
        }
        if (*line == '[') {
            in_styles = strncmp(line, "[V4+ Styles]", 12) == 0 || strncmp(line, "[V4 Styles]", 11) == 0;
            in_events = strncmp(line, "[Events]", 8) == 0;
            continue;
        }
        if (strncmp(line, "PlayResX:", 9) == 0) {
            play_w = atof(line + 9);
            if (play_w < 100) play_w = 1920.0;
            continue;
        }
        if (strncmp(line, "PlayResY:", 9) == 0) {
            play_h = atof(line + 9);
            if (play_h < 100) play_h = 1080.0;
            continue;
        }
        if (in_styles && strncmp(line, "Format:", 7) == 0) {
            char *fields[64];
            split_fields(line + 7, ',', fields, 64);
            for (int i = 0; i < 64; i++) {
                while (*fields[i] == ' ') fields[i]++;
                char *end = fields[i] + strlen(fields[i]);
                while (end > fields[i] && (end[-1] == ' ')) *--end = '\0';
                if (!strcmp(fields[i], "Name")) f_name = i;
                else if (!strcmp(fields[i], "Fontname")) f_font = i;
                else if (!strcmp(fields[i], "Fontsize")) f_size = i;
                else if (!strcmp(fields[i], "PrimaryColour")) f_color = i;
                else if (!strcmp(fields[i], "BackColour")) f_backcolor = i;
                else if (!strcmp(fields[i], "Bold")) f_bold = i;
                else if (!strcmp(fields[i], "Italic")) f_italic = i;
                else if (!strcmp(fields[i], "Outline")) f_outline = i;
                else if (!strcmp(fields[i], "OutlineColour")) f_outcolor = i;
                else if (!strcmp(fields[i], "Shadow")) f_shadow = i;
                else if (!strcmp(fields[i], "BorderStyle")) f_border = i;
                else if (!strcmp(fields[i], "Spacing")) f_spacing = i;
                else if (!strcmp(fields[i], "ScaleX")) f_scalex = i;
                else if (!strcmp(fields[i], "ScaleY")) f_scaley = i;
                else if (!strcmp(fields[i], "Angle")) f_angle = i;
                else if (!strcmp(fields[i], "MarginL")) f_ml = i;
                else if (!strcmp(fields[i], "MarginR")) f_mr = i;
                else if (!strcmp(fields[i], "MarginV")) f_mv = i;
                else if (!strcmp(fields[i], "Alignment")) f_align = i;
            }
            continue;
        }
        if (in_styles && strncmp(line, "Style:", 6) == 0) {
            char *fields[64];
            split_fields(line + 6, ',', fields, 64);
            if (track_ensure_style(t, t->nb_styles + 1) != 0) {
                continue;
            }
            LpSubStyle *s = &t->styles[t->nb_styles];
            style_default(s);
            /* Without the name every Style block collapses onto "Default" and
             * every dialogue resolves to the first one. */
            if (f_name >= 0) {
                /* "Style: Default,..." splits into " Default": drop the leading
                 * pad, or the name lookup below never matches. */
                const char *nm = fields[f_name];
                while (*nm == ' ' || *nm == '\t') nm++;
                snprintf(s->name, sizeof(s->name), "%s", nm);
            }
            if (f_font >= 0) snprintf(s->font_name, sizeof(s->font_name), "%s", fields[f_font]);
            if (f_size >= 0 && atof(fields[f_size]) > 0) {
                s->font_scale = atof(fields[f_size]) / play_h;
            }
            s->play_res_y = play_h;
            if (f_color >= 0) s->color = ass_color(fields[f_color]);
            if (f_outcolor >= 0) s->outline_color = ass_color(fields[f_outcolor]);
            if (f_backcolor >= 0) s->back_color = ass_color(fields[f_backcolor]);
            if (f_bold >= 0) s->bold = atoi(fields[f_bold]) != 0;
            if (f_italic >= 0) s->italic = atoi(fields[f_italic]) != 0;
            if (f_outline >= 0) s->outline_width = atoi(fields[f_outline]);
            if (f_shadow >= 0) s->shadow = atoi(fields[f_shadow]);
            if (f_border >= 0) {
                int bs = atoi(fields[f_border]);
                if (bs > 0) s->border_style = bs;
            }
            if (f_spacing >= 0) s->spacing = atof(fields[f_spacing]);
            if (f_scalex >= 0 && atof(fields[f_scalex]) > 0) s->scale_x = atof(fields[f_scalex]);
            if (f_scaley >= 0 && atof(fields[f_scaley]) > 0) s->scale_y = atof(fields[f_scaley]);
            if (f_angle >= 0) s->angle = atof(fields[f_angle]);
            if (f_ml >= 0) s->margin_l = atof(fields[f_ml]);
            if (f_mr >= 0) s->margin_r = atof(fields[f_mr]);
            if (f_mv >= 0) s->margin_v = atof(fields[f_mv]);
            if (f_align >= 0) {
                int a = atoi(fields[f_align]);
                if (a >= 1 && a <= 9) s->align = a;
            }
            t->nb_styles++;
            continue;
        }
        if (in_events && strncmp(line, "Format:", 7) == 0) {
            char *fields[64];
            split_fields(line + 7, ',', fields, 64);
            for (int i = 0; i < 64; i++) {
                while (*fields[i] == ' ') fields[i]++;
                char *end = fields[i] + strlen(fields[i]);
                while (end > fields[i] && end[-1] == ' ') *--end = '\0';
                if (!strcmp(fields[i], "Start")) e_start = (char *)(intptr_t)i;
                else if (!strcmp(fields[i], "End")) e_end = (char *)(intptr_t)i;
                else if (!strcmp(fields[i], "Text")) e_text = (char *)(intptr_t)i;
                else if (!strcmp(fields[i], "Style")) e_style = (char *)(intptr_t)i;
                e_count = i > e_count ? i : e_count;
            }
            continue;
        }
        if ((in_events || strncmp(line, "Dialogue:", 9) == 0) &&
            (strncmp(line, "Dialogue:", 9) == 0 || strncmp(line, "Comment:", 8) == 0)) {
            if (strncmp(line, "Comment:", 8) == 0) {
                continue;
            }
            /* A lone "Dialogue:" line (the shape libavcodec hands us for an
             * embedded ASS track) has no [Events] header, so assume the
             * standard SSA field order. */
            if (!e_start || !e_end || !e_text) {
                e_start = (char *)(intptr_t)1;
                e_end = (char *)(intptr_t)2;
                e_style = (char *)(intptr_t)3;
                e_text = (char *)(intptr_t)9;
            }
            char *body = line + 9;
            /* Text is the last field and may contain commas: split only up to
             * the field index of Text. */
            char *fields[64];
            int text_idx = e_text ? (int)(intptr_t)e_text : 9;
            /* Stop one field short: Text is last and may contain commas (an
             * inline {\pos(960,900)} would otherwise be chopped in half). */
            split_fields(body, ',', fields, text_idx + 1);
            int64_t start = 0, end = 0;
            if (!e_start || !e_end) {
                continue;
            }
            if (parse_clock(fields[e_start ? (int)(intptr_t)e_start : 1], &start, ',') != 0 ||
                parse_clock(fields[e_end ? (int)(intptr_t)e_end : 2], &end, ',') != 0) {
                continue;
            }
            /* Resolve the named style so inline tags that "inherit" get the
             * right base, and so \r falls back to it. */
            int style_idx = 0;
            if (e_style) {
                const char *want = fields[(int)(intptr_t)e_style];
                while (*want == ' ') want++;
                for (int i = 0; i < t->nb_styles; i++) {
                    if (!strcmp(t->styles[i].name, want)) {
                        style_idx = i;
                        break;
                    }
                }
            }
            AssCtx ctx;
            memset(&ctx, 0, sizeof(ctx));
            ctx.play_w = play_w;
            ctx.play_h = play_h;
            ctx.base = t->nb_styles > 0 ? &t->styles[style_idx] : NULL;
            LpSubCue cue;
            memset(&cue, 0, sizeof(cue));
            cue.start_us = start;
            cue.end_us = end;
            cue.style = style_idx;
            cue.pos_x = -1.0;
            cue.pos_y = -1.0;
            cue.margin_l = -1.0;
            cue.margin_r = -1.0;
            cue.margin_v = -1.0;
            if (sub_compile_text(fields[text_idx], &cue, &ctx) == 0 &&
                track_add_cue_full(t, &cue) == 0) {
                count++;
            } else {
                cue_free(&cue);
            }
        }
    }
    free(copy);
    if (count == 0) {
        snprintf(err, errlen, "no dialogue lines parsed (ASS)");
        return -1;
    }
    return count;
}

static int parse_vtt(const char *text, LpSubtitleTrack *t, char *err, size_t errlen)
{
    /* WebVTT is close enough to SRT for the common case: reuse the SRT parser
     * after dropping the header and cue identifiers. */
    const char *p = text;
    if (strncmp(p, "WEBVTT", 6) == 0) {
        const char *nl = strpbrk(p, "\r\n");
        p = nl ? nl + 1 : p + 6;
    }
    int n = parse_srt(p, t, err, errlen);
    if (n > 0) {
        return n;
    }
    snprintf(err, errlen, "no cues parsed (WebVTT)");
    return -1;
}

/* -------------------------------------------------------------- lifecycle --- */

static int read_whole_file(const char *url, const char *options_json, uint8_t **out,
                           size_t *out_len, char *err, size_t errlen)
{
    LpSourceOptions opts;
    lp_source_options_parse(options_json, &opts);
    LpIo *io = lp_io_open(url, &opts, err, errlen);
    if (!io) {
        return LP_ERR_IO;
    }
    int64_t size = lp_io_size(io);
    size_t cap = size > 0 && size < 32 * 1024 * 1024 ? (size_t)size + 1 : 1024 * 1024;
    uint8_t *buf = malloc(cap);
    if (!buf) {
        lp_io_close(io);
        return LP_ERR_NOMEM;
    }
    size_t len = 0;
    for (;;) {
        if (len + 65536 > cap) {
            if (cap > 32 * 1024 * 1024) {
                free(buf);
                lp_io_close(io);
                snprintf(err, errlen, "subtitle file too large");
                return LP_ERR_UNSUPPORTED;
            }
            cap *= 2;
            uint8_t *grown = realloc(buf, cap);
            if (!grown) {
                free(buf);
                lp_io_close(io);
                return LP_ERR_NOMEM;
            }
            buf = grown;
        }
        int r = lp_io_read(io, buf + len, 65536);
        if (r < 0) {
            free(buf);
            lp_io_close(io);
            return r;
        }
        if (r == 0) {
            break;
        }
        len += (size_t)r;
    }
    lp_io_close(io);
    *out = buf;
    *out_len = len;
    return LP_OK;
}

int lp_subtitle_add_file(LpPlayer *p, const char *url, const char *options_json)
{
    if (!url || !*url) {
        return LP_ERR_ARGUMENT;
    }
    pthread_mutex_lock(&p->subs.mutex);
    int nb = p->subs.nb_tracks;
    /* 同一个文件读第二次就把原来那条交出去，不要再叠一条新的：调用方（字幕面板）
     * 每点一次这个文件就调一次本函数，重复点会得到两条一模一样的轨道，用户看到
     * 的就是「同一个字幕出现了两次、还都标着外挂」。 */
    for (int i = 0; i < nb; i++) {
        if (p->subs.tracks[i].is_external && strcmp(p->subs.tracks[i].path, url) == 0) {
            int existing = p->subs.tracks[i].index;
            pthread_mutex_unlock(&p->subs.mutex);
            return existing;
        }
    }
    pthread_mutex_unlock(&p->subs.mutex);
    if (nb >= LP_MAX_SUBTITLE_TRACKS) {
        return LP_ERR_NOMEM;
    }

    uint8_t *raw = NULL;
    size_t raw_len = 0;
    char err[256] = {0};
    int r = read_whole_file(url, options_json, &raw, &raw_len, err, sizeof(err));
    if (r != LP_OK) {
        LP_WARN("subtitle", "cannot read %s: %s", url, err[0] ? err : "io error");
        return r;
    }
    int charset_ok = 1;
    char *text = decode_text(raw, raw_len, NULL, &charset_ok);
    free(raw);
    if (!text) {
        return LP_ERR_NOMEM;
    }
    if (!charset_ok) {
        LP_WARN("subtitle", "%s is not valid UTF-8 and no charset converter is available", url);
    }

    const char *ext = strrchr(url, '.');
    ext = ext ? ext + 1 : "";
    pthread_mutex_lock(&p->subs.mutex);
    LpSubtitleTrack *t = &p->subs.tracks[nb];
    memset(t, 0, sizeof(*t));
    t->index = 1000 + nb;
    t->is_external = 1;
    t->embedded = 0;
    t->current_cue = -1;
    snprintf(t->path, sizeof(t->path), "%s", url);
    const char *base = strrchr(url, '/');
    snprintf(t->title, sizeof(t->title), "%s", base ? base + 1 : url);
    if (strcasecmp(ext, "ass") == 0 || strcasecmp(ext, "ssa") == 0) {
        r = parse_ass(text, t, err, sizeof(err));
    } else if (strcasecmp(ext, "vtt") == 0) {
        r = parse_vtt(text, t, err, sizeof(err));
    } else {
        r = parse_srt(text, t, err, sizeof(err));
        if (r <= 0 && strstr(text, "[Script Info]")) {
            r = parse_ass(text, t, err, sizeof(err));
        }
    }
    free(text);
    if (r <= 0) {
        pthread_mutex_unlock(&p->subs.mutex);
        LP_WARN("subtitle", "%s: %s", url, err[0] ? err : "parse failed");
        return LP_ERR_UNSUPPORTED;
    }
    if (t->nb_cues > 1) {
        qsort(t->cues, (size_t)t->nb_cues, sizeof(LpSubCue), cue_cmp);
    }
    track_style(t, 0);
    p->subs.nb_tracks++;
    if (p->subs.selected < 0) {
        p->subs.selected = nb; /* first available track becomes active */
    }
    p->subs.dirty = 1;
    pthread_mutex_unlock(&p->subs.mutex);
    LP_INFO("subtitle", "loaded %s (%d cues)", url, t->nb_cues);
    return t->index;
}

int lp_subtitle_open(LpPlayer *p)
{
    /* p->subs.mutex 的生命周期跟播放器对象一致：lp_player_create 里 init
     * 一次、lp_player_destroy 里 destroy 一次。这里以前每开一个文件就重新
     * init，lp_subtitle_close 里又 destroy，于是关片之后紧接着的
     * setOption("subtitle_delay") 会锁到一把已销毁的 mutex，bionic 的
     * FORTIFY 直接 abort：
     *   FORTIFY: pthread_mutex_lock called on a destroyed mutex
     * 播放页每换一次片都会走这条路径，属于必现崩溃。 */
    p->subs_inited = 1;
    p->subs.nb_tracks = 0;
    p->subs.selected = -1;
    p->subs.delay_us = 0;
    p->subs.dirty = 0;
    if (!p->fmt) {
        return LP_OK;
    }
    for (unsigned i = 0; i < p->fmt->nb_streams; i++) {
        AVStream *st = p->fmt->streams[i];
        if (st->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) {
            continue;
        }
        const AVCodecDescriptor *desc = avcodec_descriptor_get(st->codecpar->codec_id);
        int is_text = desc && (desc->props & AV_CODEC_PROP_TEXT_SUB);
        if (!is_text) {
            /* Graphics subtitles (PGS / VobSub / DVB) decode into bitmaps that
             * the host paints as images; the decoder is opened exactly like a
             * text one, only the rect handling in feed_packet differs. */
            LP_INFO("subtitle", "graphics subtitle stream #%u (%s) %dx%d", i,
                    avcodec_get_name(st->codecpar->codec_id), st->codecpar->width,
                    st->codecpar->height);
        }
        if (p->subs.nb_tracks >= LP_MAX_SUBTITLE_TRACKS) {
            break;
        }
        LpSubtitleTrack *t = &p->subs.tracks[p->subs.nb_tracks];
        memset(t, 0, sizeof(*t));
        t->index = (int)i;
        t->embedded = 1;
        t->current_cue = -1;
        t->bitmap = !is_text;
        /* DVD/PGS streams declare their canvas; when the header is missing
         * (common for VobSub in Matroska) fall back to the video size, which is
         * the grid the rect coordinates were authored against. */
        t->ref_w = st->codecpar->width;
        t->ref_h = st->codecpar->height;
        if (t->bitmap && (t->ref_w <= 0 || t->ref_h <= 0)) {
            for (unsigned v = 0; v < p->fmt->nb_streams; v++) {
                AVStream *vs = p->fmt->streams[v];
                if (vs->codecpar->codec_type == AVMEDIA_TYPE_VIDEO &&
                    vs->codecpar->width > 0 && vs->codecpar->height > 0) {
                    t->ref_w = vs->codecpar->width;
                    t->ref_h = vs->codecpar->height;
                    break;
                }
            }
            LP_DEBUG("subtitle", "graphics grid falls back to video %dx%d", t->ref_w,
                     t->ref_h);
        }
        const AVDictionaryEntry *lang = av_dict_get(st->metadata, "language", NULL, 0);
        const AVDictionaryEntry *title = av_dict_get(st->metadata, "title", NULL, 0);
        snprintf(t->lang, sizeof(t->lang), "%s", lang ? lang->value : "");
        snprintf(t->title, sizeof(t->title), "%s",
                 title ? title->value : avcodec_get_name(st->codecpar->codec_id));
        const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
        if (codec) {
            AVCodecContext *ctx = avcodec_alloc_context3(codec);
            if (ctx && avcodec_parameters_to_context(ctx, st->codecpar) >= 0 &&
                avcodec_open2(ctx, codec, NULL) >= 0) {
                t->avctx = ctx;
                p->subs.nb_tracks++;
                track_style(t, 0);
                continue;
            }
            avcodec_free_context(&ctx);
        }
        LP_WARN("subtitle", "cannot open embedded subtitle #%u", i);
    }
    /* Default to the first subtitle track: for the target audience (Chinese
     * dramas, foreign films) subtitles are the expected default, and the player
     * UI offers an explicit "off" switch. */
    if (p->subs.nb_tracks > 0) {
        p->subs.selected = 0;
        for (int i = 0; i < p->subs.nb_tracks; i++) {
            p->subs.tracks[i].enabled = (i == 0);
        }
        p->subs.dirty = 1;
        LP_INFO("subtitle", "%d embedded track(s), #0 selected by default", p->subs.nb_tracks);
    }
    return LP_OK;
}

void lp_subtitle_close(LpPlayer *p)
{
    overlay_reset(&p->subs.overlay);
    for (int i = 0; i < p->subs.nb_tracks; i++) {
        LpSubtitleTrack *t = &p->subs.tracks[i];
        track_reset(t);
        if (t->avctx) {
            avcodec_free_context(&t->avctx);
        }
    }
    p->subs.nb_tracks = 0;
    p->subs.selected = -1;
    /* 不销毁 p->subs.mutex：它属于播放器对象本身（lp_player_destroy 负责
     * 销毁）。关片之后 Dart 侧仍可能调 setOption("subtitle_delay")，那把
     * 锁必须还活着。 */
}

void lp_subtitle_feed_packet(LpPlayer *p, int stream_index, AVPacket *pkt)
{
    LpSubtitleTrack *t = NULL;
    pthread_mutex_lock(&p->subs.mutex);
    for (int i = 0; i < p->subs.nb_tracks; i++) {
        if (p->subs.tracks[i].embedded && p->subs.tracks[i].index == stream_index) {
            t = &p->subs.tracks[i];
            break;
        }
    }
    if (!t || !t->avctx) {
        pthread_mutex_unlock(&p->subs.mutex);
        return;
    }
    AVSubtitle sub;
    memset(&sub, 0, sizeof(sub));
    int got = 0;
    if (avcodec_decode_subtitle2(t->avctx, &sub, &got, pkt) < 0 || !got) {
        avsubtitle_free(&sub);
        pthread_mutex_unlock(&p->subs.mutex);
        return;
    }
    if (t->bitmap && sub.num_rects == 0) {
        /* A display set with no rectangles is how PGS clears the screen. */
        for (int k = 0; k < t->nb_cues; k++) {
            cue_free(&t->cues[k]);
        }
        t->nb_cues = 0;
        t->current_cue = -1;
        overlay_reset(&p->subs.overlay);
        avsubtitle_free(&sub);
        pthread_mutex_unlock(&p->subs.mutex);
        return;
    }
    /* Prefer the container timestamp: for Matroska the decoder often leaves
     * AVSubtitle.pts unset, while the packet pts is always there. */
    int64_t start_us = 0;
    if (pkt->pts != AV_NOPTS_VALUE) {
        AVStream *st = p->fmt->streams[stream_index];
        start_us = av_rescale_q(pkt->pts, st->time_base, AV_TIME_BASE_Q);
    } else if (sub.pts != AV_NOPTS_VALUE) {
        start_us = sub.pts;
    }
    int64_t dur_us = (int64_t)sub.end_display_time * 1000;
    if (dur_us <= 0) {
        AVStream *st = p->fmt->streams[stream_index];
        dur_us = pkt->duration > 0 ? av_rescale_q(pkt->duration, st->time_base, AV_TIME_BASE_Q)
                                   : 3000000;
    }
    LpSubCue cue;
    memset(&cue, 0, sizeof(cue));
    cue.start_us = start_us;
    cue.end_us = start_us + dur_us;
    cue.pos_x = -1.0;
    cue.pos_y = -1.0;
    cue.margin_l = -1.0;
    cue.margin_r = -1.0;
    cue.margin_v = -1.0;
    SubRich merged;
    sub_rich_init(&merged, &cue);
    int merge_ok = 1;
    for (unsigned i = 0; i < sub.num_rects && merge_ok; i++) {
        AVSubtitleRect *r = sub.rects[i];
        if (r->type == SUBTITLE_BITMAP) {
            LpSubBitmap b;
            memset(&b, 0, sizeof(b));
            if (bitmap_from_rect(r, &b) == 0) {
                if (cue_add_bitmap(&cue, &b) != 0) {
                    free(b.rgba);
                    merge_ok = 0;
                } else {
                    LP_DEBUG("subtitle", "bitmap rect %u %dx%d at %d,%d", i, b.w, b.h,
                             b.x, b.y);
                }
            }
            continue;
        }
        const char *src = r->type == SUBTITLE_ASS ? r->ass : r->text;
        if (!src) {
            continue;
        }
        LP_DEBUG("subtitle", "rect %u type=%d: %.80s", i, (int)r->type, src);
        LpSubCue one;
        memset(&one, 0, sizeof(one));
        one.pos_x = -1.0;
        one.pos_y = -1.0;
        AssCtx ctx;
        memset(&ctx, 0, sizeof(ctx));
        if (r->type == SUBTITLE_ASS && strncmp(src, "Dialogue:", 9) == 0) {
            /* The ASS packet is a single dialogue line: strip its own timing
             * and let the container decide when it shows. */
            const char *body = strchr(src, ':');
            body = body ? body + 1 : src;
            char *copy = lp_str_dup(body);
            if (!copy) {
                merge_ok = 0;
                break;
            }
            char *fields[16];
            split_fields(copy, ',', fields, 10);
            if (sub_compile_text(fields[9], &one, &ctx) != 0) {
                merge_ok = 0;
            }
            free(copy);
        } else {
            const char *plain = src;
            if (r->type == SUBTITLE_ASS) {
                /* Some demuxers hand back an ASS body without "Dialogue:" and
                 * with zeroed fields; keep only the text column. */
                const char *mark = strstr(src, ",,0,0,0,,");
                if (mark) {
                    plain = mark + 9;
                }
            }
            if (sub_compile_text(plain, &one, &ctx) != 0) {
                merge_ok = 0;
            }
        }
        if (merge_ok && merge_cue_into(&merged, &one) != 0) {
            merge_ok = 0;
        }
        cue_free(&one);
    }
    int keep = 0;
    if (merge_ok) {
        cue.text = lp_str_take(&merged.plain);
        if (merged.nb > 0) {
            cue.runs = merged.runs;
            cue.nb_runs = merged.nb;
            merged.runs = NULL;
            merged.nb = merged.cap = 0;
        }
        int has_text = cue.text && *cue.text;
        if (has_text || cue.nb_bitmaps > 0) {
            if (track_add_cue_full(t, &cue) == 0) {
                keep = 1;
            }
        }
    }
    sub_rich_free(&merged);
    avsubtitle_free(&sub);
    if (keep && t->nb_cues > 512) {
        /* Trim embedded history to keep memory flat for long movies. */
        int drop = t->nb_cues - 512;
        for (int i = 0; i < drop; i++) cue_free(&t->cues[i]);
        memmove(t->cues, t->cues + drop, (size_t)(t->nb_cues - drop) * sizeof(LpSubCue));
        t->nb_cues -= drop;
    }
    if (!keep) {
        cue_free(&cue);
    }
    pthread_mutex_unlock(&p->subs.mutex);
}

void lp_subtitle_seek(LpPlayer *p, int64_t pos_us)
{
    pthread_mutex_lock(&p->subs.mutex);
    overlay_reset(&p->subs.overlay);
    for (int i = 0; i < p->subs.nb_tracks; i++) {
        LpSubtitleTrack *t = &p->subs.tracks[i];
        if (t->embedded) {
            /* Drop decoded history; it will be re-fed by the demuxer. */
            for (int k = 0; k < t->nb_cues; k++) {
                cue_free(&t->cues[k]);
            }
            t->nb_cues = 0;
        }
        t->current_cue = -1;
        if (t->avctx) {
            avcodec_flush_buffers(t->avctx);
        }
    }
    (void)pos_us;
    p->subs.dirty = 1;
    pthread_mutex_unlock(&p->subs.mutex);
}

/* One cue style as JSON.  Shared by the whole-cue payload (kept for the plain
 * case) and by the per-line list, which is what lets two simultaneously
 * visible dialogues keep their own colours, weight and box. */
static void append_style_json(LpStr *s, const LpSubStyle *st)
{
    lp_str_append(s, "\"bold\":%s,\"italic\":%s,\"underline\":%s,\"strikeout\":%s,",
                  st->bold ? "true" : "false", st->italic ? "true" : "false",
                  st->underline ? "true" : "false", st->strikeout ? "true" : "false");
    lp_str_append(s, "\"color\":%u,\"outline_color\":%u,\"back_color\":%u,",
                  (unsigned)st->color, (unsigned)st->outline_color,
                  (unsigned)st->back_color);
    lp_str_append(s, "\"outline\":%d,\"shadow\":%d,\"border_style\":%d,",
                  st->outline_width, st->shadow, st->border_style);
    lp_str_append(s, "\"spacing\":%.4f,\"scale_x\":%.4f,\"scale_y\":%.4f,\"angle\":%.4f,",
                  st->spacing, st->scale_x, st->scale_y, st->angle);
    lp_str_append(s, "\"margin_l\":%.4f,\"margin_r\":%.4f,\"margin_v\":%.4f,",
                  st->margin_l, st->margin_r, st->margin_v);
    lp_str_append(s, "\"align\":%d,\"font_scale\":%.6f,\"play_res_y\":%.2f,",
                  st->align, st->font_scale, st->play_res_y);
    lp_str_append(s, "\"pos_x\":%.4f,\"pos_y\":%.4f,", st->pos_x, st->pos_y);
    lp_str_append(s, "\"font\":");
    lp_str_append_json_str(s, st->font_name);
}

static void emit_subtitle(LpPlayer *p, const char *text, int64_t start_us, int64_t end_us,
                          const LpSubStyle *st, const char *runs_json)
{
    LpStr s;
    lp_str_init(&s);
    lp_str_append(&s, "{\"text\":");
    lp_str_append_json_str(&s, text);
    lp_str_append(&s, ",\"start\":%lld,\"end\":%lld,\"style\":{", (long long)start_us,
                  (long long)end_us);
    append_style_json(&s, st);
    lp_str_append(&s, "}");
    if (runs_json && *runs_json) {
        lp_str_append(&s, ",\"runs\":[%s]", runs_json);
    }
    lp_str_append(&s, "}");
    lp_emit_event(p, LP_EVENT_SUBTITLE, "%s", s.p);
    lp_str_free(&s);
}

/* Serialises the cues on screen line by line: their text, their inline runs
 * and their own placement.  Every hit gets an entry even when it carries no
 * inline styling, because two plain cues can still sit in different corners. */
static void append_runs_json(LpStr *out, LpSubtitleTrack *t, const int *idx, int n)
{
    if (n <= 0) {
        return;
    }
    for (int k = 0; k < n; k++) {
        LpSubCue *c = &t->cues[idx[k]];
        if (k > 0) {
            lp_str_append(out, ",");
        }
        lp_str_append(out, "{\"text\":");
        lp_str_append_json_str(out, c->text ? c->text : "");
        /* Every line carries its own style and placement.  Two dialogues can
         * be on screen at once with different colours, weights, boxes and
         * margins; reusing the last hit's style paints both the same way. */
        LpSubStyle *cst = track_style(t, c->style);
        if (cst) {
            LpSubStyle line = *cst;
            /* Per-cue {\\anN} / {\\pos(x,y)} win over the style. */
            if (c->align_override) {
                line.align = c->align_override;
            }
            if (c->pos_x >= 0 && c->pos_y >= 0) {
                line.pos_x = c->pos_x;
                line.pos_y = c->pos_y;
            }
            lp_str_append(out, ",\"style\":{");
            append_style_json(out, &line);
            lp_str_append(out, "}");
        }
        /* Runs are optional: a cue can be plain while a sibling is styled. */
        if (c->nb_runs > 0) {
            lp_str_append(out, ",\"runs\":[");
            for (int i = 0; i < c->nb_runs; i++) {
                LpSubRun *r = &c->runs[i];
                if (i > 0) {
                    lp_str_append(out, ",");
                }
                lp_str_append(out, "{\"text\":");
                lp_str_append_json_str(out, r->text ? r->text : "");
                lp_str_append(out, ",\"bold\":%s,\"italic\":%s,\"underline\":%s,\"strikeout\":%s",
                              (r->flags & LP_SUB_BOLD) ? "true" : "false",
                              (r->flags & LP_SUB_ITALIC) ? "true" : "false",
                              (r->flags & LP_SUB_UNDERLINE) ? "true" : "false",
                              (r->flags & LP_SUB_STRIKEOUT) ? "true" : "false");
                if (r->color) {
                    lp_str_append(out, ",\"color\":%u", (unsigned)r->color);
                }
                if (r->outline_color) {
                    lp_str_append(out, ",\"outline_color\":%u",
                                  (unsigned)r->outline_color);
                }
                if (r->back_color) {
                    lp_str_append(out, ",\"back_color\":%u",
                                  (unsigned)r->back_color);
                }
                if (r->font_scale > 0) {
                    lp_str_append(out, ",\"scale\":%.6f", r->font_scale);
                }
                if (r->scale_x > 0 && r->scale_x != 100.0) {
                    lp_str_append(out, ",\"scale_x\":%.4f", r->scale_x);
                }
                if (r->scale_y > 0 && r->scale_y != 100.0) {
                    lp_str_append(out, ",\"scale_y\":%.4f", r->scale_y);
                }
                if (r->spacing != 0.0) {
                    lp_str_append(out, ",\"spacing\":%.4f", r->spacing);
                }
                if (r->angle != 0.0) {
                    lp_str_append(out, ",\"angle\":%.4f", r->angle);
                }
                if (r->border >= 0) {
                    lp_str_append(out, ",\"border\":%d", r->border);
                }
                if (r->shadow >= 0) {
                    lp_str_append(out, ",\"shadow\":%d", r->shadow);
                }
                if (r->font_name[0]) {
                    lp_str_append(out, ",\"font\":");
                    lp_str_append_json_str(out, r->font_name);
                }
                lp_str_append(out, "}");
            }
            lp_str_append(out, "]");
        }
        lp_str_append(out, "}");
    }
}

void lp_subtitle_tick(LpPlayer *p, int64_t now_us)
{
    pthread_mutex_lock(&p->subs.mutex);
    if (p->subs.selected < 0 || p->subs.selected >= p->subs.nb_tracks) {
        if (p->subs.selected != -1 || p->subs.dirty) {
            p->subs.selected = -1;
            p->subs.dirty = 0;
            if (p->subs.overlay.nb > 0) {
                overlay_reset(&p->subs.overlay);
            }
            pthread_mutex_unlock(&p->subs.mutex);
            emit_subtitle(p, "", 0, 0, &(LpSubStyle){0}, NULL);
            return;
        }
        if (p->subs.overlay.nb > 0) {
            overlay_reset(&p->subs.overlay);
        }
        pthread_mutex_unlock(&p->subs.mutex);
        return;
    }
    LpSubtitleTrack *t = &p->subs.tracks[p->subs.selected];
    int64_t t_now = now_us - p->subs.delay_us;
    if (t->bitmap) {
        /* Graphics tracks have no text event: the rectangles are composited by
         * the renderer through p->subs.overlay. */
        overlay_update(p, t, t_now);
        int found_bmp = -1;
        for (int i = 0; i < t->nb_cues; i++) {
            LpSubCue *c = &t->cues[i];
            if (c->start_us > t_now) {
                break;
            }
            if (t_now < c->end_us && c->nb_bitmaps > 0) {
                found_bmp = i;
            }
        }
        t->current_cue = found_bmp;
        int was_dirty = p->subs.dirty;
        p->subs.dirty = 0;
        pthread_mutex_unlock(&p->subs.mutex);
        if (was_dirty) {
            /* Switching to a graphics track must clear whatever text the
             * previous track left on screen. */
            emit_subtitle(p, "", 0, 0, &(LpSubStyle){0}, NULL);
        }
        return;
    }
    LpStr text;
    lp_str_init(&text);
    LpStr runs;
    lp_str_init(&runs);
    int hits[16];
    int nb_hits = 0;
    int found = -1;
    int64_t start_us = 0, end_us = 0;
    LpSubStyle style;
    style_default(&style);
    for (int i = 0; i < t->nb_cues; i++) {
        LpSubCue *c = &t->cues[i];
        if (c->start_us > t_now) {
            break;
        }
        if (t_now < c->end_us) {
            found = i;
            if (text.len) lp_str_append(&text, "\n");
            lp_str_append(&text, "%s", c->text);
            if (start_us == 0) {
                start_us = c->start_us;
            }
            end_us = c->end_us;
            LpSubStyle *cs = track_style(t, c->style);
            if (cs) {
                style = *cs;
            }
            /* Per-cue {\anN} / {\pos(x,y)} win over the style. */
            if (c->align_override) {
                style.align = c->align_override;
            }
            if (c->pos_x >= 0 && c->pos_y >= 0) {
                style.pos_x = c->pos_x;
                style.pos_y = c->pos_y;
            }
            if (nb_hits < (int)(sizeof(hits) / sizeof(hits[0]))) {
                hits[nb_hits++] = i;
            }
        }
    }
    if (nb_hits > 0) {
        append_runs_json(&runs, t, hits, nb_hits);
    }
    int changed = (found != t->current_cue) || p->subs.dirty;
    t->current_cue = found;
    pthread_mutex_unlock(&p->subs.mutex);

    if (changed) {
        emit_subtitle(p, text.p ? text.p : "", start_us, end_us, &style,
                      runs.p ? runs.p : NULL);
        pthread_mutex_lock(&p->subs.mutex);
        p->subs.dirty = 0;
        pthread_mutex_unlock(&p->subs.mutex);
    }
    lp_str_free(&text);
    lp_str_free(&runs);
}

void lp_subtitle_select(LpPlayer *p, int track_index)
{
    pthread_mutex_lock(&p->subs.mutex);
    int sel = -1;
    for (int i = 0; i < p->subs.nb_tracks; i++) {
        if (p->subs.tracks[i].index == track_index) {
            sel = i;
            break;
        }
    }
    if (track_index < 0) {
        sel = -1;
    }
    p->subs.selected = sel;
    for (int i = 0; i < p->subs.nb_tracks; i++) {
        p->subs.tracks[i].current_cue = -1;
        p->subs.tracks[i].enabled = (i == sel);
    }
    p->subs.dirty = 1;
    pthread_mutex_unlock(&p->subs.mutex);
}

void lp_subtitle_set_delay(LpPlayer *p, int64_t delay_ms)
{
    pthread_mutex_lock(&p->subs.mutex);
    p->subs.delay_us = delay_ms * 1000;
    p->subs.dirty = 1;
    pthread_mutex_unlock(&p->subs.mutex);
}

/* 测试入口：把一段只含 override 标签和文字的 ASS 行编成 run 列表，返回
 * 第一段文本生效的四色。仅供 native/tests/lp_subcolor_test.c 使用 —— 正常
 * 播放路径不会调它。 */
int lp_sub_test_parse_runs(const char *dialogue_text, int run_index,
                           uint32_t *color, uint32_t *outline_color,
                           uint32_t *back_color)
{
    LpSubStyle base;
    style_default(&base);
    LpSubCue cue;
    memset(&cue, 0, sizeof(cue));
    AssCtx ctx;
    ctx.play_w = 384.0;
    ctx.play_h = 288.0;
    ctx.base = &base;
    int rc = sub_compile_text(dialogue_text, &cue, &ctx);
    if (rc != 0) {
        cue_free(&cue);
        return -1;
    }
    uint32_t c = 0, o = 0, k = 0;
    if (run_index >= 0 && run_index < cue.nb_runs) {
        c = cue.runs[run_index].color;
        o = cue.runs[run_index].outline_color;
        k = cue.runs[run_index].back_color;
    }
    cue_free(&cue);
    if (color) *color = c;
    if (outline_color) *outline_color = o;
    if (back_color) *back_color = k;
    return 0;
}
