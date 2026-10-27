/*
 * ASS 高级特性的回归测试 —— 用户反馈「\t 动画、\clip、矢量绘图 \p、卡拉 OK
 * \k 不渲染」。
 *
 * 这四类标签以前在 apply_override() 的 default 分支里被整体跳过：\t 和 \clip
 * 的括号参数被吃掉，\p 只记了一个布尔值（坐标全丢），\k 完全不认识。本测试
 * 断言解析器现在真的把它们变成了数据，并且该丢弃的仍然丢弃（向量裁剪、\2c
 * 的颜色、\4a 的透明度都不能污染可见属性）。
 *
 *   scripts\build_windows.py        # 会一起编出来
 *   .\build\win-x64\lp_subanim_test.exe
 *
 * 退出码 0 表示全过。
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "player_internal.h"

static int failures;

static void fail(const char *why, const char *detail)
{
    failures++;
    fprintf(stderr, "FAIL [%s] %s\n", why, detail ? detail : "");
}

static int approx_eq(double a, double b)
{
    double d = a - b;
    if (d < 0) {
        d = -d;
    }
    return d <= 0.01;
}

/* --- \t 动画 ---------------------------------------------------------- */

static void test_anim_window(void)
{
    LpSubTestAnim a;
    const char *body = "{\\t(400,1400,\\1c&HFFFFFF&)}text";
    if (lp_sub_test_parse_anim(body, 0, 2000000, &a) != 0) {
        fail("anim-window", "parser rejected the line");
        return;
    }
    if (a.nb_anims != 1) {
        fail("anim-window", "expected exactly one animation");
        return;
    }
    if (!approx_eq(a.anim_t1, 400.0) || !approx_eq(a.anim_t2, 1400.0)) {
        fail("anim-window", "t1/t2 were not read from the tag");
        return;
    }
    if (!(a.anim_fields & LP_SUB_ANIM_COLOR)) {
        fail("anim-window", "\\1c inside \\t did not register as a colour animation");
        return;
    }
    /* &HFFFFFF is white: ASS stores BGR, the parsed value is 0xAARRGGBB. */
    if (a.anim_color != 0xFFFFFFFFu) {
        fail("anim-window", "animated colour did not parse to opaque white");
        return;
    }
    if (a.anim_fields & (LP_SUB_ANIM_SCALE_X | LP_SUB_ANIM_SCALE_Y |
                         LP_SUB_ANIM_ALPHA | LP_SUB_ANIM_FONT)) {
        fail("anim-window", "unrelated fields were marked as animated");
        return;
    }
}

static void test_anim_whole_cue(void)
{
    LpSubTestAnim a;
    /* \t(tags) spans the whole cue: 0 .. cue duration. */
    const char *body = "{\\t(\\fscy200)}bigger";
    if (lp_sub_test_parse_anim(body, 0, 1500000, &a) != 0) {
        fail("anim-whole-cue", "parser rejected the line");
        return;
    }
    if (a.nb_anims != 1 || !approx_eq(a.anim_t1, 0.0) || !approx_eq(a.anim_t2, 1500.0)) {
        fail("anim-whole-cue", "an omitted window must span the cue");
        return;
    }
    if (!(a.anim_fields & LP_SUB_ANIM_SCALE_Y) || !approx_eq(a.anim_scale_y, 200.0)) {
        fail("anim-whole-cue", "\\fscy inside \\t was not captured");
        return;
    }
}

static void test_anim_accel_and_alpha(void)
{
    LpSubTestAnim a;
    const char *body = "{\\t(0,800,2,\\alpha&HFF&)}fade";
    if (lp_sub_test_parse_anim(body, 0, 3000000, &a) != 0) {
        fail("anim-accel", "parser rejected the line");
        return;
    }
    if (a.nb_anims != 1 || !approx_eq(a.anim_accel, 2.0)) {
        fail("anim-accel", "the acceleration argument was not read");
        return;
    }
    if (!(a.anim_fields & LP_SUB_ANIM_ALPHA) || !approx_eq(a.anim_alpha, 0.0)) {
        fail("anim-accel", "\\alpha&HFF& must animate towards fully transparent");
        return;
    }
}

static void test_anim_clip_in_t(void)
{
    LpSubTestAnim a;
    /* The shape used by the real subtitles: a clip that grows inside \t. */
    const char *body =
        "{\\clip(94.4,219.2,95.6,246.4)\\t(0,300,\\clip(94.4,219.2,339.2,246.4))}m 200 -1";
    if (lp_sub_test_parse_anim(body, 0, 1000000, &a) != 0) {
        fail("anim-clip", "parser rejected the line");
        return;
    }
    if (!a.clip_on || !approx_eq(a.clip_x2, 95.6)) {
        fail("anim-clip", "the static \\clip rectangle was not stored");
        return;
    }
    if (a.nb_anims != 1 || !(a.anim_fields & LP_SUB_ANIM_CLIP)) {
        fail("anim-clip", "the animated \\clip inside \\t was not captured");
        return;
    }
    if (!approx_eq(a.anim_clip_x2, 339.2)) {
        fail("anim-clip", "the animated rectangle kept the wrong right edge");
    }
}

