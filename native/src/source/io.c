/* Transport handle, read-ahead cache, AVIO bridge and the public source API. */
#include <errno.h>
#include <stdlib.h>
#include <unistd.h>

#include "source_internal.h"

/* ------------------------------------------------------------- options --- */

void lp_source_options_default(LpSourceOptions *opts)
{
    memset(opts, 0, sizeof(*opts));
    opts->timeout_ms = 8000;
    opts->readahead_kb = 1024;
}

int32_t lp_source_options_parse(const char *options_json, LpSourceOptions *opts)
{
    if (!opts) {
        return LP_ERR_ARGUMENT;
    }
    lp_source_options_default(opts);
    if (!options_json || !*options_json) {
        return LP_OK;
    }
    lp_json_get_str(options_json, "user", opts->user, sizeof(opts->user));
    lp_json_get_str(options_json, "password", opts->password, sizeof(opts->password));
    lp_json_get_str(options_json, "domain", opts->domain, sizeof(opts->domain));
    int64_t v = 0;
    if (lp_json_get_int(options_json, "timeout_ms", &v) == 0 && v > 0 && v <= 120000) {
        opts->timeout_ms = (int32_t)v;
    }
    if (lp_json_get_int(options_json, "readahead_kb", &v) == 0 && v >= 64 && v <= 16384) {
        opts->readahead_kb = (int32_t)v;
    }
    return LP_OK;
}

/* ------------------------------------------------------------- handle --- */

LpIo *lp_io_open(const char *url, const LpSourceOptions *opts, char *err, size_t errlen)
{
    if (err && errlen) {
        err[0] = '\0';
    }
    if (!url) {
        if (err && errlen) snprintf(err, errlen, "empty url");
        return NULL;
    }
    LpUrl parsed;
    if (lp_url_parse(url, &parsed) != LP_OK) {
        if (err && errlen) snprintf(err, errlen, "invalid url: %s", url);
        return NULL;
    }
    const LpTransport *tp = lp_transport_find(parsed.scheme);
    if (!tp) {
        if (err && errlen) snprintf(err, errlen, "unsupported scheme: %s", parsed.scheme);
        return NULL;
    }
    LpSourceOptions local;
    if (!opts) {
        lp_source_options_default(&local);
        opts = &local;
    }

    LpIo *io = calloc(1, sizeof(*io));
    if (!io) {
        return NULL;
    }
    io->tp = tp;
    io->url = parsed;
    io->size = -1;
    io->pos = 0;
    io->timeout_ms = opts->timeout_ms > 0 ? opts->timeout_ms : 8000;
    atomic_init(&io->abort, 0);
    io->cache_cap = (opts->readahead_kb > 0 ? opts->readahead_kb : 1024) * 1024;
    io->cache = malloc((size_t)io->cache_cap);
    if (!io->cache) {
        free(io);
        return NULL;
    }
    if (opts->user[0] && !parsed.user[0]) {
        snprintf(io->url.user, sizeof(io->url.user), "%s", opts->user);
    }
    if (opts->password[0] && !parsed.password[0]) {
        snprintf(io->url.password, sizeof(io->url.password), "%s", opts->password);
    }
    if (tp->open(io, &io->url, opts, err, errlen) != LP_OK) {
        free(io->cache);
        free(io);
        return NULL;
    }
    if (io->size < 0 && tp->size) {
        io->size = tp->size(io);
    }
    return io;
}

void lp_io_close(LpIo *io)
{
    if (!io) {
        return;
    }
    atomic_store(&io->abort, 1);
    if (io->tp && io->tp->close) {
        io->tp->close(io);
    }
    if (io->avio) {
        av_freep(&io->avio->buffer);
        avio_context_free(&io->avio);
    }
    free(io->cache);
    free(io);
}

static int io_refill(LpIo *io, int64_t pos)
{
    /* 注意边界用 <= ：pos 正好等于 cache_start + cache_len 时缓存里
     * 一个字节都不剩，必须重新填充，否则调用方会拿到 avail=0 空转。 */
    if (io->cache_valid && pos >= io->cache_start && pos < io->cache_start + io->cache_len) {
        return LP_OK;
    }
    if (io->size >= 0 && pos >= io->size) {
        io->eof = 1;
        return LP_ERR_END_OF_STREAM;
    }
    if (io->tp->seek(io, pos, SEEK_SET) < 0) {
        return LP_ERR_IO;
    }
    int want = io->cache_cap;
    if (io->size >= 0 && io->size - pos < want) {
        want = (int)(io->size - pos);
    }
    if (want <= 0) {
        io->eof = 1;
        return LP_ERR_END_OF_STREAM;
    }
    int got = io->tp->read(io, io->cache, want);
    if (io->dbg_reads <= 5 || io->dbg_reads % 1000 == 0) {
        LP_DEBUG("io", "refill pos=%lld want=%d got=%d", (long long)pos, want, got);
    }
    if (got < 0) {
        io->cache_valid = 0;
        return LP_ERR_IO;
    }
    io->cache_start = pos;
    io->cache_len = got;
    io->cache_valid = got > 0;
    if (got == 0) {
        io->eof = 1;
        return LP_ERR_END_OF_STREAM;
    }
    return LP_OK;
}

