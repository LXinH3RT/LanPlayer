/*
 * 字幕事件打包：把当前 cue 与它的样式、动画、裁剪矩形打包成
 * LP_EVENT_SUBTITLE 的 JSON，发给 Flutter 侧去排版。
 *
 * 这一层无状态：只读 cue，不修改轨道，也不做解析。文件末尾的
 * lp_sub_test_* 是给原生测试用的行为入口，它们直接调解析段与轨道段
 * 的函数，放在这条最外层，测试才不需要把三段都链进来。
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

static void append_style_json(LpStr *s, const LpSubStyle *st)
{
    lp_str_append(s, "\"bold\":%s,\"italic\":%s,\"underline\":%s,\"strikeout\":%s,",
                  st->bold ? "true" : "false", st->italic ? "true" : "false",
                  st->underline ? "true" : "false", st->strikeout ? "true" : "false");
    lp_str_append(s, "\"color\":%u,\"outline_color\":%u,\"back_color\":%u,",
                  (unsigned)st->color, (unsigned)st->outline_color,
                  (unsigned)st->back_color);
    /* Karaoke needs the "not yet sung" colour as well as the primary one. */
    lp_str_append(s, "\"secondary_color\":%u,", (unsigned)st->secondary_color);
    lp_str_append(s, "\"outline\":%d,\"shadow\":%d,\"border_style\":%d,",
                  st->outline_width, st->shadow, st->border_style);
    lp_str_append(s, "\"spacing\":%.4f,\"scale_x\":%.4f,\"scale_y\":%.4f,\"angle\":%.4f,",
                  st->spacing, st->scale_x, st->scale_y, st->angle);
    lp_str_append(s, "\"margin_l\":%.4f,\"margin_r\":%.4f,\"margin_v\":%.4f,",
                  st->margin_l, st->margin_r, st->margin_v);
    lp_str_append(s, "\"align\":%d,\"font_scale\":%.6f,\"play_res_y\":%.2f,",
                  st->align, st->font_scale, st->play_res_y);
    /* \clip and \p coordinates are in script units on both axes; the width
     * cannot be derived from the height when the script is not 16:9. */
    lp_str_append(s, "\"play_res_x\":%.2f,", st->play_res_x);
    lp_str_append(s, "\"pos_x\":%.4f,\"pos_y\":%.4f,", st->pos_x, st->pos_y);
    lp_str_append(s, "\"font\":");
    lp_str_append_json_str(s, st->font_name);
}

