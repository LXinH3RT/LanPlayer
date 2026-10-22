/*
 * SMB2/3 transport on top of libsmb2 (https://github.com/sahlberg/libsmb2).
 *
 * libsmb2 is used instead of libsmbclient because it is a small, dependency
 * free C library that cross-compiles cleanly for Android (NDK), iOS and macOS -
 * which is exactly what a Flutter plugin needs.  See docs/build.md.
 *
 * Builds without libsmb2 (desktop bring-up, CI) compile an empty translation
 * unit and report "smb" as an unsupported scheme at runtime.
 */
#include "source_internal.h"

#if defined(LP_HAVE_SMB2)

#include <fcntl.h>
#include <stdlib.h>

#if defined(_WIN32)
/* winsock2.h must precede windows.h; the smb2 shims rely on this order too. */
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#endif

#include <smb2/libsmb2.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2-raw.h>

/*
 * libsmb2 requires Winsock to be initialised by its host (it reports
 * "Winsock was not initialized. Please call WSAStartup()" otherwise) and never
 * calls WSAStartup itself.  Every Windows build of a libsmb2 client has to do
 * it once; WSAStartup is refcounted, so a benign race is harmless.
 */
static void smb_wsa_init(void)
{
#if defined(_WIN32)
    static atomic_int wsa_ready;
    if (atomic_exchange(&wsa_ready, 1) == 0) {
        WSADATA data;
        if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
            LP_ERROR("smb", "WSAStartup failed");
        }
    }
#endif
}

typedef struct LpSmbCtx {
    struct smb2_context *smb2;
    struct smb2fh *fh;
} LpSmbCtx;

/*
 * libsmb2 wants paths *relative to the share root*: "" for the share itself and
 * "dir/file" without a leading separator.  A leading "/" makes Windows return
 * STATUS_INVALID_PARAMETER (0xc000000d) on both CREATE and the directory open,
 * so every call has to strip it.  The URL layer keeps the "/dir/file" form.
 */
static const char *smb_relpath(const char *path)
{
    if (!path || !path[0] || strcmp(path, "/") == 0) {
        return "";
    }
    return path[0] == '/' ? path + 1 : path;
}

static int smb_error_rc(struct smb2_context *smb2, int fallback)
{
    const char *e = smb2 ? smb2_get_error(smb2) : NULL;
    if (e) {
        if (strstr(e, "STATUS_LOGON_FAILURE") || strstr(e, "STATUS_ACCESS_DENIED") ||
            strstr(e, "STATUS_BAD_NETWORK_NAME") || strstr(e, "Permission denied")) {
            return LP_ERR_AUTH;
        }
        if (strstr(e, "STATUS_OBJECT_NAME_NOT_FOUND") || strstr(e, "No such file")) {
            return LP_ERR_NOT_FOUND;
        }
        if (strstr(e, "timed out") || strstr(e, "Timeout")) {
            return LP_ERR_TIMEOUT;
        }
    }
    return fallback;
}

static struct smb2_context *smb_connect(const LpUrl *u, const LpSourceOptions *opts,
                                        char *err, size_t errlen)
{
    smb_wsa_init();
    struct smb2_context *smb2 = smb2_init_context();
    if (!smb2) {
        if (err && errlen) snprintf(err, errlen, "smb2_init_context failed");
        return NULL;
    }
    int timeout_sec = (opts->timeout_ms > 0 ? opts->timeout_ms : 8000) / 1000;
    if (timeout_sec < 1) {
        timeout_sec = 1;
    }
    smb2_set_timeout(smb2, timeout_sec);
    smb2_set_security_mode(smb2, SMB2_NEGOTIATE_SIGNING_ENABLED);
    if (opts->domain[0]) {
        smb2_set_domain(smb2, opts->domain);
    }
    const char *user = u->user[0] ? u->user : (opts->user[0] ? opts->user : NULL);
    const char *pass = u->password[0] ? u->password : (opts->password[0] ? opts->password : NULL);
    if (user) {
        smb2_set_user(smb2, user);
    }
    if (pass) {
        smb2_set_password(smb2, pass);
    }
    /* libsmb2 takes the port inside the server string ("host:port"), there is
     * no smb2_set_port() in 4.x. */
    char server[200];
    if (u->port && u->port != 445) {
        snprintf(server, sizeof(server), "%s:%d", u->host, u->port);
    } else {
        snprintf(server, sizeof(server), "%s", u->host);
    }
    if (smb2_connect_share(smb2, server, u->share, user) < 0) {
        if (err && errlen) {
            const char *detail = smb2_get_error(smb2);
            if (detail && strstr(detail, "Connect failed")) {
                /* libsmb2 reports errno as 0 on Windows; say something useful. */
                snprintf(err, errlen,
                         "cannot reach %s (network unreachable, wrong port, or blocked by a "
                         "firewall)",
                         server);
            } else {
                snprintf(err, errlen, "connect //%s/%s failed: %s", server, u->share,
                         detail ? detail : "unknown error");
            }
        }
        smb2_destroy_context(smb2);
        return NULL;
    }
    return smb2;
}

