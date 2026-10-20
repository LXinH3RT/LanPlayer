import 'package:flutter/material.dart';

import '../core/bindings.dart';
import '../data/stores.dart';

/// Module 4: the knobs advanced users reach for when a file misbehaves.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _settings = SettingsStore.instance.value;

  Future<void> _persist() async {
    await SettingsStore.instance.save();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final abi = _safeAbi();
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const _Section('解码'),
          SwitchListTile(
            value: _settings.hardwareDecoding,
            title: const Text('硬件解码'),
            subtitle: const Text('关闭后强制使用 FFmpeg 软件解码，用于排查花屏/绿屏问题。'
                '切换后需要重新打开视频。'),
            onChanged: (v) {
              _settings.hardwareDecoding = v;
              _persist();
            },
          ),
          SwitchListTile(
            value: _settings.deinterlace,
            title: const Text('去隔行（yadif）'),
            subtitle: const Text('仅对隔行扫描的片源生效，逐行片源不会额外消耗。'),
            onChanged: (v) {
              _settings.deinterlace = v;
              _persist();
            },
          ),
          const _Section('画面'),
          for (final (label, hint, mode) in [
            ('适应屏幕', '保持比例，上下或左右留黑边', 0),
            ('铺满裁切', '填满屏幕，超出部分裁掉', 1),
            ('拉伸', '忽略原始比例（不推荐）', 2),
          ])
            RadioListTile<int>(
              value: mode,
              groupValue: _settings.scaleMode,
              title: Text(label),
              subtitle: Text(hint),
              onChanged: (v) {
                _settings.scaleMode = v ?? 0;
                _persist();
              },
            ),
          const _Section('音频'),
          ListTile(
            title: const Text('默认音量'),
            subtitle: Slider(
              value: _settings.volume,
              max: 2.0,
              divisions: 20,
              label: '${(_settings.volume * 100).round()}%',
              onChanged: (v) {
                setState(() => _settings.volume = v);
              },
              onChangeEnd: (_) => _persist(),
            ),
          ),
          ListTile(
            title: const Text('默认倍速'),
            subtitle: Slider(
              value: _settings.speed,
              min: 0.5,
              max: 2.0,
              divisions: 6,
              label: '${_settings.speed}x',
              onChanged: (v) => setState(() => _settings.speed = v),
              onChangeEnd: (_) => _persist(),
            ),
          ),
          const _Section('字幕'),
          ListTile(
            title: const Text('字幕大小'),
            subtitle: Slider(
              value: _settings.subtitleScale,
              min: 0.6,
              max: 2.0,
              divisions: 14,
              label: '${(_settings.subtitleScale * 100).round()}%',
              onChanged: (v) => setState(() => _settings.subtitleScale = v),
              onChangeEnd: (_) => _persist(),
            ),
          ),
          ListTile(
            title: const Text('字幕延迟'),
            subtitle: Slider(
              value: _settings.subtitleDelayMs.toDouble(),
              min: -5000,
              max: 5000,
              divisions: 100,
              label:
                  '${(_settings.subtitleDelayMs / 1000).toStringAsFixed(1)} s',
              onChanged: (v) =>
                  setState(() => _settings.subtitleDelayMs = v.round()),
              onChangeEnd: (_) => _persist(),
            ),
          ),
          const _Section('连播'),
          SwitchListTile(
            value: _settings.autoNext,
            title: const Text('当前目录自动连播'),
            subtitle: const Text('一集结束后自动播放同目录的下一集，按 SxxExx / 第 N 集 识别顺序。'),
            onChanged: (v) {
              _settings.autoNext = v;
              _persist();
            },
          ),
          SwitchListTile(
            value: _settings.rememberProgress,
            title: const Text('记忆上次播放位置'),
            subtitle: const Text('再次打开同一个视频时，从上次看到的位置继续播放。'
                '关闭后不再记录进度，已保存的历史仍会保留。'),
            onChanged: (v) {
              _settings.rememberProgress = v;
              _persist();
            },
          ),
          const _Section('关于'),
          ListTile(
            title: const Text('播放内核 ABI'),
            subtitle: Text(abi == null ? '未能加载原生库' : 'v$abi（期望 v$abiVersion）'),
            trailing: Icon(
              abi == abiVersion ? Icons.verified : Icons.warning_amber,
              color:
                  abi == abiVersion ? Colors.greenAccent : Colors.orangeAccent,
            ),
          ),
          const ListTile(
            title: Text('解码内核'),
            subtitle: Text('FFmpeg 6.1+ · 音频 float32 主时钟同步 · SMB 传输基于 libsmb2'),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              '提示：图形字幕（PGS/VobSub/DVB）由内核直接解码后叠加到画面上，'
              '无需外挂；文本字幕支持 SRT/ASS，ASS 的粗体、斜体、颜色、字号、'
              '定位等样式会一并渲染。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  int? _safeAbi() {
    try {
      return NativeCore.instance.version;
    } catch (_) {
      return null;
    }
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            letterSpacing: 1.2,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
}
