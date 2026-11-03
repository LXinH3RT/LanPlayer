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
    this.width = 96,
  });

  /// 当前值（显示用）。
  final num value;

  /// 提交一个合法值。
  final ValueChanged<int> onChanged;

  final int? min;
  final int? max;

  /// 输入框右边的单位，如「秒」「%」。

  final double width;

  @override
  State<NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<NumberField> {
  late final TextEditingController _controller =
      TextEditingController(text: _format(widget.value));
  late final FocusNode _focus = FocusNode()..addListener(_onFocusChange);

  /// 只收整数：这个输入框用到的地方（快进快退步长、字幕延迟…）都是整数量。
  /// 曾经留过一个 `decimals` 参数，但输入框固定挂着 `digitsOnly`，小数点
  /// 根本敲不进去，那个参数没人读 —— 已删掉，需要小数请用下拉框。
  String _format(num v) => v.round().toString();

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
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}
