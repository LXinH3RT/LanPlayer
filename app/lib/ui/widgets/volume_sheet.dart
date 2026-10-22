import 'package:flutter/material.dart';

/// 音量面板：滑杆（0–200%）+ 静音开关 + 常用档位。
///
/// 单独抽成 widget 有实际原因：它此前只是底部操作行里的一个
/// `IconButton`，`onPressed` 里只有 `toggleMute()` —— 用户能静音，却
/// 没有任何办法把音量调小或调大。抽出来之后可以用 widget test 真正拖动
/// 滑杆并断言回调，而不是靠在真实桌面上猜坐标截图。
///
/// 这是个**受控组件**：不持有音量状态，值从 [volume] 进来、变化经
/// [onVolumeChanged] / [onMutedChanged] 出去，方便测试与复用。
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

  /// 常用档位。0–2 之间取这六个，覆盖「小声听」到「增强」。
  static const List<double> presets = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0];

  /// 滑杆上限。内核 `lp_player_set_volume` 也是夹到 0–2。
  static const double maxVolume = 2.0;

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
    final pct = (_value * 100).round();
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _muted ? '音量（已静音）' : '音量  $pct%',
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
                    value: _value,
                    max: VolumeSheet.maxVolume,
                    // 0 → 1.0 是最常用的区间，40 档 = 每档 5%。
                    divisions: 40,
                    label: '$pct%',
                    onChanged: _setVolume,
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text('$pct%',
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
                    key: Key('volume-preset-${(preset * 100).round()}'),
                    label: Text('${(preset * 100).round()}%'),
                    selected: (_value - preset).abs() < 0.001,
                    onSelected: (_) => _setVolume(preset),
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
