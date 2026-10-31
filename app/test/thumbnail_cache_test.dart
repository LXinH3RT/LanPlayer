import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/data/progress.dart';
import 'package:lanplayer/data/thumbs.dart';

/// 封面缓存的两个纯函数：缓存键与 URL 归一化。
///
/// 这里不测真的解码（那需要内核动态库），只锁住「同一个文件永远落到
/// 同一个缓存键」这条契约 —— 一旦键算错，用户换台机器就会看到别人的
/// 封面，或者每次进目录都重新解码。
void main() {
  group('ThumbnailCache.sanitizeKey', () {
    test('去掉 URL 里的账号密码', () {
      expect(
        ThumbnailCache.sanitizeKey('smb://u:p@host/share/a.mkv'),
        'smb://host/share/a.mkv',
      );
    });

    test('把 file:///D:/x 折成 file://D:/x', () {
      expect(
        ThumbnailCache.sanitizeKey('file:///D:/movies/a.mkv'),
        'file://D:/movies/a.mkv',
      );
    });

    test('解掉百分号转义（%2F 除外）', () {
      expect(
        ThumbnailCache.sanitizeKey('smb://host/share/%E7%94%B5%E5%BD%B1/a.mkv'),
        'smb://host/share/电影/a.mkv',
      );
      expect(
        ThumbnailCache.sanitizeKey('smb://host/share/a%2Fb.mkv'),
        'smb://host/share/a%2Fb.mkv',
      );
    });

    test('和 ProgressStore 归一化完全一致', () {
      const urls = [
        'smb://u:p@host/share/x.mkv',
        'file:///tmp/y.mp4',
        'smb://host/share/%E7%94%B5%E5%BD%B1/z.mkv',
        'file://D:/plain.mp4',
      ];
      for (final url in urls) {
        expect(ThumbnailCache.sanitizeKey(url), ProgressStore.sanitizeKey(url),
            reason: url);
      }
    });
  });

  group('ThumbnailCache.keyFor', () {
    test('同一个文件的不同写法得到同一个键', () {
      final a = ThumbnailCache.keyFor('smb://host/share/a.mkv');
      final b = ThumbnailCache.keyFor('smb://u:p@host/share/a.mkv');
      final c = ThumbnailCache.keyFor('smb://host/share/%61.mkv');
      expect(b, a);
      expect(c, a);
    });

    test('不同文件的键不同', () {
      final a = ThumbnailCache.keyFor('smb://host/share/a.mkv');
      final b = ThumbnailCache.keyFor('smb://host/share/b.mkv');
      expect(a, isNot(b));
    });

    test('键是纯 ASCII 且不含路径分隔符', () {
      final key = ThumbnailCache.keyFor('smb://host/共享/电影/movie-01.mp4');
      expect(RegExp(r'^[0-9a-f]+_\d+$').hasMatch(key), isTrue, reason: key);
      expect(key.contains('/'), isFalse);
      expect(key.contains(Platform.pathSeparator), isFalse);
      // 16 位散列 + 下划线 + 长度，足够短，不会撞文件名长度上限。
      expect(key.length, lessThan(40));
    });

    test('长度不同的相似路径不会被折叠', () {
      final a = ThumbnailCache.keyFor('smb://host/s/a.mkv');
      final b = ThumbnailCache.keyFor('smb://host/s/a.mkvv');
      expect(a, isNot(b));
    });
  });

  group('ThumbnailCache.keyForVersion', () {
    const url = 'smb://host/share/a.mkv';

    test('没有版本号时退回只按 URL 缓存', () {
      expect(
          ThumbnailCache.keyForVersion(url, null), ThumbnailCache.keyFor(url));
    });

    test('文件换了版本就换键，旧封面自动失效', () {
      final old = ThumbnailCache.keyForVersion(url, '1000-1024');
      final next = ThumbnailCache.keyForVersion(url, '2000-1024');
      expect(old, isNot(next));
      expect(old, isNot(ThumbnailCache.keyFor(url)));
    });

    test('版本相同则键相同，刷新不会反复重解', () {
      expect(ThumbnailCache.keyForVersion(url, '1000-1024'),
          ThumbnailCache.keyForVersion(url, '1000-1024'));
    });
  });

  group('MediaEntry.version', () {
    MediaEntry entry({int size = 1024, DateTime? modified}) => MediaEntry(
          name: 'a.mkv',
          path: 'smb://h/s/a.mkv',
          isDir: false,
          size: size,
          kind: 'video',
          ext: 'mkv',
          modified: modified,
        );

    test('同样大小、同样时间 → 同一个版本标记', () {
      final t = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      expect(entry(modified: t).version, entry(modified: t).version);
    });

    test('同名文件被替换（大小变了）→ 版本标记跟着变', () {
      final t = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      expect(entry(size: 1024, modified: t).version,
          isNot(entry(size: 2048, modified: t).version));
    });

    test('只有时间变了也算换了一版', () {
      final a = entry(modified: DateTime.fromMillisecondsSinceEpoch(1000));
      final b = entry(modified: DateTime.fromMillisecondsSinceEpoch(2000));
      expect(a.version, isNot(b.version));
    });

    test('拿不到时间且大小为空时不给版本，避免空文件共用一个键', () {
      expect(entry(size: 0).version, isNull);
    });
  });

  group('ThumbnailCache 磁盘格式往返', () {
    test('编码再解码得到同样的尺寸和像素', () async {
      // 2x2 的纯色图，四个像素各不相同，能同时验证行序与通道顺序。
      final pixels = <int>[
        255, 0, 0, 255, // 红
        0, 255, 0, 255, // 绿
        0, 0, 255, 255, // 蓝
        255, 255, 255, 255, // 白
      ];
      final encoded = ThumbnailCache.encodeThumb(
        ThumbPixels(width: 2, height: 2, rgba: Uint8List.fromList(pixels)),
      );
      // 头是 12 字节：4 字节 magic + 宽 + 高。
      expect(encoded.length, 12 + 16);

      final image = await ThumbnailCache.decodeThumb(encoded);
      expect(image, isNotNull);
      expect(image!.width, 2);
      expect(image.height, 2);

      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(data, isNotNull);
      expect(data!.buffer.asUint8List(), pixels);
      image.dispose();
    });

    test('旧版 LPT1 文件会被判成非法', () async {
      // 只是 magic 不同、长度也不够；读取端必须拒绝，不能当成功。
      final stale =
          Uint8List.fromList(<int>[0x4C, 0x50, 0x54, 0x31, 0, 0, 0, 0]);
      expect(await ThumbnailCache.decodeThumb(stale), isNull);
    });

    test('长度与头部对不上的文件被拒绝', () async {
      final pixels = Uint8List(16);
      final encoded = ThumbnailCache.encodeThumb(
          ThumbPixels(width: 2, height: 2, rgba: pixels));
      final truncated = Uint8List.sublistView(encoded, 0, encoded.length - 4);
      expect(await ThumbnailCache.decodeThumb(truncated), isNull);
    });
  });

  group('ThumbnailCache 失败标记的时效', () {
    // 失败标记曾经是「有文件就算永久失败」，一次网络抖动就让这个视频
    // 再也没有封面。改成带时间戳、过期重试。
    final t0 = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    test('刚记下的失败不重试', () {
      expect(ThumbnailCache.markerExpired(t0, t0), isFalse);
      expect(
        ThumbnailCache.markerExpired(t0, t0.add(const Duration(minutes: 5))),
        isFalse,
      );
    });

    test('过了有效期就放它重试', () {
      expect(
        ThumbnailCache.markerExpired(t0, t0.add(ThumbnailCache.failureTtl)),
        isTrue,
        reason: '刚好到期也算过期，否则边界上永远差一秒',
      );
      expect(
        ThumbnailCache.markerExpired(t0, t0.add(const Duration(days: 1))),
        isTrue,
      );
    });

    test('有效期不是无穷大，也不是短到每次滚动都重解', () {
      expect(ThumbnailCache.failureTtl.inMinutes, greaterThanOrEqualTo(10));
      expect(ThumbnailCache.failureTtl.inHours, lessThanOrEqualTo(24));
    });
  });

  group('ImageLru 的淘汰顺序', () {
    // 内存缓存以前是个没有上限的 Map：滑完一整个剧集目录，解码过的封面
    // 一张都不会被释放，一千个文件就是六十多 MB。
    test('超出上限就丢最久没被访问的那张', () {
      final lru = ImageLru<String>(limit: 3);
      lru['a'] = 'A';
      lru['b'] = 'B';
      lru['c'] = 'C';
      expect(lru.length, 3);

      lru['d'] = 'D';
      expect(lru.containsKey('a'), isFalse, reason: 'a 最老，应该先被丢');
      expect(lru.containsKey('b'), isTrue);
      expect(lru.length, 3);
    });

    test('读过一次就算「最近用过」，不会马上被淘汰', () {
      final lru = ImageLru<String>(limit: 2);
      lru['a'] = 'A';
      lru['b'] = 'B';
      // 再读一次 a：它在链表里的位置要挪到末尾。
      expect(lru['a'], 'A');
      lru['c'] = 'C';
      expect(lru.containsKey('a'), isTrue, reason: '刚读过，不该先淘汰它');
      expect(lru.containsKey('b'), isFalse);
    });

    test('重复写同一个键不会撑大缓存', () {
      final lru = ImageLru<String>(limit: 2);
      lru['a'] = 'A';
      lru['a'] = 'A2';
      expect(lru.length, 1);
      expect(lru['a'], 'A2');
    });

    test('clear 与淘汰都会释放值', () {
      final disposed = <String>[];
      final lru = ImageLru<String>(limit: 4, disposeValue: disposed.add);
      lru['a'] = 'A';
      lru['b'] = 'B';
      lru.clear();
      expect(lru.length, 0);
      expect(disposed, <String>['A', 'B']);

      // 超出上限被挤掉的那一项也要回收：封面缓存传的正是 `image.dispose()`，
      // 漏掉这一半的话淘汰只是丢引用，像素要等下一次 GC 才还回去。
      final evicting = ImageLru<String>(limit: 2, disposeValue: disposed.add);
      evicting['x'] = 'X';
      evicting['y'] = 'Y';
      evicting['z'] = 'Z';
      expect(evicting.containsKey('x'), isFalse);
      expect(disposed, <String>['A', 'B', 'X'], reason: '挤掉的最老那项要释放');

      // 不传回收函数时什么也不做（纯值缓存不该被顺手释放）。
      final plain = ImageLru<String>(limit: 2);
      plain['x'] = 'X';
      plain['y'] = 'Y';
      plain['z'] = 'Z';
      expect(plain.length, 2);
    });

    test('上限是 240 张、磁盘 128 MB，都不是随手写的量级', () {
      expect(ThumbnailCache.memoryLimit, greaterThanOrEqualTo(64));
      expect(ThumbnailCache.memoryLimit, lessThanOrEqualTo(1024));
      expect(ThumbnailCache.diskLimitBytes, greaterThan(16 * 1024 * 1024));
      expect(
          ThumbnailCache.diskLimitBytes, lessThanOrEqualTo(512 * 1024 * 1024));
    });
  });
}
