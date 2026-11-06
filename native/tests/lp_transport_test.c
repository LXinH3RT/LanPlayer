/* Transport registry behaviour test.
 *
 *   lp_transport_test    run every registry assertion, exit 0 only if all pass
 *
 * 为什么单独一个 exe：这些断言要用 source_internal.h 的内部接口，而 Linux/CI
 * 的 lp_smoke_test 链接的是 liblanplayer.so，符号可见性是 hidden，内部符号
 * 不在动态符号表里（ld 报 undefined reference to `lp_transport_find'）。
 * 这个测试和 lp_nal_test 一样直接链内核对象，所以能看见内部函数，也就不需要
 * 为了测试去放开整个共享库的可见性。
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lanplayer/lp_source.h"

#include "source_internal.h"

static int failures;

static void check(int cond, const char *what)
{
    if (cond) {
        return;
    }
    fprintf(stderr, "FAIL: %s\n", what);
    failures++;
}

/* scheme 列表必须由注册表推导出来，而不是另有一份手写清单。 */
static void test_scheme_list(void)
{
    char *schemes = NULL;
    if (lp_source_schemes(&schemes) != LP_OK || !schemes) {
        fprintf(stderr, "FAIL: lp_source_schemes failed\n");
        failures++;
        return;
    }
    printf("schemes=%s\n", schemes);

    check(strstr(schemes, "\"file\"") != NULL, "scheme list is missing \"file\"");

    /* 每个列出来的 scheme 都必须能在注册表里找到一份条目。 */
    for (int i = 0; i < lp_transport_count(); i++) {
        const LpTransport *tp = lp_transport_at(i);
        if (!tp || !tp->public_scheme) {
            continue;
        }
        char needle[64];
        snprintf(needle, sizeof(needle), "\"%s\"", tp->scheme);
        if (!strstr(schemes, needle)) {
            fprintf(stderr, "FAIL: %s is registered as public but missing from %s\n", tp->scheme,
                    schemes);
            failures++;
        }
    }
    lp_string_free(schemes);
}

/* 查表、未知 scheme、别名归一。 */
static void test_lookup(void)
{
    const LpTransport *file = lp_transport_find("file");
    check(file != NULL, "file:// does not resolve to a transport");
    check(file && file->custom_io == 1, "file:// must drive its own LpIo");
    check(file && file->hosted == 0, "file:// has no host/share shape");
    check(lp_transport_custom_io("file") == 1, "lp_transport_custom_io(file) must be 1");
    check(lp_transport_default_port("file") == -1, "file:// must not claim a default port");
    check(lp_transport_hosted("file") == 0, "lp_transport_hosted(file) must be 0");

    check(lp_transport_find("no-such-scheme") == NULL, "unknown scheme must not resolve");
    check(lp_transport_find("") == NULL, "empty scheme must not resolve");
    check(lp_transport_find(NULL) == NULL, "NULL scheme must not resolve");
    check(lp_transport_custom_io("no-such-scheme") == 0,
          "unknown scheme must not claim a custom IO");
    check(lp_transport_default_port("no-such-scheme") == -1,
          "unknown scheme must not report a default port");

    /* smb2:// is an alias of smb://, not a second transport. */
    const LpTransport *smb = lp_transport_find("smb");
    check(lp_transport_find("smb2") == smb, "smb2:// must alias smb://");

    check(lp_transport_at(-1) == NULL, "lp_transport_at(-1) must be NULL");
    check(lp_transport_at(lp_transport_count()) == NULL,
          "lp_transport_at(count) must be NULL");
    check(lp_transport_count() >= 1, "the registry must hold at least one transport");

    /* file:// is present in every build; smb may be compiled out. */
    check(file != NULL, "file:// must always be registered");
}

/* 每个条目自己的字段必须自洽，否则 URL 拼装会默默变形。 */
static void test_entries(void)
{
    for (int i = 0; i < lp_transport_count(); i++) {
        const LpTransport *tp = lp_transport_at(i);
        if (!tp) {
            fprintf(stderr, "FAIL: registry slot %d is NULL\n", i);
            failures++;
            continue;
        }
        check(tp->scheme != NULL && tp->scheme[0] != '\0', "every transport needs a scheme");
        /* 托管型（host/share）必须有端口概念，本地型必须没有。 */
        if (tp->hosted) {
            check(tp->default_port >= 0 || tp->default_port == -1,
                  "a hosted transport either has a default port or leaves it to the URL");
        } else {
            check(tp->default_port == -1, "a non-hosted transport must not claim a default port");
        }
        /* 自建 IO 的必须有 open/read/seek；交给 FFmpeg 的必须一个都没有。 */
        if (tp->custom_io) {
            check(tp->open != NULL, "a custom-IO transport needs an open callback");
            check(tp->read != NULL, "a custom-IO transport needs a read callback");
            check(tp->seek != NULL, "a custom-IO transport needs a seek callback");
            check(tp->close != NULL, "a custom-IO transport needs a close callback");
        }
        /* 查表按名字能找到自己。 */
        check(lp_transport_find(tp->scheme) == tp, "a registered scheme must resolve to itself");
    }
}

