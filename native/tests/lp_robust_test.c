/*
 * 畸形字幕输入的回归测试 —— 用户下载来的字幕什么形状都有。
 *
 * 第 2 章的五条严重缺陷全部属于「正常样本永远触发不到，坏输入才炸」：
 * ASS 的 Format 列序和 Dialogue 行对不上、正文按字节截断切在多字节字符
 * 中间、`\uXXXX` 代理对只校验高半区、\r 式只改样式不新增 run 时动画被
 * 嫁接到上一条。这些都不会在演示里出现，却会在真实片库里以「字幕少一
 * 行」「某块跑到别处」「整条事件消失」的形式反复出现。
 *
 * 本文件把每一类的判定都钉成行为断言。判据取的是「解析器接受 / 拒绝」与
 * 「产出的字符串是合法 UTF-8」，而不是内部实现细节，所以后续重构不该
 * 让这里变红。
 *
 *   scripts\build_windows.py        # 会一起编出来
 *   .\build\win-x64\lp_robust_test.exe
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

static void expect_int(const char *why, int got, int want)
{
    if (got != want) {
        char detail[128];
        snprintf(detail, sizeof(detail), "got %d, want %d", got, want);
        fail(why, detail);
    }
}

static void expect_true(const char *why, int cond, const char *detail)
{
    if (!cond) {
        fail(why, detail);
    }
}

/* 严格 UTF-8 校验：不接受超长编码、代理区码点、以及超过 U+10FFFF 的码点。
 * 返回第一个非法字节的下标，全合法时返回 -1。 */
static int utf8_bad_index(const char *s)
{
    const unsigned char *p = (const unsigned char *)s;
    while (*p) {
        unsigned cp;
        int extra;
        if (*p < 0x80) {
            p++;
            continue;
        }
        if ((*p & 0xE0) == 0xC0) {
            cp = (unsigned)(*p & 0x1F);
            extra = 1;
        } else if ((*p & 0xF0) == 0xE0) {
            cp = (unsigned)(*p & 0x0F);
            extra = 2;
        } else if ((*p & 0xF8) == 0xF0) {
            cp = (unsigned)(*p & 0x07);
            extra = 3;
        } else {
            return (int)(p - (const unsigned char *)s);
        }
        for (int i = 1; i <= extra; i++) {
            if ((p[i] & 0xC0) != 0x80) {
                return (int)(p - (const unsigned char *)s);
            }
            cp = (cp << 6) | (unsigned)(p[i] & 0x3F);
        }
        if ((extra == 1 && cp < 0x80) || (extra == 2 && cp < 0x800) ||
            (extra == 3 && cp < 0x10000)) {
            return (int)(p - (const unsigned char *)s); /* overlong */
        }
        if (cp >= 0xD800 && cp <= 0xDFFF) {
            return (int)(p - (const unsigned char *)s);
        }
        if (cp > 0x10FFFF) {
            return (int)(p - (const unsigned char *)s);
        }
        p += extra + 1;
    }
    return -1;
}

/* --- 2.3 utf8_put 的四字节分支与代理对校验 ----------------------------- */