static void emit_subtitle(LpPlayer *p, const char *text, int64_t start_us, int64_t end_us,
                          int64_t now_cue_us, const LpSubStyle *st, const LpStr *runs_json)
{
    LpStr s;
    lp_str_init(&s);
    lp_str_append(&s, "{\"text\":");
    lp_str_append_json_str(&s, text);
    lp_str_append(&s, ",\"start\":%lld,\"end\":%lld,\"now\":%lld,\"style\":{",
                  (long long)start_us, (long long)end_us, (long long)now_cue_us);
    append_style_json(&s, st);
    lp_str_append(&s, "}");
    /* runs 直接接进同一个缓冲区，不再先用 %s 把整段 runs 拷进事件串。 */
    if (runs_json && runs_json->len > 0) {
        lp_str_append_raw(&s, ",\"runs\":[", 9);
        lp_str_append_raw(&s, runs_json->p, runs_json->len);
        lp_str_append_raw(&s, "]", 1);
    }
    lp_str_append(&s, "}");
    /* 直接把 LpStr 的缓冲区交出去：以前走 lp_emit_event(p, LP_EVENT_SUBTITLE,
     * "%s", s.p)，lp_emit_event 内部先 vsnprintf 量长度再 vsnprintf 一遍
     * 格式化，等于把整串（带样式时几 KB）复制两次。动画字幕 50 Hz 发事件，
     * 这两次拷贝纯属浪费。 */
    lp_emit_event_owned(p, LP_EVENT_SUBTITLE, lp_str_take(&s));
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
        LpSubStyle *cst = lp_sub_track_style(t, c->style);
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
                if (r->alpha != 1.0) {
                    lp_str_append(out, ",\"alpha\":%.4f", r->alpha);
                }
                if (r->karaoke_kind) {
                    lp_str_append(out,
                                  ",\"karaoke\":%d,\"karaoke_start\":%.2f,\"karaoke_end\":%.2f",
                                  r->karaoke_kind, r->karaoke_start_ms,
                                  r->karaoke_end_ms);
                }
                if (r->clip_on) {
                    lp_str_append(out,
                                  ",\"clip\":[%.2f,%.2f,%.2f,%.2f],\"clip_inverse\":%s",
                                  r->clip_x1, r->clip_y1, r->clip_x2, r->clip_y2,
                                  r->clip_inverse ? "true" : "false");
                }
                if (r->nb_anims > 0) {
                    lp_str_append(out, ",\"anims\":[");
                    for (int a = 0; a < r->nb_anims; a++) {
                        LpSubAnim *an = &r->anims[a];
                        if (a > 0) {
                            lp_str_append(out, ",");
                        }
                        lp_str_append(out, "{\"t1\":%.2f,\"t2\":%.2f,\"accel\":%.2f,\"f\":%u",
                                      an->t1_ms, an->t2_ms, an->accel,
                                      (unsigned)an->fields);
                        if (an->fields & LP_SUB_ANIM_COLOR) {
                            lp_str_append(out, ",\"color\":%u", (unsigned)an->color);
                        }
                        if (an->fields & LP_SUB_ANIM_SCALE_X) {
                            lp_str_append(out, ",\"scale_x\":%.4f", an->scale_x);
                        }
                        if (an->fields & LP_SUB_ANIM_SCALE_Y) {
                            lp_str_append(out, ",\"scale_y\":%.4f", an->scale_y);
                        }
                        if (an->fields & LP_SUB_ANIM_FONT) {
                            lp_str_append(out, ",\"scale\":%.6f", an->font_scale);
                        }
                        if (an->fields & LP_SUB_ANIM_ANGLE) {
                            lp_str_append(out, ",\"angle\":%.4f", an->angle);
                        }
                        if (an->fields & LP_SUB_ANIM_SPACING) {
                            lp_str_append(out, ",\"spacing\":%.4f", an->spacing);
                        }
                        if (an->fields & LP_SUB_ANIM_BORDER) {
                            lp_str_append(out, ",\"border\":%d", an->border);
                        }
                        if (an->fields & LP_SUB_ANIM_SHADOW) {
                            lp_str_append(out, ",\"shadow\":%d", an->shadow);
                        }
                        if (an->fields & LP_SUB_ANIM_ALPHA) {
                            lp_str_append(out, ",\"alpha\":%.4f", an->alpha);
                        }
                        if (an->fields & LP_SUB_ANIM_CLIP) {
                            lp_str_append(out,
                                          ",\"clip\":[%.2f,%.2f,%.2f,%.2f]",
                                          an->clip_x1, an->clip_y1, an->clip_x2,
                                          an->clip_y2);
                        }
                        lp_str_append(out, "}");
                    }
                    lp_str_append(out, "]");
                }
                if (r->nb_path > 0) {
                    lp_str_append(out, ",\"draw\":%d,\"path\":[", r->drawing_scale);
                    for (int q = 0; q < r->nb_path; q++) {
                        lp_str_append(out, "%s[%d,%.2f,%.2f]", q ? "," : "",
                                      r->path[q].sub, r->path[q].x, r->path[q].y);
                    }
                    lp_str_append(out, "]");
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
                lp_sub_overlay_reset(&p->subs.overlay);
            }
            pthread_mutex_unlock(&p->subs.mutex);
            emit_subtitle(p, "", 0, 0, 0, &(LpSubStyle){0}, NULL);
            return;
        }
        if (p->subs.overlay.nb > 0) {
            lp_sub_overlay_reset(&p->subs.overlay);
        }
        pthread_mutex_unlock(&p->subs.mutex);
        return;
    }
    LpSubtitleTrack *t = &p->subs.tracks[p->subs.selected];
    int64_t t_now = now_us - p->subs.delay_us;
    if (t->bitmap) {
        /* Graphics tracks have no text event: the rectangles are composited by
         * the renderer through p->subs.overlay. */
        lp_sub_overlay_update(p, t, t_now);
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
            emit_subtitle(p, "", 0, 0, 0, &(LpSubStyle){0}, NULL);
        }
        return;
    }
    LpStr text;
    lp_str_init(&text);
    LpStr runs;
    lp_str_init(&runs);
    /* 同屏命中的 cue 下标。原先是个 `int hits[16]` 的定长数组，第 17 条
     * 及以后的 cue 只进了 plain 文本、没进 runs —— 渲染层优先用 runs，
     * 表现就是「双语 + 注释同屏时少了一两行」。这里按需增长。 */
    int *hits = NULL;
    int nb_hits = 0;
    int hits_cap = 0;
    int found = -1;
    int64_t start_us = 0, end_us = 0;
    LpSubStyle style;
    lp_sub_style_default(&style);
    for (int i = 0; i < t->nb_cues; i++) {
        LpSubCue *c = &t->cues[i];
        if (c->start_us > t_now) {
            break;
        }
        if (t_now < c->end_us) {
            /* found / start_us / end_us / style 必须来自同一条 cue。
             * 以前 found 取最后一条、start_us 取第一条、end_us 与 style
             * 取最后一条：双语或「上方注释 + 下方对白」同屏时，事件里的
             * 起始时间会跳回第一条的位置，卡拉 OK 的填色进度
             * （cue_now_us 用的是 found 那条的 start_us）也就跟着错位。
             * 这里 fixed 成「第一条命中」，和 start_us 的口径一致。 */
            if (found < 0) {
                found = i;
            }
            if (text.len) lp_str_append_raw(&text, "\n", 1);
            lp_str_append_raw(&text, c->text, strlen(c->text));
            if (start_us == 0) {
                start_us = c->start_us;
            }
            /* 样式、结束时间、逐条的 {\anN} / {\pos(x,y)} 也只认第一条
             * 命中的 cue：这一条才是 start_us / cue_now_us 的来源，
             * 三样东西同一口径。 */
            if (found == i) {
                end_us = c->end_us;
                LpSubStyle *cs = lp_sub_track_style(t, c->style);
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
            }
            if (nb_hits == hits_cap) {
                const int next = hits_cap == 0 ? 8 : hits_cap * 2;
                int *grown = (int *)realloc(hits, (size_t)next * sizeof(int));
                if (!grown) {
                    break;
                }
                hits = grown;
                hits_cap = next;
            }
            hits[nb_hits++] = i;
        }
    }
    if (nb_hits > 0) {
        append_runs_json(&runs, t, hits, nb_hits);
    }
    /* \t and \k are time driven: the renderer needs the cue-relative clock and
     * a fresh event on every tick while such a cue is on screen.  Repainting
     * 50 times a second for a static line would be waste, so the animated flag
     * is collected while the runs are serialised. */
    int animated = 0;
    for (int k = 0; k < nb_hits && !animated; k++) {
        LpSubCue *c = &t->cues[hits[k]];
        for (int i = 0; i < c->nb_runs; i++) {
            if (c->runs[i].nb_anims > 0 || c->runs[i].karaoke_kind) {
                animated = 1;
                break;
            }
        }
    }
    int changed = (found != t->current_cue) || p->subs.dirty || animated;
    int64_t cue_now_us = 0;
    if (found >= 0) {
        cue_now_us = t_now - t->cues[found].start_us;
        if (cue_now_us < 0) {
            cue_now_us = 0;
        }
    }
    t->current_cue = found;
    pthread_mutex_unlock(&p->subs.mutex);

    if (changed) {
        emit_subtitle(p, text.p ? text.p : "", start_us, end_us, cue_now_us, &style, &runs);
        pthread_mutex_lock(&p->subs.mutex);
        p->subs.dirty = 0;
        pthread_mutex_unlock(&p->subs.mutex);
    }
    lp_str_free(&text);
    lp_str_free(&runs);
    free(hits);
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
    /* 切轨必须顺手清掉图形字幕的 overlay：tick 只在新轨是位图轨时重建它，
     * 从 PGS 切到文本轨、或者直接关字幕，残留下来的矩形会一直贴在画面上。
     * 更长的连锁反应在 Windows 上：win32_platform.c 只要有 overlay 就返回
     * LP_ERR_UNSUPPORTED 让调用方下载回 CPU 混合，残留一次等于永久放弃 GPU
     * 直出。 */
    if (p->subs.overlay.nb > 0) {
        lp_sub_overlay_reset(&p->subs.overlay);
    }
    p->subs.dirty = 1;
    pthread_mutex_unlock(&p->subs.mutex);
}

