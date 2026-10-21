// 局域网 SMB 扫描的实地验证脚本：扫本机所在 /24，打印命中的 445 主机。
//
// 用法（在 app/ 下）：
//   flutter test tool/lan_scan_probe.dart   # 不行，这是可执行脚本
//   dart run tool/lan_scan_probe.dart
import 'dart:io';

import 'package:lanplayer/data/lan_scan.dart';

Future<void> main(List<String> args) async {
  final subnets = await localSubnets();
  stdout.writeln('本机网段: $subnets');
  if (subnets.isEmpty) {
    stdout.writeln('没有找到可扫的 IPv4 网段');
    exit(1);
  }

  final cidr = args.isNotEmpty ? args.first : subnets.first;
  stdout.writeln('扫描: $cidr (445 端口)');

  final sw = Stopwatch()..start();
  final hosts = await scanSubnet(
    cidr,
    onProgress: (done, total) {
      if (done % 32 == 0 || done == total) {
        stdout.writeln('  进度 $done/$total');
      }
    },
  );
  sw.stop();

  stdout.writeln('用时 ${sw.elapsedMilliseconds} ms，命中 ${hosts.length} 台');
  if (hosts.isEmpty) {
    stdout.writeln('结论: 该网段没有开放 445 的主机');
    exit(1);
  }

  await resolveNames(hosts);
  for (final host in hosts) {
    stdout.writeln('  ${host.label}');
  }

  final expected = args.length > 1 ? args[1] : null;
  if (expected != null) {
    final hit = hosts.any((h) => h.address == expected);
    stdout.writeln(hit ? '期望的 $expected 已命中' : '没有扫到期望的 $expected');
    exit(hit ? 0 : 2);
  }
}