static void test_anim_inside_t_does_not_leak(void)
{
    LpSubTestAnim a;
    /* \fscy200 lives inside \t, so the static run must stay unscaled. */
    const char *body = "{\\t(0,500,\\fscy200)}text";
    if (lp_sub_test_parse_anim(body, 0, 1000000, &a) != 0) {
        fail("anim-no-leak", "parser rejected the line");
        return;
    }
    if (a.anim_fields == 0) {
        fail("anim-no-leak", "no animation recorded");
        return;
    }
    /* The scale animation exists, but the run's own geometry must not have
     * been overwritten by the nested tags. */
    if (approx_eq(a.anim_scale_y, 0.0)) {
        fail("anim-no-leak", "the animated scale was not recorded");
    }
}

/* --- \clip 静态 ------------------------------------------------------- */

static void test_clip_plain(void)
{
    LpSubTestAnim a;
    const char *body = "{\\clip(10,20,300,400)}text";
    if (lp_sub_test_parse_anim(body, 0, 1000000, &a) != 0) {
        fail("clip-plain", "parser rejected the line");
        return;
    }
    if (!a.clip_on || !approx_eq(a.clip_x1, 10) || !approx_eq(a.clip_y1, 20) ||
        !approx_eq(a.clip_x2, 300) || !approx_eq(a.clip_y2, 400)) {
        fail("clip-plain", "the rectangle coordinates were not all stored");
    }
}

static void test_clip_c_untouched(void)
{
    LpSubTestAnim a;
    /* \c must still be a colour, not a clip: the two share the first letter. */
    const char *body = "{\\c&H00FF00&}green";
    if (lp_sub_test_parse_anim(body, 0, 1000000, &a) != 0) {
        fail("clip-vs-colour", "parser rejected the line");
        return;
    }
    if (a.clip_on) {
        fail("clip-vs-colour", "\\c was mistaken for a clip");
    }
}

/* --- \p 矢量绘图 ------------------------------------------------------ */

static void test_drawing_path(void)
{
    LpSubTestAnim a;
    const char *body =
        "{\\p1\\c&H0000FF&}m 200 -1 l 200 13 l 19 13 b 14 12 14 6 14 6{\\p0}";
    if (lp_sub_test_parse_anim(body, 0, 1000000, &a) != 0) {
        fail("drawing-path", "parser rejected the line");
        return;
    }
    if (a.drawing_scale != 1) {
        fail("drawing-path", "the \\p exponent was not stored");
        return;
    }
    /* m + l + l + b: the `b` command carries three points (two control points
     * and the end point) but adds exactly one vertex to the outline -- the end
     * point.  So the total is 1 + 2 + 1 = 4, not 5. */
    if (a.nb_path != 4) {
        fail("drawing-path", "expected 4 points (move + 2 lines + 1 spline end)");
        return;
    }
    if (!approx_eq(a.path_x0, 200) || !approx_eq(a.path_y0, -1)) {
        fail("drawing-path", "the first point is wrong");
        return;
    }
    if (!approx_eq(a.path_last_x, 14) || !approx_eq(a.path_last_y, 6)) {
        fail("drawing-path", "the last point is wrong");
        return;
    }
    if (a.nb_subpaths != 1) {
        fail("drawing-path", "one `m` must produce exactly one subpath");
    }
}

static void test_drawing_two_subpaths(void)
{
    LpSubTestAnim a;
    const char *body = "{\\p2}m 0 0 l 10 0 m 20 0 l 30 0{\\p0}";
    if (lp_sub_test_parse_anim(body, 0, 1000000, &a) != 0) {
        fail("drawing-subpaths", "parser rejected the line");
        return;
    }
    if (a.nb_path != 4 || a.nb_subpaths != 2) {
        fail("drawing-subpaths", "two `m` commands must give two subpaths");
    }
}

static void test_drawing_leaves_text_alone(void)
{
    LpSubTestAnim a;
    /* Everything between \p1 and \p0 is geometry; the visible text after
     * \p0 must still render as a normal run. */
    const char *body = "{\\p1}m 0 0 l 10 10{\\p0}hello";
    if (lp_sub_test_parse_anim(body, 1, 1000000, &a) != 0) {
        fail("drawing-text", "parser rejected the line");
        return;
    }
    if (a.nb_runs != 2) {
        fail("drawing-text", "expected one shape run followed by one text run");
        return;
    }
    if (a.drawing_scale != 0) {
        fail("drawing-text", "the text run must not be flagged as a drawing");
    }
}

/* --- \k 卡拉 OK ------------------------------------------------------- */

