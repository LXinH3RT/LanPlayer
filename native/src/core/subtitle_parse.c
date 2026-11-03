/*
 * 字幕解析：ASS/SSA、SRT、WebVTT 的文本解析，以及 ASS 的样式继承、
 * `\r` 覆盖标签与 `\t` 动画求值。
 *
 * 这一层刻意做成纯函数：输入一段文本或一包字节，输出填好的 cue 与
 * run，不持锁、不读播放器状态。因此可以拿任意字符串直接喂进来测
 * （见文件末尾的 lp_sub_test_* 与 native/tests/lp_sub*_test.c）。
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
#include "subtitle_internal.h"

int lp_sub_has_drawing_runs(const LpSubCue *cue)
{
    for (int i = 0; i < cue->nb_runs; i++) {
        if (cue->runs[i].nb_path > 0) {
            return 1;
        }
    }
    return 0;
}


/* -------------------------------------------------------- graphics overlay --- */

/* The overlay owns copies of the rects so that history trimming, a seek or a
 * track switch can free cues without the render thread ever reading freed
 * memory.  subtitle.c updates it under p->subs.mutex; the renderer takes the
 * same lock, grabs references to what it needs, and blends outside of it.
 *
 * 引用计数是为了省掉渲染线程每帧的深拷贝：一张 PGS 位图几百 KB，
 * 1080p 双行字幕每帧要 memcpy 一遍，纯粹的浪费。 */
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
            /* 0x00 不是文本：无 BOM 的 UTF-16 字幕里每个 ASCII 字符后面都跟着
             * 一个 0x00，把 NUL 当合法 UTF-8 会让整份文件「通过」校验，于是
             * decode_text 不回落到 UTF-16 分支，解析出 0 条 cue。 */
            if (c == 0) {
                return 0;
            }
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

/* 无 BOM 的 UTF-16 猜测：中文/日文/韩文用 UTF-16 存下来时，ASCII 与标点都是
 * 「低字节 + 0x00」，于是偶数位上 0x00 的比例极高；纯 UTF-8 文本里 0x00 根本
 * 不该出现（上面已判非法）。只在「长度成对 + 其中一侧 0x00 过半 + 另一侧没有
 * 几个 0x00」时才认，避免误伤真正的单字节文本。返回 0 = LE，1 = BE，-1 = 不是
 * UTF-16。 */
static int guess_utf16(const uint8_t *raw, size_t len)
{
    if (len < 4 || (len % 2) != 0) {
        return -1;
    }
    size_t pairs = len / 2;
    if (pairs < 2) {
        return -1;
    }
    size_t zero_even = 0;
    size_t zero_odd = 0;
    for (size_t i = 0; i + 1 < len; i += 2) {
        if (raw[i] == 0) {
            zero_even++;
        }
        if (raw[i + 1] == 0) {
            zero_odd++;
        }
    }
    /* 纯 ASCII 的 UTF-16 里 100% 的配对都有一侧是 0；带中文的也远高于一半。
     * 反过来要求「另一侧几乎没有 0」，否则两个方向都像，宁可放弃。 */
    if (zero_odd * 2 >= pairs && zero_even * 8 <= pairs) {
        return 0;
    }
    if (zero_even * 2 >= pairs && zero_odd * 8 <= pairs) {
        return 1;
    }
    return -1;
}

