/* OS junk filter test — 目录列表里不能出现系统元数据文件。
 *
 *   lp_junk_test <dir>
 *
 * 用户反馈「macbook 访问共享后服务端多出 .DS_Store」。要分两件事：
 *   1. 谁写的：是 Finder，不是本 app（内核打开共享一律 O_RDONLY）；
 *      正解是在 Mac 上设 DSDontWriteNetworkStores。
 *   2. 列表里别显示：即使服务器上已经有了这些文件，也不该混进媒体列表 ——
 *      这条由 lp_is_os_junk_name() 保证，本程序就是它的回归测试。
 *
 * 退出码：0 通过；1 有元数据文件漏进列表。
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lanplayer/lp_player.h"
#include "lanplayer/lp_source.h"

/* 判定「这个文件名属于系统元数据」。测试自己再写一遍，不依赖被测代码，
 * 否则被测函数写错了测试也会跟着错。 */
static int is_junk(const char *n)
{
    if (!n) return 0;
    if (strcmp(n, ".DS_Store") == 0) return 1;
    if (strcmp(n, "desktop.ini") == 0) return 1;
    if (strcmp(n, "Thumbs.db") == 0) return 1;
    if (strcmp(n, ".directory") == 0) return 1;
    if (n[0] == '.' && n[1] == '_') return 1; /* AppleDouble */
    if (strcmp(n, ".Trashes") == 0) return 1;
    if (strcmp(n, ".Spotlight-V100") == 0) return 1;
    if (strcmp(n, ".fseventsd") == 0) return 1;
    if (strcmp(n, "System Volume Information") == 0) return 1;
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <dir-or-smb-url>\n", argv[0]);
        return 2;
    }
    char *json = NULL;
    int32_t rc = lp_source_list(argv[1], NULL, &json);
    if (rc != 0 || !json) {
        fprintf(stderr, "FAIL list %s rc=%d\n", argv[1], (int)rc);
        return 1;
    }

    /* 列表是 JSON，这里只需要找 "name":"..." 里的文件名 —— 用最朴素的扫描，
     * 免得为测试引入一个 JSON 解析器。 */
    int entries = 0, leaked = 0;
    const char *p = json;
    const char *key = "\"name\":\"";
    size_t klen = strlen(key);
    while ((p = strstr(p, key)) != NULL) {
        p += klen;
        const char *end = strchr(p, '"');
        if (!end) break;
        size_t len = (size_t)(end - p);
        char name[512];
        if (len >= sizeof(name)) len = sizeof(name) - 1;
        memcpy(name, p, len);
        name[len] = '\0';
        entries++;
        if (is_junk(name)) {
            fprintf(stderr, "FAIL 元数据文件漏进列表: %s\n", name);
            leaked++;
        }
        p = end;
    }

    printf("entries=%d leaked=%d\n", entries, leaked);
    lp_string_free(json);
    if (leaked) {
        return 1;
    }
    printf("all junk-filter cases passed\n");
    return 0;
}