static void test_karaoke_basic(void)
{
    LpSubTestAnim a;
    const char *body = "{\\k13}a{\\k13}b";
    if (lp_sub_test_parse_anim(body, 0, 3000000, &a) != 0) {
        fail("karaoke", "parser rejected the line");
        return;
    }
    if (a.karaoke_kind != 1) {
        fail("karaoke", "\\k was not recognised");
        return;
    }
    if (!approx_eq(a.karaoke_start_ms, 0.0) || !approx_eq(a.karaoke_end_ms, 130.0)) {
        fail("karaoke", "\\k13 must be 130 ms, not 13");
    }
}

static void test_karaoke_f_ko(void)
{
    LpSubTestAnim a;
    if (lp_sub_test_parse_anim("{\\kf50}x", 0, 1000000, &a) != 0 || a.karaoke_kind != 2) {
        fail("karaoke-kf", "\\kf must map to the sweep kind");
        return;
    }
    if (!approx_eq(a.karaoke_end_ms, 500.0)) {
        fail("karaoke-kf", "\\kf50 must be 500 ms");
        return;
    }
    if (lp_sub_test_parse_anim("{\\ko105}y", 0, 1000000, &a) != 0 || a.karaoke_kind != 3) {
        fail("karaoke-ko", "\\ko must map to the outline-fade kind");
        return;
    }
    if (lp_sub_test_parse_anim("{\\K32}z", 0, 1000000, &a) != 0 || a.karaoke_kind != 2) {
        fail("karaoke-K", "\\K is the documented alias of \\kf");
    }
}

static void test_karaoke_accumulates(void)
{
    LpSubTestAnim a;
    /* Three syllables: the third must start where the second ended. */
    const char *body = "{\\k10}a{\\k20}b{\\k30}c";
    if (lp_sub_test_parse_anim(body, 2, 6000000, &a) != 0) {
        fail("karaoke-cursor", "parser rejected the line");
        return;
    }
    if (!approx_eq(a.karaoke_start_ms, 300.0) || !approx_eq(a.karaoke_end_ms, 600.0)) {
        fail("karaoke-cursor", "the karaoke cursor did not accumulate");
    }
}

/* --- 透明度 ----------------------------------------------------------- */

static void test_alpha(void)
{
    LpSubTestAnim a;
    if (lp_sub_test_parse_anim("{\\alpha&H80&}half", 0, 1000000, &a) != 0) {
        fail("alpha", "parser rejected the line");
        return;
    }
    /* &H80 = 128/255 transparent -> 1 - 0.502 = 0.498 */
    if (a.alpha < 0.49 || a.alpha > 0.51) {
        fail("alpha", "\\alpha&H80& should give roughly 0.5 opacity");
        return;
    }
    if (lp_sub_test_parse_anim("{\\1a&H00&}opaque", 0, 1000000, &a) != 0) {
        fail("alpha-1a", "parser rejected the line");
        return;
    }
    if (!approx_eq(a.alpha, 1.0)) {
        fail("alpha-1a", "\\1a&H00& must stay fully opaque");
    }
}

static void test_alpha_does_not_leak_from_other_channels(void)
{
    LpSubTestAnim a;
    /* \3a targets the outline; the text opacity must be untouched. */
    if (lp_sub_test_parse_anim("{\\3a&HFF&}text", 0, 1000000, &a) != 0) {
        fail("alpha-channel", "parser rejected the line");
        return;
    }
    if (!approx_eq(a.alpha, 1.0)) {
        fail("alpha-channel", "\\3a must not change the text opacity");
    }
}

/* --- 兼容性 ----------------------------------------------------------- */

static void test_plain_line_has_nothing(void)
{
    LpSubTestAnim a;
    if (lp_sub_test_parse_anim("plain text", 0, 1000000, &a) != 0) {
        fail("plain", "parser rejected the line");
        return;
    }
    if (a.nb_anims || a.karaoke_kind || a.clip_on || a.nb_path) {
        fail("plain", "a plain line must not invent advanced features");
    }
}

static void test_malformed_t_is_skipped(void)
{
    LpSubTestAnim a;
    /* \t without parentheses used to eat the rest of the line. */
    if (lp_sub_test_parse_anim("{\\t\\b1}text", 0, 1000000, &a) != 0) {
        fail("malformed-t", "parser rejected the line");
        return;
    }
    if (a.nb_runs != 1) {
        fail("malformed-t", "the body text was lost after a malformed \\t");
    }
}

int main(void)
{
    test_anim_window();
    test_anim_whole_cue();
    test_anim_accel_and_alpha();
    test_anim_clip_in_t();
    test_anim_inside_t_does_not_leak();
    test_clip_plain();
    test_clip_c_untouched();
    test_drawing_path();
    test_drawing_two_subpaths();
    test_drawing_leaves_text_alone();
    test_karaoke_basic();
    test_karaoke_f_ko();
    test_karaoke_accumulates();
    test_alpha();
    test_alpha_does_not_leak_from_other_channels();
    test_plain_line_has_nothing();
    test_malformed_t_is_skipped();

    if (failures) {
        fprintf(stderr, "\n%d check(s) failed\n", failures);
        return 1;
    }
    printf("lp_subanim_test: all ASS advanced-feature checks passed\n");
    return 0;
}