static int smb_transport_open(LpIo *io, const LpUrl *u, const LpSourceOptions *opts,
                              char *err, size_t errlen)
{
    if (!u->share[0]) {
        if (err && errlen) snprintf(err, errlen, "share name missing in %s://%s", u->scheme, u->host);
        return LP_ERR_ARGUMENT;
    }
    LpSmbCtx *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) {
        return LP_ERR_NOMEM;
    }
    ctx->smb2 = smb_connect(u, opts, err, errlen);
    if (!ctx->smb2) {
        free(ctx);
        return LP_ERR_IO;
    }
    const char *rel = smb_relpath(u->path);
    if (rel[0]) {
        ctx->fh = smb2_open(ctx->smb2, rel, O_RDONLY);
        if (!ctx->fh) {
            if (err && errlen) {
                snprintf(err, errlen, "open %s failed: %s", u->path, smb2_get_error(ctx->smb2));
            }
            int rc = smb_error_rc(ctx->smb2, LP_ERR_IO);
            smb2_destroy_context(ctx->smb2);
            free(ctx);
            return rc;
        }
        struct smb2_stat_64 st;
        memset(&st, 0, sizeof(st));
        if (smb2_fstat(ctx->smb2, ctx->fh, &st) == 0) {
            io->size = (int64_t)st.smb2_size;
        }
    }
    io->ctx = ctx;
    LP_INFO("smb", "connected //%s/%s%s", u->host, u->share, u->path);
    return LP_OK;
}

static void smb_transport_close(LpIo *io)
{
    LpSmbCtx *ctx = io ? io->ctx : NULL;
    if (!ctx) {
        return;
    }
    if (ctx->fh) {
        smb2_close(ctx->smb2, ctx->fh);
        ctx->fh = NULL;
    }
    if (ctx->smb2) {
        smb2_disconnect_share(ctx->smb2);
        smb2_destroy_context(ctx->smb2);
        ctx->smb2 = NULL;
    }
    free(ctx);
    io->ctx = NULL;
}

static int smb_transport_read(LpIo *io, uint8_t *buf, int size)
{
    LpSmbCtx *ctx = io->ctx;
    if (!ctx || !ctx->fh) {
        return LP_ERR_IO;
    }
    int total = 0;
    while (total < size) {
        int want = size - total;
        /* libsmb2 caps a single READ at 1 MiB on most servers. */
        if (want > 1024 * 1024) {
            want = 1024 * 1024;
        }
        int got = smb2_read(ctx->smb2, ctx->fh, buf + total, (uint32_t)want);
        if (got < 0) {
            return total > 0 ? total : smb_error_rc(ctx->smb2, LP_ERR_IO);
        }
        if (got == 0) {
            break;
        }
        total += got;
        if (atomic_load(&io->abort)) {
            return total > 0 ? total : LP_ERR_INTERRUPTED;
        }
        if (got < want) {
            break;
        }
    }
    return total;
}

static int64_t smb_transport_seek(LpIo *io, int64_t offset, int whence)
{
    LpSmbCtx *ctx = io->ctx;
    if (!ctx || !ctx->fh) {
        return -1;
    }
    int64_t pos = smb2_lseek(ctx->smb2, ctx->fh, offset, whence, NULL);
    if (pos < 0) {
        return -1;
    }
    return pos;
}

static int64_t smb_transport_size(LpIo *io)
{
    LpSmbCtx *ctx = io->ctx;
    if (!ctx || !ctx->fh) {
        return -1;
    }
    struct smb2_stat_64 st;
    memset(&st, 0, sizeof(st));
    if (smb2_fstat(ctx->smb2, ctx->fh, &st) < 0) {
        return -1;
    }
    return (int64_t)st.smb2_size;
}

