import 'package:flutter/foundation.dart';

/// 启动初始化的结果。
///
/// 启动分两段：先找可写的状态目录，再把四个 store 读进内存。这两段都可能
/// 失败 —— 存储目录被系统收回、磁盘满、权限策略变了。以前失败只写一行
/// `print`（发布版连这行都看不到），首页于是永远停在「还没读完」的空白上：
/// 用户既不知道出了什么事，也没有任何可以点的东西。
///
/// 这里只记一个「失败原因」，界面据此画出可读的说明与重试按钮。
class BootStatus extends ChangeNotifier {
  BootStatus._();
  static final BootStatus instance = BootStatus._();

  bool _done = false;
  Object? _failure;

  /// 启动初始化结束了吗（成功或失败都算）。
  bool get done => _done;

  /// 失败原因；成功时为 null。
  Object? get failure => _failure;

  /// 重跑启动初始化。由 [main] 在启动时挂上来，首页的重试按钮调它。
  ///
  /// 放在这里而不是让首页自己持有一个回调，是因为首页由 `SplashGate` 的
  /// builder 直接 `const HomeScreen()` 造出来，中间还有一层，逐层传参只会让
  /// 这个「失败也能重试」的能力更难接到。
  Future<void> Function()? retry;

  void succeeded() {
    if (_done && _failure == null) return;
    _done = true;
    _failure = null;
    notifyListeners();
  }

  void failed(Object error) {
    _done = true;
    _failure = error;
    notifyListeners();
  }

  /// 回到「还没跑过」的状态。测试用。
  @visibleForTesting
  void reset() {
    _done = false;
    _failure = null;
    retry = null;
  }
}