static void test_json_unicode_escapes(void)
{
    char out[64];

    /* U+1F600 的微笑脸：UTF-16 里是一对代理，拼出来的码点必须写成 4 字节。
     * 少了这一支的时候它掉进 3 字节分支，产出的 JSON 不再是合法 UTF-8，
     * Dart 侧 utf8.decode 抛 FormatException，整条字幕事件丢失。 */
    memset(out, 0, sizeof(out));
    if (lp_json_get_str("{\"k\":\"\\uD83D\\uDE00\"}", "k", out, sizeof(out)) != 0) {
        fail("surrogate-pair", "parser rejected a well-formed emoji escape");
        return;
    }
    expect_int("emoji is valid UTF-8", utf8_bad_index(out), -1);
    expect_int("emoji is four bytes", (int)strlen(out), 4);
    expect_true("emoji leading byte", ((unsigned char)out[0] & 0xF8) == 0xF0,
                "first byte is not 0xF0..0xF7, so it was encoded as three bytes");

    /* CJK 扩展 B 区的 U+20000 同理。 */
    memset(out, 0, sizeof(out));
    if (lp_json_get_str("{\"k\":\"\\uD840\\uDC00\"}", "k", out, sizeof(out)) == 0) {
        expect_int("CJK-B is valid UTF-8", utf8_bad_index(out), -1);
        expect_int("CJK-B is four bytes", (int)strlen(out), 4);
    }

    /* 半个代理对：低半区落在 0xDC00-0xDFFF 之外时不能拼。以前只校验了高
     * 半区，`\uD83D\u0041` 会拼出一个凭空多出 0x400 的码点，把后面的字符
     * 整段吃掉。 */
    memset(out, 0, sizeof(out));
    if (lp_json_get_str("{\"k\":\"\\uD83D\\u0041\"}", "k", out, sizeof(out)) == 0) {
        expect_int("half pair stays valid UTF-8", utf8_bad_index(out), -1);
        expect_true("half pair does not swallow the next char",
                    strchr(out, 'A') != NULL,
                    "the trailing 'A' disappeared, so the low half was consumed");
    }

    /* 孤立的高半区代理项本身也不是合法码点，必须替换成 U+FFFD。 */
    memset(out, 0, sizeof(out));
    if (lp_json_get_str("{\"k\":\"\\uD83D\"}", "k", out, sizeof(out)) == 0) {
        expect_int("lone surrogate stays valid UTF-8", utf8_bad_index(out), -1);
    }

    /* 普通 BMP 字符不能因为新分支而走样。 */
    memset(out, 0, sizeof(out));
    if (lp_json_get_str("{\"k\":\"\\u4E2D\\u6587\"}", "k", out, sizeof(out)) == 0) {
        expect_int("BMP is three bytes each", (int)strlen(out), 6);
        expect_int("BMP is valid UTF-8", utf8_bad_index(out), -1);
    }
}

/* --- 2.1 / 2.2 畸形 ASS 的解析 ---------------------------------------- */

/* 正常 ASS：Time/Text 都在 Format 里，能出 cue。 */
static void test_ass_normal(void)
{
    static const char kAss[] =
        "[Script Info]\n"
        "PlayResX: 1920\n"
        "PlayResY: 1080\n"
        "[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, "
        "OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, "
        "ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
        "Alignment, MarginL, MarginR, MarginV, Encoding\n"
        "Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,"
        "0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1\n"
        "[Events]\n"
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, "
        "Effect, Text\n"
        "Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,hello\n";
    LpSubtitleTrack *t = lp_sub_test_parse_ass(kAss, strlen(kAss));
    if (!t) {
        fail("ass-normal", "parser returned NULL for a well-formed file");
        return;
    }
    expect_int("ass-normal cue count", t->nb_cues, 1);
    if (t->nb_cues == 1) {
        expect_true("ass-normal text", t->cues[0].text && strcmp(t->cues[0].text, "hello") == 0,
                    "the text column did not survive");
        expect_int("ass-normal start", (int)t->cues[0].start_us, 1000000);
        expect_int("ass-normal end", (int)t->cues[0].end_us, 3000000);
    }
    lp_sub_test_free_track(t);
}

/* Text 不在最后一列：正文里就不会再有逗号歧义，但切分用的 max 会跟着变。
 * 以前这条会读越界的栈指针，要么整行被丢掉，要么时间变成随机值。 */
static void test_ass_text_not_last(void)
{
    static const char kAss[] =
        "[Script Info]\nPlayResX: 1920\nPlayResY: 1080\n"
        "[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, "
        "OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, "
        "ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
        "Alignment, MarginL, MarginR, MarginV, Encoding\n"
        "Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,"
        "0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1\n"
        "[Events]\n"
        "Format: Layer, Start, End, Style, Text, Name\n"
        "Dialogue: 0,0:00:02.00,0:00:04.00,Default,second,foo\n"
        "Dialogue: 0,0:00:05.00,0:00:06.00,Default,third,bar\n";
    LpSubtitleTrack *t = lp_sub_test_parse_ass(kAss, strlen(kAss));
    if (!t) {
        fail("ass-text-not-last", "parser returned NULL");
        return;
    }
    /* 这两行都必须解析出来，时间必须来自各自的行。 */
    expect_int("ass-text-not-last cue count", t->nb_cues, 2);
    for (int i = 0; i < t->nb_cues; i++) {
        expect_true("ass-text-not-last start is sane", t->cues[i].start_us >= 0,
                    "start time came from uninitialised memory");
        expect_true("ass-text-not-last end > start", t->cues[i].end_us > t->cues[i].start_us,
                    "end time came from uninitialised memory");
        expect_int("ass-text-not-last text is valid UTF-8", utf8_bad_index(t->cues[i].text ? t->cues[i].text : ""), -1);
    }
    lp_sub_test_free_track(t);
}