static int smb_transport_list(const LpUrl *u, const LpSourceOptions *opts,
                              LpStr *out, char *err, size_t errlen)
{
    struct smb2_context *smb2 = smb_connect(u, opts, err, errlen);
    if (!smb2) {
        return LP_ERR_IO;
    }
    const char *rel = smb_relpath(u->path);
    struct smb2dir *dir = smb2_opendir(smb2, rel);
    if (!dir) {
        if (err && errlen) {
            snprintf(err, errlen, "opendir %s failed: %s", u->path[0] ? u->path : "/",
                     smb2_get_error(smb2));
        }
        int rc = smb_error_rc(smb2, LP_ERR_IO);
        smb2_destroy_context(smb2);
        return rc;
    }

    int cap = 256, count = 0;
    LpDirItem *items = calloc((size_t)cap, sizeof(LpDirItem));
    if (!items) {
        smb2_closedir(smb2, dir);
        smb2_destroy_context(smb2);
        return LP_ERR_NOMEM;
    }
    struct smb2dirent *ent;
    while ((ent = smb2_readdir(smb2, dir)) != NULL) {
        if (!ent->name || strcmp(ent->name, ".") == 0 || strcmp(ent->name, "..") == 0) {
            continue;
        }
        /* 跳过 macOS / Windows 的目录元数据（.DS_Store、._foo、desktop.ini …）。
         * 这些文件是客户端系统写的，对播放没有意义，列出来只会干扰用户；
         * 而且 .DS_Store 常被误认成「本 app 往服务器写了东西」。 */
        if (lp_is_os_junk_name(ent->name)) {
            continue;
        }
        /* 只列视频 / 字幕 / 音频。.txt、.docx、.ini 之类对播放器没用，
         * 混在列表里只会把真正的媒体挤下去（用户报的就是这个）。
         * 目录不过滤 —— 不然就进不去子文件夹了。 */
        int is_dir = ent->st.smb2_type == SMB2_TYPE_DIRECTORY;
        if (!is_dir && !lp_is_listable_media(ent->name)) {
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
        snprintf(it->name, sizeof(it->name), "%s", ent->name);
        it->is_dir = is_dir;
        it->size = (int64_t)ent->st.smb2_size;
        it->mtime = (int64_t)ent->st.smb2_mtime;
    }
    smb2_closedir(smb2, dir);
    smb2_disconnect_share(smb2);
    smb2_destroy_context(smb2);

    lp_sort_items(items, count);
    lp_entries_begin(out, u);
    lp_entries_add(out, u, items, count);
    lp_entries_end(out, u);
    free(items);
    return LP_OK;
}

/*
 * 凭据校验（probe）。
 *
 * 只做一件事：用给定的账号密码真的连一次服务器，连上了就说明凭据可用。
 * 不列共享名 —— 想让用户从列表里挑共享，需要走 SRVSVC（IPC$ 上的 DCE/RPC），
 * 那条路径已经按需求移除，共享名改由用户自己填写。
 *
 * 有共享名：直接打开该共享，这同时也是最严格的凭据证明（权限不足会在这里失败）。
 * 没共享名：连 IPC$，只验证登录本身能过。
 */
static int smb_transport_probe(const LpUrl *u, const LpSourceOptions *opts,
                               LpStr *out, char *err, size_t errlen)
{
    LpUrl target = *u;
    int had_share = u->share[0] ? 1 : 0;
    if (!had_share) {
        /* IPC$ 是每个 SMB 服务器都有的内置共享，只用来验证登录。 */
        snprintf(target.share, sizeof(target.share), "IPC$");
        snprintf(target.path, sizeof(target.path), "/");
    }

    char connect_err[256];
    connect_err[0] = '\0';
    struct smb2_context *smb2 = smb_connect(&target, opts, connect_err, sizeof(connect_err));
    if (!smb2) {
        if (err && errlen) {
            if (strstr(connect_err, "Timeout") || strstr(connect_err, "timed out") ||
                strstr(connect_err, "cannot reach")) {
                snprintf(err, errlen,
                         "cannot reach %s (no SMB answer: wrong address/port, or blocked by a "
                         "firewall)",
                         u->host);
            } else if (strstr(connect_err, "STATUS_LOGON_FAILURE") ||
                       strstr(connect_err, "STATUS_ACCESS_DENIED")) {
                snprintf(err, errlen, "login failed on %s: wrong user name or password", u->host);
            } else {
                snprintf(err, errlen, "%s",
                         connect_err[0] ? connect_err : "authentication failed");
            }
        }
        return smb_error_rc(NULL, LP_ERR_AUTH);
    }
    smb2_disconnect_share(smb2);
    smb2_destroy_context(smb2);

    /* 只回报「连上了」，不再附带共享列表。 */
    lp_str_append(out, "{\"server\":");
    lp_str_append_json_str(out, u->host);
    lp_str_append(out, ",\"authenticated\":true}");
    return LP_OK;
}

const LpTransport lp_transport_smb = {
    .scheme = "smb",
    .open = smb_transport_open,
    .close = smb_transport_close,
    .read = smb_transport_read,
    .seek = smb_transport_seek,
    .size = smb_transport_size,
    .list = smb_transport_list,
    .probe = smb_transport_probe,
};

#else /* !LP_HAVE_SMB2 */

/* 没有编进 libsmb2 时（桌面 bring-up、CI）留一个空翻译单元：
 * 符号不注册，运行时 "smb" 会被当成不支持的协议。 */
typedef int lp_smb_disabled_placeholder;

#endif /* LP_HAVE_SMB2 */