/* URL 的形状由注册表决定，不再散落在 url.c 里的 if 链。 */
static void test_url_shape(void)
{
    LpUrl u;
    memset(&u, 0, sizeof(u));
    check(lp_url_parse("file:///tmp/movie.mkv", &u) == LP_OK, "file:// URL must parse");
    check(u.is_hosted == 0, "file:// must parse as a local path");
    check(u.port == -1, "file:// must parse without a port");

    memset(&u, 0, sizeof(u));
    check(lp_url_parse("smb2://user:pw@nas/share/dir/a.mkv", &u) == LP_OK,
          "smb2:// URL must parse");
    check(u.is_hosted == 1, "smb:// must parse as a hosted share");
    check(u.port == 445, "smb:// must default to 445");
    check(strcmp(u.scheme, "smb2") == 0, "the raw scheme is kept as typed");

    /* 拼回去时 scheme 与共享名都要来自注册表，且默认端口不重复出现在 URL 里。 */
    char built[256];
    memset(built, 0, sizeof(built));
    lp_url_build(&u, built, sizeof(built));
    check(strncmp(built, "smb2://", 7) == 0, "lp_url_build must reuse the parsed scheme");
    check(strstr(built, ":445") == NULL, "the default port must stay implicit");
    check(strstr(built, "/share") != NULL, "the share segment must survive the round trip");
    check(strstr(built, "user") == NULL, "lp_url_build must not leak credentials");

    memset(&u, 0, sizeof(u));
    check(lp_url_parse("file:///tmp/movie.mkv", &u) == LP_OK, "file:// URL must parse again");
    memset(built, 0, sizeof(built));
    lp_url_build(&u, built, sizeof(built));
    check(strncmp(built, "file://", 7) == 0, "lp_url_build must use the parsed scheme for files");
}

/* 主机名后面不许凭空多出字符。
 *
 * 这里钉的是一次真实事故：lp_url_authority 用 "%s://%s%s%d" 配
 * `with_port ? ":" : ""` 和 `with_port ? port : 0`，默认端口时那个 %d 仍然会
 * 打印出 0，于是 "smb://192.168.5.7" 变成 "smb://192.168.5.70"。首页的根目录
 * URL 由 Dart 侧拼，所以照样列得出来；点进任何子目录都是内核拼的 URL，全部
 * 连不上 —— 表现就是「主目录能看到，进下级文件夹就报错」。
 *
 * 主机名必须用点分 IP：域名里带数字结尾（nas1）时那个多余的 0 会拼成
 * nas10，同样连不上，但不看字符数是看不出来的。 */
static void test_authority_shape(void)
{
    LpUrl u;
    memset(&u, 0, sizeof(u));
    check(lp_url_parse("smb://192.168.5.7/share/dir", &u) == LP_OK, "smb:// URL must parse");
    char auth[128];
    memset(auth, 0, sizeof(auth));
    lp_url_authority(&u, auth, sizeof(auth));
    check(strcmp(auth, "smb://192.168.5.7") == 0,
          "the default port must not leave a stray character behind the host");

    /* 整条拼回来的 URL 也要逐字对得上，只看 host 会漏掉后面几段。 */
    char built[256];
    memset(built, 0, sizeof(built));
    lp_url_build(&u, built, sizeof(built));
    check(strcmp(built, "smb://192.168.5.7/share/dir") == 0,
          "lp_url_build must reproduce the URL that was parsed");

    /* 非默认端口要真的出现，且只出现一次。 */
    memset(&u, 0, sizeof(u));
    check(lp_url_parse("smb://192.168.5.7:4450/share/dir", &u) == LP_OK,
          "smb:// URL with a custom port must parse");
    check(u.port == 4450, "a custom port must survive the parse");
    memset(built, 0, sizeof(built));
    lp_url_build(&u, built, sizeof(built));
    check(strcmp(built, "smb://192.168.5.7:4450/share/dir") == 0,
          "a non-default port must appear exactly once");

    /* 域名以数字结尾时同理：不许变成 nas10。根目录的 path 是 "/"，拼回来
     * 自带尾斜杠，所以这里只钉主机段。 */
    memset(&u, 0, sizeof(u));
    check(lp_url_parse("smb://nas1/share", &u) == LP_OK, "a hostname may end with a digit");
    memset(built, 0, sizeof(built));
    lp_url_build(&u, built, sizeof(built));
    check(strncmp(built, "smb://nas1/", 11) == 0,
          "a hostname ending in a digit must not grow another digit");

    /* 默认端口显式写出来时，拼回去要收敛成不带端口的那种写法。 */
    memset(&u, 0, sizeof(u));
    check(lp_url_parse("smb://192.168.5.7:445/share", &u) == LP_OK, "an explicit default port parses");
    memset(built, 0, sizeof(built));
    lp_url_build(&u, built, sizeof(built));
    check(strncmp(built, "smb://192.168.5.7/", 18) == 0,
          "an explicit default port must collapse back to the implicit form");
}