/* Returns a NUL terminated UTF-8 buffer (malloc). */
char *lp_sub_decode_text(const uint8_t *raw, size_t len, size_t *out_len, int *charset_ok)
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
    } else {
        /* 无 BOM 的 UTF-16：先猜再走正常流程。猜错时下面的 is_valid_utf8 会
         * 把结果判否，字符集回退仍能接手，所以这里不必过于保守。 */
        int be = guess_utf16(raw, len);
        if (be >= 0) {
            LP_DEBUG("subtitle", "no BOM, guessing UTF-16%s", be ? "BE" : "LE");
            return utf16_to_utf8(raw, len, be);
        }
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


void lp_sub_rich_init(SubRich *b, LpSubCue *cue)
{
    memset(b, 0, sizeof(*b));
    b->cue = cue;
    /* -1 means "inherit the cue style" for the numeric decorations, so an
     * absent {\bord} cannot be confused with an explicit {\bord0}. */
    b->st.border = -1;
    b->st.shadow = -1;
    b->st.alpha = 1.0;
    /* a \clip 之后紧跟 {\clip0} 之类的复位写法时，逆裁剪标记必须一起清掉，
     * 否则下一条矩形裁剪会莫名其妙变成「挖洞」。 */
    b->st.clip_inverse = 0;
    b->st.clip_x1 = b->st.clip_y1 = b->st.clip_x2 = b->st.clip_y2 = 0.0;
    lp_str_init(&b->plain);
}

void lp_sub_rich_free(SubRich *b)
{
    lp_str_free(&b->plain);
    for (int i = 0; i < b->nb; i++) {
        free(b->runs[i].text);
        free(b->runs[i].anims);
        free(b->runs[i].path);
    }
    free(b->runs);
    free(b->st.anims);
    free(b->st.path);
    b->st.anims = NULL;
    b->st.path = NULL;
    b->st.nb_anims = b->st.cap_anims = 0;
    b->st.nb_path = b->st.cap_path = 0;
    b->runs = NULL;
    b->nb = b->cap = 0;
}

/* Two runs can only be merged when every rendered property matches; missing a
 * field here silently collapses two differently styled spans into one. */
static int run_state_matches(const LpSubRun *r, const SubRunState *st)
{
    return r->flags == st->flags && r->color == st->color &&
           r->outline_color == st->outline_color &&
           r->back_color == st->back_color &&
           r->font_scale == st->font_scale && r->scale_x == st->scale_x &&
           r->scale_y == st->scale_y && r->spacing == st->spacing &&
           r->angle == st->angle && r->border == st->border &&
           r->shadow == st->shadow && r->alpha == st->alpha &&
           r->karaoke_kind == st->karaoke_pending_kind &&
           r->clip_on == st->clip_on && r->clip_inverse == st->clip_inverse &&
           r->clip_x1 == st->clip_x1 && r->clip_y1 == st->clip_y1 &&
           r->clip_x2 == st->clip_x2 && r->clip_y2 == st->clip_y2 &&
           r->drawing_scale == st->drawing_scale &&
           !strcmp(r->font_name, st->font_name);
}

int lp_sub_rich_append(SubRich *b, const char *text, size_t len)
{
    if (len == 0) {
        return 0;
    }
    if (b->plain.len >= LP_MAX_TEXT_BYTES) {
        return 0;
    }
    if (b->plain.len + (int)len > LP_MAX_TEXT_BYTES) {
        len = (size_t)(LP_MAX_TEXT_BYTES - b->plain.len);
        /* 截断点可能落在多字节字符中间。text[len] 是被丢掉的第一字节，
         * 它如果是续字节（10xxxxxx），说明这个字符被切成两半了 ——
         * 一直退到 start byte 之前，把整个字符都丢掉。留着半个 UTF-8
         * 序列的话，lp_str_append_json_str 会原样打进 JSON，Dart 侧
         * utf8.decode 抛 FormatException，整条字幕事件丢失。 */
        while (len > 0 && ((unsigned char)text[len] & 0xC0) == 0x80) {
            len--;
        }
    }
    lp_str_append(&b->plain, "%.*s", (int)len, text);
    if (b->nb > 0) {
        LpSubRun *last = &b->runs[b->nb - 1];
        /* A pending karaoke duration means the next glyphs are the ones that
         * have to be timed, so they need a run of their own: merging them into
         * the previous syllable dropped every \k after the first. */
        if (run_state_matches(last, &b->st) && last->nb_anims == 0 &&
            b->st.karaoke_pending_kind == 0) {
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
    r->alpha = b->st.alpha;
    r->clip_on = b->st.clip_on;
    r->clip_inverse = b->st.clip_inverse;
    r->clip_x1 = b->st.clip_x1;
    r->clip_y1 = b->st.clip_y1;
    r->clip_x2 = b->st.clip_x2;
    r->clip_y2 = b->st.clip_y2;
    r->drawing_scale = b->st.drawing_scale;
    snprintf(r->font_name, sizeof(r->font_name), "%s", b->st.font_name);
    /* Karaoke: the duration collected before this run applies to the glyphs
     * that start here.  \k fills per syllable, \ko fades out afterwards. */
    if (b->st.karaoke_pending_kind) {
        r->karaoke_kind = b->st.karaoke_pending_kind;
        r->karaoke_start_ms = b->st.karaoke_cursor_ms;
        b->st.karaoke_cursor_ms += b->st.karaoke_pending_ms;
        r->karaoke_end_ms = b->st.karaoke_cursor_ms;
        b->st.karaoke_pending_kind = 0;
        b->st.karaoke_pending_ms = 0;
    }
    /* A run inherits the animations that were in force when its text started.
     * Copying (rather than sharing) keeps freeing trivial. */
    if (b->st.nb_anims > 0) {
        r->anims = malloc((size_t)b->st.nb_anims * sizeof(LpSubAnim));
        if (!r->anims) {
            free(r->text);
            r->text = NULL;
            return -1;
        }
        memcpy(r->anims, b->st.anims, (size_t)b->st.nb_anims * sizeof(LpSubAnim));
        r->nb_anims = b->st.nb_anims;
    }
    if (b->st.nb_path > 0) {
        r->path = malloc((size_t)b->st.nb_path * sizeof(LpSubPathPoint));
        if (!r->path) {
            free(r->text);
            free(r->anims);
            r->text = NULL;
            r->anims = NULL;
            return -1;
        }
        memcpy(r->path, b->st.path, (size_t)b->st.nb_path * sizeof(LpSubPathPoint));
        r->nb_path = b->st.nb_path;
    }
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

/* --- \t animations ------------------------------------------------------ */

/* Appends one animation to the state.  \t repeats accumulate: each one runs on
 * its own window and the last finished value wins, which is close enough to
 * libass for the reveal effects scripts actually use. */
static int anim_add(SubRunState *st, const LpSubAnim *a)
{
    if (st->nb_anims == st->cap_anims) {
        int cap = st->cap_anims ? st->cap_anims * 2 : 4;
        LpSubAnim *grown = realloc(st->anims, (size_t)cap * sizeof(LpSubAnim));
        if (!grown) {
            return -1;
        }
        st->anims = grown;
        st->cap_anims = cap;
    }
    st->anims[st->nb_anims++] = *a;
    return 0;
}

/* Parses the "t1,t2,accel" prefix of \t.  Any part can be omitted:
 * \t(tags) means "animate over the whole cue", \t(t1,tags) starts at t1. */
static void anim_window(const char **pp, LpSubAnim *a, double cue_len_ms)
{
    const char *p = *pp;
    a->t1_ms = 0.0;
    a->t2_ms = cue_len_ms > 0 ? cue_len_ms : 0.0;
    a->accel = 0.0;
    if (isdigit((unsigned char)*p) || *p == '-' || *p == '+') {
        double v = atof(p);
        while (*p && *p != ',' && *p != ')') {
            p++;
        }
        a->t1_ms = v;
    }
    if (*p == ',') {
        p++;
        if (isdigit((unsigned char)*p) || *p == '-' || *p == '+') {
            double v = atof(p);
            while (*p && *p != ',' && *p != ')') {
                p++;
            }
            a->t2_ms = v;
        }
        if (*p == ',') {
            p++;
            if (isdigit((unsigned char)*p) || *p == '-' || *p == '+') {
                a->accel = atof(p);
                while (*p && *p != '(' && *p != '\\' && *p != '}' && *p != ')') {
                    p++;
                }
            }
        }
    }
    *pp = p;
}

/* --- \p vector drawings ------------------------------------------------- */

/* Part of a `\p<n>` path.  `m` starts a new subpath, `l` adds a line, `b`
 * adds a cubic spline end point (the two control points matter for the curve
 * but the renderer flattens using the end point only, so they are stored as
 * the preceding nodes and the contour keeps its shape). */
enum { PATH_MOVE = 0, PATH_LINE = 1, PATH_CURVE = 2 };

static int path_push(SubRunState *st, int kind, double x, double y)
{
    if (st->nb_path > 0) {
        LpSubPathPoint *last = &st->path[st->nb_path - 1];
        if (kind != PATH_MOVE && last->x == x && last->y == y) {
            return 0; /* zero-length segment, would only add noise */
        }
    }
    if (kind == PATH_MOVE) {
        st->path_sub++;
    }
    if (st->nb_path == st->cap_path) {
        int cap = st->cap_path ? st->cap_path * 2 : 16;
        LpSubPathPoint *grown =
            realloc(st->path, (size_t)cap * sizeof(LpSubPathPoint));
        if (!grown) {
            return -1;
        }
        st->path = grown;
        st->cap_path = cap;
    }
    LpSubPathPoint *pt = &st->path[st->nb_path];
    pt->sub = st->path_sub;
    pt->x = x;
    pt->y = y;
    st->nb_path++;
    return 0;
}

/* Reads the numeric arguments of a drawing command until the next command
 * letter.  ASS drawings are space separated, but "100 -1 l 200 13" and
 * "100,-1" both occur in the wild. */
static int path_numbers(const char **pp, double *out, int max)
{
    const char *p = *pp;
    int n = 0;
    while (n < max) {
        while (*p == ' ' || *p == ',' || *p == '\t' || *p == '\r' || *p == '\n') {
            p++;
        }
        if (!(isdigit((unsigned char)*p) || *p == '-' || *p == '+' || *p == '.')) {
            break;
        }
        out[n++] = atof(p);
        while (isdigit((unsigned char)*p) || *p == '-' || *p == '+' || *p == '.' ||
               *p == 'e' || *p == 'E') {
            p++;
        }
    }
    *pp = p;
    return n;
}

/* Walks one drawing chunk ("m 200 -1 l 200 13 b 14 12 14 6 14 6").  Curves are
 * flattened to their end point: the renderer draws polylines, and at the size
 * ASS titles are used the missing control points are not visible. */
static int path_consume(SubRunState *st, const char *s)
{
    const char *p = s;
    while (*p) {
        while (*p == ' ' || *p == ',' || *p == '\t' || *p == '\r' || *p == '\n') {
            p++;
        }
        if (!*p) {
            break;
        }
        char cmd = *p;
        if (cmd == 'm' || cmd == 'n' || cmd == 'l' || cmd == 'b' || cmd == 's' ||
            cmd == 'p' || cmd == 'c') {
            p++;
        } else if (isdigit((unsigned char)*p) || *p == '-' || *p == '+' || *p == '.') {
            cmd = 'l'; /* implicit lineto after the closing point of a subpath */
        } else {
            p++;
            continue;
        }
        double v[8];
        int want = (cmd == 'b') ? 6 : (cmd == 's' ? 4 : 2);
        for (;;) {
            int n = path_numbers(&p, v, want);
            if (n < want) {
                break;
            }
            if (cmd == 'm' || cmd == 'n') {
                if (path_push(st, PATH_MOVE, v[0], v[1]) != 0) {
                    return -1;
                }
                /* Extra pairs after `m` are implicit lineto commands. */
                cmd = 'l';
                want = 2;
            } else if (cmd == 'b') {
                if (path_push(st, PATH_CURVE, v[4], v[5]) != 0) {
                    return -1;
                }
            } else if (cmd == 's') {
                if (path_push(st, PATH_CURVE, v[2], v[3]) != 0) {
                    return -1;
                }
            } else if (cmd == 'l') {
                if (path_push(st, PATH_LINE, v[0], v[1]) != 0) {
                    return -1;
                }
            } else {
                break;
            }
        }
    }
    return 0;
}

/* {\b1\i1\c&H0000FF&\fs48\an8\pos(960,80)} -> run state / cue overrides. */
static void apply_override(const char *tags, const AssCtx *ctx, SubRich *b);
static int sub_rich_flush_drawing(SubRich *b);

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
            /* \i0 / \i1 是斜体开关，\iclip 是逆裁剪，两者只共用一个首字母。
             * 以前这里不区分，直接按「有没有参数」决定开关：\iclip(...) 的
             * 参数以 '(' 开头，tag_number 返回非 0，于是整行被当成「开启斜体」，
             * 真正想要的效果被丢掉、还顺手把文字变成斜的。 */
            if (!strncmp(p, "clip", 4)) {
                p += 4;
                if (*p == '(') {
                    p++;
                    double v[4];
                    int n = path_numbers(&p, v, 4);
                    if (n >= 4) {
                        b->st.clip_on = 1;
                        b->st.clip_inverse = 1;
                        b->st.clip_x1 = v[0];
                        b->st.clip_y1 = v[1];
                        b->st.clip_x2 = v[2];
                        b->st.clip_y2 = v[3];
                    }
                    while (*p && *p != ')' && *p != '\\' && *p != '}') {
                        p++;
                    }
                    if (*p == ')') {
                        p++;
                    }
                }
                break;
            }
            if (tag_has_arg(p)) {
                if (tag_number(&p, &num) == 0) {
                    b->st.flags = num == 0 ? (b->st.flags & ~LP_SUB_ITALIC)
                                           : (b->st.flags | LP_SUB_ITALIC);
                }
            } else {
                b->st.flags |= LP_SUB_ITALIC;
            }
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
            /* \clip(x1,y1,x2,y2) and \clip(m 100 0 l 200 0 ...) share the
             * leading letter with \c, so it has to be checked first. */
            if (!strncmp(p, "lip", 3)) {
                p += 3;
                if (*p == '(') {
                    p++;
                    double v[4];
                    int n = path_numbers(&p, v, 4);
                    if (n >= 4) {
                        b->st.clip_on = 1;
                        b->st.clip_x1 = v[0];
                        b->st.clip_y1 = v[1];
                        b->st.clip_x2 = v[2];
                        b->st.clip_y2 = v[3];
                    }
                    /* A vector clip (``\clip(1,m 0 0 l ...)'') is not a
                     * rectangle; skipping it is better than clipping the
                     * whole line away. */
                    while (*p && *p != ')' && *p != '\\' && *p != '}') {
                        p++;
                    }
                    if (*p == ')') {
                        p++;
                    }
                }
                break;
            }
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
            /* An empty value means "no change"; a parsed colour is always
             * taken literally.  \1c&HFFFFFF& really is white — treating it
             * as "inherit" silently dropped the most common karaoke and
             * fade-to-white animation there is. */
            uint32_t parsed = n ? ass_color(color) : 0;
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
            } else if (*p == 'r') {
                /* \fr45 是 \frz 的简写，`\fr<N>` 这种「只有角度、没有轴」的写法
                 * 恰恰是旋转最常用的形式。以前这里用 `!tag_has_arg(p + 1)` 当作
                 * 「没有后缀」的判据，而 \fr45 的参数本身就是数字，条件不成立，
                 * 于是整条分支进不去：不旋转、也不报错。到了这一步 rz/rx/ry 已经
                 * 被上面的分支吃掉，剩下的 'r' 只可能是 \fr 本身。 */
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
            } else if (!strncmp(p, "lpha", 4) || channel == 1) {
                /* \alpha&H80& and \1a&H80& both mean "text opacity"; ASS
                 * stores the inverse of alpha, so FF (transparent) -> 0.0
                 * and 00 (opaque) -> 1.0.  \2a/\3a/\4a target the other
                 * slots, which the Flutter renderer does not paint. */
                if (!strncmp(p, "lpha", 4)) {
                    p += 4;
                }
                const char *start = p;
                while (*p && *p != '\\' && *p != '}') {
                    p++;
                }
                char buf[32];
                size_t n = (size_t)(p - start);
                if (n >= sizeof(buf)) {
                    n = sizeof(buf) - 1;
                }
                memcpy(buf, start, n);
                buf[n] = '\0';
                if (n > 0) {
                    unsigned long raw = 0;
                    const char *d = buf;
                    if (*d == '&') {
                        d++;
                        if (*d == 'H' || *d == 'h') {
                            d++;
                        }
                        raw = strtoul(d, NULL, 16);
                    } else {
                        raw = strtoul(d, NULL, 10);
                    }
                    /* \alpha&H80& carries a single bytes worth of alpha, not
                     * the high byte of a colour: taking (raw >> 24) made every
                     * two-digit value look fully opaque, which is why fade-ins
                     * never appeared.  An eight-digit value is a whole colour
                     * and does put the alpha in the top byte. */
                    unsigned aa = raw > 0xFFul ? (unsigned)((raw >> 24) & 0xFFu)
                                               : (unsigned)(raw & 0xFFu);
                    b->st.alpha = 1.0 - (double)aa / 255.0;
                }
            } else {
                while (*p && *p != '\\' && *p != '}') {
                    p++;
                }
            }
            break;
        case 'k':
            /* \k<cs> plain karaoke, \kf sweep, \ko outline fade, \K = \kf.
             * The number is centiseconds and applies to the glyphs that
             * follow, so it is only parked in the state until the next run
             * is appended. */
            {
                int kind = 1;
                if (*p == 'f' || *p == 'F') {
                    kind = 2;
                    p++;
                } else if (*p == 'o' || *p == 'O') {
                    kind = 3;
                    p++;
                }
                if (tag_number(&p, &num) == 0 && num >= 0) {
                    b->st.karaoke_pending_kind = kind;
                    b->st.karaoke_pending_ms = num * 10.0; /* cs -> ms */
                }
            }
            break;
        case 'K':
            if (tag_number(&p, &num) == 0 && num >= 0) {
                b->st.karaoke_pending_kind = 2;
                b->st.karaoke_pending_ms = num * 10.0;
            }
            break;
        case 't': {
            /* \t(<tags>) / \t(<t1>,<tags>) / \t(<t1>,<t2>,<accel>,<tags>)
             *
             * The inner tags are parsed against a copy of the current state
             * and only the fields that actually changed become animated. That
             * keeps \t(\1c&HFFFFFF&) from also freezing the font size, which
             * is what would happen if the whole state were snapshotted. */
            const char *inner = NULL;
            if (*p == '(') {
                p++;
                LpSubAnim a;
                memset(&a, 0, sizeof(a));
                anim_window(&p, &a, b->cue ? (double)(b->cue->end_us - b->cue->start_us) / 1000.0 : 0.0);
                while (*p == ',' || *p == ' ') {
                    p++;
                }
                if (*p != ')' && *p != '\0') {
                    const char *start = p;
                    int depth = 1;
                    while (*p) {
                        if (*p == '(') {
                            depth++;
                        } else if (*p == ')') {
                            depth--;
                            if (depth == 0) {
                                break;
                            }
                        }
                        p++;
                    }
                    inner = start;
                    size_t n = (size_t)(p - start);
                    char *tags = malloc(n + 3);
                    if (tags) {
                        tags[0] = '{';
                        memcpy(tags + 1, inner, n);
                        tags[n + 1] = '}';
                        tags[n + 2] = '\0';
                        SubRunState tmp = b->st;
                        tmp.anims = NULL;
                        tmp.nb_anims = tmp.cap_anims = 0;
                        tmp.path = NULL;
                        tmp.nb_path = tmp.cap_path = 0;
                        tmp.path_sub = b->st.path_sub;
                        tmp.karaoke_pending_kind = 0;
                        tmp.karaoke_pending_ms = 0.0;
                        SubRich shim;
                        memset(&shim, 0, sizeof(shim));
                        shim.cue = b->cue;
                        shim.st = tmp;
                        shim.st.border = -1;
                        shim.st.shadow = -1;
                        apply_override(tags, ctx, &shim);
                        SubRunState *r = &shim.st;
                        if (r->color != tmp.color) {
                            a.fields |= LP_SUB_ANIM_COLOR;
                            a.color = r->color;
                        }
                        if (r->scale_x != tmp.scale_x) {
                            a.fields |= LP_SUB_ANIM_SCALE_X;
                            a.scale_x = r->scale_x;
                        }
                        if (r->scale_y != tmp.scale_y) {
                            a.fields |= LP_SUB_ANIM_SCALE_Y;
                            a.scale_y = r->scale_y;
                        }
                        if (r->font_scale != tmp.font_scale) {
                            a.fields |= LP_SUB_ANIM_FONT;
                            a.font_scale = r->font_scale;
                        }
                        if (r->angle != tmp.angle) {
                            a.fields |= LP_SUB_ANIM_ANGLE;
                            a.angle = r->angle;
                        }
                        if (r->spacing != tmp.spacing) {
                            a.fields |= LP_SUB_ANIM_SPACING;
                            a.spacing = r->spacing;
                        }
                        if (r->border != tmp.border) {
                            a.fields |= LP_SUB_ANIM_BORDER;
                            a.border = r->border;
                        }
                        if (r->shadow != tmp.shadow) {
                            a.fields |= LP_SUB_ANIM_SHADOW;
                            a.shadow = r->shadow;
                        }
                        if (r->alpha != tmp.alpha) {
                            a.fields |= LP_SUB_ANIM_ALPHA;
                            a.alpha = r->alpha;
                        }
                        if (r->clip_on && (!tmp.clip_on ||
                                           r->clip_x2 != tmp.clip_x2 ||
                                           r->clip_x1 != tmp.clip_x1)) {
                            a.fields |= LP_SUB_ANIM_CLIP;
                            a.clip_on = r->clip_on;
                            a.clip_x1 = r->clip_x1;
                            a.clip_y1 = r->clip_y1;
                            a.clip_x2 = r->clip_x2;
                            a.clip_y2 = r->clip_y2;
                        }
                        if (a.fields) {
                            anim_add(&b->st, &a);
                        }
                        free(tags);
                    }
                    if (*p == ')') {
                        p++;
                    }
                }
            } else {
                /* \t without parentheses is malformed; skip to the next tag. */
                while (*p && *p != '\\' && *p != '}') {
                    p++;
                }
            }
            break;
        }
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
                int scale = (int)num;
                if (scale > 0) {
                    /* Entering drawing mode.  The exponent says how many
                     * script units one drawing pixel is worth, so the shape
                     * has to be scaled on screen by 2^scale relative to the
                     * text coordinate system. */
                    if (!b->drawing) {
                        b->st.nb_path = 0;
                        b->st.path_sub = -1;
                    }
                    b->drawing = 1;
                    b->st.drawing_scale = scale;
                } else {
                    if (b->st.nb_path > 0) {
                        sub_rich_flush_drawing(b);
                    }
                    b->drawing = 0;
                    /* \p0 ends the shape; the scale has to go with it or the
                     * text that follows inherits "drawing" and is dropped. */
                    b->st.drawing_scale = 0;
                }
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
            b->st.alpha = 1.0;
            b->st.font_name[0] = '\0';
            b->st.clip_on = 0;
            b->st.clip_inverse = 0;
            b->st.nb_path = 0;
            b->st.path_sub = -1;
            b->st.drawing_scale = 0;
            b->st.karaoke_pending_kind = 0;
            b->st.karaoke_pending_ms = 0.0;
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


/* A finished vector drawing becomes a drawable run of its own: the renderer
 * needs the point list, the fill colour and the scale, not the command text. */
static int sub_rich_flush_drawing(SubRich *b)
{
    if (b->st.nb_path < 2) {
        b->st.nb_path = 0;
        b->st.path_sub = -1;
        return 0;
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
    r->text = strdup("");
    if (!r->text) {
        return -1;
    }
    r->flags = b->st.flags;
    r->color = b->st.color ? b->st.color : 0xFFFFFFFF;
    r->outline_color = b->st.outline_color;
    r->back_color = b->st.back_color;
    r->font_scale = b->st.font_scale;
    r->scale_x = b->st.scale_x;
    r->scale_y = b->st.scale_y;
    r->angle = b->st.angle;
    r->border = b->st.border;
    r->shadow = b->st.shadow;
    r->alpha = b->st.alpha;
    r->drawing_scale = b->st.drawing_scale;
    snprintf(r->font_name, sizeof(r->font_name), "%s", b->st.font_name);
    r->clip_on = b->st.clip_on;
    r->clip_inverse = b->st.clip_inverse;
    r->clip_x1 = b->st.clip_x1;
    r->clip_y1 = b->st.clip_y1;
    r->clip_x2 = b->st.clip_x2;
    r->clip_y2 = b->st.clip_y2;
    if (b->st.nb_anims > 0) {
        r->anims = malloc((size_t)b->st.nb_anims * sizeof(LpSubAnim));
        if (!r->anims) {
            free(r->text);
            r->text = NULL;
            return -1;
        }
        memcpy(r->anims, b->st.anims, (size_t)b->st.nb_anims * sizeof(LpSubAnim));
        r->nb_anims = b->st.nb_anims;
    }
    r->path = b->st.path;
    r->nb_path = b->st.nb_path;
    b->st.path = NULL;
    b->st.nb_path = b->st.cap_path = 0;
    b->st.path_sub = -1;
    b->nb++;
    return 0;
}

/* Compiles one dialogue body into cue->text plus (when the line actually
 * changes style mid-sentence) cue->runs.  Returns 0, or -1 on OOM. */
int lp_sub_compile_text(const char *in, LpSubCue *cue, const AssCtx *ctx)
{
    SubRich b;
    lp_sub_rich_init(&b, cue);
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
            if (!b.drawing && lp_sub_rich_append(&b, &ch, 1) != 0) {
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
            if (!b.drawing && lp_sub_rich_append(&b, " ", 1) != 0) {
                rc = -1;
                break;
            }
            p += 6;
            continue;
        }
        if (*p == '\r' || *p == '\n') {
            if (!b.drawing && lp_sub_rich_append(&b, "\n", 1) != 0) {
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
            if (b.drawing) {
                /* Inside {\p1} the body is a shape description, not text. */
                if (path_consume(&b.st, start) != 0) {
                    rc = -1;
                    break;
                }
            } else if (lp_sub_rich_append(&b, start, (size_t)(p - start)) != 0) {
                rc = -1;
                break;
            }
        } else {
            /* A lone backslash (not \N, \n, \h): keep the byte. */
            if (!b.drawing && lp_sub_rich_append(&b, p, 1) != 0) {
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
                b.runs[i].font_name[0] || b.runs[i].scale_x != 0.0 ||
                b.runs[i].scale_y != 0.0 || b.runs[i].spacing != 0.0 ||
                b.runs[i].angle != 0.0 || b.runs[i].border >= 0 ||
                b.runs[i].shadow >= 0 || b.runs[i].alpha != 1.0 ||
                b.runs[i].karaoke_kind || b.runs[i].nb_anims > 0 ||
                b.runs[i].nb_path > 0 || b.runs[i].clip_on) {
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
    lp_sub_rich_free(&b);
    if (rc != 0) {
        free(cue->text);
        cue->text = NULL;
    }
    return rc;
}

/* Appends an already compiled cue to a builder that is collecting several
 * rectangles (an ASS packet can carry more than one line). */
int lp_sub_merge_cue_into(SubRich *dst, LpSubCue *src)
{
    if (dst->plain.len > 0) {
        if (lp_sub_rich_append(dst, "\n", 1) != 0) {
            return -1;
        }
    }
    /* \pos, \an and the margins live on the cue, not on a run, and every
     * rectangle is compiled into its own temporary cue before being merged
     * here.  Without this the tags were parsed, stored on `src`, and dropped
     * on the floor: an embedded ASS track lost \pos entirely (the overlay
     * then fell back to the alignment default).  Only copy what the source
     * actually set - -1 / 0 mean "not specified", and a later rectangle
     * without the tag must not blank out an earlier one that had it. */
    if (src->pos_x >= 0.0 && src->pos_y >= 0.0) {
        dst->cue->pos_x = src->pos_x;
        dst->cue->pos_y = src->pos_y;
    }
    if (src->margin_l >= 0.0) {
        dst->cue->margin_l = src->margin_l;
    }
    if (src->margin_r >= 0.0) {
        dst->cue->margin_r = src->margin_r;
    }
    if (src->margin_v >= 0.0) {
        dst->cue->margin_v = src->margin_v;
    }
    if (src->align_override) {
        dst->cue->align_override = src->align_override;
    }
    if (src->nb_runs > 0 && src->runs) {
        for (int i = 0; i < src->nb_runs; i++) {
            LpSubRun *run = &src->runs[i];
            dst->st.flags = run->flags;
            dst->st.color = run->color;
            dst->st.outline_color = run->outline_color;
            dst->st.back_color = run->back_color;
            dst->st.font_scale = run->font_scale;
            dst->st.scale_x = run->scale_x;
            dst->st.scale_y = run->scale_y;
            dst->st.spacing = run->spacing;
            dst->st.angle = run->angle;
            dst->st.border = run->border;
            dst->st.shadow = run->shadow;
            dst->st.alpha = run->alpha;
            dst->st.clip_on = run->clip_on;
            dst->st.clip_inverse = run->clip_inverse;
            dst->st.clip_x1 = run->clip_x1;
            dst->st.clip_y1 = run->clip_y1;
            dst->st.clip_x2 = run->clip_x2;
            dst->st.clip_y2 = run->clip_y2;
            dst->st.drawing_scale = run->drawing_scale;
            snprintf(dst->st.font_name, sizeof(dst->st.font_name), "%s",
                     run->font_name);
            /* The karaoke cursor and the animation list are positional: the
             * merge helper must not inherit them, or run i+1 would restart
             * where run i ended.  sub_rich_append re-copies the animation
             * list from dst->st.anims, so keep that in sync below. */
            dst->st.nb_anims = 0;
            dst->st.nb_path = 0;
            /* sub_rich_append 有三条路径不新增 run：空文本、正文已达上限、
             * 样式与上一条相同于是并进上一条。前两条什么都没追加，此时
             * dst->runs[dst->nb - 1] 指向的是**上一条** run，下面的
             * free + memcpy 会把那一条的动画覆盖掉 —— 表现为多 rect 字幕
             * 里某一块跑到别处，或者前半截突然开始旋转。
             *
             * 并进上一条那一支则必须照常嫁接：合并的前提就是上一条
             * nb_anims == 0（且没有待定的卡拉 OK 时长），所以
             * free(made->anims) 是 free(NULL)，拷贝过去刚好把这组动画
             * 挂到已经包含新文本的那条 run 上，正是想要的效果。 */
            const int runs_before = dst->nb;
            const int plain_before = dst->plain.len;
            if (lp_sub_rich_append(dst, run->text, strlen(run->text)) != 0) {
                return -1;
            }
            if (dst->nb <= runs_before && dst->plain.len <= plain_before) {
                /* 什么都没追加，这条 run 的内容无处可去，跳过。 */
                continue;
            }
            /* Now graft the source run's payload onto the run we just built. */
            LpSubRun *made = &dst->runs[dst->nb - 1];
            if (run->nb_anims > 0) {
                free(made->anims);
                made->anims = malloc((size_t)run->nb_anims * sizeof(LpSubAnim));
                if (!made->anims) {
                    made->nb_anims = 0;
                    return -1;
                }
                memcpy(made->anims, run->anims, (size_t)run->nb_anims * sizeof(LpSubAnim));
                made->nb_anims = run->nb_anims;
            }
            made->karaoke_kind = run->karaoke_kind;
            made->karaoke_start_ms = run->karaoke_start_ms;
            made->karaoke_end_ms = run->karaoke_end_ms;
            if (run->nb_path > 0) {
                free(made->path);
                made->path = malloc((size_t)run->nb_path * sizeof(LpSubPathPoint));
                if (!made->path) {
                    made->nb_path = 0;
                    return -1;
                }
                memcpy(made->path, run->path, (size_t)run->nb_path * sizeof(LpSubPathPoint));
                made->nb_path = run->nb_path;
            }
        }
    } else if (src->text) {
        dst->st.flags = 0;
        dst->st.color = 0;
        dst->st.outline_color = 0;
        dst->st.back_color = 0;
        dst->st.font_scale = 0;
        dst->st.scale_x = 0;
        dst->st.scale_y = 0;
        dst->st.spacing = 0;
        dst->st.angle = 0;
        dst->st.border = -1;
        dst->st.shadow = -1;
        dst->st.alpha = 1.0;
        dst->st.clip_on = 0;
        dst->st.drawing_scale = 0;
        dst->st.nb_anims = 0;
        dst->st.nb_path = 0;
        dst->st.font_name[0] = '\0';
        if (lp_sub_rich_append(dst, src->text, strlen(src->text)) != 0) {
            return -1;
        }
    }
    dst->st.flags = 0;
    dst->st.color = 0;
    dst->st.outline_color = 0;
    dst->st.back_color = 0;
    dst->st.font_scale = 0;
    dst->st.scale_x = 0;
    dst->st.scale_y = 0;
    dst->st.spacing = 0;
    dst->st.angle = 0;
    dst->st.border = -1;
    dst->st.shadow = -1;
    dst->st.alpha = 1.0;
    dst->st.clip_on = 0;
    dst->st.drawing_scale = 0;
    dst->st.nb_anims = 0;
    dst->st.nb_path = 0;
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

/* 行缓冲按字节截断时会把一个多字节字符切成两半。这里把尾巴上那半个
 * 序列去掉：从末尾往前数续字节（10xxxxxx），数到首字节时看它声明了
 * 几个字节；声明数大于实际剩下的，说明这个字符被切断了，整段删掉。 */
static void truncate_partial_utf8(char *s)
{
    size_t n = strlen(s);
    if (n == 0) {
        return;
    }
    size_t cont = 0;
    while (cont < n && cont < 3 && ((unsigned char)s[n - 1 - cont] & 0xC0) == 0x80) {
        cont++;
    }
    if (cont >= n) {
        /* 整行都是续字节：不是合法 UTF-8，清空交给上层丢弃。 */
        s[0] = '\0';
        return;
    }
    const unsigned char lead = (unsigned char)s[n - 1 - cont];
    const size_t need = lead < 0x80 ? 1 : (lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4));
    if (need == 1) {
        /* 末尾没有续字节，且首字节本身合法：这一行是完整的。 */
        return;
    }
    if (need > cont + 1) {
        s[n - 1 - cont] = '\0';
    }
}

/* SRT (and WebVTT, which shares the shape): a timing line followed by one or
 * more text lines, blank line terminated.  Index lines are simply skipped. */
int lp_sub_parse_srt(const char *text, LpSubtitleTrack *t, char *err, size_t errlen)
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
            /* srt_next_line 按字节拷进 2048 字节的 line，超长行会在多字节
             * 字符中间断掉。这里把尾巴上那半个字符退回，交给下一轮再拼 ——
             * 否则整条字幕的 JSON 都会变成非法 UTF-8。 */
            truncate_partial_utf8(txt);
            lp_str_append(&body, "%s\n", txt);
        }
        if (body.len > 0) {
            AssCtx ctx;
            memset(&ctx, 0, sizeof(ctx));
            ctx.base = lp_sub_track_style(t, 0);
            LpSubCue cue;
            memset(&cue, 0, sizeof(cue));
            cue.start_us = start;
            cue.end_us = end;
            cue.pos_x = -1.0;
            cue.pos_y = -1.0;
            cue.margin_l = -1.0;
            cue.margin_r = -1.0;
            cue.margin_v = -1.0;
            if (lp_sub_compile_text(body.p ? body.p : "", &cue, &ctx) == 0 &&
                lp_sub_track_add_cue_full(t, &cue) == 0) {
                count++;
            } else {
                lp_sub_cue_free(&cue);
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

/* Splits `line` on `sep` into at most `max` fields and returns how many were
 * actually written.  Callers that pass a small `max` (the Dialogue path stops
 * one field short so that Text keeps its commas) must use the return value:
 * everything past it is untouched stack memory, not an empty string. */
int lp_sub_split_fields(char *line, char sep, char **fields, int max)
{
    int n = 0;
    if (max <= 0) {
        return 0;
    }
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
    return n;
}

/* Reads PlayResX/PlayResY out of an ASS ``[Script Info]`` header.  Embedded
 * tracks keep that header in the codec extradata rather than in the packets,
 * so the packet path cannot reuse lp_sub_parse_ass(); this is the small piece of it
 * that translates script coordinates.  Leaves the outputs untouched when the
 * header does not name them (100 is the same floor lp_sub_parse_ass() applies). */
void lp_sub_script_resolution(const char *text, size_t len, double *play_w,
                              double *play_h)
{
    if (!text || len == 0) {
        return;
    }
    for (size_t i = 0; i + 9 < len; i++) {
        if (i > 0 && text[i - 1] != '\n' && text[i - 1] != '\r') {
            continue;
        }
        if (strncmp(text + i, "PlayResX:", 9) == 0) {
            double v = atof(text + i + 9);
            if (v >= 100.0) {
                *play_w = v;
            }
        } else if (strncmp(text + i, "PlayResY:", 9) == 0) {
            double v = atof(text + i + 9);
            if (v >= 100.0) {
                *play_h = v;
            }
        }
    }
}

int lp_sub_parse_ass(const char *text, LpSubtitleTrack *t, char *err, size_t errlen)
{
    char *copy = lp_str_dup(text);
    if (!copy) {
        return -1;
    }
    /* Style format map. */
    int f_name = -1, f_font = -1, f_size = -1, f_color = -1, f_bold = -1, f_italic = -1;
    int f_outline = -1, f_outcolor = -1, f_align = -1, f_seccolor = -1;
    int f_backcolor = -1, f_shadow = -1, f_border = -1, f_spacing = -1;
    int f_scalex = -1, f_scaley = -1, f_angle = -1;
    int f_ml = -1, f_mr = -1, f_mv = -1;
    char *e_name = NULL, *e_start = NULL, *e_end = NULL, *e_text = NULL, *e_style = NULL;
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
            lp_sub_split_fields(line + 7, ',', fields, 64);
            for (int i = 0; i < 64; i++) {
                while (*fields[i] == ' ') fields[i]++;
                char *end = fields[i] + strlen(fields[i]);
                while (end > fields[i] && (end[-1] == ' ')) *--end = '\0';
                if (!strcmp(fields[i], "Name")) f_name = i;
                else if (!strcmp(fields[i], "Fontname")) f_font = i;
                else if (!strcmp(fields[i], "Fontsize")) f_size = i;
                else if (!strcmp(fields[i], "PrimaryColour")) f_color = i;
                else if (!strcmp(fields[i], "SecondaryColour")) f_seccolor = i;
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
            lp_sub_split_fields(line + 6, ',', fields, 64);
            if (lp_sub_track_ensure_style(t, t->nb_styles + 1) != 0) {
                continue;
            }
            LpSubStyle *s = &t->styles[t->nb_styles];
            lp_sub_style_default(s);
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
            s->play_res_x = play_w;
            if (f_color >= 0) s->color = ass_color(fields[f_color]);
            if (f_seccolor >= 0) {
                s->secondary_color = ass_color(fields[f_seccolor]);
            }
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
            const int got = lp_sub_split_fields(line + 7, ',', fields, 64);
            /* e_* 这几个下标跨 Format: 行复用，换一条 Format: 时必须整体
             * 重算：否则上一条给的 e_style 会留在这一条上，指到一个这条
             * Format: 里根本不存在（或含义不同）的列。 */
            e_name = e_start = e_end = e_text = e_style = NULL;
            for (int i = 0; i < got; i++) {
                while (*fields[i] == ' ') fields[i]++;
                char *end = fields[i] + strlen(fields[i]);
                while (end > fields[i] && end[-1] == ' ') *--end = '\0';
                if (!strcmp(fields[i], "Start")) e_start = (char *)(intptr_t)i;
                else if (!strcmp(fields[i], "End")) e_end = (char *)(intptr_t)i;
                else if (!strcmp(fields[i], "Text")) e_text = (char *)(intptr_t)i;
                else if (!strcmp(fields[i], "Style")) e_style = (char *)(intptr_t)i;
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
            if (text_idx < 1) {
                text_idx = 1;
            }
            if (text_idx > 63) {
                text_idx = 63;
            }
            if (!e_start || !e_end) {
                continue;
            }
            const int start_idx = (int)(intptr_t)e_start;
            const int end_idx = (int)(intptr_t)e_end;
            /* 切分的上界要盖住**所有**会用到的下标，而不是只到正文那一格。
             * 正文通常排在最后（这时上界就是 text_idx，正文里的逗号不会被
             * 切断），但 Format: 也允许 Time/Text 的任意列序 —— 例如
             * ``Format: Text, Start, End`` 时正文下标是 1、结束时间是 2，
             * 只切到正文就会让时间两格落进 split_fields 没写过的区域，
             * parse_clock 读的就是未初始化的栈。 */
            int split_max = text_idx;
            if (start_idx > split_max) {
                split_max = start_idx;
            }
            if (end_idx > split_max) {
                split_max = end_idx;
            }
            if (split_max > 62) {
                split_max = 62; /* fields 是 64 项，给未终结的正文留一点余量 */
            }
            const int got = lp_sub_split_fields(body, ',', fields, split_max + 1);
            int64_t start = 0, end = 0;
            /* got 是这一行真正切出来的段数，可能少于 Format: 声明的列数
             * （手写的半截行）。下标一旦越过 got，读到的就是 fields[got..]
             * 那片没写过的栈，所以三处都得先确认下标落在 got 之内。 */
            if (start_idx >= got || end_idx >= got || text_idx >= got) {
                continue;
            }
            if (parse_clock(fields[start_idx], &start, ',') != 0 ||
                parse_clock(fields[end_idx], &end, ',') != 0) {
                continue;
            }
            /* Resolve the named style so inline tags that "inherit" get the
             * right base, and so \r falls back to it. */
            int style_idx = 0;
            if (e_style && (int)(intptr_t)e_style < got) {
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
            if (lp_sub_compile_text(fields[text_idx], &cue, &ctx) == 0 &&
                lp_sub_track_add_cue_full(t, &cue) == 0) {
                count++;
            } else {
                lp_sub_cue_free(&cue);
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

int lp_sub_parse_vtt(const char *text, LpSubtitleTrack *t, char *err, size_t errlen)
{
    /* WebVTT is close enough to SRT for the common case: reuse the SRT parser
     * after dropping the header and cue identifiers. */
    const char *p = text;
    if (strncmp(p, "WEBVTT", 6) == 0) {
        const char *nl = strpbrk(p, "\r\n");
        p = nl ? nl + 1 : p + 6;
    }
    int n = lp_sub_parse_srt(p, t, err, errlen);
    if (n > 0) {
        return n;
    }
    snprintf(err, errlen, "no cues parsed (WebVTT)");
    return -1;
}

/* -------------------------------------------------------------- lifecycle --- */

