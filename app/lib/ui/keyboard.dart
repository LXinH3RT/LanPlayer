import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 全应用统一的键盘触发时机：**按键抬起时才执行**。
///
/// 用户 2026-10-30 要求：所有键盘按键触发的逻辑都改成抬起后触发，
/// 长按或按下不抬起不产生任何效果。
///
/// 为什么统一到抬起：
///   * 按下即触发的话，长按期间系统反复发 [KeyRepeatEvent]，退层、切轨
///     这类动作会被连续执行，深目录里按住两秒直接退到根；
///   * 按下即触发还有个「按下后又反悔」的窗口 —— 抬起才执行时，用户
///     按住期间改变主意直接松手，不会误触。
///
/// 实现要点：
///   * [KeyDownEvent] 一律返回 handled 但**不执行**。返回 ignored 会让事件
///     继续冒泡给上层 Focus 或系统默认行为（比如空格滚动列表），同一颗键
///     就被两处响应了。
///   * [KeyRepeatEvent] 同样 handled 而不执行。
///   * 只有 [KeyUpEvent] 才真正跑动作，而且要自己记住「按下时是不是这颗
///     键」—— 焦点可能是在按住期间才转移过来的，那种松手不该算一次触发。
class KeyReleaseTrigger {
  KeyReleaseTrigger(this._expected);

  /// 哪些键归这个触发器管。
  final bool Function(LogicalKeyboardKey key) _expected;

  /// 已经按下、还没抬起的键。多个键同时按住时都要记，否则先后松手会乱。
  final Set<LogicalKeyboardKey> _held = {};

  /// 喂一个按键事件；[fire] 是抬起时执行的动作。
  ///
  /// 返回 [KeyEventResult.handled] 时这个事件不会再往下传递。
  KeyEventResult handle(
      KeyEvent event, void Function(LogicalKeyboardKey key) fire) {
    final key = event.logicalKey;
    if (!_expected(key)) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      _held.add(key);
      // 先记下，不动作：等抬起。
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) {
      // 长按重复一律吞掉，不执行。
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      if (!_held.remove(key)) {
        // 焦点在按住期间才过来的，这次松手不算数。
        return KeyEventResult.handled;
      }
      fire(key);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 页面失焦时清空按住状态。
  ///
  /// 不清理的话：按住空格切走窗口，回来再按一次空格松手，会被当成
  /// 「第一次」的抬起而触发一次莫名其妙的重播。
  void reset() => _held.clear();
}

/// 「返回上一浏览层级」用哪颗键。
///
/// 用户 2026-10-30 要求：按 Backspace 回到上一浏览层级。这里不复用 Escape，
/// 是因为播放页里 Escape 已经承担「退出全屏 / 退出播放」，而列表页没有这个
/// 概念 —— 在列表里按 Backspace，就像在文件管理器里按退格键，退到上一层。
///
/// macOS 键盘上印着 Delete 的那颗键，物理位置就是 Backspace，Flutter 给出的
/// 也是 [LogicalKeyboardKey.backspace]，所以不需要为它再单独映射一次。
bool isBackKey(LogicalKeyboardKey key) => key == LogicalKeyboardKey.backspace;

/// Backspace → 退一层。触发时机由 [KeyReleaseTrigger] 统一决定：抬起才退。
///
/// 页面上有输入框时不用特别判断 —— Flutter 的按键先从焦点最近的节点往外
/// 冒泡，`TextField` 拿到 Backspace 会自己消费掉（删一个字），不会传到包裹
/// 整页的那个 `Focus`。
class BackKeyHandler {
  final KeyReleaseTrigger _trigger = KeyReleaseTrigger(isBackKey);

  KeyEventResult handle(KeyEvent event, void Function() goBack) =>
      _trigger.handle(event, (_) => goBack());

  /// 页面失焦时调用，丢掉「按住中」的记录。
  void reset() => _trigger.reset();
}
