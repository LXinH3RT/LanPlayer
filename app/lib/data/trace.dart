import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'probe.dart';

/// 排查用的运行日志：只在 `--dart-define=LANPLAYER_TRACE=1` 的包里生效。
///
/// iOS 上 `--console` 拿不到 Dart 的 `print`，要看清「谁把路由弹掉了」
/// 只能自己写文件，再从 Mac 侧挂载的应用容器里读回来。默认包不带这个开关，
/// [trace] 在没有日志文件时直接返回，留下的调用点只是几行空函数。
///
/// 现在已经查明的事情（见 `ui/add_sheet.dart` 与 AgentsReadMe）：iPadOS 上
/// 弹层会自己收回，`TraceObserver` 的栈加 [installPointerTrace] 记下的
/// `(0,0)` 指针事件才把根因和「代码主动 pop」「用户点遮罩」区分开。
bool get traceEnabled => probeFlag('LANPLAYER_TRACE') == '1';

File? _file;

/// 指定日志文件（启动时把状态目录拿到之后调用一次）。
void traceTo(String path) {
  if (!traceEnabled) return;
  _file = File(path);
}

/// 是否已经有日志文件了。`LANPLAYER_TRACE_PATH` 先设定时，[traceTo] 的
/// 默认位置不再覆盖它。
bool get traceHasFile => _file != null;

/// 超过这个大小就从头重写，避免长时间开着 trace 把设备塞满。
const int traceMaxBytes = 8 << 20;

int _written = 0;

void trace(String message) {
  if (!traceEnabled) return;
  final file = _file;
  if (file == null) return;
  final line = '${DateTime.now().toIso8601String()} $message\n';
  _written += line.length;
  try {
    if (_written > traceMaxBytes) {
      /* 轮转：不是追加而是覆盖，写的还是同一份路径 —— 抓日志的脚本不必
       * 关心文件名会变。丢掉的只是旧的现场，最近这一段才是要看的。 */
      _written = line.length;
      file.writeAsStringSync('--- trace rotated ---\n$line', flush: true);
      return;
    }
    file.writeAsStringSync(line, mode: FileMode.append, flush: true);
  } catch (_) {
    // 日志失败绝不影响主流程。
  }
}

/// 把导航栈上发生的每一次 push / pop / remove / replace 都记下来。
class TraceObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    trace('push ${route.runtimeType} on ${previousRoute.runtimeType}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    trace('pop ${route.runtimeType} back to ${previousRoute.runtimeType}\n'
        '${_caller()}');
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    trace('remove ${route.runtimeType} on ${previousRoute.runtimeType}\n'
        '${_caller()}');
  }

  /// 摘出「谁调用了 pop」。
  ///
  /// 早先只留第一条 `package:lanplayer/` 的帧，结果那条永远是本文件里的
  /// `_caller` 自己 —— 等于什么都没记。改成跳过本文件的帧，再把剩下
  /// 前若干条完整留下：遮罩点击、下滑关闭、代码里主动 pop 这三种来源
  /// 的栈长得完全不一样，一眼就能分开。
  String _caller() {
    final frames = StackTrace.current.toString().split('\n');
    final kept = <String>[];
    for (final line in frames) {
      if (line.contains('package:lanplayer/data/trace.dart')) continue;
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      kept.add('    $trimmed');
      if (kept.length >= 14) break;
    }
    if (kept.isEmpty) return '  at (framework)';
    return '  stack:\n${kept.join('\n')}';
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    trace('replace ${oldRoute?.runtimeType} -> ${newRoute?.runtimeType}');
  }
}

/// 只记窗口尺寸与前后台切换，用来分辨「是系统把界面弄没了」还是「代码里 pop 了」。
class TraceLifecycle extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    trace('lifecycle $state');
  }

  @override
  void didChangeMetrics() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    trace('metrics ${view.physicalSize} dpr=${view.devicePixelRatio}');
  }
}