int lp_io_read(LpIo *io, uint8_t *buf, int size)
{
    if (!io || !buf || size <= 0) {
        return LP_ERR_ARGUMENT;
    }
    if (atomic_load(&io->abort)) {
        return LP_ERR_INTERRUPTED;
    }
    int done = 0;
    long spins = 0;
    while (done < size) {
        if (++spins > 100000) {
            LP_ERROR("io", "read spin guard: pos=%lld size=%d done=%d cache[%lld,%d]",
                     (long long)io->pos, size, done, (long long)io->cache_start, io->cache_len);
            break;
        }
        int64_t pos = io->pos + done;
        int r = io_refill(io, pos);
        if (r == LP_ERR_END_OF_STREAM) {
            break;
        }
        if (r < 0) {
            return done > 0 ? done : r;
        }
        int off = (int)(pos - io->cache_start);
        int avail = io->cache_len - off;
        int chunk = size - done;
        if (chunk > avail) {
            chunk = avail;
        }
        /* avail 可能为 0：pos 正好落在缓存末尾（cache_start + cache_len）。
         * 这时 memcpy 复制 0 字节，done 不前进，下面又回到同一个 pos —— 
         * 一个纯空转的死循环。FLV 的 demuxer 恰好会跨过缓存边界连续读，
         * 于是「打开含 flv 的文件夹」就卡死在这里（mp4 因为读了正好一段
         * 就够解析，碰不到这个边界，所以之前一直是绿的）。
         * 重新 refill 一次把 pos 拉进新缓存；若仍然没有数据就当作 EOF。 */
        if (chunk <= 0) {
            io->cache_valid = 0;
            if (io_refill(io, pos) != LP_OK) {
                break;
            }
            off = (int)(pos - io->cache_start);
            avail = io->cache_len - off;
            if (avail <= 0) {
                break;
            }
            chunk = size - done;
            if (chunk > avail) {
                chunk = avail;
            }
            if (chunk <= 0) {
                break;
            }
        }
        memcpy(buf + done, io->cache + off, (size_t)chunk);
        done += chunk;
    }
    io->pos += done;
    return done;
}

int64_t lp_io_seek(LpIo *io, int64_t offset, int whence)
{
    if (!io) {
        return LP_ERR_ARGUMENT;
    }
    int64_t target;
    switch (whence) {
    case SEEK_SET: target = offset; break;
    case SEEK_CUR: target = io->pos + offset; break;
    case SEEK_END:
        if (io->size < 0 && io->tp->size) {
            io->size = io->tp->size(io);
        }
        target = io->size >= 0 ? io->size + offset : offset;
        break;
    default: return LP_ERR_ARGUMENT;
    }
    if (target < 0) {
        target = 0;
    }
    if (io->size >= 0 && target > io->size) {
        target = io->size;
    }
    if (io->tp->seek(io, target, SEEK_SET) < 0) {
        return LP_ERR_IO;
    }
    io->cache_valid = 0;
    io->eof = 0;
    io->pos = target;
    return target;
}

int64_t lp_io_size(LpIo *io)
{
    if (!io) {
        return -1;
    }
    if (io->size < 0 && io->tp->size) {
        io->size = io->tp->size(io);
    }
    return io->size;
}

/* AVIO integration. */

