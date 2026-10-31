import 'dart:async';
import 'dart:collection';
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

  /// 「这个文件解不出封面」这条结论的有效期。
  ///
  /// 记失败本身是有必要的：目录里混着 .flv、坏文件、改了后缀的 .docx，
  /// 不记账就会每次滚回来都重走一遍 SMB + 解码。但**不能记成永久结论** ——
  /// 网络抖一下、那一刻文件正被别的程序占用，都会让一帧解不出来，
  /// 而这两种情况下次完全可能成功。所以标记带时效，过期后放它重试一次。
  static const Duration failureTtl = Duration(hours: 6);

  /// 失败时间戳是不是已经过期。抽成纯函数是为了单测能直接喂时间。
  @visibleForTesting
  static bool markerExpired(DateTime failureAt, DateTime now) =>
      now.difference(failureAt) >= failureTtl;

  /// 内存里最多留多少张已解码的封面。
  ///
  /// 一张 128×128 的 RGBA 图约 64 KB，240 张约 15 MB —— 足够盖住一屏加上
  /// 上下各几屏的回滚，又不会因为「列表刷过一千个文件」把内存吃满。以前没有
  /// 上限：滑完一整个剧集目录，这些 `ui.Image` 只会增加、从不释放。
  static const int memoryLimit = 240;

  /// 磁盘缓存的上限，超过就按最后访问时间淘汰。
  ///
  /// 一个封面文件约 64 KB，128 MB 大致是两千个。以前只有 `diskUsage()`
  /// 这一个尺子，没有任何地方会删：库越滚越大，装久了就是几百 MB 的死重量。
  static const int diskLimitBytes = 128 * 1024 * 1024;

  /// 每写这么多个缓存文件，回头看一次磁盘用量。逐个写都去 `list()` 一遍
  /// 目录代价太高，攒一批再扫既省事又不会让占用翻倍太多。
  static const int _pruneEvery = 16;

  /// 已解码封面的内存缓存，超出 [memoryLimit] 就丢掉最久没被用过的那张。
  ///
  /// 缓存持有的是「母本」，每个调用方拿到的是 [ui.Image.clone] 出来的副本。
  /// 这样两边各自 dispose 自己的句柄都不会伤到对方：行被滚出屏幕时立刻
  /// 归还像素，缓存淘汰时再释放母本。只有一个引用、谁都不敢 dispose 的
  /// 做法会让 128×128 的封面一直挂到下一次 GC。
  final ImageLru<ui.Image> _memory = ImageLru<ui.Image>(
      limit: memoryLimit, disposeValue: (image) => image.dispose());

  /// 自上次清理以来写了多少个缓存文件。
  int _writesSincePrune = 0;

  /// 正在解码的请求，避免同一行被 build 多次时重复解码。
  final Map<String, Future<ui.Image?>> _inflight =
      <String, Future<ui.Image?>>{};

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

  /// 带版本号的缓存键。
  ///
  /// [version] 来自目录列表里的修改时间与大小：同名文件被替换后它会变，
  /// 于是键也变，旧封面自然失效。[version] 为 null 时退回只按 URL 缓存。
  static String keyForVersion(String url, String? version) =>
      keyFor(version == null ? url : '$url?v=$version');

  /// 取封面。永远不抛异常：拿不到就返回 null，界面显示占位图标。
  ///
  /// [version] 是这家文件「当前这一版」的标记（来自目录列表的修改时间 +
  /// 大小）。同名文件被替换后它就会变，缓存键随之改变，封面自然重解；
  /// 传 null 时退回只按 URL 缓存 —— 这是老行为，只在拿不到元数据时用。
  Future<ui.Image?> load(String url, Map<String, dynamic> options,
      {String? version}) {
    final key = keyForVersion(url, version);
    final hit = _memory[key];
    // 命中缓存也要给副本：调用方会 dispose 自己那一份，母本留在缓存里。
    if (hit != null) return Future<ui.Image?>.value(hit.clone());
    final pending = _inflight[key];
    // 同一个键正在解码时后续调用方也得各拿一份副本 —— 把同一个 future
    // 交给两行，第一行 dispose 之后第二行就画到已释放的像素上了。
    if (pending != null) return pending.then((img) => img?.clone());

    final future = _load(key, url, options);
    _inflight[key] = future;
    future.whenComplete(() => _inflight.remove(key));
    return future.then((img) => img?.clone());
  }

  Future<ui.Image?> _load(
      String key, String url, Map<String, dynamic> options) async {
    final watch = Stopwatch()..start();
    try {
      final dir = await _cacheDir();
      final file = File('${dir.path}${Platform.pathSeparator}$key.thumb');

      var bytes = await _readCache(file);
      final fromDisk = bytes != null;
      if (bytes != null) {
        // 把「最后访问时间」推到现在，磁盘淘汰才分得清冷热。失败不影响显示。
        unawaited(_touch(file));
      }
      if (bytes == null) {
        // 「这个文件解不出封面」也要记住，否则每次滚回来都重新走一遍
        // SMB + 解码。目录里混着 .flv / 坏文件 / .docx 改名成 .mp4 时，
        // 这类必然失败的请求会一直占着闸门。
        //
        // 但记忆带时效（[failureTtl]）：一次网络抖动不该让这个文件
        // 永远没有封面。过期的标记直接删掉重试。
        final marker = File('${dir.path}${Platform.pathSeparator}$key.none');
        if (await marker.exists()) {
          var expired = true;
          try {
            final at = await marker.lastModified();
            expired = markerExpired(at, DateTime.now());
          } catch (_) {
            // 读不到时间就当过期，宁可重解一次。
          }
          if (!expired) {
            if (_verbose) {
              // ignore: avoid_print
              print('LanPlayer thumb: $key skipped (recent failure) $url');
            }
            return null;
          }
          try {
            await marker.delete();
          } catch (_) {}
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
        _noteDiskWrite();
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

  /// 命中磁盘缓存时把文件的修改时间推到现在。
  ///
  /// Dart 的 `File` 没有 `utimes`，读写一遍是最省事的等价物；封面本来就只有
  /// 几十 KB，比再走一次 SMB 便宜得多。写不进去也无所谓 —— 那只是让这个文件
  /// 在淘汰时排得靠前一些。
  static Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {}
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

  /// 记下「这个 URL 解不出封面」。内容是失败时刻的毫秒时间戳，
  /// 读回来才知道要不要按 [failureTtl] 放它重试。
  static Future<void> _writeMarker(File marker) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      await marker.writeAsString('$now', flush: true);
    } catch (_) {}
  }

  /// 每写一批缓存文件就回头看一次磁盘占用，超了 [diskLimitBytes] 就淘汰。
  void _noteDiskWrite() {
    if (++_writesSincePrune < _pruneEvery) return;
    _writesSincePrune = 0;
    unawaited(pruneDisk());
  }

  /// 按最后访问时间淘汰磁盘缓存，直到回到 [diskLimitBytes] 以下。
  ///
  /// 「最后访问时间」用文件的 `lastModified`：命中缓存时 [_touch] 会把它
  /// 推到现在，于是长期没再出现的文件自然排到队首被删。失败标记
  /// （`.none`）也一起算年龄，它们同样是会过期的缓存。
  ///
  /// 返回删掉的字节数，设置页/单测可以直接用它判断有没有真的动手。
  Future<int> pruneDisk() async {
    try {
      final dir = await _cacheDir();
      if (!await dir.exists()) return 0;
      final files = <({File file, int size, DateTime at})>[];
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          total += stat.size;
          files.add((file: entity, size: stat.size, at: stat.modified));
        } catch (_) {
          // 正被别的进程动过的文件，这次先跳过。
        }
      }
      if (total <= diskLimitBytes) return 0;
      files.sort((a, b) => a.at.compareTo(b.at));
      var freed = 0;
      for (final entry in files) {
        if (total - freed <= diskLimitBytes) break;
        try {
          await entry.file.delete();
          freed += entry.size;
        } catch (_) {}
      }
      if (freed > 0 && _verbose) {
        // ignore: avoid_print
        print('LanPlayer thumb: pruned ${freed ~/ 1024} KiB of covers');
      }
      return freed;
    } catch (_) {
      return 0;
    }
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
    _writesSincePrune = 0;
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

/// 有上限的 LRU 缓存：超过 [limit] 就丢掉最久没被读取的那一项。
///
/// 淘汰与 `clear()` 都会调 [disposeValue]（如果给了）。[ThumbnailCache] 传进来的
/// 回收函数直接释放母本 —— 调用方手里都是 [ui.Image.clone] 出来的副本，各自
/// dispose 各自的，互不影响。
///
/// 用 [LinkedHashMap] 的插入顺序当访问顺序：每次 [operator []] 命中就把键
/// 挪到队尾，于是队首永远是最冷的那个。这样做比给每项记时间戳简单，也不比
/// 它差 —— 缓存命中的次数就是我们要的热度。
class ImageLru<V extends Object> {
  ImageLru({required this.limit, this.disposeValue}) : assert(limit > 0);

  final int limit;
  final void Function(V value)? disposeValue;
  final LinkedHashMap<String, V> _entries = LinkedHashMap<String, V>();

  @visibleForTesting
  int get length => _entries.length;

  @visibleForTesting
  bool containsKey(String key) => _entries.containsKey(key);

  V? operator [](String key) {
    final value = _entries.remove(key);
    if (value == null) return null;
    // 重新插到队尾 = 标记为最近使用。
    _entries[key] = value;
    return value;
  }

  void operator []=(String key, V value) {
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > limit) {
      final oldest = _entries.keys.first;
      final evicted = _entries.remove(oldest);
      if (evicted != null) disposeValue?.call(evicted);
    }
  }

  void remove(String key) => _entries.remove(key);

  /// 全部丢弃。只有「整个缓存都不要了」时才调用 [disposeValue]。
  void clear() {
    if (disposeValue != null) {
      for (final value in _entries.values) {
        disposeValue!(value);
      }
    }
    _entries.clear();
  }
}
