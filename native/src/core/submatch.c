/*
 * 外挂字幕和视频的配对规则。
 *
 * 真实的片源目录里，字幕名和视频名很少逐字相同：同一个文件可能带发布组
 * 标签、压制参数、集数、语言后缀，甚至只写英文名而视频是中文名。这里把
 * 「怎样算同一个片」的判断集中到一处，和 Dart 侧的
 * `app/lib/data/subtitle_match.dart` 用同一套思路，免得两边各说各话。
 *
 * 判定分三级，从严到宽：
 *
 *   1. 主干相同，或字幕主干以「视频主干 + 分隔符」开头；
 *   2. 集数一致。两边都能认出集数且相等时，片名写法不再重要；集数不同
 *      直接判否，`悠哉日常大王013.ass` 不会挂到 `...001.mkv` 上；
 *   3. 去掉发布组/分辨率/编码/语言标签后仍然对得上。
 *
 * 反例同样是规则的一部分：`电影2.srt` 不能挂到 `电影.mkv` 上 —— 主干前缀
 * 之后多出来的若是裸数字，说明是另一个片子（续集、另一集），不是语言后缀。
 */
#include <ctype.h>
#include <stdio.h>
#include <string.h>

#include "player_internal.h"

/* 出现在谁身上都不影响「是不是同一个片子」的词，比较前先摘掉。
 * 与 Dart 侧 _noiseTokens 保持同步；两边不一致会让列表里认得出的字幕在
 * 打开时挂不上，这类不一致很难从界面上看出来。 */
static const char *const kNoise[] = {
    /* 分辨率 */
    "2160p", "1080p", "1080i", "720p", "576p", "480p", "4k", "8k", "uhd", "hd", "sd",
    /* 片源 */
    "bluray", "blu", "ray", "bdrip", "brrip", "bd", "remux", "webrip", "webdl",
    "web", "dl", "hdtv", "dvdrip", "dvd", "hdrip", "cam", "ts", "tc",
    /* 编码 */
    "x264", "x265", "h264", "h265", "avc", "hevc", "av1", "vp9", "10bit", "8bit",
    "10bits", "hi10p", "main10",
    /* 音频 */
    "aac", "ac3", "eac3", "dts", "dtshd", "flac", "truehd", "atmos", "ddp", "dd",
    "ddp5", "dd5", "mp3", "opus",
    /* 其它 */
    "proper", "repack", "extended", "uncut", "unrated", "directors", "cut",
    "hdr", "hdr10", "dovi", "sdr", "yify", "yts", "mx", "nf", "amzn", "itv",
    "dsnp", "hmax", "atvp", "multi", "dual", "subs", "sub", "chs", "cht",
    NULL,
};

/* 语言/字幕类型标签：出现在主干之后属于「同一条字幕的不同语言版本」。
 * 注意 `2`、`5.1` 这类音轨编号故意不在表里 —— 它们和续集数字混在一起，
 * 放进来会让 `电影2.srt` 挂到 `电影.mkv`。 */
static const char *const kLang[] = {
    "zh", "zhcn", "zhtw", "zhhk", "chs", "cht", "chn", "chi", "zho",
    "en", "eng", "english", "jp", "jpn", "japanese", "kr", "kor", "korean",
    "sc", "tc", "gb", "big5",
    NULL,
};

static int in_list(const char *const *list, const char *word)
{
    for (int i = 0; list[i]; i++) {
        if (strcmp(list[i], word) == 0) {
            return 1;
        }
    }
    return 0;
}

static int is_noise_word(const char *word)
{
    return in_list(kNoise, word) || in_list(kLang, word);
}

/* 词是否「只是装饰」：语言标签、噪声词，或 v2/v3 这类版本号。
 * 裸数字不算装饰 —— 那是续集或另一集的编号。 */
static int only_decoration(const char *rest)
{
    char buf[512];
    size_t n = 0;
    for (const char *q = rest; *q && n + 1 < sizeof(buf); q++) {
        unsigned char c = (unsigned char)*q;
        if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || c >= 0x80) {
            buf[n++] = (char)c;
        } else {
            buf[n++] = ' ';
        }
    }
    buf[n] = '\0';
    char *save = NULL;
    for (char *t = strtok_r(buf, " ", &save); t; t = strtok_r(NULL, " ", &save)) {
        if (is_noise_word(t)) {
            continue;
        }
        if (t[0] == 'v' && isdigit((unsigned char)t[1])) {
            int digits_only = 1;
            for (const char *q = t + 1; *q; q++) {
                if (!isdigit((unsigned char)*q)) {
                    digits_only = 0;
                    break;
                }
            }
            if (digits_only) {
                continue;
            }
        }
        return 0;
    }
    return 1;
}

