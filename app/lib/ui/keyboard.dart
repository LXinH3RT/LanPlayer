import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 「返回上一浏览层级」用哪颗键。
///
/// 用户 2026-10-30 要求：按 Backspace 回到上一浏览层级。这里不复用 Escape，
/// 是因为播放页里 Escape 已经承担「退出全屏 / 退出播放」，而列表页没有这个
/// 概念 —— 在列表里按 Backspace，就像在文件管理器里按退格键，退到上一层。
///
/// macOS 键盘上印着 Delete 的那颗键，物理位置就是 Backspace，Flutter 给出的
/// 也是 [LogicalKeyboardKey.backspace]，所以不需要为它再单独映射一次。
bool isBackKey(LogicalKeyboardKey key) => key == LogicalKeyboardKey.backspace;

/// 把按键事件交给某个「退一层」的动作，返回是否需要拦下这个事件。
///
/// 只认 [KeyDownEvent]：按住不放会产生 [KeyRepeatEvent]，一并处理的话
/// 在深目录里按住两秒就直接退到根了，用户来不及看中间那层。
///
/// 页面上有输入框时不用特别判断 —— Flutter 的按键是先从焦点最近的节点
/// 往外冒泡，`TextField` 拿到 Backspace 会自己消费掉（删一个字），不会
/// 传到包裹整页的那个 [Focus]。
KeyEventResult handleBackKey(KeyEvent event, void Function() goBack) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;
  if (!isBackKey(event.logicalKey)) return KeyEventResult.ignored;
  goBack();
  return KeyEventResult.handled;
}
