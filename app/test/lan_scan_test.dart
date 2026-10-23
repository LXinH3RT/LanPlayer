import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/lan_scan.dart';

void main() {
  group('parseIPv4', () {
    test('接受正常的点分十进制', () {
      expect(parseIPv4('192.168.1.20'), 0xC0A80114);
      expect(parseIPv4('0.0.0.0'), 0);
      expect(parseIPv4('255.255.255.255'), 0xFFFFFFFF);
      // 前导零按十进制处理，不当成八进制。
      expect(parseIPv4('010.0.0.1'), 0x0A000001);
    });

    test('拒绝非法写法', () {
      expect(parseIPv4('192.168.1'), isNull);
      expect(parseIPv4('192.168.1.256'), isNull);
      expect(parseIPv4('192.168.1.-1'), isNull);
      expect(parseIPv4('192.168.1.a'), isNull);
      expect(parseIPv4('192.168.1.1.1'), isNull);
      expect(parseIPv4(''), isNull);
      expect(parseIPv4('192.168..1'), isNull);
    });
  });

  group('formatIPv4', () {
    test('与 parseIPv4 互为逆运算', () {
      for (final text in [
        '0.0.0.0',
        '10.0.0.1',
        '192.168.1.20',
        '255.255.255.255'
      ]) {
        expect(formatIPv4(parseIPv4(text)!), text);
      }
    });
  });

  group('hostsInSubnet', () {
    test('/24 得到 254 个可分配地址，跳过网络号与广播地址', () {
      final hosts = hostsInSubnet('192.168.1.0/24');
      expect(hosts.length, 254);
      expect(hosts.first, '192.168.1.1');
      expect(hosts.last, '192.168.1.254');
      expect(hosts, isNot(contains('192.168.1.0')));
      expect(hosts, isNot(contains('192.168.1.255')));
    });

    test('/24 的输入即使不是网络地址，也按网络地址对齐', () {
      final hosts = hostsInSubnet('192.168.1.20/24');
      expect(hosts.first, '192.168.1.1');
      expect(hosts.last, '192.168.1.254');
    });

    test('/30 只有 2 个可用地址', () {
      expect(hostsInSubnet('10.1.1.0/30'), ['10.1.1.1', '10.1.1.2']);
    });

    test('/31 与 /32 退化成单地址，不做广播地址裁剪', () {
      expect(hostsInSubnet('10.1.1.5/32'), ['10.1.1.5']);
      expect(hostsInSubnet('10.1.1.4/31'), ['10.1.1.4']);
    });

    test('超过 maxHosts 的网段收敛到本机所在的 /24', () {
      // /16 有 65534 个地址，必须收敛，否则一次扫描要跑几分钟。
      final hosts = hostsInSubnet('10.20.0.0/16', maxHosts: 1024);
      expect(hosts.length, lessThanOrEqualTo(1024));
      expect(hosts.first, '10.20.0.1');
      expect(hosts.every((h) => h.startsWith('10.20.')), isTrue);
    });

    test('非法 CIDR 返回空列表而不是抛异常', () {
      expect(hostsInSubnet('192.168.1.0'), isEmpty);
      expect(hostsInSubnet('192.168.1.0/33'), isEmpty);
      expect(hostsInSubnet('192.168.1.0/-1'), isEmpty);
      expect(hostsInSubnet('abc/24'), isEmpty);
    });
  });

  group('scanSubnet', () {
    test('扫一个没有 SMB 服务的 /30，返回空列表', () async {
      // 文档保留段 192.0.2.0/30 不会被路由到，连接必然失败。
      final hosts = await scanSubnet(
        '192.0.2.0/30',
        timeout: const Duration(milliseconds: 120),
        concurrency: 4,
      );
      expect(hosts, isEmpty);
    });

    test('onProgress 会把每个地址都报一遍', () async {
      var total = 0;
      var lastDone = 0;
      await scanSubnet(
        '192.0.2.0/30',
        timeout: const Duration(milliseconds: 120),
        concurrency: 2,
        onProgress: (done, count) {
          total = count;
          lastDone = done;
        },
      );
      expect(total, 2);
      expect(lastDone, 2);
    });

    test('shouldStop 能提前结束扫描', () async {
      var calls = 0;
      final hosts = await scanSubnet(
        '192.0.2.0/24',
        timeout: const Duration(milliseconds: 120),
        concurrency: 4,
        shouldStop: () {
          calls++;
          return calls > 20;
        },
      );
      // 提前停止时不可能扫完 254 个地址。
      expect(hosts, isEmpty);
      expect(calls, lessThan(254));
    });
  });

  test('LanHost.label 在有主机名与没有主机名时都合理', () {
    expect(const LanHost(address: '192.168.1.10').label, '192.168.1.10');
    expect(const LanHost(address: '192.168.1.10', name: 'nas').label,
        'nas (192.168.1.10)');
    expect(
        const LanHost(address: '192.168.1.10', name: '').label, '192.168.1.10');
  });
}
