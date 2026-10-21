import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
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
}