/* 摘掉发布组/质量/语言标签后的主体，只留片名与本集编号。
 * 方括号、圆括号里的整段丢链 —— 那里通常是发布组和站点标签。 */
static void core_of(const char *stem, char *out, size_t outlen)
{
    char buf[1024];
    size_t n = 0;
    int bracket = 0;
    for (const char *q = stem; *q && n + 1 < sizeof(buf); q++) {
        if (*q == '[' || *q == '(' || *q == '{') {
            bracket++;
            buf[n++] = ' ';
            continue;
        }
        if (*q == ']' || *q == ')' || *q == '}') {
            if (bracket > 0) {
                bracket--;
            }
            buf[n++] = ' ';
            continue;
        }
        if (bracket) {
            buf[n++] = ' ';
            continue;
        }
        unsigned char c = (unsigned char)*q;
        if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || c >= 0x80) {
            buf[n++] = (char)c;
        } else {
            buf[n++] = ' ';
        }
    }
    buf[n] = '\0';

    size_t w = 0;
    char *save = NULL;
    for (char *t = strtok_r(buf, " ", &save); t; t = strtok_r(NULL, " ", &save)) {
        if (is_noise_word(t)) {
            continue;
        }
        /* 8 位十六进制且带数字的串，基本是发布组算出来的 CRC（D12B2CA8）。 */
        size_t len = strlen(t);
        if (len == 8) {
            int hex = 1;
            int digit = 0;
            for (size_t i = 0; i < len; i++) {
                if (isdigit((unsigned char)t[i])) {
                    digit = 1;
                } else if (t[i] < 'a' || t[i] > 'f') {
                    hex = 0;
                    break;
                }
            }
            if (hex && digit) {
                continue;
            }
        }
        if (w && w + 1 < outlen - 1) {
            out[w++] = ' ';
        }
        for (const char *q = t; *q && w + 1 < outlen - 1; q++) {
            out[w++] = *q;
        }
    }
    out[w] = '\0';
}

/* 认集数，返回归一化键；认不出返回 0 并把 out 置空。
 *
 * 只认有明确形状的写法：S01E02、1x02、第02集、E02，以及两位以上的纯数字
 * 尾巴（悠哉日常大王001、白箱101、101.mp4）。一位数字不当集数，否则
 * 「电影2」这种续集会被当成第 2 集，进而和「电影」误配。 */
static void episode_key(const char *stem, char *out, size_t outlen)
{
    out[0] = '\0';
    size_t len = strlen(stem);

    for (size_t i = 0; i < len; i++) {
        if (stem[i] == 's' && i + 1 < len && isdigit((unsigned char)stem[i + 1])) {
            size_t j = i + 1;
            long season = 0;
            while (j < len && isdigit((unsigned char)stem[j]) && j - i <= 3) {
                season = season * 10 + (stem[j] - '0');
                j++;
            }
            while (j < len && (stem[j] == ' ' || stem[j] == '.' || stem[j] == '_' ||
                               stem[j] == '-')) {
                j++;
            }
            if (j < len && stem[j] == 'e' && j + 1 < len &&
                isdigit((unsigned char)stem[j + 1])) {
                long ep = 0;
                j++;
                while (j < len && isdigit((unsigned char)stem[j]) && j - i <= 8) {
                    ep = ep * 10 + (stem[j] - '0');
                    j++;
                }
                snprintf(out, outlen, "s%lde%ld", season, ep);
                return;
            }
        }
    }

    for (size_t i = 0; i + 2 < len; i++) {
        if (!isdigit((unsigned char)stem[i])) {
            continue;
        }
        if (i > 0 && (isalnum((unsigned char)stem[i - 1]))) {
            continue;
        }
        size_t j = i;
        long season = 0;
        while (j < len && isdigit((unsigned char)stem[j]) && j - i < 3) {
            season = season * 10 + (stem[j] - '0');
            j++;
        }
        if (j >= len || stem[j] != 'x') {
            continue;
        }
        j++;
        if (j >= len || !isdigit((unsigned char)stem[j])) {
            continue;
        }
        long ep = 0;
        while (j < len && isdigit((unsigned char)stem[j]) && j - i < 8) {
            ep = ep * 10 + (stem[j] - '0');
            j++;
        }
        snprintf(out, outlen, "s%lde%ld", season, ep);
        return;
    }

    /* 纯数字尾巴：101.mp4 / 悠哉日常大王001。 */
    size_t end = len;
    size_t start = end;
    while (start > 0 && isdigit((unsigned char)stem[start - 1])) {
        start--;
    }
    if (end - start >= 2) {
        long ep = 0;
        for (size_t i = start; i < end; i++) {
            ep = ep * 10 + (stem[i] - '0');
        }
        snprintf(out, outlen, "e%ld", ep);
        return;
    }
    /* 单数字前缀：`54-S10E01 ...` 里的 S10E01 已在上面处理。裸「2」不算。 */
}

