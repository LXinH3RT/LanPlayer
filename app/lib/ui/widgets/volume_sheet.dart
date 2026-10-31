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
    this.onVolumeCommitted,
  });

  /// 当前音量，0.0–2.0（1.0 = 100%，2.0 = 200% 增强）。
  final double volume;
  final bool muted;

  /// 音量**正在**变化：滑杆每动一档、滚轮每滚一格都会来一次。
  /// 只该用来即时改内核增益与重绘，不要在里面落盘。
  final ValueChanged<double> onVolumeChanged;

  /// 音量**改完了**：松手、点档位、滚轮停下时来一次。
  ///
  /// 落盘只挂这里。以前把它挂在 [onVolumeChanged] 上，拖一次滑杆会连发几十
  /// 次 save()，几次写入互相截断同一个 `.tmp` 后落盘的可能是半截 JSON。
  final ValueChanged<double>? onVolumeCommitted;

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

  /// 键盘上下键按一次走多少显示刻度。
  ///
  /// 曾经这里和滚轮各走各的：键盘是 `_nudgeVolume(±0.05)`（2.5 个显示刻度），
  /// 滚轮是一格 5 个，滑杆一档又是 2.5 个。同一个「调大一点」，三条路径给出
  /// 三个幅度，用户按十下键盘才等于滚五下滚轮。现在键与滚轮统一成
  /// [wheelStep]，滑杆一档是它的一半（[sliderDivisions] 的粒度）。
  static const double keyStep = wheelStep;

  /// 滑杆分几档。40 档 = 每档 2.5 个显示刻度 = 5% 增益。
  static const int sliderDivisions = 40;

  /// Flutter 在 Windows 上把一格滚轮报成 `scrollDelta.dy = 60`（原始消息是
  /// 120，Flutter 折了一半）。换算以实测值为准，别照抄 Win32 的 120 ——
  /// 那样一格会跳两倍，滚两下就满。
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
                    // 40 档 = 每档 2.5 显示值，等值于 5% 增益。滚轮/键盘
                    // 一格是它的两倍（[wheelStep]），三条路径步长同源。
                    divisions: VolumeSheet.sliderDivisions,
                    label: label,
                    // 滑杆按显示值走，回调时换算回增益。
                    onChanged: _setDisplay,
                    // 松手才落盘（见 onVolumeCommitted 的注释）。
                    onChangeEnd: (display) =>
                        widget.onVolumeCommitted?.call(
                            VolumeSheet.volumeOf(display)),
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
                    onSelected: (_) {
                      _setDisplay(preset);
                      widget.onVolumeCommitted?.call(_value);
                    },
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
