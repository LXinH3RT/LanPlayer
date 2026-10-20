/*
 * LanPlayer native core - media source abstraction.
 *
 * Every byte the player consumes comes from an LpSource implementation.  The
 * transport (SMB today, TCP/HTTP/NFS tomorrow) is chosen from the URL scheme,
 * so neither the demuxer nor the UI layer knows anything about SMB.
 *
 *   smb://user:pass@192.168.1.10/Share/Movies/a.mkv
 *   file:///storage/emulated/0/Movies/a.mkv      (also accepted: plain path)
 *   http://192.168.1.10:8080/a.mkv               (FFmpeg native protocol)
 *   tcp://192.168.1.10:9000/a.mkv                (reserved, see docs/media-source.md)
 *
 * `options_json` (all keys optional):
 *   {"user":"lanplay","password":"...","domain":"WORKGROUP",
 *    "timeout_ms":8000,"readahead_kb":4096}
 */
#ifndef LANPLAYER_LP_SOURCE_H
#define LANPLAYER_LP_SOURCE_H

#include "lanplayer/lp_types.h"

#ifdef __cplusplus
extern "C" {
#endif

#ifndef LP_EXPORT
#if defined(_WIN32)
#define LP_EXPORT __declspec(dllexport)
#else
#define LP_EXPORT __attribute__((visibility("default")))
#endif
#endif

/* Resolved transport configuration, filled from options_json by
 * lp_source_options_parse(). */
typedef struct LpSourceOptions {
    char user[128];
    char password[256];
    char domain[64];
    int32_t timeout_ms;
    int32_t readahead_kb;
} LpSourceOptions;

LP_EXPORT void lp_source_options_default(LpSourceOptions *opts);
LP_EXPORT int32_t lp_source_options_parse(const char *options_json, LpSourceOptions *opts);

/*
 * List one directory.
 *
 * out_json (free with lp_string_free):
 * {
 *   "url": "smb://host/Share/Movies",
 *   "parent": "smb://host/Share",
 *   "entries": [
 *     {"name":"S01E01.mkv","path":"smb://host/Share/Movies/S01E01.mkv",
 *      "is_dir":false,"size":1234567,"mtime":1690000000,
 *      "kind":"video","ext":"mkv"}
 *   ]
 * }
 * `kind` is one of "dir" | "video" | "subtitle" | "audio" | "image" | "other".
 * Entries are sorted: directories first, then natural name order.
 */
LP_EXPORT int32_t lp_source_list(const char *url, const char *options_json, char **out_json);

/*
 * 校验服务器账号密码是否可用（添加服务器时的「测试连接」）。
 * url: smb://host 或 smb://host/share （账号密码放在 options_json 里）
 * 只验证登录，不枚举共享名；成功时 out_json 为
 *   {"server":"192.168.1.10","authenticated":true}
 * 失败返回负数，原因用 lp_source_last_error 取。
 */
LP_EXPORT int32_t lp_source_probe(const char *url, const char *options_json, char **out_json);

/* JSON array of schemes this build supports: ["smb","file","http"] */
LP_EXPORT int32_t lp_source_schemes(char **out_json);

/* Free a string returned by this library. */
LP_EXPORT void lp_string_free(char *s);

/* Human readable description of the last failure on the calling thread,
 * as JSON {"message":"..."} (free with lp_string_free).  The UI shows this
 * instead of a generic "connection failed". */
LP_EXPORT int32_t lp_source_last_error(char **out_json);

/* Normalise/split helpers shared with the Dart layer, exposed for tests. */
LP_EXPORT int32_t lp_url_normalize(const char *url, char **out_json);

#ifdef __cplusplus
}
#endif

#endif /* LANPLAYER_LP_SOURCE_H */