static int avio_read_cb(void *opaque, uint8_t *buf, int size)
{
    LpIo *io = opaque;
    int r = lp_io_read(io, buf, size);
    io->dbg_reads++;
    if (io->dbg_reads <= 3 || io->dbg_reads % 500 == 0) {
        LP_DEBUG("io", "read #%ld pos=%lld size=%d -> %d", (long)io->dbg_reads,
                 (long long)io->pos, size, r);
    }
    if (r == LP_ERR_INTERRUPTED) {
        return AVERROR_EXIT;
    }
    if (r == LP_ERR_END_OF_STREAM) {
        return AVERROR_EOF;
    }
    if (r < 0) {
        return AVERROR(EIO);
    }
    /* 读到 0 字节也是 EOF。
     *
     * lp_io_read 在文件末尾会返回 done=0（既不是错误也不是 END_OF_STREAM，
     * 因为它用 break 跳出循环后无条件返回 done）。以前这里直接把 0 交给
     * FFmpeg，而 AVIO 的约定是「返回 0 表示这次没拿到数据」——demuxer 于是
     * 反复重试，形成永远退不出来的循环：日志里是 read #500/#1000/…#6500
     * 全是 size=64543 -> 0。FLV 的 demuxer 读满整个文件后还要继续读，正好
     * 撞上这个边界；mp4 读够 moov 就停了，所以一直没暴露。 */
    if (r == 0) {
        return AVERROR_EOF;
    }
    return r;
}

static int64_t avio_seek_cb(void *opaque, int64_t offset, int whence)
{
    LpIo *io = opaque;
    if (whence & AVSEEK_SIZE) {
        int64_t s = lp_io_size(io);
        return s < 0 ? AVERROR(ENOSYS) : s;
    }
    whence &= ~AVSEEK_FORCE;
    io->dbg_seeks++;
    if (io->dbg_seeks % 100 == 1) {
        LP_DEBUG("io", "seek #%ld off=%lld whence=%d", (long)io->dbg_seeks,
                 (long long)offset, whence);
    }
    int64_t r = lp_io_seek(io, offset, whence);
    if (r < 0) {
        return AVERROR(EIO);
    }
    return r;
}
int lp_io_interrupt(void *user)
{
    LpIo *io = user;
    if (!io) {
        return 0;
    }
    if (atomic_load(&io->abort)) {
        return 1;
    }
    return io->external_abort && atomic_load(io->external_abort) ? 1 : 0;
}

void lp_io_abort(LpIo *io)
{
    if (io) {
        atomic_store(&io->abort, 1);
    }
}

int lp_io_attach_avio(LpIo *io, AVFormatContext **out, char *err, size_t errlen)
{
    if (!io || !out) {
        return LP_ERR_ARGUMENT;
    }
    io->avio_buf = av_malloc(65536);
    if (!io->avio_buf) {
        return LP_ERR_NOMEM;
    }
    io->avio = avio_alloc_context(io->avio_buf, 65536, 0, io, avio_read_cb, NULL, avio_seek_cb);
    if (!io->avio) {
        av_freep(&io->avio_buf);
        return LP_ERR_NOMEM;
    }
    io->avio->seekable = io->size > 0 ? AVIO_SEEKABLE_NORMAL : 0;

    AVFormatContext *fmt = avformat_alloc_context();
    if (!fmt) {
        return LP_ERR_NOMEM;
    }
    fmt->pb = io->avio;
    fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
    fmt->interrupt_callback.callback = lp_io_interrupt;
    fmt->interrupt_callback.opaque = io;
    *out = fmt;
    if (err && errlen) {
        err[0] = '\0';
    }
    return LP_OK;
}

const LpTransport *lp_transport_find(const char *scheme)
{
    if (!scheme) {
        return NULL;
    }
    if (strcmp(scheme, "smb") == 0 || strcmp(scheme, "smb2") == 0) {
#if defined(LP_HAVE_SMB2)
        return &lp_transport_smb;
#else
        return NULL; /* build without libsmb2: reported as unsupported */
#endif
    }
    if (strcmp(scheme, "file") == 0) {
        return &lp_transport_file;
    }
    return NULL;
}

/* ------------------------------------------------------------- public --- */

static _Thread_local char g_last_error[256];

void lp_source_set_last_error(const char *msg)
{
    snprintf(g_last_error, sizeof(g_last_error), "%s", msg ? msg : "");
}

void lp_string_free(char *s)
{
    free(s);
}

int32_t lp_source_last_error(char **out_json)
{
    if (!out_json) {
        return LP_ERR_ARGUMENT;
    }
    LpStr s;
    lp_str_init(&s);
    lp_str_append(&s, "{\"message\":");
    lp_str_append_json_str(&s, g_last_error[0] ? g_last_error : "");
    lp_str_append(&s, "}");
    *out_json = lp_str_take(&s);
    return LP_OK;
}

