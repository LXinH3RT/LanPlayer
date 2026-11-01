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

int main(void)
{
    printf("transport registry: %d entries\n", lp_transport_count());
    test_scheme_list();
    test_lookup();
    test_entries();
    test_url_shape();
    if (failures) {
        fprintf(stderr, "\n%d failure(s)\n", failures);
        return 1;
    }
    printf("\nall transport registry cases passed\n");
    return 0;
}
