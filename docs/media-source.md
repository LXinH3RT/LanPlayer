# 媒体源与协议扩展

需求里有一条关键约束：**“后期可能会考虑改为使用 tcp 等其他协议，因此请确保此处的协议兼容性”**。
所以播放器不认识 SMB：它只认识 `LpSource`。

## 1. 抽象

```c
/* native/src/source/source_internal.h */
typedef struct LpTransport {
    const char *scheme;
    int  (*open)(LpIo *io, const LpUrl *u, const LpSourceOptions *opts, char *err, size_t n);
    void (*close)(LpIo *io);
    int  (*read)(LpIo *io, uint8_t *buf, int size);
    int64_t (*seek)(LpIo *io, int64_t offset, int whence);
    int64_t (*size)(LpIo *io);
    int  (*list)(const LpUrl *u, const LpSourceOptions *opts, LpStr *out, char *err, size_t n);
    int  (*probe)(const LpUrl *u, const LpSourceOptions *opts, LpStr *out, char *err, size_t n);
} LpTransport;
```

`lp_io_open()` 按 URL scheme 选择实现；`lp_io_attach_avio()` 把 `LpIo` 包装成
`AVIOContext`（自定义 `read_packet`/`seek`），然后 `avformat_open_input` 完全不知道
底下是 SMB 还是别的。**新增协议 = 新增一个 .c 文件 + 注册一行**，播放内核零改动。

现有实现：

| scheme | 文件 | 说明 |
|--------|------|------|
| `smb://` | `source/smb.c` | libsmb2，SMB2/3，认证、目录、断点读取 |
| `file://` | `source/file.c` | 本地文件与目录（模块 5） |
| `http(s)://`、`tcp://` | 交给 FFmpeg 原生协议层 | 设了 abort 回调与超时 |

## 2. 读放大与 seek

SMB 单次 READ 的往返成本远高于本地磁盘，因此 `LpIo` 有顺序预读缓存：

* 默认 1 MiB（`options_json.readahead_kb`），命中即直接从内存拷贝；
* 未命中时定位到底层并读满一个窗口；`avio` 只看到 64 KiB 的块；
* seek 会清空缓存，目标位置立即从底层读；
* 读取循环每块都检查 `abort`，退出/切集时能在几毫秒内停下。

## 3. 目录列表 JSON

```json
{
  "url": "smb://192.168.1.10/Movies/S01",
  "parent": "smb://192.168.1.10/Movies",
  "entries": [
    {"name":"E01.mkv","path":"smb://192.168.1.10/Movies/S01/E01.mkv",
     "is_dir":false,"size":1234567,"mtime":1690000000,"kind":"video","ext":"mkv"}
  ]
}
```

* `kind ∈ {dir, video, subtitle, audio, image, other}`，由扩展名判定。
* 排序：目录在前，其余自然序（`E2` 在 `E10` 前）。
* `path` **不含凭据**；Dart 侧 `MediaLocation.credentialized()` 在播放前补回 `user:pass@`，
  避免凭据出现在浏览列表/缓存里。

## 4. 错误映射

| 底层 | 返回 | UI |
|------|------|----|
| `STATUS_LOGON_FAILURE` / `ACCESS_DENIED` | `LP_ERR_AUTH` | “认证失败” |
| `STATUS_BAD_NETWORK_NAME` | `LP_ERR_AUTH` | “共享名不存在” |
| `STATUS_OBJECT_NAME_NOT_FOUND` | `LP_ERR_NOT_FOUND` | “文件/目录不存在” |
| 超时 | `LP_ERR_TIMEOUT` | “连接超时，检查 IP 与防火墙” |
| 其它 | `LP_ERR_IO` | `lp_source_last_error()` 原文 |

`lp_source_last_error()` 是 **线程局部** 的：Dart 在同一个 isolate 线程里紧接着调用，
拿到的就是刚才那次失败的描述。

## 5. 加一个 TCP 传输（示例）

```c
/* source/tcp.c */
static int tcp_open(LpIo *io, const LpUrl *u, const LpSourceOptions *o, char *err, size_t n) {
    int fd = socket_connect(u->host, u->port, o->timeout_ms);
    if (fd < 0) { snprintf(err, n, "connect %s:%d failed", u->host, u->port); return LP_ERR_IO; }
    io->ctx = (void *)(intptr_t)fd;
    io->size = -1;                      /* 流式：长度未知 */
    return LP_OK;
}
static int tcp_read(LpIo *io, uint8_t *buf, int size) { /* recv，处理 EINTR/EAGAIN */ }
static int64_t tcp_seek(LpIo *io, int64_t off, int whence) { /* 发送 seek 请求帧 */ }

const LpTransport lp_transport_tcp = {
    .scheme = "tcp", .open = tcp_open, .close = tcp_close,
    .read = tcp_read, .seek = tcp_seek, .size = tcp_size,
    .list = tcp_list, .probe = tcp_probe,
};
```

然后在 `lp_transport_find()` 加：

```c
if (strcmp(scheme, "tcp") == 0) return &lp_transport_tcp;
```

要点：

* **必须实现 seek**（或让 `io->size = -1` 且返回 `AVERROR(ENOSYS)`）。容器需要随机访问
  才能解析 `moov`/索引；不支持 seek 的流只能播 `mpegts` 这类可顺序解析的容器。
* `list()` 返回同样结构的 JSON 即可，UI 不需要区分协议。
* 如果新协议的吞吐不如 SMB，调大 `readahead_kb`，或让 `read()` 内部组大块再返回。

## 6. 兼容性检查清单

新增协议时确认：

- [ ] `lp_source_list` 能列出目录，`parent` 正确
- [ ] `lp_io_read` 在文件末尾返回 0（不是错误）
- [ ] `lp_io_seek(SEEK_END)` 在 `size` 未知时返回 `-1` 而不是崩溃
- [ ] abort（退出播放）能在 100 ms 内打断阻塞读
- [ ] 认证失败映射到 `LP_ERR_AUTH`，并写入 `lp_source_last_error`
- [ ] 凭据只在 `options_json` 或 URL userinfo 里，不出现在路径与日志