/* 正文不排在最后：``Format: Layer, Text, Start, End, Style``。
 * 切分上界如果只算到正文那一格，起止时间就落在 split_fields 没写过的
 * 栈上；按老实现整行会被 got 判断拦掉，一个字幕都出不来。 */
static void test_ass_text_before_times(void)
{
    static const char kAss[] =
        "[Script Info]\nPlayResX: 1920\nPlayResY: 1080\n"
        "[Events]\n"
        "Format: Layer, Text, Start, End, Style\n"
        "Dialogue: 0,hello,0:00:01.00,0:00:03.00,Default\n";
    LpSubtitleTrack *t = lp_sub_test_parse_ass(kAss, strlen(kAss));
    if (!t) {
        fail("ass-text-before-times", "parser returned NULL: the line was dropped "
                                      "instead of being split wide enough");
        return;
    }
    expect_int("ass-text-before-times cue count", t->nb_cues, 1);
    if (t->nb_cues == 1) {
        expect_true("ass-text-before-times text",
                    t->cues[0].text && strcmp(t->cues[0].text, "hello") == 0,
                    "the text column did not land on the text field");
        expect_int("ass-text-before-times start", (int)t->cues[0].start_us, 1000000);
        expect_int("ass-text-before-times end", (int)t->cues[0].end_us, 3000000);
    }
    lp_sub_test_free_track(t);
}

/* 两条 Format: 前后夹着 Dialogue：第二条短、没有 Style 列。
 * 旧实现把上一条 Format: 给的 e_style 留着，于是这一行去 fields[3]
 * 找样式名 —— 而 fields[3] 其实是正文。样本里让第三条 Dialogue 的正文
 * 恰好是样式名 "Default"，旧实现就会把样式算成下标 1，新实现是 0。 */
static void test_ass_format_reuse(void)
{
    static const char kAss[] =
        "[Script Info]\nPlayResX: 1920\nPlayResY: 1080\n"
        "[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize\n"
        "Style: Arial,Arial,48\n"
        "Style: Default,Arial,48\n"
        "[Events]\n"
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, "
        "Effect, Text\n"
        "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,first\n"
        "Format: Layer, Start, End, Text\n"
        "Dialogue: 0,0:00:03.00,0:00:04.00,Default\n";
    LpSubtitleTrack *t = lp_sub_test_parse_ass(kAss, strlen(kAss));
    if (!t) {
        fail("ass-format-reuse", "parser returned NULL");
        return;
    }
    expect_int("ass-format-reuse cue count", t->nb_cues, 2);
    for (int i = 0; i < t->nb_cues; i++) {
        const LpSubCue *c = &t->cues[i];
        if (c->text && strcmp(c->text, "Default") == 0) {
            /* 这一行没有 Style 列，样式只能回落到第一条。 */
            expect_int("ass-format-reuse ignores the stale style column", c->style, 0);
        }
    }
    lp_sub_test_free_track(t);
}

/* 短的 Format: 之后紧跟一条 Dialogue：字段数少于 Format 声明的列数。
 * 以前 fields[] 的后半截没被写过，按老下标去取就是栈垃圾。 */
static void test_ass_short_dialogue(void)
{
    static const char kAss[] =
        "[Script Info]\nPlayResX: 1920\nPlayResY: 1080\n"
        "[Events]\n"
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, "
        "Effect, Text\n"
        "Dialogue: 0,0:00:01.00,0:00:02.00\n"
        "Dialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,ok\n";
    LpSubtitleTrack *t = lp_sub_test_parse_ass(kAss, strlen(kAss));
    if (!t) {
        fail("ass-short-dialogue", "parser returned NULL");
        return;
    }
    /* 第一条行太短，读不出正文；不管接受还是拒绝，都不能崩、不能出野指针。 */
    for (int i = 0; i < t->nb_cues; i++) {
        expect_true("ass-short-dialogue text is readable",
                    t->cues[i].text != NULL, "text pointer is NULL");
        if (t->cues[i].text) {
            expect_int("ass-short-dialogue valid UTF-8", utf8_bad_index(t->cues[i].text), -1);
            expect_true("ass-short-dialogue no empty cue from the truncated line",
                        t->cues[i].text[0] != '\0',
                        "a truncated Dialogue line produced an empty cue");
        }
    }
    /* 第二条完整的行必须照常解析。 */
    int found_ok = 0;
    for (int i = 0; i < t->nb_cues; i++) {
        if (t->cues[i].text && strcmp(t->cues[i].text, "ok") == 0) {
            found_ok = 1;
        }
    }
    expect_int("ass-short-dialogue keeps the good line", found_ok, 1);
    lp_sub_test_free_track(t);
}

