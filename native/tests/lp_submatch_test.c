/*
 * 外挂字幕配对规则的回归测试。
 *
 * 用例全部取自真实片库（SMB 共享里那些原本配不上的字幕），是这套近似匹配
 * 唯一需要覆盖的输入。要跑的话：
 *
 *   scripts\build_windows.py  # 会一起编出来
 *   .\build\win-x64\lp_submatch_test.exe
 *
 * 退出码 0 表示全过。
 */
#include <stdio.h>
#include <string.h>

#include "player_internal.h"

static int failures;

static void stem(const char *name, char *out, size_t outlen)
{
    lp_sub_match_stem(name, out, outlen);
}

static void check(const char *video, const char *sub, int want, const char *why)
{
    char a[256];
    char b[256];
    stem(video, a, sizeof(a));
    stem(sub, b, sizeof(b));
    int got = lp_sub_match_related(a, b);
    if (got != want) {
        failures++;
        fprintf(stderr, "FAIL [%s] %s <-> %s : want %d got %d\n", why, video, sub, want, got);
    } else {
        printf("ok   [%s] %s <-> %s\n", why, video, sub);
    }
}

int main(void)
{
    /* 主干直接对上 */
    check("电影.mkv", "电影.srt", 1, "同名");
    check("movie.mkv", "movie.zh-CN.srt", 1, "语言后缀");
    check("movie.mkv", "movie_zh.srt", 1, "下划线");
    check("movie.mkv", "movie-zh.srt", 1, "连字符");
    check("Movie.MKV", "movie.zh.SRT", 1, "大小写");

    /* 续集/异集不能错配 */
    check("movie.mkv", "movie2.srt", 0, "续集");
    check("悠哉日常大王001.mkv", "悠哉日常大王013.ass", 0, "异集数字尾巴");
    check("Show.S01E01.mkv", "Show.S01E02.zh.srt", 0, "异集 SxxExx");

    /* 跨语言片名不该硬凑 */
    check("兵临城下.mp4", "Enemy.At.The.Gates.2001.1080p.BrRip.x264.YIFY.srt", 0, "跨语言");
    check("终结者1.mp4", "The.Terminator.1984.1080p.BRrip.x264.GAZ.YIFY.srt", 0, "跨语言");
    check("警察故事1988.mp4",
          "Police Story 2 (1988) 1080p BluRay H264 DolbyD 5.1 + nickarad.eng.srt", 0,
          "跨语言");

    /* 发布组 / 语言标签 */
    check("[YYDM-11FANS][Higurashi no Naku Koro ni Kai][01][BDRIP][720P][X264-10bit_AAC][D12B2CA8].mp4",
          "[YYDM-11FANS][Higurashi no Naku Koro ni Kai][01][BDRIP][720P][X264-10bit_AAC][D12B2CA8].SC-CASO&I.G.ass",
          1, "只多语言标签");
    check("勇敢的心.mp4", "勇敢的心en.srt", 1, "语言标签 en");

    /* 靠集数配对 */
    check("S10E01.mkv",
          "54-S10E01 The Mystery of the Blue Train 蓝色列车之谜.蓝光版英中字幕.srt", 1,
          "集数配对");
    check("S10E01.mkv", "55-S10E02 另一个标题.中英字幕.srt", 0, "集数不同");

    /* 数字后面跟标点（发布组最常见的命名）。以前这类写法两边都认不出集数，
     * 于是掉进 Dice 近似判定 —— `show name 01` 与 `show name 02` 相似度约
     * 0.909，整季字幕会被判成同一片挂到每一集上。 */
    check("[Group] Show Name - 01 [1080p].mkv", "[Group] Show Name - 02.chs.ass", 0,
          "方括号集数不同");
    check("[Group] Show Name - 01 [1080p].mkv", "[Group] Show Name - 01.chs.ass", 1,
          "方括号集数相同");
    check("Show - 03.mkv", "Show - 04.zh.srt", 0, "短横线集数不同");
    check("白箱第12集.mkv", "白箱第13集.ass", 0, "第N集不同");
    check("白箱第12集.mkv", "白箱第12集.ass", 1, "第N集相同");
    check("Show - E03.mkv", "Show - E04.chs.ass", 0, "独立 E 集数不同");

    /* 语言标签补全后，这类最普通的命名要能对上。 */
    check("Movie.2024.1080p.mkv", "Movie.2024.zh-CN.srt", 1, "zh-CN 语言标签");
    check("Movie.2024.1080p.mkv", "Movie.2024.hans.ass", 1, "hans 语言标签");

    /* 年份、续集号里的数字不能被当成集数：`2049` 是片名的一部分。 */
    check("Blade.Runner.2049.2017.mkv", "Blade.Runner.2049.2017.zh.srt", 1, "年份与续集号");

    if (failures) {
        fprintf(stderr, "\n%d failure(s)\n", failures);
        return 1;
    }
    printf("\nall subtitle-match cases passed\n");
    return 0;
}
