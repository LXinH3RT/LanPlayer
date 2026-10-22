/* URL parsing/joining and directory-entry JSON helpers. */
#include <ctype.h>
#include <stdlib.h>

#include "source_internal.h"

static int hex_val(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Percent-decodes into dst.  Invalid escapes are copied verbatim. */
static void url_decode(char *dst, size_t dstlen, const char *src, size_t srclen)
{
    size_t o = 0;
    for (size_t i = 0; i < srclen && o + 1 < dstlen; i++) {
        if (src[i] == '%' && i + 2 < srclen) {
            int hi = hex_val(src[i + 1]);
            int lo = hex_val(src[i + 2]);
            if (hi >= 0 && lo >= 0) {
                dst[o++] = (char)((hi << 4) | lo);
                i += 2;
                continue;
            }
        }
        dst[o++] = src[i];
    }
    dst[o] = '\0';
}

static void copy_lower(char *dst, size_t dstlen, const char *src, size_t srclen)
{
    size_t n = srclen < dstlen - 1 ? srclen : dstlen - 1;
    for (size_t i = 0; i < n; i++) {
        dst[i] = (char)tolower((unsigned char)src[i]);
    }
    dst[n] = '\0';
}

static void copy_raw(char *dst, size_t dstlen, const char *src, size_t srclen)
{
    size_t n = srclen < dstlen - 1 ? srclen : dstlen - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

int lp_url_parse(const char *url, LpUrl *out)
{
    if (!url || !out) {
        return LP_ERR_ARGUMENT;
    }
    memset(out, 0, sizeof(*out));
    out->port = 445;

    const char *rest = url;
    const char *sep = strstr(url, "://");
    if (sep) {
        copy_lower(out->scheme, sizeof(out->scheme), url, (size_t)(sep - url));
        rest = sep + 3;
    } else {
        snprintf(out->scheme, sizeof(out->scheme), "file");
    }

    if (strcmp(out->scheme, "file") == 0) {
        const char *p = rest;
        /* file:///a/b  -> authority is empty, path begins at the third slash */
        if (p[0] == '/' && p[1] == '/') {
            p += 2;
            const char *slash = strchr(p, '/');
            p = slash ? slash : p;
        }
        url_decode(out->path, sizeof(out->path), p, strlen(p));
#if defined(_WIN32)
        /* Normalise separators so parent/child URL building stays consistent. */
        for (char *q = out->path; *q; q++) {
            if (*q == '\\') {
                *q = '/';
            }
        }
        /* file:///C:/x and /C:/x both mean "C:/x" on Windows. */
        if (out->path[0] == '/' && ((out->path[1] >= 'A' && out->path[1] <= 'Z') ||
                                    (out->path[1] >= 'a' && out->path[1] <= 'z')) &&
            out->path[2] == ':') {
            memmove(out->path, out->path + 1, strlen(out->path));
        }
#endif
        out->is_smb = 0;
        snprintf(out->host, sizeof(out->host), "localhost");
        return LP_OK;
    }

    if (strcmp(out->scheme, "smb") == 0 || strcmp(out->scheme, "smb2") == 0) {
        out->is_smb = 1;
        out->port = 445;
    } else if (strcmp(out->scheme, "https") == 0) {
        out->port = 443;
    } else if (strcmp(out->scheme, "http") == 0) {
        out->port = 80;
    } else if (strcmp(out->scheme, "tcp") == 0) {
        out->port = 0;
    }

    const char *authority = rest;
    const char *slash = strchr(rest, '/');
    const char *authority_end = slash ? slash : rest + strlen(rest);

    const char *at = memchr(authority, '@', (size_t)(authority_end - authority));
    const char *host_start = authority;
    if (at) {
        const char *colon = memchr(authority, ':', (size_t)(at - authority));
        if (colon) {
            url_decode(out->user, sizeof(out->user), authority, (size_t)(colon - authority));
            url_decode(out->password, sizeof(out->password), colon + 1, (size_t)(at - colon - 1));
        } else {
            url_decode(out->user, sizeof(out->user), authority, (size_t)(at - authority));
        }
        host_start = at + 1;
    }

    /* Optional :port after the host. */
    const char *port_sep = NULL;
    for (const char *p = authority_end; p > host_start; p--) {
        if (*(p - 1) == ':') {
            port_sep = p - 1;
            break;
        }
    }
    if (port_sep) {
        char portbuf[16];
        copy_raw(portbuf, sizeof(portbuf), port_sep + 1, (size_t)(authority_end - port_sep - 1));
        char *end = NULL;
        long v = strtol(portbuf, &end, 10);
        if (end && *end == '\0' && v > 0 && v < 65536) {
            out->port = (int)v;
        }
        copy_raw(out->host, sizeof(out->host), host_start, (size_t)(port_sep - host_start));
    } else {
        copy_raw(out->host, sizeof(out->host), host_start, (size_t)(authority_end - host_start));
    }

    if (slash) {
        url_decode(out->path, sizeof(out->path), slash, strlen(slash));
    } else {
        snprintf(out->path, sizeof(out->path), "/");
    }

    if (out->is_smb) {
        /* The first segment is the share name; the rest is the path inside it. */
        const char *p = out->path;
        while (*p == '/') {
            p++;
        }
        const char *end = strchr(p, '/');
        if (end) {
            copy_raw(out->share, sizeof(out->share), p, (size_t)(end - p));
            char restpath[1024];
            snprintf(restpath, sizeof(restpath), "%s", end);
            snprintf(out->path, sizeof(out->path), "%s", restpath);
        } else {
            copy_raw(out->share, sizeof(out->share), p, strlen(p));
            snprintf(out->path, sizeof(out->path), "/");
        }
    }

    /* Canonicalise the path: no trailing separator except for the root.  The UI
     * may hand us "smb://host/share/电影/" and a non-canonical path would make
     * every child URL carry a "//" segment and break parent comparison. */
    size_t plen = strlen(out->path);
    while (plen > 1 && out->path[plen - 1] == '/') {
        out->path[--plen] = '\0';
    }
    return LP_OK;
}

void lp_url_join(const LpUrl *u, const char *name, char *out, size_t outlen)
{
    char base[1200];
    int n = 0;
    if (u->is_smb) {
        n = snprintf(base, sizeof(base), "smb://%s%s%s", u->host,
                     u->port && u->port != 445 ? ":" : "", u->port && u->port != 445 ? "" : "");
        if (u->port && u->port != 445) {
            snprintf(base + n, sizeof(base) - (size_t)n, "%d", u->port);
            n = (int)strlen(base);
        }
        n += snprintf(base + n, sizeof(base) - (size_t)n, "/%s%s", u->share, u->path);
    } else {
        n = snprintf(base, sizeof(base), "file://%s", u->path);
    }
    if (strcmp(u->path, "/") != 0) {
        snprintf(out, outlen, "%s%s%s", base, (*name && base[strlen(base) - 1] == '/') ? "" : "/", name);
    } else {
        snprintf(out, outlen, "%s%s%s", base, u->is_smb ? "/" : "", name);
    }
}

const char *lp_kind_for_name(const char *name)
{
    const char *dot = strrchr(name, '.');
    if (!dot) {
        return "other";
    }
    char ext[16];
    copy_lower(ext, sizeof(ext), dot + 1, strlen(dot + 1));
    static const char *video[] = {"mkv", "mp4", "m4v", "avi", "mov", "wmv", "flv", "ts",
                                  "m2ts", "mts", "webm", "mpg", "mpeg", "rmvb", "rm", "3gp",
                                  "vob", "ogv", "asf", "divx", "f4v", "m2v", "mxf", NULL};
    static const char *sub[] = {"srt", "ass", "ssa", "vtt", "smi", "sami", "sub", "sup", "idx", NULL};
    static const char *audio[] = {"mp3", "aac", "flac", "wav", "ogg", "m4a", "opus", "wma", "ape", NULL};
    static const char *image[] = {"jpg", "jpeg", "png", "webp", "bmp", "gif", NULL};
    for (int i = 0; video[i]; i++) {
        if (strcmp(ext, video[i]) == 0) return "video";
    }
    for (int i = 0; sub[i]; i++) {
        if (strcmp(ext, sub[i]) == 0) return "subtitle";
    }
    for (int i = 0; audio[i]; i++) {
        if (strcmp(ext, audio[i]) == 0) return "audio";
    }
    for (int i = 0; image[i]; i++) {
        if (strcmp(ext, image[i]) == 0) return "image";
    }
    return "other";
}

int lp_is_video_name(const char *name)
{
    return strcmp(lp_kind_for_name(name), "video") == 0;
}

/* 浏览列表是否该显示这个文件。
 *
 * 只留视频、字幕、音频三类。`.txt`、`.docx`、`.ini`、`.exe` 之类对播放器
 * 没有任何意义，列出来只会把真正的媒体挤下去（用户报的就是这个）。
 * 目录始终保留 —— 由调用方判断 is_dir 之后再决定是否过滤。
 *
 * 注意这里**不改** lp_kind_for_name 的返回值：kind 还用于别的判断
 * （比如播放器要不要尝试打开），只是不再把它们展示出来。 */
int lp_is_listable_media(const char *name)
{
    const char *kind = lp_kind_for_name(name);
    return strcmp(kind, "video") == 0 || strcmp(kind, "subtitle") == 0 ||
           strcmp(kind, "audio") == 0;
}

int lp_is_subtitle_name(const char *name)
{
    return strcmp(lp_kind_for_name(name), "subtitle") == 0;
}

/* 系统/桌面环境留下的元数据文件：不该出现在播放器的文件列表里。
 *
 *   .DS_Store           macOS Finder 的目录布局缓存（**由 Finder 写入服务器**，
 *                       不是本 app 写的 —— 内核打开共享一律 O_RDONLY）
 *   ._foo              AppleDouble 资源分支（macOS 拷文件到非 HFS+ 卷时产生）
 *   desktop.ini/.Thumbs.db/.directory   Windows/Linux 的同类文件
 *   .Trashes/.Spotlight-V100/.fseventsd  macOS 在共享根上建的隐藏目录
 *
 * 用户反馈「macbook 访问共享后服务端多出 .DS_Store」，那是 Finder 的行为，
 * 正解是在 Mac 上 `defaults write com.apple.desktopservices
 * DSDontWriteNetworkStores -bool true`（见 docs/build.md 4.9）；
 * 这里做的是另一件事：即使服务器上已经有这些文件，也别把它们列进列表。 */
int lp_is_os_junk_name(const char *name)
{
    if (!name || !*name) {
        return 0;
    }
    if (strcmp(name, ".DS_Store") == 0 || strcmp(name, "desktop.ini") == 0 ||
        strcmp(name, "Thumbs.db") == 0 || strcmp(name, ".directory") == 0 ||
        strcmp(name, ".localized") == 0) {
        return 1;
    }
    /* 以 "._" 开头的 AppleDouble 旁文件 */
    if (name[0] == '.' && name[1] == '_') {
        return 1;
    }
    static const char *hidden_dirs[] = {
        ".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems",
        ".DocumentRevisions-V100", ".AppleDouble", "System Volume Information",
        "$RECYCLE.BIN", NULL};
    for (int i = 0; hidden_dirs[i]; i++) {
        if (strcmp(name, hidden_dirs[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

/* Natural order: "E2" sorts before "E10", directories first. */
static int natural_cmp(const char *a, const char *b)
{
    while (*a && *b) {
        if (isdigit((unsigned char)*a) && isdigit((unsigned char)*b)) {
            const char *pa = a;
            const char *pb = b;
            while (*pa == '0') pa++;
            while (*pb == '0') pb++;
            const char *ea = pa;
            const char *eb = pb;
            while (isdigit((unsigned char)*ea)) ea++;
            while (isdigit((unsigned char)*eb)) eb++;
            int la = (int)(ea - pa);
            int lb = (int)(eb - pb);
            if (la != lb) return la < lb ? -1 : 1;
            int r = strncmp(pa, pb, (size_t)la);
            if (r != 0) return r < 0 ? -1 : 1;
            while (isdigit((unsigned char)*a)) a++;
            while (isdigit((unsigned char)*b)) b++;
            continue;
        }
        int ca = tolower((unsigned char)*a);
        int cb = tolower((unsigned char)*b);
        if (ca != cb) return ca < cb ? -1 : 1;
        a++;
        b++;
    }
    if (*a == *b) return 0;
    return *a ? 1 : -1;
}

static int item_cmp(const void *va, const void *vb)
{
    const LpDirItem *a = va;
    const LpDirItem *b = vb;
    if (a->is_dir != b->is_dir) {
        return a->is_dir ? -1 : 1;
    }
    return natural_cmp(a->name, b->name);
}

void lp_sort_items(LpDirItem *items, int count)
{
    if (count > 1) {
        qsort(items, (size_t)count, sizeof(LpDirItem), item_cmp);
    }
}

int lp_path_parent(const char *path, char *out, size_t outlen)
{
    if (!path || !out) {
        return -1;
    }
    snprintf(out, outlen, "%s", path);
    size_t n = strlen(out);
    while (n > 1 && out[n - 1] == '/') {
        out[--n] = '\0';
    }
    char *slash = strrchr(out, '/');
    char *bslash = strrchr(out, '\\');
    if (bslash && (!slash || bslash > slash)) {
        slash = bslash;
    }
    if (!slash || slash == out) {
        snprintf(out, outlen, "/");
        return 0;
    }
    *slash = '\0';
    return 0;
}

static void url_build(const LpUrl *u, char *out, size_t outlen)
{
    if (u->is_smb) {
        if (u->port && u->port != 445) {
            snprintf(out, outlen, "smb://%s:%d/%s%s", u->host, u->port, u->share, u->path);
        } else {
            snprintf(out, outlen, "smb://%s/%s%s", u->host, u->share, u->path);
        }
    } else {
        snprintf(out, outlen, "file://%s", u->path);
    }
}

void lp_entries_begin(LpStr *out, const LpUrl *u)
{
    char self[2048];
    char parent_path[1024];
    LpUrl parent = *u;
    lp_path_parent(u->path, parent_path, sizeof(parent_path));
    snprintf(parent.path, sizeof(parent.path), "%s", parent_path);

    char parent_url[2048];
    url_build(u, self, sizeof(self));
    url_build(&parent, parent_url, sizeof(parent_url));

    lp_str_append(out, "{\"url\":");
    lp_str_append_json_str(out, self);
    lp_str_append(out, ",\"parent\":");
    lp_str_append_json_str(out, strcmp(self, parent_url) == 0 ? "" : parent_url);
    lp_str_append(out, ",\"entries\":[");
}

/* Join a child name onto a directory path without producing "//" when the
 * parent path already ends with a separator (a listing URL may arrive as
 * ".../电影/" from the UI).  "." and "" stay at the current directory. */
static void join_child_path(const char *base, const char *name, char *out, size_t outlen)
{
    size_t n = strlen(base);
    while (n > 1 && base[n - 1] == '/') {
        n--;
    }
    if (n == 0) {
        snprintf(out, outlen, "/%s", name);
    } else if (n == 1 && base[0] == '/') {
        snprintf(out, outlen, "/%s", name);
    } else {
        snprintf(out, outlen, "%.*s/%s", (int)n, base, name);
    }
}

void lp_entries_add(LpStr *out, const LpUrl *u, const LpDirItem *items, int count)
{
    for (int i = 0; i < count; i++) {
        const LpDirItem *it = &items[i];
        LpUrl child = *u;
        join_child_path(u->path, it->name, child.path, sizeof(child.path));
        /* For entries the share must be preserved; only the path changes. */
        char child_url[2048];
        url_build(&child, child_url, sizeof(child_url));

        const char *dot = strrchr(it->name, '.');
        char ext[16] = "";
        if (dot) {
            copy_lower(ext, sizeof(ext), dot + 1, strlen(dot + 1));
        }

        if (i) {
            lp_str_append(out, ",");
        }
        lp_str_append(out, "{\"name\":");
        lp_str_append_json_str(out, it->name);
        lp_str_append(out, ",\"path\":");
        lp_str_append_json_str(out, child_url);
        lp_str_append(out, ",\"is_dir\":%s", it->is_dir ? "true" : "false");
        lp_str_append(out, ",\"size\":%lld", (long long)it->size);
        lp_str_append(out, ",\"mtime\":%lld", (long long)it->mtime);
        lp_str_append(out, ",\"kind\":");
        lp_str_append_json_str(out, it->is_dir ? "dir" : lp_kind_for_name(it->name));
        lp_str_append(out, ",\"ext\":");
        lp_str_append_json_str(out, ext);
        lp_str_append(out, "}");
    }
}

void lp_entries_end(LpStr *out, const LpUrl *u)
{
    (void)u;
    lp_str_append(out, "]}");
}
