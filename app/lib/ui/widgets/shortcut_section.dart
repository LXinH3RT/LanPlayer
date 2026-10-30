import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/shortcuts.dart';
import '../theme.dart';

/// 录制结果：要么绑到一颗键，要么是「清除绑定」。
class ShortcutPick {
  const ShortcutPick.key(LogicalKeyboardKey this.key) : cleared = false;
  const ShortcutPick.cleared()
      : key = null,
        cleared = true;

  final LogicalKeyboardKey? key;
  final bool cleared;
}

/// 「按下任意键」的录制对话框。
///
/// 做法：整块铺一个 `Focus` 吃 `onKeyEvent`，按下就把键交出去并关上对话框。
/// 为什么不复用播放页的 `KeyReleaseTrigger`：那里要求「抬起才执行」是为了
/// 避免长按连发；改键恰恰要抓**按下**那一刻，而且必须能捕获 Tab / Esc 这种
/// 平时会被导航消费的键，所以用 `KeyEventResult.handled` 全部拦住。
class ShortcutRecorder extends StatefulWidget {
  const ShortcutRecorder({super.key, required this.action, this.current});

  final ShortcutAction action;
  final LogicalKeyboardKey? current;

  /// 返回 `null` 表示用户取消。
  ///
  /// 「取消」和「清除绑定」都要能从对话框传回来，而 `showDialog` 的 `null`
  /// 只能表示一件事，所以用一个小的结果类型区分两者 —— 拿 keyId 0 之类
  /// 的哨兵键来冒充「清除」迟早会和真实键撞上。
  static Future<ShortcutPick?> show(BuildContext context,
      ShortcutAction action, LogicalKeyboardKey? current) {
    return showDialog<ShortcutPick>(
      context: context,
      builder: (_) => ShortcutRecorder(action: action, current: current),
    );
  }

  @override
  State<ShortcutRecorder> createState() => _ShortcutRecorderState();
}

class _ShortcutRecorderState extends State<ShortcutRecorder> {
  String? _hint;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    // 只按了修饰键：告诉用户还不够，别把 Shift 本身绑上去。
    if (_isModifier(key)) {
      setState(() => _hint = '还差一个主键 —— 比如 Shift + P');
      return KeyEventResult.handled;
    }
    Navigator.of(context).pop(ShortcutPick.key(key));
    return KeyEventResult.handled;
  }

  static bool _isModifier(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.shiftLeft ||
      key == LogicalKeyboardKey.shiftRight ||
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.altLeft ||
      key == LogicalKeyboardKey.altRight ||
      key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: AlertDialog(
        title: Text('录制「${widget.action.label}」'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('按下要绑定的键。',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            Text(
              widget.current == null
                  ? '当前未绑定'
                  : '当前：${ShortcutBindings.label(widget.current!)}',
              style: theme.textTheme.titleMedium,
            ),
            if (_hint != null) ...[
              const SizedBox(height: 10),
              Text(_hint!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(const ShortcutPick.cleared()),
            child: const Text('清除绑定'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }
}

/// 设置页里的「快捷键」整段：键盘绑定表 + 鼠标手势说明。
class ShortcutSection extends StatelessWidget {
  const ShortcutSection({
    super.key,
    required this.bindings,
    required this.onBind,
    required this.onResetAll,
  });

  final ShortcutBindings bindings;
  final void Function(ShortcutAction action, LogicalKeyboardKey? key) onBind;
  final VoidCallback onResetAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  bindings.isDefault
                      ? '键盘快捷键，全部是出厂设置。'
                      : '键盘快捷键，已按你的设置改过。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              TextButton(
                onPressed: bindings.isDefault ? null : onResetAll,
                child: const Text('全部恢复默认'),
              ),
            ],
          ),
        ),
        for (final group in ShortcutGroup.values) ...[
          if (ShortcutAction.values.any((a) => a.group == group)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
              child: Text(
                group.title,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  letterSpacing: 1.1,
                ),
              ),
            ),
            for (final action in ShortcutAction.values)
              if (action.group == group) _row(context, action),
          ],
        ],
        const Divider(height: 28),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
          child: Text(
            '鼠标与触控手势（固定，不可改）',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
              letterSpacing: 1.1,
            ),
          ),
        ),
        for (final g in PointerGesture.all)
          ListTile(
            dense: true,
            title: Text(g.gesture),
            subtitle: Text(g.effect),
            trailing: const Icon(Icons.lock_outline, size: 16),
          ),
      ],
    );
  }

  Widget _row(BuildContext context, ShortcutAction action) {
    final key = bindings.keyFor(action);
    final changed = bindings.isDefault == false &&
        (key != action.defaultKey);
    return ListTile(
      title: Text(action.label),
      subtitle: changed && action.defaultKey != null
          ? Text('出厂：${ShortcutBindings.label(action.defaultKey!)}')
          : null,
      trailing: TextButton(
        onPressed: () async {
          final picked = await ShortcutRecorder.show(context, action, key);
          if (picked == null) return;
          onBind(action, picked.cleared ? null : picked.key);
        },
        child: Text(
          key == null ? '未绑定' : ShortcutBindings.label(key),
          style: key == null
              ? const TextStyle(color: LanPlayerTheme.accent)
              : null,
        ),
      ),
    );
  }
}
