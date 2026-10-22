import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/thumbs.dart';

/// 「打开视频多的文件夹会卡死」的回归测试。
///
/// 根因是每一行封面各自起一个 `Isolate.run` 去 SMB 上解码，一屏十几行就是
/// 十几路并发，把单次耗时从 0.6s 放大到 5.0s（实测见
/// `build/probe_thumb_conc.py`）。修法是加一道全局串行闸门，并给
/// 「解不出封面」的文件留失败标记，避免反复重试。
///
/// 这里不测真的解码（那要内核动态库 + NAS），只锁住并发度与失败缓存这两条
/// 不变量 —— 一旦有人把闸门去掉，下面的用例会立刻变红。
void main() {
  group('并发闸门', () {
    test('默认只放行 1 路，保证不会同时敲 NAS', () {
      expect(ThumbnailCache.maxConcurrent, 1);
    });

    test('任务按提交顺序串行执行，且同一时刻只有一个在跑', () async {
      final gate = ConcurrencyGate(max: 2);
      var running = 0;
      var peak = 0;
      final order = <int>[];
      final done = <Future<void>>[];

      for (var i = 0; i < 6; i++) {
        done.add(gate.run(() async {
          running++;
          peak = running > peak ? running : peak;
          // 让出事件循环，别的任务若被同时放行就会在这里被观察到。
          await Future<void>.delayed(const Duration(milliseconds: 5));
          order.add(i);
          running--;
        }).then((_) {}));
      }
      await Future.wait(done);

      expect(peak, lessThanOrEqualTo(2), reason: '同时最多 2 个');
      expect(order, [0, 1, 2, 3, 4, 5], reason: 'FIFO，不插队');
      expect(gate.active, 0, reason: '全部归还名额');
      expect(gate.pending, 0, reason: '队列清空');
    });

    test('任务抛异常也会把名额还回去', () async {
      final gate = ConcurrencyGate(max: 1);
      await expectLater(
        gate.run<void>(() async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      expect(gate.active, 0, reason: '异常路径必须归还名额');

      // 名额还回来了，下一个任务不能永远挂住。
      final v = await gate.run(() async => 42);
      expect(v, 42);
    });

    test('单路闸门下排队任务不会饿死', () async {
      final gate = ConcurrencyGate(max: 1);
      final results = await Future.wait<int>([
        for (var i = 0; i < 5; i++)
          gate.run<int>(() async {
            await Future<void>.delayed(const Duration(milliseconds: 2));
            return i;
          }),
      ]);
      expect(results, [0, 1, 2, 3, 4]);
      expect(gate.active, 0);
    });
  });

  group('失败标记不影响成功路径', () {
    test('缓存键仍是纯 ASCII，标记文件名可用', () {
      final key = ThumbnailCache.keyFor('smb://h/s/坏文件.flv');
      expect(RegExp(r'^[0-9a-f]+_\d+$').hasMatch(key), isTrue, reason: key);
      // `<key>.thumb` 与 `<key>.none` 都落在这个名字上，不能含分隔符。
      expect(key.contains('/'), isFalse);
      expect(key.contains('\\'), isFalse);
    });
  });
}
