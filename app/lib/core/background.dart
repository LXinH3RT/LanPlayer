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
import 'dart:isolate';

import '../core/bindings.dart';

/// 在后台 isolate 里列一次目录，返回内核给的原始 JSON。
///
/// 失败（连不上、超时、路径不存在）返回 null —— 原因由内核记在线程本地，
/// 跨 isolate 拿不到，所以调用方拿到的错误文案是通用的一条。
/// 这也是为什么这个函数的名字带 `Raw`：调用方要知道自己失去了具体原因。
Future<String?> listDirectoryInBackground(
        String url, Map<String, dynamic> options) =>
    Isolate.run(() => _listRaw(url, options));

Future<String?> probeServerInBackground(
        String url, Map<String, dynamic> options) =>
    Isolate.run(() => _probeRaw(url, options));

String? _listRaw(String url, Map<String, dynamic> options) {
  final map = NativeCore.instance.listDirectory(url, options);
  return map == null ? null : _encode(map);
}

String? _probeRaw(String url, Map<String, dynamic> options) {
  final map = NativeCore.instance.probeServer(url, options);
  return map == null ? null : _encode(map);
}

/// 后台 isolate 里拿不到主 isolate 的 `jsonEncode` 之外的上下文，直接编码。
String _encode(Map<String, dynamic> map) => encodeJson(map);
