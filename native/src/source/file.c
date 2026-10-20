/* Local file system transport (module 5: local playback). */
#include <dirent.h>
#include <errno.h>
#include <stdlib.h>
#include <sys/stat.h>

#include "source_internal.h"

static int file_transport_open(LpIo *io, const LpUrl *u, const LpSourceOptions *opts,
                               char *err, size_t errlen)
{
    (void)opts;
    if (!u->path[0]) {
        if (err && errlen) snprintf(err, errlen, "empty path");
        return LP_ERR_ARGUMENT;
    }
    FILE *f = fopen(u->path, "rb");
    if (!f) {
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

static int file_transport_list(const LpUrl *u, const LpSourceOptions *opts,
                               LpStr *out, char *err, size_t errlen)
{
    (void)opts;
    if (strcmp(u->path, "/") == 0) {
        /* "file:///" is not a useful listing target; the UI passes an absolute
         * directory instead. */
        lp_str_append(out, "{\"url\":\"\",\"parent\":\"\",\"entries\":[]}");
        return LP_OK;
    }
    DIR *d = opendir(u->path);
    if (!d) {
        if (err && errlen) snprintf(err, errlen, "opendir %s failed: %s", u->path, strerror(errno));
        return errno == EACCES ? LP_ERR_AUTH : LP_ERR_NOT_FOUND;
    }
    int cap = 256, count = 0;
    LpDirItem *items = calloc((size_t)cap, sizeof(LpDirItem));
    if (!items) {
        closedir(d);
        return LP_ERR_NOMEM;
    }
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) {
            continue;
        }
        char full[1600];
        snprintf(full, sizeof(full), "%s/%s", u->path, ent->d_name);
        struct stat st;
        if (stat(full, &st) != 0) {
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
        it->is_dir = S_ISDIR(st.st_mode);
        it->size = (int64_t)st.st_size;
        it->mtime = (int64_t)st.st_mtime;
    }
    closedir(d);

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
    if (stat(u->path, &st) != 0) {
        if (err && errlen) snprintf(err, errlen, "stat %s failed: %s", u->path, strerror(errno));
        return LP_ERR_NOT_FOUND;
    }
    lp_str_append(out, "{\"server\":\"localhost\",\"authenticated\":true,\"shares\":[");
    if (!S_ISDIR(st.st_mode)) {
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