void lp_subtitle_set_delay(LpPlayer *p, int64_t delay_ms)
{
    if (!p || !p->subs_inited) {
        /* 播放器刚创建、字幕子系统还没起来时内核会先按 open options 调一次。
         * 那时 p->subs.mutex 还没初始化，锁上去是未定义行为。这个值本身也
         * 不需要在这里落下：真正生效的是 p->subs.delay_us，而打开字幕时会
         * 按同一份 options 再设一遍。 */
        return;
    }
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
    lp_sub_style_default(&base);
    LpSubCue cue;
    memset(&cue, 0, sizeof(cue));
    AssCtx ctx;
    ctx.play_w = 384.0;
    ctx.play_h = 288.0;
    ctx.base = &base;
    int rc = lp_sub_compile_text(dialogue_text, &cue, &ctx);
    if (rc != 0) {
        lp_sub_cue_free(&cue);
        return -1;
    }
    uint32_t c = 0, o = 0, k = 0;
    if (run_index >= 0 && run_index < cue.nb_runs) {
        c = cue.runs[run_index].color;
        o = cue.runs[run_index].outline_color;
        k = cue.runs[run_index].back_color;
    }
    lp_sub_cue_free(&cue);
    if (color) *color = c;
    if (outline_color) *outline_color = o;
    if (back_color) *back_color = k;
    return 0;
}

