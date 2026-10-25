/* Local file system transport (module 5: local playback).
 *
 * Windows：URL 里的路径是 UTF-8，而 fopen/opendir/stat 的窄字符版本按 ANSI
 * 代码页解释字节 —— 中文目录名会因此打不开（列目录直接 NOT_FOUND），
 * 列出来的名字也会以 ANSI 字节塞进 JSON，Dart 那边解析 UTF-8 时炸掉。
 * 所以本文件在 _WIN32 下统一走宽字符：进来先 UTF-8 -> UTF-16，出去再从
 * UTF-16 转回 UTF-8。POSIX 侧原样使用字节路径。
 */
#include <dirent.h>
#include <errno.h>
#include <stdlib.h>
#include <sys/stat.h>

#if defined(_WIN32)
#include <windows.h>
#endif

#include "source_internal.h"

#if defined(_WIN32)

/* UTF-8 -> UTF-16，调用方负责 free。失败返回 NULL。 */
static wchar_t *wide_from_utf8(const char *s)
{
    if (!s) {
        return NULL;
    }
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) {
        return NULL;
    }
    wchar_t *w = malloc((size_t)n * sizeof(wchar_t));
    if (!w) {
        return NULL;
    }
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}

/* UTF-16 -> UTF-8，写进固定缓冲。失败时 buf 置空串。 */
static void utf8_from_wide(const wchar_t *w, char *buf, size_t cap)
{
    buf[0] = '\0';
    if (!w || cap == 0) {
        return;
    }
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, buf, (int)cap, NULL, NULL);
    if (n <= 0) {
        buf[0] = '\0';
    }
}

#endif /* _WIN32 */

static int file_transport_open(LpIo *io, const LpUrl *u, const LpSourceOptions *opts,
                               char *err, size_t errlen)
{
    (void)opts;
    if (!u->path[0]) {
        if (err && errlen) snprintf(err, errlen, "empty path");
        return LP_ERR_ARGUMENT;
    }
#if defined(_WIN32)
    wchar_t *wpath = wide_from_utf8(u->path);
    if (!wpath) {
        if (err && errlen) snprintf(err, errlen, "bad path %s", u->path);
        return LP_ERR_ARGUMENT;
    }
    FILE *f = _wfopen(wpath, L"rb");
    free(wpath);
#else
    FILE *f = fopen(u->path, "rb");
#endif
    if (!f) {
        /* errno 在这里可能已经不可靠（_wfopen 会自己置 errno），
         * 但 EACCES / ENOENT 的区分依旧有效。 */
        if (err && errlen) snprintf(err, errlen, "open %s failed: %s", u->path, strerror(errno));
        return errno == EACCES ? LP_ERR_AUTH : LP_ERR_NOT_FOUND;
    }
    struct stat st;
    if (fstat(fileno(f), &st) == 0) {
        io->size = (int64_t)st.st_size;
    } else {
        io->size = -1;
    }
    io->ctx = f;
    return LP_OK;
}

static void file_transport_close(LpIo *io)
{
    if (io && io->ctx) {
        fclose((FILE *)io->ctx);
        io->ctx = NULL;
    }
}

static int file_transport_read(LpIo *io, uint8_t *buf, int size)
{
    FILE *f = io ? io->ctx : NULL;
    if (!f) {
        return LP_ERR_IO;
    }
    size_t n = fread(buf, 1, (size_t)size, f);
    if (n == 0 && ferror(f)) {
        return LP_ERR_IO;
    }
    return (int)n;
}

static int64_t file_transport_seek(LpIo *io, int64_t offset, int whence)
{
    FILE *f = io ? io->ctx : NULL;
    if (!f) {
        return -1;
    }
#if defined(_WIN32)
    if (_fseeki64(f, offset, whence) != 0) {
        return -1;
    }
    return (int64_t)_ftelli64(f);
#else
    if (fseeko(f, (off_t)offset, whence) != 0) {
        return -1;
    }
    return (int64_t)ftello(f);
#endif
}

static int64_t file_transport_size(LpIo *io)
{
    FILE *f = io ? io->ctx : NULL;
    if (!f) {
        return -1;
    }
    struct stat st;
    if (fstat(fileno(f), &st) == 0) {
        return (int64_t)st.st_size;
    }
    return -1;
}

/* 一条目录项是否要收进列表。目录一律收；文件按 list_all 决定。
 * name 必须是 UTF-8（调用方已经从宽字符转好），否则扩展名判断对不上。 */
static int keep_entry(const char *name, int is_dir, const LpSourceOptions *opts)
{
    if (is_dir) {
        return 1;
    }
    if (opts && opts->list_all) {
        return 1;
    }
    /* 与 SMB 侧同一套规则：文件只留视频 / 字幕 / 音频。 */
    return lp_is_listable_media(name);
}

