// 把会阻塞的 FFI 调用搬到后台 isolate。
//
// 内核的 `lp_source_list` / `lp_source_probe` / `lp_source_thumbnail` 是同步
// C 函数：连 SMB 要开 TCP、握手、SMB2 negotiate/session/树连接，服务器不响应
// 时一路等到 socket 超时。这些函数在 Flutter 主 isolate 上直接调用，整条 UI
// 线程（渲染、手势、动画）就一起停在那里 —— 用户看到的是窗口一片白/黑、
// 按钮按下去没有水波纹、转圈不动。
//
// 为什么不在主 isolate 上「先画个转圈再去调」：Dart 的事件循环是单线程的，
// 同步调用一进去就不会再回到事件循环，之前排的任何帧都发不出去。
//
// 所以所有可能触网的入口都走这里：`Isolate.run` 起一个短命的后台 isolate，
// 在那边自己 open 一次动态库（`DynamicLibrary` 不能跨 isolate 传递，
// `NativeCore.instance` 在子 isolate 里是独立的一份，正好是我们要的），
// 拿完 JSON 字符串就退出。
//
// 为什么返回 JSON 字符串而不是解析好的对象：跨 isolate 传的是拷贝，
// 传字符串最省事也最快；解析留在调用方那一侧（主 isolate），顺便让
// `DirectoryListing.fromJson` 之类的代码只在一个地方跑。

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../core/bindings.dart';

/// 在后台 isolate 里列一次目录，返回内核给的原始 JSON。
///
/// 失败时返回的不是 null，而是带 `code` 的 [ListingResult] —— 错误码在
/// 后台 isolate 里就取出来一起带回来。内核把「这一次失败的原因」记在线程
/// 本地，恰好就是后台那个线程，所以这里是唯一能把分类码捞回主 isolate 的
/// 地方；以前在失败时只返回 null，主 isolate 上只剩一句「连不上」。
Future<ListingResult> listDirectoryInBackground(
        String url, Map<String, dynamic> options) =>
    Isolate.run(() => _listRaw(url, options));

Future<ListingResult> probeServerInBackground(
        String url, Map<String, dynamic> options) =>
    Isolate.run(() => _probeRaw(url, options));

ListingResult _listRaw(String url, Map<String, dynamic> options) {
  final map = NativeCore.instance.listDirectory(url, options);
  if (map == null) {
    return ListingResult.failure(NativeCore.instance.lastSourceFailure());
  }
  return ListingResult.json(_encode(map));
}

ListingResult _probeRaw(String url, Map<String, dynamic> options) {
  final map = NativeCore.instance.probeServer(url, options);
  if (map == null) {
    return ListingResult.failure(NativeCore.instance.lastSourceFailure());
  }
  return ListingResult.json(_encode(map));
}

/// 在后台 isolate 里试一遍 A–Z 盘符，返回真实存在的根（形如 `C:\`）。
///
/// 为什么不能在主 isolate 上做：`Directory.existsSync()` 对**掉线的网络盘**
/// 要等系统重试（几秒到十几秒），而这段代码在打开「添加本地文件夹」时同步
/// 跑，用户看到的是点了没反应。断掉的盘符越多，等得越久。
///
/// 返回字符串列表而不是 `({String label, String path})` 记录：跨 isolate 传输
/// 只保证基本类型与列表可发送，标签在调用方那一侧拼更省事。
Future<List<String>> windowsDriveRootsInBackground() =>
    Isolate.run(_scanWindowsDrives);

List<String> _scanWindowsDrives() {
  if (!Platform.isWindows) return const <String>[];
  final out = <String>[];
  for (var code = 'A'.codeUnitAt(0); code <= 'Z'.codeUnitAt(0); code++) {
    final letter = String.fromCharCode(code);
    final path = '$letter:\\';
    try {
      if (Directory(path).existsSync()) out.add(path);
    } catch (_) {
      // 没插盘 / 没权限：跳过，别让一个坏盘符挡住整个列表。
    }
  }
  return out;
}

/// 后台 isolate 里拿不到主 isolate 的 `jsonEncode` 之外的上下文，直接编码。
String _encode(Map<String, dynamic> map) => encodeJson(map);

/// 后台 isolate 的返回：要么是内核 JSON，要么是失败分类。
///
/// 必须是可以在 isolate 之间传的类型（字符串 + 可空 int），所以是普通类。
class ListingResult {
  ListingResult.json(String this.json)
      : code = null,
        message = null;

  ListingResult.failure(SourceFailure? failure)
      : json = null,
        code = failure?.code,
        message = failure?.message;

  final String? json;
  final int? code;
  final String? message;

  bool get ok => json != null;

  /// 失败分类；成功时为 null。
  SourceFailure? get failure =>
      ok ? null : SourceFailure(message: message, code: code);
}
