/* 交给 FFmpeg 原生协议层的 scheme（http/https/tcp）。
 *
 * 这几条没有 LpIo 传输实现：没有 open/read/seek，也不能 list/probe。
 * 它们出现在注册表里的唯一目的，是让「哪些 scheme 合法」「默认端口是
 * 多少」「URL 是不是 host/share/path 形态」「要不要自己挂 AVIO」这些问题
 * 有一个统一答案，而不是散落在 url.c 的 if 链和 demux.c 的字符串比较里。
 *
 * 代价是有几个空函数指针字段，收益是新增一种源类型不用再改这些地方。
 */
#include "source_internal.h"

#if defined(LP_ENABLE_HTTP)

const LpTransport lp_transport_http = {
    .scheme = "http",
    .hosted = 1,
    .default_port = 80,
    .custom_io = 0,
    .public_scheme = 1,
};

const LpTransport lp_transport_https = {
    .scheme = "https",
    .hosted = 1,
    .default_port = 443,
    .custom_io = 0,
    .public_scheme = 1,
};

/* tcp:// 目前只是占位（见 docs/media-source.md）：注册它是为了让 URL 解析
 * 与「端口必填」的语义保持一致，但不进 lp_source_schemes() 的列表。 */
const LpTransport lp_transport_tcp = {
    .scheme = "tcp",
    .hosted = 1,
    .default_port = 0,
    .custom_io = 0,
    .public_scheme = 0,
};

#else /* !LP_ENABLE_HTTP */

/* 空翻译单元在 -Wpedantic 下是错误，留一个内部链接的哑对象。 */
typedef int lp_source_ffmpeg_disabled_placeholder;

#endif /* LP_ENABLE_HTTP */
