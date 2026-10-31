/* Transport layer internals: URL splitting and the LpIo handle shared by the
 * SMB / file transports. */
#ifndef LANPLAYER_SOURCE_INTERNAL_H
#define LANPLAYER_SOURCE_INTERNAL_H

#include "player_internal.h"

#ifdef __cplusplus
extern "C" {
#endif

#define LP_URL_MAX 2048

typedef struct LpUrl {
    char scheme[16];
    char user[128];
    char password[256];
    char host[160];
    int port;          /* -1 = 该 scheme 没有端口概念（见 lp_transport_default_port） */
    char share[160];   /* 托管型 URL 的第一段路径（smb://host/<share>/...） */
    char path[1024];   /* 剩下的路径，总以 '/' 开头 */
    /* 1 = "<scheme>://host/share/path" 形态：authority 之后的第一段是共享名。
     * 0 = "<scheme>://path" 形态（file），整条 URL 就是一个路径。
     * 哪一种是哪种由传输层注册表决定，url.c 不再逐个 scheme 判断。 */
    int is_hosted;
} LpUrl;

int lp_url_parse(const char *url, LpUrl *out);

/* "<scheme>://[user:pass@]host[:port]" —— 不含 path。非托管型（file）只
 * 给 "<scheme>://"。拼 URL 的地方一律走它，不再手写 "smb://" / "file://"。 */
void lp_url_authority(const LpUrl *u, char *out, size_t outlen);

/* 给一条不带凭据的 URL 补上 u 里的登录信息。u 没有用户名、或者 url 自己
 * 已经带了 '@' 时按原样复制。 */
void lp_url_insert_credentials(const LpUrl *u, const char *url, char *out, size_t outlen);

/* 把解析后的 URL 拼回去（不含凭据）。托管型走 "<scheme>://host[:port]/share/path"，
 * 其余走 "<scheme>://path"；scheme 名一律取自 LpUrl，不再手写。 */
void lp_url_build(const LpUrl *u, char *out, size_t outlen);

/* 记录「调用线程上一次失败的原因」，供 lp_source_last_error() 取。
 * 和 lp_source_list / lp_source_probe 共用同一份线程局部缓冲。 */
void lp_source_set_last_error(const char *msg);

/* 同上，但记的是分类码（LP_ERR_AUTH / LP_ERR_NOT_FOUND / LP_ERR_TIMEOUT …）。
 * 文本够人看，程序要靠码决定说哪句话。 */
void lp_source_set_last_result(int32_t rc);
int32_t lp_source_last_result(void);

typedef struct LpIo LpIo;

typedef struct LpTransport {
    const char *scheme;
    /* "<scheme>://host/share/path"（1）还是 "<scheme>://path"（0）。
     * url.c 靠它决定要不要切出共享名、以及怎么把 URL 拼回去。 */
    int hosted;
    /* 该 scheme 的默认端口；-1 = 没有端口概念，0 = 端口必填。 */
    int default_port;
    /* 1 = 由本层用 LpIo 打开（file/smb）；0 = 交给 FFmpeg 原生协议（http）。
     * demux.c / thumb.c 靠它决定要不要自己挂 AVIO。 */
    int custom_io;
    /* 1 = 出现在 lp_source_schemes() 的列表里。 */
    int public_scheme;
    /* 实现本 scheme 的函数指针；交给 FFmpeg 的条目留空。 */
    int (*open)(LpIo *io, const LpUrl *u, const LpSourceOptions *opts, char *err, size_t errlen);
    void (*close)(LpIo *io);
    int (*read)(LpIo *io, uint8_t *buf, int size);
    int64_t (*seek)(LpIo *io, int64_t offset, int whence);
    int64_t (*size)(LpIo *io);
    int (*list)(const LpUrl *u, const LpSourceOptions *opts, LpStr *out, char *err, size_t errlen);
    int (*probe)(const LpUrl *u, const LpSourceOptions *opts, LpStr *out, char *err, size_t errlen);
} LpTransport;

/* 传输层注册表。
 *
 * 新增一种源类型 = 写一个 .c 定义 const LpTransport，再在 io.c 的
 * lp_transports[] 里加一行；其余地方（scheme 列表、URL 形态、自定义 AVIO
 * 判定、默认端口）全部由这张表推导。 */
const LpTransport *lp_transport_find(const char *scheme);
/* 该 scheme 是否需要本层自己挂 AVIO（http/tcp 这类交给 FFmpeg 的返回 0）。 */
int lp_transport_custom_io(const char *scheme);
/* 该 scheme 的默认端口；-1 = 没有端口概念。 */
int lp_transport_default_port(const char *scheme);
/* 该 scheme 是不是 "<scheme>://host/share/path" 形态。 */
int lp_transport_hosted(const char *scheme);
/* 已注册的条目数 / 逐条访问；lp_transport_at 按注册顺序返回，用于拼
 * lp_source_schemes() 与文档里的一致性检查。 */
int lp_transport_count(void);
const LpTransport *lp_transport_at(int index);

struct LpIo {
    const LpTransport *tp;
    LpUrl url;
    void *ctx;
    int64_t size;
    int64_t pos;
    int eof;
    atomic_int abort;
    atomic_int *external_abort; /* points at LpPlayer::abort_request */
    int64_t timeout_ms;

    /* Sequential read-ahead cache.  A single SMB read of 1 MiB costs a few
     * milliseconds, far cheaper than one round trip per 32 KiB AVIO read.
     *
     * 缓冲区是懒分配的：打开目录里 200 个文件时每个 LpIo 都要一份 1 MiB
     * 直接就是 200 MiB 常驻，而绝大多数 LpIo 只读头部几 KiB（探测、封面）。
     * readahead_cap 是配置值，cache_cap 是实际分配到的容量。 */
    uint8_t *cache;
    int readahead_cap;
    int cache_cap;
    int cache_len;
    int64_t cache_start;
    int cache_valid;
    /* 传输层当前文件位置（-1 = 未知，下次填充必须先 seek）。
     * 顺序读时能省掉一次 SMB/HTTP 往返。 */
    int64_t tp_pos;

    AVIOContext *avio;
    uint8_t *avio_buf;

    /* 诊断计数：排查「某些容器打开时长时间不返回」用（见 thumb.c）。
     * 正常路径不看它，成本只是一次自增。 */
    long dbg_reads;
    long dbg_seeks;
};

/* Shared helper: entries JSON from a list of names. */
typedef struct LpDirItem {
    char name[512];
    int64_t size;
    int64_t mtime;
    int is_dir;
} LpDirItem;

void lp_entries_begin(LpStr *out, const LpUrl *u);
void lp_entries_add(LpStr *out, const LpUrl *u, const LpDirItem *items, int count);
void lp_entries_end(LpStr *out, const LpUrl *u);
void lp_sort_items(LpDirItem *items, int count);
const char *lp_kind_for_name(const char *name);
int lp_is_video_name(const char *name);
int lp_is_subtitle_name(const char *name);
int lp_path_parent(const char *path, char *out, size_t outlen);

/* 系统/桌面环境写进目录、与媒体无关的元数据文件，列表里一律不显示。 */
int lp_is_os_junk_name(const char *name);

/* 浏览列表只展示视频 / 字幕 / 音频；目录由调用方单独保留。 */
int lp_is_listable_media(const char *name);

#ifdef __cplusplus
}
#endif

#endif /* LANPLAYER_SOURCE_INTERNAL_H */