int32_t lp_source_list(const char *url, const char *options_json, char **out_json)
{
    if (!url || !out_json) {
        return LP_ERR_ARGUMENT;
    }
    *out_json = NULL;
    LpUrl parsed;
    if (lp_url_parse(url, &parsed) != LP_OK) {
        return LP_ERR_ARGUMENT;
    }
    const LpTransport *tp = lp_transport_find(parsed.scheme);
    if (!tp || !tp->list) {
        return LP_ERR_UNSUPPORTED;
    }
    LpSourceOptions opts;
    lp_source_options_parse(options_json, &opts);
    /* Credentials embedded in the URL win over the option object. */
    if (parsed.user[0]) {
        snprintf(opts.user, sizeof(opts.user), "%s", parsed.user);
    }
    if (parsed.password[0]) {
        snprintf(opts.password, sizeof(opts.password), "%s", parsed.password);
    }
    /* Also accept top level "url" style credentials in options_json. */
    if (options_json && (!opts.user[0] || !opts.password[0])) {
        char u[128], p[256];
        if (!opts.user[0] && lp_json_get_str(options_json, "user", u, sizeof(u)) == 0) {
            snprintf(opts.user, sizeof(opts.user), "%s", u);
        }
        if (!opts.password[0] && lp_json_get_str(options_json, "password", p, sizeof(p)) == 0) {
            snprintf(opts.password, sizeof(opts.password), "%s", p);
        }
    }

    LpStr out;
    lp_str_init(&out);
    char err[256] = {0};
    int r = tp->list(&parsed, &opts, &out, err, sizeof(err));
    if (r != LP_OK) {
        lp_str_free(&out);
        LP_WARN("source", "list %s failed: %s", url, err[0] ? err : "unknown");
        snprintf(g_last_error, sizeof(g_last_error), "%s", err[0] ? err : "unknown transport error");
        return r;
    }
    *out_json = lp_str_take(&out);
    return LP_OK;
}

int32_t lp_source_probe(const char *url, const char *options_json, char **out_json)
{
    if (!url || !out_json) {
        return LP_ERR_ARGUMENT;
    }
    *out_json = NULL;
    LpUrl parsed;
    if (lp_url_parse(url, &parsed) != LP_OK) {
        return LP_ERR_ARGUMENT;
    }
    const LpTransport *tp = lp_transport_find(parsed.scheme);
    if (!tp) {
        return LP_ERR_UNSUPPORTED;
    }
    LpSourceOptions opts;
    lp_source_options_parse(options_json, &opts);
    if (parsed.user[0]) snprintf(opts.user, sizeof(opts.user), "%s", parsed.user);
    if (parsed.password[0]) snprintf(opts.password, sizeof(opts.password), "%s", parsed.password);

    LpStr out;
    lp_str_init(&out);
    char err[256] = {0};
    int r = tp->probe ? tp->probe(&parsed, &opts, &out, err, sizeof(err)) : LP_ERR_UNSUPPORTED;
    if (r != LP_OK) {
        snprintf(g_last_error, sizeof(g_last_error), "%s",
                 err[0] ? err : "authentication or network failure");
        lp_str_free(&out);
        return r;
    }
    g_last_error[0] = 0;
    *out_json = lp_str_take(&out);
    return LP_OK;
}

int32_t lp_source_schemes(char **out_json)
{
    if (!out_json) {
        return LP_ERR_ARGUMENT;
    }
    LpStr s;
    lp_str_init(&s);
    lp_str_append(&s, "[");
#if defined(LP_HAVE_SMB2)
    lp_str_append(&s, "\"smb\",");
#endif
    lp_str_append(&s, "\"file\"");
#if defined(LP_ENABLE_HTTP)
    lp_str_append(&s, ",\"http\",\"https\"");
#endif
    lp_str_append(&s, "]");
    *out_json = lp_str_take(&s);
    return LP_OK;
}

int32_t lp_url_normalize(const char *url, char **out_json)
{
    if (!url || !out_json) {
        return LP_ERR_ARGUMENT;
    }
    LpUrl u;
    if (lp_url_parse(url, &u) != LP_OK) {
        return LP_ERR_ARGUMENT;
    }
    LpStr s;
    lp_str_init(&s);
    lp_str_append(&s, "{\"scheme\":");
    lp_str_append_json_str(&s, u.scheme);
    lp_str_append(&s, ",\"host\":");
    lp_str_append_json_str(&s, u.host);
    lp_str_append(&s, ",\"port\":%d,\"share\":", u.port);
    lp_str_append_json_str(&s, u.share);
    lp_str_append(&s, ",\"path\":");
    lp_str_append_json_str(&s, u.path);
    lp_str_append(&s, ",\"user\":");
    lp_str_append_json_str(&s, u.user);
    lp_str_append(&s, "}");
    *out_json = lp_str_take(&s);
    return LP_OK;
}
