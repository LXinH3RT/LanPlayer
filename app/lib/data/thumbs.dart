import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/bindings.dart';
import 'progress.dart';
import 'stores.dart';

/// 一帧缩略图的数据（与 [ThumbnailResult] 等价，但只保留跨 isolate 需要的东西）。
class ThumbPixels {
  const ThumbPixels(
      {required this.width, required this.height, required this.rgba});

  final int width;
  final int height;
  final Uint8List rgba;
}

/// 后台 isolate 的入口：自己打开一次动态库，解一帧，把纯数据送回去。
///
/// 为什么不能把主 isolate 的 [NativeCore] 传进来：`DynamicLibrary` 不可跨
/// isolate 传递，静态字段在每个 isolate 里是各自独立的，所以这里
/// `NativeCore.instance` 会在子 isolate 里重新 open 一次 —— 这正是我们要的。
ThumbPixels? extractThumbnail(
    String url, Map<String, dynamic> options, int maxWidth) {
  final result = NativeCore.instance.thumbnail(url, options, maxWidth);
  if (result == null) return null;
  return ThumbPixels(
      width: result.width, height: result.height, rgba: result.rgba);
}

/// 列表里的视频封面：解一帧、缩到小尺寸、存成文件，下次直接用。
///
/// 三层缓存，从快到慢：
///   1. 内存：`Map<String, ui.Image>`，滚回同一个列表不重复解码；
///   2. 磁盘：`<state>/thumbs/<key>.thumb`，重启后仍然命中；
///   3. 内核：都没有才真的去 SMB 上读一帧（几百毫秒）。
///
/// 磁盘格式故意不用 PNG/JPEG：三端的 FFmpeg 都是裁剪构建，编码器未必在；
/// Dart 侧也没有图像编码库（为了这个功能加依赖不划算）。所以直接存
/// 8 字节头（宽、高）+ RGBA8888，读回来用 `decodeImageFromPixels` 还原。
class ThumbnailCache {
  ThumbnailCache._();
  static final ThumbnailCache instance = ThumbnailCache._();

  /// 封面宽度。列表里的缩略图是 56×56 的圆角方块，取 2 倍图足够。
  static const int width = 128;

  /// 同时真正解码的封面数上限。
  ///
  /// **这是「打开视频多的文件夹会卡死」的修复核心。** 每个封面都要在 SMB 上
  /// 打开一次文件、读 probe 数据、解一帧，单次几百毫秒到一秒多。以前每次
  /// `ListView.builder` 建出一行就起一个 `Isolate.run`，一屏十几行就是十几路
  /// 并发：libsmb2 每路各开一条独立连接，服务器侧互相争抢，实测单次耗时从
  /// 0.6s 放大到 5.0s（`build/probe_thumb_conc.py`，11 个视频：串行 6.87s /
  /// 并发 5.00s 且最慢一次 4.99s），表现为整页转圈、进度条不动、看起来像卡死。
  ///
  /// 限制成 1 之后总耗时反而更短，而且 UI 一直是响应的：第一行封面马上出来，
  /// 其余按顺序补齐。想调大可改这里，但四路以上在机械硬盘的 NAS 上没有收益。
  static const int maxConcurrent = 1;

  // "LPT2"：v1 的 "LPT1" 只写了宽没写高，读回必定失败。
  static const List<int> _magic = [0x4C, 0x50, 0x54, 0x32];

  final Map<String, ui.Image> _memory = <String, ui.Image>{};

  /// 正在解码的请求，避免同一行被 build 多次时重复解码。
  final Map<String, Future<ui.Image?>> _inflight = <String, Future<ui.Image?>>{};

  /// 全局解码闸门：取值 1..[maxConcurrent]。所有封面共用，跨页面也共用，
  /// 因为底层争抢的是同一台 NAS 的 SMB 会话，不是某个页面的资源。
  /// 用 `ConcurrencyGate` 而不是自己数信号量，是为了在异常路径上也一定还回去。
  final ConcurrencyGate _gate = ConcurrencyGate(max: maxConcurrent);

  Directory? _dir;