/* 测试入口：编一段 ASS 行，把第 run_index 个 run 的时间类特性（动画条数、
 * 首条动画的窗口与字段、卡拉 OK 区间、\clip 矩形、矢量点列）抄出来。仅供
 * native/tests/lp_subanim_test.c 使用。 */
int lp_sub_test_parse_anim(const char *dialogue_text, int run_index,
                           int64_t cue_dur_us, LpSubTestAnim *out)
{
    if (!out) {
        return -1;
    }
    memset(out, 0, sizeof(*out));
    /* A line whose only tags leave it fully opaque produces no styled run at
     * all, and "no run" means "plain text with the default look" -- fully
     * opaque.  Report that instead of the zeroed struct. */
    out->alpha = 1.0;
    LpSubStyle base;
    lp_sub_style_default(&base);
    LpSubCue cue;
    memset(&cue, 0, sizeof(cue));
    cue.end_us = cue_dur_us > 0 ? cue_dur_us : 1000000;
    AssCtx ctx;
    ctx.play_w = 384.0;
    ctx.play_h = 288.0;
    ctx.base = &base;
    int rc = lp_sub_compile_text(dialogue_text, &cue, &ctx);
    if (rc != 0) {
        lp_sub_cue_free(&cue);
        return -1;
    }
    out->nb_runs = cue.nb_runs;
    if (run_index >= 0 && run_index < cue.nb_runs) {
        LpSubRun *r = &cue.runs[run_index];
        out->nb_anims = r->nb_anims;
        if (r->nb_anims > 0 && r->anims) {
            out->anim_t1 = r->anims[0].t1_ms;
            out->anim_t2 = r->anims[0].t2_ms;
            out->anim_accel = r->anims[0].accel;
            out->anim_fields = r->anims[0].fields;
            out->anim_color = r->anims[0].color;
            out->anim_scale_x = r->anims[0].scale_x;
            out->anim_scale_y = r->anims[0].scale_y;
            out->anim_alpha = r->anims[0].alpha;
            out->anim_clip_on = r->anims[0].clip_on;
            out->anim_clip_x1 = r->anims[0].clip_x1;
            out->anim_clip_x2 = r->anims[0].clip_x2;
        }
        out->karaoke_kind = r->karaoke_kind;
        out->karaoke_start_ms = r->karaoke_start_ms;
        out->karaoke_end_ms = r->karaoke_end_ms;
        out->alpha = r->alpha;
        out->angle = r->angle;
        out->clip_on = r->clip_on;
        out->clip_x1 = r->clip_x1;
        out->clip_y1 = r->clip_y1;
        out->clip_x2 = r->clip_x2;
        out->clip_y2 = r->clip_y2;
        out->clip_inverse = r->clip_inverse;
        out->drawing_scale = r->drawing_scale;
        out->nb_path = r->nb_path;
        if (r->nb_path > 0 && r->path) {
            out->path_x0 = r->path[0].x;
            out->path_y0 = r->path[0].y;
            out->path_last_x = r->path[r->nb_path - 1].x;
            out->path_last_y = r->path[r->nb_path - 1].y;
            out->nb_subpaths = r->path[r->nb_path - 1].sub + 1;
        }
    }
    lp_sub_cue_free(&cue);
    return 0;
}