void lp_sub_match_stem(const char *name, char *out, size_t outlen)
{
    const char *base = name;
    for (const char *q = name; *q; q++) {
        if (*q == '/' || *q == '\\') {
            base = q + 1;
        }
    }
    const char *dot = strrchr(base, '.');
    size_t n = dot ? (size_t)(dot - base) : strlen(base);
    if (n >= outlen) {
        n = outlen - 1;
    }
    for (size_t i = 0; i < n; i++) {
        out[i] = (char)tolower((unsigned char)base[i]);
    }
    out[n] = '\0';
}

/* 字符二元组 Dice 系数，给「不是前缀、但有重叠」的名字用。和 Dart 侧同一
 * 阈值 0.86：低了会把《电影1》配到《电影2》这种只差一位的名字上。
 *
 * 比对时要把已经配掉的二元组扣掉（计数池），否则 `aaaa` 这种重复字符会把
 * 系数算成 1.5 —— 每条 a 的二元组都能在前缀里找到同一个。 */
static double dice(const char *a, const char *b)
{
    size_t la = strlen(a);
    size_t lb = strlen(b);
    if (la < 2 || lb < 2) {
        return 0.0;
    }
    /* 核心名一般不到 200 字节，定点容量的计数池足够；溢出就退回朴素比较。 */
    unsigned char used[1024];
    size_t pairs = lb - 1;
    if (pairs >= sizeof(used)) {
        return 0.0;
    }
    memset(used, 0, pairs);
    int common = 0;
    size_t i = 0;
    while (i + 1 < la) {
        size_t j = 0;
        while (j + 1 < lb) {
            if (!used[j] && a[i] == b[j] && a[i + 1] == b[j + 1]) {
                used[j] = 1;
                common++;
                break;
            }
            j++;
        }
        i++;
    }
    return 2.0 * (double)common / (double)((la - 1) + (lb - 1));
}

int lp_sub_match_related(const char *video_stem, const char *sub_stem)
{
    if (!video_stem || !*video_stem || !sub_stem || !*sub_stem) {
        return 0;
    }
    size_t va = strlen(video_stem);
    size_t vb = strlen(sub_stem);
    if (strcmp(video_stem, sub_stem) == 0) {
        return 1;
    }
    /* 第一级：主干前缀 + 分隔符（老规则，保留）。用「主干 + 分隔符」而不是
     * 裸 strncmp，是为了不把 `电影2.srt` 错配到 `电影.mkv` 上。 */
    if (vb > va && strncmp(sub_stem, video_stem, va) == 0) {
        char sep = sub_stem[va];
        if (sep == '.' || sep == '_' || sep == '-' || sep == ' ' || sep == '(') {
            return 1;
        }
    }

    char ka[64];
    char kb[64];
    episode_key(video_stem, ka, sizeof(ka));
    episode_key(sub_stem, kb, sizeof(kb));
    if (ka[0] && kb[0] && strcmp(ka, kb) != 0) {
        return 0;
    }

    char ca[512];
    char cb[512];
    core_of(video_stem, ca, sizeof(ca));
    core_of(sub_stem, cb, sizeof(cb));
    if (!ca[0] || !cb[0]) {
        return 0;
    }
    if (ka[0] && kb[0]) {
        /* 同一集：片名写法不同也认。 */
        return 1;
    }
    if (strcmp(ca, cb) == 0) {
        return 1;
    }
    size_t la = strlen(ca);
    size_t lb = strlen(cb);
    if (lb > la && strncmp(cb, ca, la) == 0) {
        return only_decoration(cb + la);
    }
    if (la > lb && strncmp(ca, cb, lb) == 0) {
        return only_decoration(ca + lb);
    }
    /* 都不是前缀关系：退到字符二元组相似度。同名片源跨语言（中文名 vs
     * 英文名）在这里对不上，那是翻译问题，字符相似度解决不了，也不该硬凑。 */
    return dice(ca, cb) >= 0.86;
}