  Future<Directory> _cacheDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await AppStorage.directory();
    final dir = Directory('${base.path}${Platform.pathSeparator}thumbs');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  /// 缓存文件名。URL 可能很长也可能含 `/`、`%`、中文，全都不能直接进文件名，
  /// 所以做一次 FNV-1a 64 位散列；长度也参与，进一步降低碰撞概率。
  ///
  /// 注意用 [sanitizeKey] 归一化：同一个文件带不带账号密码、带不带 `%20`
  /// 都必须落到同一个缓存条目上。
  ///
  /// Dart 的 int 是有符号 64 位，FNV 的结果可能为负；负数调 `toRadixString`
  /// 会带一个前导 `-`（`toUnsigned(64)` 在 VM 上也救不回来，因为 64 位整数
  /// 本身就装不下 2^64-1）。所以拆成高低两个 32 位分别转十六进制，
  /// 结果必然是 16 位纯十六进制字符，可以直接当文件名。
  static String keyFor(String url) {
    final normalized = sanitizeKey(url);
    var hash = 0xcbf29ce484222325;
    for (final unit in normalized.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    final hi = (hash >> 32) & 0xFFFFFFFF;
    final lo = hash & 0xFFFFFFFF;
    final hex = hi.toRadixString(16).padLeft(8, '0') +
        lo.toRadixString(16).padLeft(8, '0');
    return '${hex}_${normalized.length}';
  }

  /// 与 [ProgressStore] 相同的键归一化：去掉 `user:pass@`、
  /// 把 `file:///D:/x` 折成 `file://D:/x`、解百分号转义。
  ///
  /// 直接复用 [ProgressStore.sanitizeKey]，两个缓存对「同一个文件」的
  /// 判断必须完全一致，否则封面与续播位置会各认各的。
  static String sanitizeKey(String key) => ProgressStore.sanitizeKey(key);

  /// 取封面。永远不抛异常：拿不到就返回 null，界面显示占位图标。
  Future<ui.Image?> load(String url, Map<String, dynamic> options) {
    final key = keyFor(url);
    final hit = _memory[key];
    if (hit != null) return Future<ui.Image?>.value(hit);
    final pending = _inflight[key];
    if (pending != null) return pending;

    final future = _load(key, url, options);
    _inflight[key] = future;
    future.whenComplete(() => _inflight.remove(key));
    return future;
  }

  Future<ui.Image?> _load(
      String key, String url, Map<String, dynamic> options) async {
    final watch = Stopwatch()..start();
    try {
      final dir = await _cacheDir();
      final file = File('${dir.path}${Platform.pathSeparator}$key.thumb');

      var bytes = await _readCache(file);
      final fromDisk = bytes != null;
      if (bytes == null) {
        // 「这个文件解不出封面」也要记住，否则每次滚回来都重新走一遍
        // SMB + 解码。目录里混着 .flv / 坏文件 / .docx 改名成 .mp4 时，
        // 这类必然失败的请求会一直占着闸门。
        final marker = File('${dir.path}${Platform.pathSeparator}$key.none');
        if (await marker.exists()) {
          if (_verbose) {
            // ignore: avoid_print
            print('LanPlayer thumb: $key skipped (known failure) $url');
          }
          return null;
        }

        // 内核调用是同步阻塞的，放到后台 isolate，避免卡住滚动；
        // 同时整个解码过程排在全局闸门后面 —— 一屏十几行不应该同时去敲 NAS。
        final decoded = await _gate.run(
            () => Isolate.run(() => extractThumbnail(url, options, width)));
        if (decoded == null) {
          unawaited(_writeMarker(marker));
          return null;
        }
        bytes = encodeThumb(decoded);
        // 写盘失败不影响这次显示，下次再试。
        unawaited(_writeCache(file, bytes));
      }

      final image = await decodeThumb(bytes);
      if (image != null) _memory[key] = image;
      if (_verbose) {
        // ignore: avoid_print
        print('LanPlayer thumb: $key ${image?.width}x${image?.height} '
            'disk=$fromDisk ${watch.elapsedMilliseconds}ms $url');
      }
      return image;
    } catch (_) {
      return null;
    }
  }

  /// `LANPLAYER_THUMBS=1`（或 `--dart-define=LANPLAYER_THUMBS=1`）时打印
  /// 每次取封面的来源与耗时，供桌面/模拟器验证用；默认安静。
  static bool get _verbose {
    final env = Platform.environment['LANPLAYER_THUMBS'];
    if (env == '1') return true;
    return const String.fromEnvironment('LANPLAYER_THUMBS') == '1';
  }

  static Future<Uint8List?> _readCache(File file) async {
    try {
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length < 12 || !_hasMagic(bytes)) {
        // 半截文件或格式变过：删掉重新生成。
        await file.delete();
        return null;
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeCache(File file, Uint8List bytes) async {
    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // 缓存写不进去只是慢一点，不该影响播放列表。
    }
  }

  /// 记下「这个 URL 解不出封面」，内容为空文件，只靠存在与否判断。
  static Future<void> _writeMarker(File marker) async {
    try {
      await marker.writeAsBytes(const <int>[], flush: true);
    } catch (_) {}
  }

  static bool _hasMagic(Uint8List bytes) {
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  /// 文件布局：`"LPT2"` + u32 宽 + u32 高 + RGBA8888 原始像素。
  ///
  /// 早期版本（`LPT1`）只写了宽、漏了高，读回时一定抛越界异常，
  /// 于是封面永远显示不出来。换了 magic，旧的半截缓存会在
  /// [_readCache] 里被判成不合法并删掉重建。
  ///
  /// 标 `@visibleForTesting` 是为了让单测直接跑一遍「编码 → 解码」往返，
  /// 这种头字段对不上的错误只能靠往返测试挡住。
  @visibleForTesting
  static Uint8List encodeThumb(ThumbPixels pixels) {
    final header = ByteData(8)
      ..setUint32(0, pixels.width, Endian.little)
      ..setUint32(4, pixels.height, Endian.little);
    final out = Uint8List(12 + pixels.rgba.length);
    out.setRange(0, 4, _magic);
    out.setRange(4, 12, header.buffer.asUint8List());
    out.setRange(12, out.length, pixels.rgba);
    return out;
  }

  /// 与 [encodeThumb] 配对的读取端；单测直接用它验证往返。
  ///
  /// 任何不合法的输入（magic 不对、长度不足、头部尺寸与数据长度矛盾）
  /// 都返回 null，不抛异常：缓存文件是可能被外部改坏/截断的。
  @visibleForTesting
  static Future<ui.Image?> decodeThumb(Uint8List bytes) {
    // 必须先查长度再读头：ByteData.sublistView(bytes, 4, 12) 对 8 字节的
    // 旧文件会直接抛 RangeError，冒到界面就是一张永远转圈的占位图。
    if (bytes.length < 12 || !_hasMagic(bytes)) {
      return Future<ui.Image?>.value(null);
    }
    final header = ByteData.sublistView(bytes, 4, 12);
    final w = header.getUint32(0, Endian.little);
    final h = header.getUint32(4, Endian.little);
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192) {
      return Future<ui.Image?>.value(null);
    }
    if (bytes.length != 12 + w * h * 4) {
      return Future<ui.Image?>.value(null);
    }
    final pixels = Uint8List.sublistView(bytes, 12);
    final completer = Completer<ui.Image?>();
    ui.decodeImageFromPixels(
      pixels,
      w,
      h,
      ui.PixelFormat.rgba8888,
      (image) => completer.complete(image),
    );
    return completer.future;
  }

  /// 清空磁盘与内存缓存（设置里的「清空封面缓存」用）。
  Future<void> clear() async {
    _memory.clear();
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _dir = null;
      await _cacheDir();
    } catch (_) {}
  }

  /// 当前磁盘缓存占用的字节数（设置页显示用）。
  Future<int> diskUsage() async {
    try {
      final dir = await _cacheDir();
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) total += await entity.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}

/// 限流的异步闸门：最多同时放行 [max] 个任务，其余按提交顺序排队。
///
/// 为什么不用 `Future.wait` 或信号量包：这里只需要「串行化对同一台 NAS 的
/// 解码请求」这一件事，自带实现十几行，且能在任务抛异常/挂掉时把名额还回去
/// （`_active` 的递减放在 finally 里）。队列用 FIFO，保证用户先看到的行先出图。
class ConcurrencyGate {
  ConcurrencyGate({required this.max}) : assert(max > 0);

  final int max;
  int _active = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  /// 排队等待时就能知道前面还有几个，便于测试与调试。
  @visibleForTesting
  int get pending => _waiters.length;

  @visibleForTesting
  int get active => _active;

  Future<T> run<T>(Future<T> Function() task) async {
    await _acquire();
    try {
      return await task();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_active < max) {
      _active++;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      // 直接把名额转交给队首，_active 保持不变。
      _waiters.removeAt(0).complete();
      return;
    }
    _active--;
  }
}