/* 测试入口：走一遍 lp_subtitle_add_file 的文本解码链（BOM 剥除、无 BOM 的
 * UTF-16 猜测、字符集回退），把结果作为 UTF-8 返回。仅供
 * native/tests/lp_subanim_test.c 使用 —— 正常播放路径不会调它。 */
char *lp_sub_test_decode_text(const void *raw, size_t len, int *charset_ok)
{
    return lp_sub_decode_text((const uint8_t *)raw, len, NULL, charset_ok);
}

/* ---------------------------------------------------- 畸形输入的测试钩子 --- */

/* 测试入口：整段 ASS 解析一遍，把整条轨道交给调用方。仅供
 * native/tests/lp_robust_test.c 使用 —— 正常播放路径不会调它。 */
LpSubtitleTrack *lp_sub_test_parse_ass(const char *text, size_t len)
{
    if (!text || len == 0) {
        return NULL;
    }
    LpSubtitleTrack *t = calloc(1, sizeof(*t));
    if (!t) {
        return NULL;
    }
    t->current_cue = -1;
    char err[256] = {0};
    if (lp_sub_parse_ass(text, t, err, sizeof(err)) <= 0) {
        lp_sub_track_reset(t);
        free(t);
        return NULL;
    }
    return t;
}

void lp_sub_test_free_track(LpSubtitleTrack *t)
{
    if (!t) {
        return;
    }
    lp_sub_track_reset(t);
    free(t);
}

/* 测试入口：把一段超长正文压进一个 subs 构建器，返回压完的正文。
 * 用来验证截断点不会落在多字节字符中间。 */
char *lp_sub_test_clamp_text(const char *text)
{
    if (!text) {
        return NULL;
    }
    LpSubCue cue;
    memset(&cue, 0, sizeof(cue));
    SubRich b;
    lp_sub_rich_init(&b, &cue);
    int rc = lp_sub_rich_append(&b, text, strlen(text));
    char *out = rc == 0 ? lp_str_take(&b.plain) : NULL;
    lp_sub_rich_free(&b);
    return out;
}

/* 测试入口：按 ASS 包的真实顺序把几段正文合并进同一个 cue，回报合并结果。
 * 供 native/tests/lp_robust_test.c 断言「只改样式不新增 run 时，上一条
 * 的动画不会被覆盖」。 */
int lp_sub_test_merge_runs(const char *r1, const char *r2, const char *r3,
                           LpSubTestMerge *out)
{
    if (!out) {
        return -1;
    }
    memset(out, 0, sizeof(*out));
    LpSubStyle base;
    lp_sub_style_default(&base);
    AssCtx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.play_w = 384.0;
    ctx.play_h = 288.0;
    ctx.base = &base;

    LpSubCue cue;
    memset(&cue, 0, sizeof(cue));
    cue.pos_x = -1.0;
    cue.pos_y = -1.0;
    cue.margin_l = cue.margin_r = cue.margin_v = -1.0;

    SubRich merged;
    lp_sub_rich_init(&merged, &cue);
    const char *parts[3];
    parts[0] = r1;
    parts[1] = r2;
    parts[2] = r3;
    int rc = 0;
    for (int i = 0; i < 3; i++) {
        if (!parts[i]) {
            continue;
        }
        LpSubCue one;
        memset(&one, 0, sizeof(one));
        one.pos_x = -1.0;
        one.pos_y = -1.0;
        one.margin_l = one.margin_r = one.margin_v = -1.0;
        if (lp_sub_compile_text(parts[i], &one, &ctx) != 0) {
            rc = -1;
            break;
        }
        if (lp_sub_merge_cue_into(&merged, &one) != 0) {
            lp_sub_cue_free(&one);
            rc = -1;
            break;
        }
        lp_sub_cue_free(&one);
    }
    if (rc == 0) {
        out->nb_runs = merged.nb;
        for (int i = 0; i < merged.nb; i++) {
            if (merged.runs[i].nb_anims > 0) {
                out->nb_animated_runs++;
            }
        }
        if (merged.nb > 0) {
            LpSubRun *first = &merged.runs[0];
            out->first_nb_anims = first->nb_anims;
            if (first->nb_anims > 0 && first->anims) {
                out->first_anim_t2 = first->anims[0].t2_ms;
            }
            snprintf(out->first_text, sizeof(out->first_text), "%s",
                     first->text ? first->text : "");
        }
    }
    lp_sub_rich_free(&merged);
    lp_sub_cue_free(&cue);
    return rc;
}
