import 'package:flutter/material.dart';

/// 音量面板：滑杆（显示 0–100）+ 静音开关 + 常用档位。
///
/// 单独抽成 widget 有实际原因：它此前只是底部操作行里的一个
/// `IconButton`，`onPressed` 里只有 `toggleMute()` —— 用户能静音，却
/// 没有任何办法把音量调小或调大。抽出来之后可以用 widget test 真正拖动
/// 滑杆并断言回调，而不是靠在真实桌面上猜坐标截图。
///
/// 这是个**受控组件**：不持有音量状态，值从 [volume] 进来、变化经
/// [onVolumeChanged] / [onMutedChanged] 出去，方便测试与复用。
///
/// 关于刻度：内核的增益是 0–2（2.0 = 200%，会放大到削顶），但界面上不该
/// 出现「150%」这种读法 —— 用户要的是「音量条最大 100」。所以对外显示
/// 一律走 [displayOf] / [volumeOf] 这对映射：显示 0–100 对应增益 0–2.0，
/// 显示 100 就是内核的满增益 200%。
class VolumeSheet extends StatefulWidget {
  const VolumeSheet({
    super.key,
    required this.volume,
    required this.muted,
    required this.onVolumeChanged,
    required this.onMutedChanged,
  });

  /// 当前音量，0.0–2.0（1.0 = 100%，2.0 = 200% 增强）。
  final double volume;
  final bool muted;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<bool> onMutedChanged;

  /// 常用档位，按**显示值**给（0–100）。
  static const List<int> presets = [10, 25, 50, 75, 90, 100];

  /// 滑杆上限增益。内核 `lp_player_set_volume` 也是夹到 0–2。
  static const double maxVolume = 2.0;

  /// 滑杆上显示的满刻度。
  static const int displayMax = 100;

  /// 增益 → 显示值。1.0 增益显示成 50，2.0 显示成 100。
  static int displayOf(double volume) {
    final v = volume.clamp(0.0, maxVolume);
    return (v / maxVolume * displayMax).round();
  }

  /// 显示值 → 增益。100 显示值就是 2.0。
  static double volumeOf(num display) {
    final v = display.clamp(0, displayMax).toDouble();
    return (v / displayMax * maxVolume).clamp(0.0, maxVolume);
  }

  /// 滚轮一格走多少显示刻度。传统滚轮 delta 是 ±100 量级，一格跨 5 个刻度
  /// 正好能从 0 到 100 用二十格走完，不至于滚半天没反应、也不至于一碰就满。
  static const double wheelStep = 5.0;

  /// Flutter 在 Windows 上把一格滚轮报成 `scrollDelta.dy = 60`（实测：滚三格
  /// 正好走过 9 个显示刻度，每格 3），不是原始消息里的 120。换算以实测值为
  /// 准，别照抄 Win32 的 120 —— 那样一格会跳两倍。
  static const double scrollPerNotch = 60.0;

  /// 滚轮增量 → 新增益。
  ///
  /// 往上滚（`scrollDelta.dy < 0`）音量变大，这是桌面播放器的通例。触控板给
  /// 的 delta 是连续的小值，所以按 `dy / scrollPerNotch` 折算成「格」再乘
  /// [wheelStep]，不是简单地按符号加减一格。
  static double wheelVolume(double volume, double scrollDelta) {
    final display = displayOf(volume) + (-scrollDelta / scrollPerNotch) * wheelStep;
    return volumeOf(display);
  }

  @override
  State<VolumeSheet> createState() => _VolumeSheetState();
}

class _VolumeSheetState extends State<VolumeSheet> {
  late double _value = widget.volume.clamp(0.0, VolumeSheet.maxVolume);
  late bool _muted = widget.muted;

  @override
  void didUpdateWidget(covariant VolumeSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.volume != widget.volume) {
      _value = widget.volume.clamp(0.0, VolumeSheet.maxVolume);
    }
    if (oldWidget.muted != widget.muted) {
      _muted = widget.muted;
    }
  }

  void _setVolume(double v) {
    final next = v.clamp(0.0, VolumeSheet.maxVolume);
    setState(() => _value = next);
    widget.onVolumeChanged(next);
    // 拖动滑杆就当作「我要听声音」：自动取消静音，否则用户会以为滑杆坏了。
    if (_muted && next > 0) {
      setState(() => _muted = false);
      widget.onMutedChanged(false);
    }
  }

  void _setDisplay(num display) => _setVolume(VolumeSheet.volumeOf(display));

  void _setMuted(bool m) {
    setState(() => _muted = m);
    widget.onMutedChanged(m);
  }

  IconData get _icon {
    if (_muted || _value == 0) return Icons.volume_off;
    if (_value < 0.5) return Icons.volume_down;
    return Icons.volume_up;
  }

  @override
  Widget build(BuildContext context) {
    final shown = VolumeSheet.displayOf(_value);
    final label = '$shown';
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _muted ? '音量（已静音）' : '音量  $label / ${VolumeSheet.displayMax}',
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 1,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  key: const Key('volume-mute-icon'),
                  tooltip: _muted ? '取消静音' : '静音',
                  icon: Icon(_icon),
                  onPressed: () => _setMuted(!_muted),
                ),
                Expanded(
                  child: Slider(
                    key: const Key('volume-slider'),
                    value: shown.toDouble(),
                    max: VolumeSheet.displayMax.toDouble(),
                    // 40 档 = 每档 2.5 显示值，等值于原来的 5% 增益。
                    divisions: 40,
                    label: label,
                    // 滑杆按显示值走，回调时换算回增益。
                    onChanged: _setDisplay,
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(label,
                      key: const Key('volume-value'),
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.bodyMedium),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Wrap(
              spacing: 8,
              children: [
                for (final preset in VolumeSheet.presets)
                  ChoiceChip(
                    key: Key('volume-preset-$preset'),
                    label: Text('$preset'),
                    selected: shown == preset,
                    onSelected: (_) => _setDisplay(preset),
                  ),
              ],
            ),
          ),
          SwitchListTile(
            key: const Key('volume-mute-switch'),
            secondary: Icon(_muted ? Icons.volume_off : Icons.volume_up),
            title: const Text('静音'),
            value: _muted,
            onChanged: _setMuted,
          ),
        ],
      ),
    );
  }
}
