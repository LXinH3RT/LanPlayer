import 'dart:async';
import 'dart:io';

/// 局域网 SMB 主机扫描。
///
/// 为什么不用 mDNS：`_smb._tcp.local` 只有 macOS / Linux 上的 avahi 才会广播，
/// Windows 默认**不**广播（它走 WS-Discovery / SSDP），实测一个放着 Windows 共享
/// 和群晖 NAS 的 /24 网段，`dns-sd -B _smb._tcp` 一条都收不到。直接并发探测
/// 445 端口反而是全平台一致、又一定能命中的做法。
///
/// 这里刻意做成「纯 dart:io」：不引入插件，Android / iOS / Windows / macOS
/// 四个平台行为相同，也不需要在原生侧再加一层 socket 代码。

/// 扫描到的一台候选主机。
class LanHost {
  const LanHost({required this.address, this.name});

  /// IPv4 点分十进制地址，用来填「IP 地址或主机名」输入框。
  final String address;

  /// 反查到的主机名；查不到时为 null（很多 NAS 的 445 开了但没跑反向 DNS）。
  final String? name;

  /// 界面上显示的一行文字。
  String get label =>
      name == null || name!.isEmpty ? address : '$name ($address)';

  Map<String, dynamic> toJson() =>
      {'address': address, if (name != null) 'name': name};

  @override
  String toString() => 'LanHost($address, $name)';
}

/// 把 `a.b.c.d/n` 拆成 (网络地址整数, 前缀长度)。格式不对返回 null。
(int, int)? parseCidr(String cidr) {
  final slash = cidr.indexOf('/');
  if (slash <= 0) return null;
  final ip = parseIPv4(cidr.substring(0, slash));
  final prefix = int.tryParse(cidr.substring(slash + 1));
  if (ip == null || prefix == null || prefix < 0 || prefix > 32) return null;
  return (ip, prefix);
}

/// 点分十进制 IPv4 转 32 位无符号整数，格式不对返回 null。
int? parseIPv4(String text) {
  final parts = text.trim().split('.');
  if (parts.length != 4) return null;
  var value = 0;
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return null;
    final octet = int.tryParse(part);
    if (octet == null || octet < 0 || octet > 255) return null;
    // 允许 `01` 这种写法，但拒绝 `1a`。
    for (final rune in part.codeUnits) {
      if (rune < 0x30 || rune > 0x39) return null;
    }
    value = (value << 8) | octet;
  }
  return value;
}

/// 32 位整数转点分十进制。
String formatIPv4(int value) =>
    '${(value >> 24) & 0xFF}.${(value >> 16) & 0xFF}.${(value >> 8) & 0xFF}.${value & 0xFF}';

/// 列出 [cidr] 里所有可分配的主机地址（去掉网络地址与广播地址）。
///
/// [maxHosts] 是硬上限：/16 有 6 万多个地址，扫完要几分钟，没有意义。
/// 超过上限时只取「本机所在的那个 /24」——家用 / 小办公室网络实际都是 /24。
List<String> hostsInSubnet(String cidr, {int maxHosts = 1024}) {
  final parsed = parseCidr(cidr);
  if (parsed == null) return const [];
  final (ip, prefix) = parsed;
  if (prefix >= 31) return [formatIPv4(ip)];

  var effective = prefix;
  if ((1 << (32 - prefix)) - 2 > maxHosts) {
    // 太大：收敛到本机地址所在的 /24，避免几万个探测把手机打爆。
    effective = 24;
  }
  final mask =
      effective == 0 ? 0 : (0xFFFFFFFF << (32 - effective)) & 0xFFFFFFFF;
  final network = ip & mask;
  final broadcast = network | (~mask & 0xFFFFFFFF);

  final hosts = <String>[];
  for (var addr = network + 1; addr < broadcast; addr++) {
    // 收敛到 /24 后仍要跳过后缀 .0 / .255，那些本来就不是主机地址。
    if (effective > 24) {
      final lastOctet = addr & 0xFF;
      if (lastOctet == 0 || lastOctet == 255) continue;
    }
    hosts.add(formatIPv4(addr));
    if (hosts.length >= maxHosts) break;
  }
  return hosts;
}