/* --- 2.5 正文按字节截断不能切在字符中间 ------------------------------- */

static void test_text_clamp_utf8(void)
{
    /* 造一条超过 LP_MAX_TEXT_BYTES 的正文，全部是 3 字节的「中」。
     * 8192 不是 3 的整数倍，朴素按字节截断必定切在字符中间。 */
    enum { kChars = 4000 };
    char *line = malloc((size_t)kChars * 3 + 16);
    if (!line) {
        fail("text-clamp", "out of memory");
        return;
    }
    char *w = line;
    for (int i = 0; i < kChars; i++) {
        *w++ = (char)0xE4;
        *w++ = (char)0xB8;
        *w++ = (char)0xAD;
    }
    *w = '\0';

    char *out = lp_sub_test_clamp_text(line);
    free(line);
    if (!out) {
        fail("text-clamp", "clamp returned NULL");
        return;
    }
    expect_int("text-clamp stays valid UTF-8", utf8_bad_index(out), -1);
    expect_true("text-clamp produced something", strlen(out) > 0, "clamped text is empty");
    free(out);
}

/* --- 2.4 只改样式不新增 run 时不覆盖上一条的动画 ---------------------- */

static void test_merge_keeps_prev_animation(void)
{
    /* 两块矩形合成一条 cue 的路径（外挂字幕里同一个 Dialogue 带 \N 或者
     * 多行 ASS 包都会走到）。第一块长到把正文配额用满，第二块再来时
     * sub_rich_append 会在开头就返回 —— 什么都没追加。
     *
     * 旧实现这时仍然抓 dst->runs[dst->nb - 1]，那是**上一块**的 run，
     * 接着 free 掉它的 anims 再把第二块的 anims 拷进去。表现就是多 rect
     * 字幕里某一块跑到别处，或者前半截突然开始旋转。 */
    enum { kPad = 9000 };
    char *r1 = malloc((size_t)kPad + 32);
    if (!r1) {
        fail("merge-anims", "out of memory");
        return;
    }
    strcpy(r1, "{\\t(0,1000,\\fs60)}");
    size_t at = strlen(r1);
    memset(r1 + at, 'a', kPad);
    r1[at + kPad] = '\0';

    LpSubTestMerge m;
    memset(&m, 0, sizeof(m));
    const char *r2 = "{\\t(0,500,\\fs30)}{\\1c&H0000FF&}y";
    int rc = lp_sub_test_merge_runs(r1, r2, NULL, &m);
    free(r1);
    if (rc != 0) {
        fail("merge-anims", "merge helper failed");
        return;
    }
    expect_true("merge-anims keeps at least one run", m.nb_runs >= 1, "no runs survived");
    expect_int("merge-anims first run keeps its animation", m.first_nb_anims, 1);
    expect_int("merge-anims exactly one animated run", m.nb_animated_runs, 1);
    /* 1000 是第一块的 \t 窗口；被第二块的 500 覆盖就说明嫁接错了走位。 */
    expect_int("merge-anims first animation window untouched",
               (int)m.first_anim_t2, 1000);
    expect_true("merge-anims first run text survives",
                m.first_text[0] != '\0', "the first run's text was lost");
}

int main(void)
{
    test_json_unicode_escapes();
    test_ass_normal();
    test_ass_text_not_last();
    test_ass_text_before_times();
    test_ass_format_reuse();
    test_ass_short_dialogue();
    test_text_clamp_utf8();
    test_merge_keeps_prev_animation();

    if (failures) {
        fprintf(stderr, "\n%d failure(s)\n", failures);
        return 1;
    }
    printf("\nall malformed-subtitle cases passed\n");
    return 0;
}