/* 凭据里有 `@` `:` `/` 时，拼进去再解析回来必须还是原文。
 *
 * 以前 lp_url_insert_credentials 直接 `%s:%s@` 拼，lp_url_parse 又从前往后找
 * 第一个 `@` —— 密码 `p@ss:w/rd` 拼出 `smb://u:p@ss:w/rd@host/share`，解析回来
 * host 变成 `ss:w`（或 `ss`），认证必然失败，而界面上只报「连不上」。前半段钉
 * 拼接要转义、后半段钉解析认最后一个 `@`。 */
static void test_credentials_roundtrip(void)
{
    LpUrl u;
    memset(&u, 0, sizeof(u));
    check(lp_url_parse("smb://nas/share/dir", &u) == LP_OK, "a bare share URL must parse");
    snprintf(u.user, sizeof(u.user), "user");
    snprintf(u.password, sizeof(u.password), "p@ss:w/rd");

    char with_creds[512];
    memset(with_creds, 0, sizeof(with_creds));
    lp_url_insert_credentials(&u, "smb://nas/share/dir", with_creds, sizeof(with_creds));
    check(strstr(with_creds, "p@ss") == NULL,
          "the password's '@' must be percent-encoded, not spliced in raw");
    check(strstr(with_creds, "@nas") != NULL, "the host must still follow the credential marker");

    LpUrl back;
    memset(&back, 0, sizeof(back));
    check(lp_url_parse(with_creds, &back) == LP_OK, "a URL carrying credentials must parse back");
    check(strcmp(back.user, "user") == 0, "the user must survive the round trip");
    check(strcmp(back.password, "p@ss:w/rd") == 0, "the password must survive the round trip");
    check(strcmp(back.host, "nas") == 0, "the host must not absorb part of the password");
    check(strcmp(back.share, "share") == 0, "the share must survive the round trip");

    /* 手写、未转义的那种也要能认：用户从别处复制来的 URL 不会替我们转义。
     * 这里只钉 `@`（报告里的原例）—— 未转义的 `/` 与路径分隔符在语法上无法
     * 区分（`a/p@ss/b` 到底是「密码里有斜杠」还是「路径里有 at 号」没有答案），
     * 带 `/` `:` 的密码由上面那段百分号转义的往返用例负责。 */
    memset(&back, 0, sizeof(back));
    check(lp_url_parse("smb://user:p@ssword@nas/share", &back) == LP_OK,
          "an unescaped password containing '@' must still parse");
    check(strcmp(back.password, "p@ssword") == 0,
          "an unescaped password must be taken whole, up to the last '@'");
    check(strcmp(back.host, "nas") == 0, "an unescaped password must not swallow the host");
}

/* IPv6 字面量里的冒号不是端口分隔符。
 *
 * 以前 `smb://[fe80::1]/share` 被「反向找最后一个冒号」切成 host=`[fe80:` 加一个
 * 假端口，地址栏里看着没问题，连的时候报主机不存在。 */
static void test_ipv6_literal(void)
{
    LpUrl u;
    memset(&u, 0, sizeof(u));
    check(lp_url_parse("smb://[fe80::1]/share/dir", &u) == LP_OK, "an IPv6 literal must parse");
    check(strcmp(u.host, "[fe80::1]") == 0, "the bracketed IPv6 host must be taken whole");
    check(u.port == 445, "an IPv6 literal without a port must take the scheme default");
    check(strcmp(u.share, "share") == 0, "the share must survive an IPv6 authority");

    /* 带显式端口时端口要解析出来，且不能把 `]` 吞进端口文本。 */
    memset(&u, 0, sizeof(u));
    check(lp_url_parse("smb://[fe80::1]:1445/share", &u) == LP_OK,
          "an IPv6 literal with a port must parse");
    check(strcmp(u.host, "[fe80::1]") == 0, "a port must not be glued onto an IPv6 host");
    check(u.port == 1445, "an explicit port after an IPv6 literal must be honoured");

    /* 环回地址是最常见的一种，单独钉一次。 */
    memset(&u, 0, sizeof(u));
    check(lp_url_parse("smb://[::1]/share", &u) == LP_OK, "the IPv6 loopback must parse");
    check(strcmp(u.host, "[::1]") == 0, "the IPv6 loopback host must be taken whole");
}

int main(void)
{
    printf("transport registry: %d entries\n", lp_transport_count());
    test_scheme_list();
    test_lookup();
    test_entries();
    test_url_shape();
    test_authority_shape();
    test_credentials_roundtrip();
    test_ipv6_literal();
    if (failures) {
        fprintf(stderr, "\n%d failure(s)\n", failures);
        return 1;
    }
    printf("\nall transport registry cases passed\n");
    return 0;
}