/// 本机的 IPv4 网段列表（形如 `192.168.1.20/24`）。
///
/// 不依赖任何插件：`NetworkInterface.list` 是 dart:io 自带的。
/// dart:io 不暴露接口的子网掩码，家用/小办公室网络基本都是 /24，
/// 所以这里统一按 /24 给出；要精确范围时由调用方显式传 cidr。
Future<List<String>> localSubnets() async {
  final out = <String>[];
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        // 链路本地 169.254.x.x 已由 includeLinkLocal 过滤，这里再兜一层。
        if (addr.address.startsWith('169.254.')) continue;
        out.add('${addr.address}/24');
      }
    }
  } on OSError {
    // 某些沙盒环境不允许枚举接口，交给调用方退化成「扫一个 /24」。
  }
  return out;
}

/// 并发探测 [cidr] 里每个地址的 [port] 端口，命中即记为一台候选主机。
///
/// [concurrency] 控制同时在飞的连接数；[timeout] 是单次连接超时。
/// 局域网内 445 开着的机器通常 < 50 ms 就握手完成，超时设 350 ms 足够。
Future<List<LanHost>> scanSubnet(
  String cidr, {
  int port = 445,
  Duration timeout = const Duration(milliseconds: 350),
  int concurrency = 64,
  int maxHosts = 1024,
  void Function(int done, int total)? onProgress,
  bool Function()? shouldStop,
}) async {
  final hosts = hostsInSubnet(cidr, maxHosts: maxHosts);
  if (hosts.isEmpty) return const [];

  final hits = <String>[];
  var next = 0;
  var done = 0;

  Future<void> worker() async {
    while (true) {
      if (shouldStop?.call() ?? false) return;
      final index = next;
      if (index >= hosts.length) return;
      next = index + 1;
      final host = hosts[index];
      Socket? socket;
      try {
        socket = await Socket.connect(host, port, timeout: timeout);
        hits.add(host);
      } on SocketException {
        // 拒绝连接 / 超时 / 不可达都算「没有 SMB」，不是错误。
      } finally {
        socket?.destroy();
        done++;
        onProgress?.call(done, hosts.length);
      }
    }
  }

  final workers = <Future<void>>[];
  final workerCount = concurrency < hosts.length ? concurrency : hosts.length;
  for (var i = 0; i < workerCount; i++) {
    workers.add(worker());
  }
  await Future.wait(workers);

  hits.sort((a, b) {
    final ia = parseIPv4(a) ?? 0;
    final ib = parseIPv4(b) ?? 0;
    return ia.compareTo(ib);
  });
  return hits.map((address) => LanHost(address: address)).toList();
}

/// 给扫描结果补主机名。反查失败就保留 null，不影响使用。
Future<void> resolveNames(List<LanHost> hosts,
    {Duration timeout = const Duration(seconds: 2)}) async {
  await Future.wait(hosts.map((host) async {
    try {
      final result =
          await InternetAddress(host.address).reverse().timeout(timeout);
      if (result.host.isNotEmpty) {
        // 反查常见返回 `nas.local`，界面上显示时去掉 trailing dot。
        final name = result.host.endsWith('.')
            ? result.host.substring(0, result.host.length - 1)
            : result.host;
        _replaceHost(hosts, host, name);
      }
    } catch (_) {
      // 忽略：没有反向 DNS 是常态。
    }
  }));
}

void _replaceHost(List<LanHost> hosts, LanHost old, String name) {
  final index = hosts.indexOf(old);
  if (index >= 0) {
    hosts[index] = LanHost(address: old.address, name: name);
  }
}