/// 记每一帧的构建与光栅耗时。
///
/// 只覆盖「UI 有更新的帧」。视频播放本身不产生 `FrameTiming` ——
/// 外部纹理由引擎直接合成，不经过 widget 重建 —— 所以这里的数据用来判断
/// 「界面线程有没有被拖慢」，不能用来解释视频本身的卡顿。iPad 上实测
/// `worst_total` 12 ms、`slow` 0，说明卡顿不在 Dart 这一侧。
///
/// 每秒汇总一次，避免每帧写一行把 IO 本身变成噪声源。
class _FrameTrace {
  int _frames = 0;
  int _buildUs = 0;
  int _rasterUs = 0;
  int _worstBuildUs = 0;
  int _worstRasterUs = 0;
  int _worstTotalUs = 0;
  int _slow = 0;
  int _flushedAtMs = 0;

  void add(List<FrameTiming> timings) {
    for (final t in timings) {
      _frames++;
      final build = t.buildDuration.inMicroseconds;
      final raster = t.rasterDuration.inMicroseconds;
      final total = t.totalSpan.inMicroseconds;
      _buildUs += build;
      _rasterUs += raster;
      if (build > _worstBuildUs) _worstBuildUs = build;
      if (raster > _worstRasterUs) _worstRasterUs = raster;
      if (total > _worstTotalUs) _worstTotalUs = total;
      // 一帧的正常预算按 60 Hz 算就是 16.7 ms，超过它必然错过一次 vsync。
      if (total > 16667) _slow++;
    }
    // 用墙钟节流：累加帧时长在「每秒只有零星几帧」时会迟迟不到一秒。
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_flushedAtMs == 0) _flushedAtMs = now;
    if (now - _flushedAtMs < 1000 || _frames == 0) return;
    _flushedAtMs = now;
    trace('frame n=$_frames avg_build=${_buildUs ~/ _frames}us '
        'avg_raster=${_rasterUs ~/ _frames}us '
        'worst_build=${_worstBuildUs}us worst_raster=${_worstRasterUs}us '
        'worst_total=${_worstTotalUs}us slow=$_slow');
    _frames = 0;
    _buildUs = 0;
    _rasterUs = 0;
    _worstBuildUs = 0;
    _worstRasterUs = 0;
    _worstTotalUs = 0;
    _slow = 0;
  }
}

_FrameTrace? _frameTrace;

void installFrameTrace() {
  if (!traceEnabled || _frameTrace != null) return;
  final collector = _frameTrace = _FrameTrace();
  SchedulerBinding.instance.addTimingsCallback(collector.add);
}

/// 记全局指针事件。
///
/// 弹层「自己收回」有两种来源长得很像：真的有人点在遮罩上，或者代码里
/// 主动 pop。把每一次按下/抬起都记下来，就能对上「pop 前 350 毫秒里到底
/// 有没有一次指针抬起」。只用 [PointerRouter.addGlobalRoute]，不参与命中
/// 测试，所以不影响任何交互。
bool _pointerTraceInstalled = false;

void installPointerTrace() {
  if (!traceEnabled || _pointerTraceInstalled) return;
  _pointerTraceInstalled = true;
  GestureBinding.instance.pointerRouter.addGlobalRoute(_logPointerEvent);
}

void _logPointerEvent(PointerEvent event) {
  if (event is PointerDownEvent) {
    trace('pointer down #${event.pointer} ${event.kind.name} '
        '${event.position.dx.toStringAsFixed(1)},'
        '${event.position.dy.toStringAsFixed(1)}');
  } else if (event is PointerUpEvent) {
    trace('pointer up #${event.pointer} ${event.kind.name} '
        '${event.position.dx.toStringAsFixed(1)},'
        '${event.position.dy.toStringAsFixed(1)}');
  } else if (event is PointerCancelEvent) {
    trace('pointer cancel #${event.pointer} ${event.kind.name}');
  }
}
