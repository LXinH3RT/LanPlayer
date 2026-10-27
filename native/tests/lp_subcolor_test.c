/*
 * ASS 颜色标签归属的回归测试 —— 用户反馈「字幕样式渲染有问题」。
 *
 * `{\3c&H006C3300&}` 是给描边上色的标准写法，但解析器最初把通道数字
 * （1c/2c/3c/4c）直接吃掉，四条通道全写进主色，结果整行字变成了描边色、
 * 描边反而留在默认黑。本测试对每种通道写法断言解析出来的主色 / 描边色 /
 * 背景色各归各位。
 *
 * ASS 的颜色字面量是 `&HAABBGGRR`（与 RGB 相反），期望值这里按解析后的
 * `0xAARRGGBB` 写，免得两边都是「看着像」。
 *
 *   scripts\build_windows.py        # 会一起编出来
 *   .\build\win-x64\lp_subcolor_test.exe
 *
 * 退出码 0 表示全过。
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "player_internal.h"

static int failures;

static void check_at(const char *body, int run_index, uint32_t want_color,
                     uint32_t want_outline, uint32_t want_back, const char *why)
{
    uint32_t color = 0xDEADBEEF;
    uint32_t outline = 0xDEADBEEF;
    uint32_t back = 0xDEADBEEF;
    int rc = lp_sub_test_parse_runs(body, run_index, &color, &outline, &back);
    if (rc != 0) {
        failures++;
        fprintf(stderr, "FAIL [%s] parser rejected the line\n", why);
        return;
    }
    if (color != want_color || outline != want_outline || back != want_back) {
        failures++;
        fprintf(stderr,
                "FAIL [%s]\n  want color=%08X outline=%08X back=%08X\n"
                "  got  color=%08X outline=%08X back=%08X\n",
                why, (unsigned)want_color, (unsigned)want_outline,
                (unsigned)want_back, (unsigned)color, (unsigned)outline,
                (unsigned)back);
        return;
    }
    printf("ok   [%s]\n", why);
}

static void check(const char *body, uint32_t want_color, uint32_t want_outline,
                  uint32_t want_back, const char *why)
{
    check_at(body, 0, want_color, want_outline, want_back, why);
}

int main(void)
{
    /* \3c 只改描边色：这是用户真实素材里的写法（勇敢的心.ass）。
     * &H006C3300 -> BB=6C GG=33 RR=00 -> 0xFF00336C。 */
    check("{\\3c&H006C3300&}苏格兰 公元1280年", 0, 0xFF00336Cu, 0,
          "\\3c 只动描边");

    /* \1c 是主色，不能碰描边。&H0000FF -> RR=FF BB=00 -> 0xFFFF0000。 */
    check("{\\1c&H0000FF&}红字", 0xFFFF0000u, 0, 0, "\\1c 只动主色");

    /* 不带通道数字的 \c 等同 \1c（ASS 的简写）。&H00FF00 -> GG=FF。 */
    check("{\\c&H00FF00&}绿字", 0xFF00FF00u, 0, 0, "\\c 等同 \\1c");

    /* \4c 是背景色，BorderStyle 3/4 的方框用它。
     * &H102030 -> BB=10 GG=20 RR=30 -> 0xFF302010。 */
    check("{\\4c&H102030&}带底色", 0, 0, 0xFF302010u, "\\4c 只动背景");

    /* \2c 是卡拉 OK 的次色，本渲染器无处安放，绝不能污染主色。 */
    check("{\\2c&H00FFFF&}次色", 0, 0, 0, "\\2c 不影响主色");

    /* 多个通道可以连续出现，各自归位。 */
    check("{\\1c&H0000FF&\\3c&H00FF00&\\4c&H000010&}三色",
          0xFFFF0000u, 0xFF00FF00u, 0xFF100000u, "三通道各自归位");

    /* \r 要把所有通道复位回继承状态：第二段（下标 1）三色都该是继承值。 */
    check_at("{\\3c&H006C3300&}前{\\r}后", 1, 0, 0, 0, "\\r 复位描边");

    if (failures) {
        fprintf(stderr, "\n%d failure(s)\n", failures);
        return 1;
    }
    printf("\nall subtitle-colour cases passed\n");
    return 0;
}