static int file_transport_list(const LpUrl *u, const LpSourceOptions *opts,
                               LpStr *out, char *err, size_t errlen)
{
    int list_all = opts && opts->list_all;
#if defined(_WIN32)
    wchar_t *wpath = wide_from_utf8(u->path);
    if (!wpath) {
        if (err && errlen) snprintf(err, errlen, "bad path %s", u->path);
        return LP_ERR_ARGUMENT;
    }
    /* 盘符根 "C:/" 去掉结尾斜杠再交给 _wopendir，才能列出整盘。 */
    size_t wl = wcslen(wpath);
    while (wl > 3 && (wpath[wl - 1] == L'/' || wpath[wl - 1] == L'\\')) {
        wpath[--wl] = L'\0';
    }
    _WDIR *d = _wopendir(wpath);
    if (!d) {
        if (err && errlen) {
            snprintf(err, errlen, "opendir %s failed: %s", u->path,
                     errno == EACCES ? "access denied" : "not found");
        }
        int rc = errno == EACCES ? LP_ERR_AUTH : LP_ERR_NOT_FOUND;
        free(wpath);
        return rc;
    }
#else
    DIR *d = opendir(u->path);
    if (!d) {
        if (err && errlen) snprintf(err, errlen, "opendir %s failed: %s", u->path, strerror(errno));
        return errno == EACCES ? LP_ERR_AUTH : LP_ERR_NOT_FOUND;
    }
#endif
    (void)list_all;
    int cap = 256, count = 0;
    LpDirItem *items = calloc((size_t)cap, sizeof(LpDirItem));
    if (!items) {
#if defined(_WIN32)
        _wclosedir(d);
        free(wpath);
#else
        closedir(d);
#endif
        return LP_ERR_NOMEM;
    }
#if defined(_WIN32)
    struct _wdirent *ent;
    while ((ent = _wreaddir(d)) != NULL) {
        char name[512];
        utf8_from_wide(ent->d_name, name, sizeof(name));
        if (!name[0] || strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
            continue;
        }
        /* 与 SMB 侧同一套过滤：.DS_Store / ._foo / desktop.ini 不进列表。 */
        if (lp_is_os_junk_name(name)) {
            continue;
        }
        wchar_t full[1600];
        swprintf(full, sizeof(full) / sizeof(full[0]), L"%ls/%ls", wpath, ent->d_name);
        struct _stat64 st;
        if (_wstat64(full, &st) != 0) {
            continue;
        }
        int is_dir = (st.st_mode & _S_IFDIR) != 0;
        if (!keep_entry(name, is_dir, opts)) {
            continue;
        }
        if (count == cap) {
            cap *= 2;
            LpDirItem *grown = realloc(items, (size_t)cap * sizeof(LpDirItem));
            if (!grown) {
                break;
            }
            items = grown;
        }
        LpDirItem *it = &items[count++];
        snprintf(it->name, sizeof(it->name), "%s", name);
        it->is_dir = is_dir;
        it->size = (int64_t)st.st_size;
        it->mtime = (int64_t)st.st_mtime;
    }
    _wclosedir(d);
    free(wpath);
#else
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) {
            continue;
        }
        /* 与 SMB 侧同一套过滤：.DS_Store / ._foo / desktop.ini 不进列表。 */
        if (lp_is_os_junk_name(ent->d_name)) {
            continue;
        }
        char full[1600];
        snprintf(full, sizeof(full), "%s/%s", u->path, ent->d_name);
        struct stat st;
        if (stat(full, &st) != 0) {
            continue;
        }
        int is_dir = S_ISDIR(st.st_mode);
        if (!keep_entry(ent->d_name, is_dir, opts)) {
            continue;
        }
        if (count == cap) {
            cap *= 2;
            LpDirItem *grown = realloc(items, (size_t)cap * sizeof(LpDirItem));
            if (!grown) {
                break;
            }
            items = grown;
        }
        LpDirItem *it = &items[count++];
        snprintf(it->name, sizeof(it->name), "%s", ent->d_name);
        it->is_dir = is_dir;
        it->size = (int64_t)st.st_size;
        it->mtime = (int64_t)st.st_mtime;
    }
    closedir(d);
#endif

    lp_sort_items(items, count);
    lp_entries_begin(out, u);
    lp_entries_add(out, u, items, count);
    lp_entries_end(out, u);
    free(items);
    return LP_OK;
}

static int file_transport_probe(const LpUrl *u, const LpSourceOptions *opts,
                                LpStr *out, char *err, size_t errlen)
{
    (void)opts;
    struct stat st;
    int is_dir;
#if defined(_WIN32)
    wchar_t *wpath = wide_from_utf8(u->path);
    if (!wpath) {
        if (err && errlen) snprintf(err, errlen, "bad path %s", u->path);
        return LP_ERR_ARGUMENT;
    }
    struct _stat64 wst;
    if (_wstat64(wpath, &wst) != 0) {
        free(wpath);
        if (err && errlen) snprintf(err, errlen, "stat %s failed: %s", u->path, strerror(errno));
        return LP_ERR_NOT_FOUND;
    }
    free(wpath);
    is_dir = (wst.st_mode & _S_IFDIR) != 0;
    memset(&st, 0, sizeof(st));
#else
    if (stat(u->path, &st) != 0) {
        if (err && errlen) snprintf(err, errlen, "stat %s failed: %s", u->path, strerror(errno));
        return LP_ERR_NOT_FOUND;
    }
    is_dir = S_ISDIR(st.st_mode);
#endif
    lp_str_append(out, "{\"server\":\"localhost\",\"authenticated\":true,\"shares\":[");
    if (!is_dir) {
        if (err && errlen) snprintf(err, errlen, "not a directory: %s", u->path);
        return LP_ERR_ARGUMENT;
    }
    lp_str_append_json_str(out, u->path);
    lp_str_append(out, "]}");
    return LP_OK;
}

const LpTransport lp_transport_file = {
    .scheme = "file",
    .open = file_transport_open,
    .close = file_transport_close,
    .read = file_transport_read,
    .seek = file_transport_seek,
    .size = file_transport_size,
    .list = file_transport_list,
    .probe = file_transport_probe,
};
