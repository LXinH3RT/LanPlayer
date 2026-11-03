/*
 * 字幕轨道与图形字幕 overlay：内嵌轨道的解码与状态机、外挂文件的
 * 发现与加载、以及把 CPU 位图（PGS/VobSub/DVB）合进画面上。
 *
 * 这里的每个入口都在 p->subs.mutex 下运行。文本格式的一切都交给
 * subtitle_parse.c，这一层只负责「什么时候显示哪一条」。
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

static void overlay_rect_unref(LpSubOverlayRect *r)
{
    if (!r->rgba) {
        return;
    }
    if (atomic_fetch_sub(&r->refs, 1) == 1) {
        free(r->rgba);
        r->rgba = NULL;
    }
}

static void overlay_rect_ref(LpSubOverlayRect *r)
{
    atomic_fetch_add(&r->refs, 1);
}

static void overlay_rect_set(LpSubOverlayRect *r, const LpSubBitmap *b)
{
    atomic_store(&r->refs, 1);
    r->x = b->x;
    r->y = b->y;
    r->w = b->w;
    r->h = b->h;
}

void lp_sub_overlay_reset(LpSubOverlay *ov)
{
    for (int i = 0; i < ov->nb; i++) {
        overlay_rect_unref(&ov->rects[i]);
    }
    ov->nb = 0;
    ov->first = -1;
    ov->count = 0;
    ov->version++;
}

void lp_sub_cue_free(LpSubCue *c)
{
    free(c->text);
    c->text = NULL;
    for (int i = 0; i < c->nb_runs; i++) {
        free(c->runs[i].text);
        free(c->runs[i].anims);
        free(c->runs[i].path);
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
        overlay_rect_set(r, b);
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
void lp_sub_overlay_update(LpPlayer *p, LpSubtitleTrack *t, int64_t t_now)
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
            lp_sub_overlay_reset(ov);
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
    lp_sub_overlay_reset(ov);
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
            lp_sub_overlay_reset(ov);
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
        /* 只加引用，不复制像素：一块 PGS 位图动辄几百 KB，以前每个渲染帧
         * 都要 malloc + memcpy 一遍所有矩形。持有引用之后，overlay 那边
         * 重置也只是把引用放掉，我们手上这块内存照样有效。 */
        for (int i = 0; i < nb; i++) {
            overlay_rect_ref(&ov->rects[i]);
            snap[i] = ov->rects[i]; /* 连同刚加上去的引用一起抄走 */
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
            overlay_rect_unref(r);
            continue;
        }
        /* 目标列 -> 源列 的映射表：以前每像素算一次
         * (int64_t)x * r->w / dw，除数是变量，编译器没法用乘移位代替，
         * 一张 1080p 的 PGS 位图要因此做上百万次整数除法。按 512 列一段
         * 预算好映射，整段列只算一次。 */
        int map_x[512];
        for (int x0 = 0; x0 < dw; x0 += 512) {
            int n = dw - x0;
            if (n > 512) {
                n = 512;
            }
            for (int i = 0; i < n; i++) {
                int sxi = (int)((int64_t)(x0 + i) * r->w / dw);
                map_x[i] = sxi < r->w ? sxi : r->w - 1;
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
                for (int i = 0; i < n; i++) {
                    int tx = dx + x0 + i;
                    if (tx < 0 || tx >= w) {
                        continue;
                    }
                    const uint8_t *s = src_row + (size_t)map_x[i] * 4;
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
        }
        overlay_rect_unref(r);
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
    /* libavcodec 保证 SUBTITLE_BITMAP 的 data[1] 是 256 项 × 4 字节的
     * 调色板，而 src[x] 是 uint8_t，取值天然落在 0..255 —— 所以这里不需要
     * 再夹一次下标。写下来是为了下次有人想「顺手加个长度检查」时知道
     * FFmpeg 并没有把长度交出来，凭空加判断反而会误伤。 */
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

void lp_sub_track_reset(LpSubtitleTrack *t)
{
    for (int i = 0; i < t->nb_cues; i++) {
        lp_sub_cue_free(&t->cues[i]);
    }
    t->nb_cues = 0;
    t->current_cue = -1;
    free(t->styles);
    t->styles = NULL;
    t->nb_styles = 0;
}

int lp_sub_track_ensure_style(LpSubtitleTrack *t, int need)
{
    if (t->nb_styles >= need) {
        return 0;
    }
    /* need 是「要放得下第 need 个样式」，所以容量至少要 need；+4 是余量，
     * 但容量本身不再单独记，只靠 nb_styles 与 realloc 的实参推导。 */
    const int cap = need + 4;
    LpSubStyle *grown = realloc(t->styles, (size_t)cap * sizeof(LpSubStyle));
    if (!grown) {
        return -1;
    }
    t->styles = grown;
    return 0;
}

void lp_sub_style_default(LpSubStyle *s)
{
    memset(s, 0, sizeof(*s));
    snprintf(s->name, sizeof(s->name), "Default");
    s->color = 0xFFFFFFFF;
    /* SecondaryColour is what a karaoke syllable wears *before* it is sung;
     * plain white is the safe default when the style line omits it. */
    s->secondary_color = 0xFFFFFFFF;
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
    s->play_res_x = 1920.0;
    snprintf(s->font_name, sizeof(s->font_name), "sans-serif");
}

LpSubStyle *lp_sub_track_style(LpSubtitleTrack *t, int idx)
{
    if (t->nb_styles == 0) {
        if (lp_sub_track_ensure_style(t, 1) != 0) {
            return NULL;
        }
        lp_sub_style_default(&t->styles[0]);
        t->nb_styles = 1;
    }
    if (idx < 0 || idx >= t->nb_styles) {
        return &t->styles[0];
    }
    return &t->styles[idx];
}

/* Appends a pre-compiled cue: text, styled runs and bitmaps are moved out of
 * *src.  A graphics cue (bitmaps only) is valid without any text. */
int lp_sub_track_add_cue_full(LpSubtitleTrack *t, LpSubCue *src)
{
    /* 只有 \p1 矢量绘图、没有文字的 Dialogue 也是有效字幕（wipe、图形
     * 遮罩、无字的卷首版式全靠它）。判据里必须带上绘图 run，否则整条
     * 被丢掉，用户只能看到一片空白。 */
    int has_text = src->text && *src->text;
    int has_drawing = 0;
    for (int i = 0; i < src->nb_runs && !has_drawing; i++) {
        if (src->runs[i].nb_path > 0) {
            has_drawing = 1;
        }
    }
    if (!has_text && !has_drawing && src->nb_bitmaps == 0) {
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
static int read_whole_file(const char *url, const char *options_json, uint8_t **out,
                           size_t *out_len, char *err, size_t errlen)
{
    LpSourceOptions opts;
    lp_source_options_parse(options_json, &opts);
    LpIo *io = lp_io_open(url, &opts, err, errlen);
    if (!io) {
        return lp_io_last_result();
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

/* t->path 是固定长度缓冲，判重时不能再拿完整 url 去 strcmp：超长路径下
 * 两条不同的 URL 会被截成同一个 path，判定自然失真。这里按「截断之后
 * 相等的两个前缀」比较，与实际存下来的内容保持一致。 */
static int same_subtitle_path(const char *stored, const char *url, size_t cap)
{
    const size_t n = strlen(url);
    const size_t keep = n < cap - 1 ? n : cap - 1;
    return strncmp(stored, url, keep) == 0 && stored[keep] == '\0';
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
        if (p->subs.tracks[i].is_external &&
            same_subtitle_path(p->subs.tracks[i].path, url,
                                sizeof(p->subs.tracks[i].path))) {
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
    char *text = lp_sub_decode_text(raw, raw_len, NULL, &charset_ok);
    free(raw);
    if (!text) {
        return LP_ERR_NOMEM;
    }
    if (!charset_ok) {
        LP_WARN("subtitle", "%s is not valid UTF-8 and no charset converter is available", url);
    }

    /* 扩展名只在最后一段路径里找，并且止步于查询串：整条 URL 上的
     * `strrchr(url, '.')` 会被目录名或查询串里的句点带偏
     * （`.../x.vtt?t=1.srt` 取到 `srt`，SRT 结果被交给 ASS 解析器）。 */
    const char *ext_base = strrchr(url, '/');
    ext_base = ext_base ? ext_base + 1 : url;
    const char *query = strpbrk(ext_base, "?#");
    const char *ext_end = query ? query : ext_base + strlen(ext_base);
    const char *ext = NULL;
    for (const char *q = ext_base; q < ext_end; q++) {
        if (*q == '.') {
            ext = q + 1;
        }
    }
    if (!ext) {
        ext = "";
    }
    pthread_mutex_lock(&p->subs.mutex);
    /* 上面那次解锁去读文件，耗时可能是几十毫秒。这段时间里自动加载、
     * 用户在面板里再点一个文件，都可能占掉 nb 这个槽位或者把 nb_tracks
     * 推到上限 —— 拿旧 nb 直接写 tracks[nb]，轻则两条轨道互相覆盖，
     * 重则写下标 16 的越界写（LP_MAX_SUBTITLE_TRACKS 就是 16）。
     * 所以重新加锁之后必须把槽位号整个重算一遍。 */
    nb = p->subs.nb_tracks;
    if (nb >= LP_MAX_SUBTITLE_TRACKS) {
        pthread_mutex_unlock(&p->subs.mutex);
        return LP_ERR_NOMEM;
    }
    for (int i = 0; i < nb; i++) {
        if (p->subs.tracks[i].is_external &&
            same_subtitle_path(p->subs.tracks[i].path, url,
                                sizeof(p->subs.tracks[i].path))) {
            int existing = p->subs.tracks[i].index;
            pthread_mutex_unlock(&p->subs.mutex);
            return existing;
        }
    }
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
        r = lp_sub_parse_ass(text, t, err, sizeof(err));
    } else if (strcasecmp(ext, "vtt") == 0) {
        r = lp_sub_parse_vtt(text, t, err, sizeof(err));
    } else {
        r = lp_sub_parse_srt(text, t, err, sizeof(err));
        if (r <= 0 && strstr(text, "[Script Info]")) {
            r = lp_sub_parse_ass(text, t, err, sizeof(err));
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
    lp_sub_track_style(t, 0);
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
    /* delay_us 不清零。apply_open_options 是在起 open 线程之前跑的，
     * 设置里的字幕平移那会儿就已经写进来了；这里一清零，用户设的延迟
     * 在每一部片子上都被静默丢掉（界面上还显示着那个值）。 */
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
                lp_sub_track_style(t, 0);
                /* The style was just created from lp_sub_style_default() (1920x1080).
                 * If the muxer stored the ASS header, it also recorded the
                 * real PlayRes - use it so \pos lands where the author meant
                 * rather than a scaled guess. */
                if (st->codecpar->extradata && st->codecpar->extradata_size > 0) {
                    double pw = t->styles[0].play_res_x;
                    double ph = t->styles[0].play_res_y;
                    lp_sub_script_resolution((const char *)st->codecpar->extradata,
                                      (size_t)st->codecpar->extradata_size, &pw, &ph);
                    t->styles[0].play_res_x = pw;
                    t->styles[0].play_res_y = ph;
                    LP_DEBUG("subtitle", "track #%u script resolution %.0fx%.0f", i, pw,
                             ph);
                }
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
    /* 必须持锁：tick 线程每 20ms 醒一次，只要状态是 PLAYING 就会调
     * lp_subtitle_tick()，而后者持同一把锁遍历 t->cues[i] 读 start_us 与
     * text。lp_player_close() 直到很后面才把 opened 置 0、状态切 IDLE，
     * 中间这段窗口里 tick 仍在跑；以前这里不加锁就 lp_sub_track_reset() 释放
     * cue，正在播放时点「停止」「返回」「切集」有概率读到已释放的内存
     * （SIGSEGV，或者更糟的静默堆损坏）。
     *
     * 不销毁 p->subs.mutex：它属于播放器对象本身（lp_player_destroy 负责
     * 销毁）。关片之后 Dart 侧仍可能调 setOption("subtitle_delay")，那把
     * 锁必须还活着。 */
    pthread_mutex_lock(&p->subs.mutex);
    lp_sub_overlay_reset(&p->subs.overlay);
    for (int i = 0; i < p->subs.nb_tracks; i++) {
        LpSubtitleTrack *t = &p->subs.tracks[i];
        lp_sub_track_reset(t);
        if (t->avctx) {
            avcodec_free_context(&t->avctx);
        }
    }
    p->subs.nb_tracks = 0;
    p->subs.selected = -1;
    p->subs.dirty = 0;
    pthread_mutex_unlock(&p->subs.mutex);
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
            lp_sub_cue_free(&t->cues[k]);
        }
        t->nb_cues = 0;
        t->current_cue = -1;
        lp_sub_overlay_reset(&p->subs.overlay);
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
    lp_sub_rich_init(&merged, &cue);
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
        /* Embedded tracks carry dialogue lines, not a whole script file, so
         * there is no [Script Info] header in the packets themselves and
         * memset left both at zero.  Every tag that turns script coordinates
         * into screen ones (\\pos, \\fs, \\clip, \\p) is gated on ctx->play_w
         * and ctx->play_h being positive, so an embedded ASS track silently
         * ignored all of them - the very same file loaded sidecar was fine.
         * The real PlayRes lives in the track's extradata (the ASS header the
         * muxer stored once), so prefer that and fall back to the track style,
         * which lp_sub_track_style() always creates with the 1920x1080 default. */
        if (t->nb_styles > 0) {
            ctx.play_w = t->styles[0].play_res_x;
            ctx.play_h = t->styles[0].play_res_y;
            ctx.base = &t->styles[0];
        }
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
            lp_sub_split_fields(copy, ',', fields, 10);
            if (lp_sub_compile_text(fields[9], &one, &ctx) != 0) {
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
            if (lp_sub_compile_text(plain, &one, &ctx) != 0) {
                merge_ok = 0;
            }
        }
        if (merge_ok && lp_sub_merge_cue_into(&merged, &one) != 0) {
            merge_ok = 0;
        }
        lp_sub_cue_free(&one);
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
        if (has_text || cue.nb_bitmaps > 0 || lp_sub_has_drawing_runs(&cue)) {
            if (lp_sub_track_add_cue_full(t, &cue) == 0) {
                keep = 1;
            }
        }
    }
    lp_sub_rich_free(&merged);
    avsubtitle_free(&sub);
    if (keep && t->nb_cues > 512) {
        /* Trim embedded history to keep memory flat for long movies. */
        int drop = t->nb_cues - 512;
        for (int i = 0; i < drop; i++) lp_sub_cue_free(&t->cues[i]);
        memmove(t->cues, t->cues + drop, (size_t)(t->nb_cues - drop) * sizeof(LpSubCue));
        t->nb_cues -= drop;
        /* current_cue 是 cues[] 里的下标，整段前移之后它必须跟着减，
         * 否则它指向的是「前移 drop 条之后」的另一条 —— 轻则同一条字幕
         * 反复重发，重则拿错文本。 */
        if (t->current_cue >= drop) {
            t->current_cue -= drop;
        } else {
            t->current_cue = -1;
        }
    }
    if (!keep) {
        lp_sub_cue_free(&cue);
    }
    pthread_mutex_unlock(&p->subs.mutex);
}

void lp_subtitle_seek(LpPlayer *p, int64_t pos_us)
{
    pthread_mutex_lock(&p->subs.mutex);
    lp_sub_overlay_reset(&p->subs.overlay);
    for (int i = 0; i < p->subs.nb_tracks; i++) {
        LpSubtitleTrack *t = &p->subs.tracks[i];
        if (t->embedded) {
            /* 图形字幕（PGS / VobSub）的显示集只在上屏时刻出现一次，
             * 之后再也不发包。以前这里把解码历史整段丢掉 —— seek 到已经
             * 显示过的位置，画面上的字幕要等下一个显示集（几秒到几十秒）
             * 才回来，中间是被清空的黑屏。文字字幕没这问题，demuxer 会立刻
             * 重喂。
             *
             * 处理办法：留下「仍然覆盖目标位置」的那几条；图形轨道再额外
             * 留下「起始时间在目标之前、离得最近」的那一条，并把它的结束
             * 时间拉到至少 pos_us —— 那就是 seek 时刻本该还在屏幕上显示的
             * 那一张图。 */
            int keep = 0;
            int last_bitmap = -1;
            for (int k = 0; k < t->nb_cues; k++) {
                LpSubCue *c = &t->cues[k];
                int covers = c->start_us <= pos_us && c->end_us > pos_us;
                if (covers) {
                    t->cues[keep++] = *c;
                    continue;
                }
                if (t->bitmap && c->nb_bitmaps > 0 && c->start_us <= pos_us) {
                    if (last_bitmap >= 0) {
                        /* 后面还有更近的候选，这条旧图不要了。 */
                        lp_sub_cue_free(c);
                    } else {
                        last_bitmap = keep;
                        t->cues[keep++] = *c;
                    }
                    continue;
                }
                lp_sub_cue_free(c);
            }
            if (last_bitmap >= 0) {
                LpSubCue *c = &t->cues[last_bitmap];
                if (c->end_us <= pos_us) {
                    c->end_us = p->duration_us > pos_us ? p->duration_us : pos_us + 1000000;
                }
            }
            t->nb_cues = keep;
        }
        t->current_cue = -1;
        if (t->avctx) {
            avcodec_flush_buffers(t->avctx);
        }
    }
    p->subs.dirty = 1;
    pthread_mutex_unlock(&p->subs.mutex);
}

/* One cue style as JSON.  Shared by the whole-cue payload (kept for the plain
 * case) and by the per-line list, which is what lets two simultaneously
 * visible dialogues keep their own colours, weight and box. */
