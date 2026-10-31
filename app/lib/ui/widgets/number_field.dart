import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 设置页里的「填一个数」输入框。
///
/// 用户 2026-10-30 要求把音量、快进快退这两处的滑杆换成直接填数：滑杆在
/// 触控板上很难停到想要的刻度，而且拖动过程中每一帧都改设置会反复落盘。
///
/// 三条约定：
///  * 只在**提交**时回调（`onSubmitted` / 失焦），拖动式的实时改不需要；
///  * 输错不报错弹窗，直接回到上一次生效的值 —— 设置页不是表单，弹窗只会
///    打断操作；
///  * 越界由调用方的 [clamp] 处理，输入框本身不懂业务区间。
class NumberField extends StatefulWidget {
  const NumberField({
    super.key,
    required this.value,
    required this.onChanged,
    this.min,
    this.max,
    this.suffix,
    this.width = 96,
    this.decimals = 0,
  });

  /// 当前值（显示用）。
  final num value;

  /// 提交一个合法值。
  final ValueChanged<int> onChanged;

  final int? min;
  final int? max;

  /// 输入框右边的单位，如「秒」「%」。
  final String? suffix;

  final double width;

  /// 小数位数，0 表示只收整数。
  final int decimals;

  @override
  State<NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<NumberField> {
  late final TextEditingController _controller =
      TextEditingController(text: _format(widget.value));
  late final FocusNode _focus = FocusNode()..addListener(_onFocusChange);

  String _format(num v) => widget.decimals == 0
      ? v.round().toString()
      : v.toStringAsFixed(widget.decimals);

  @override
  void didUpdateWidget(NumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部改了值（比如别处重置设置）才回写，正在输入时不要打断光标。
    if (!_focus.hasFocus && widget.value != oldWidget.value) {
      _controller.text = _format(widget.value);
    }
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed == null) {
      _reset();
      return;
    }
    var v = parsed;
    if (widget.min != null && v < widget.min!) v = widget.min!;
    if (widget.max != null && v > widget.max!) v = widget.max!;
    _controller.text = v.toString();
    widget.onChanged(v);
  }

  void _reset() {
    _controller.text = _format(widget.value);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        textAlign: TextAlign.end,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
        decoration: InputDecoration(
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          border: const OutlineInputBorder(),
          suffixText: widget.suffix,
        ),
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}
