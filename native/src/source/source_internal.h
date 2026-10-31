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
    int port;
    char share[160];   /* SMB only, first path segment */
    char path[1024];   /* path inside the share, always starts with '/' */
    int is_smb;
} LpUrl;

int lp_url_parse(const char *url, LpUrl *out);
/* Builds "<scheme>://[user@]host/share/path/name" without credentials. */
void lp_url_join(const LpUrl *u, const char *name, char *out, size_t outlen);

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
    int (*open)(LpIo *io, const LpUrl *u, const LpSourceOptions *opts, char *err, size_t errlen);
    void (*close)(LpIo *io);
    int (*read)(LpIo *io, uint8_t *buf, int size);
    int64_t (*seek)(LpIo *io, int64_t offset, int whence);
    int64_t (*size)(LpIo *io);
    int (*list)(const LpUrl *u, const LpSourceOptions *opts, LpStr *out, char *err, size_t errlen);
    int (*probe)(const LpUrl *u, const LpSourceOptions *opts, LpStr *out, char *err, size_t errlen);
} LpTransport;

extern const LpTransport lp_transport_smb;
extern const LpTransport lp_transport_file;
const LpTransport *lp_transport_find(const char *scheme);

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
