import 'package:flutter/material.dart';

import '../core/bindings.dart';
import '../data/models.dart' show kLanguageOptions;
import '../data/stores.dart';
import 'widgets/volume_sheet.dart' show VolumeSheet;

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
            // 和播放页的音量面板用同一套刻度：滑杆上显示 0–100，内部存
            // 0–2.0 的增益。两处口径不一致的话，用户会以为设置没生效。
            subtitle: Slider(
              value: VolumeSheet.displayOf(_settings.volume).toDouble(),
              max: VolumeSheet.displayMax.toDouble(),
              divisions: 20,
              label: VolumeSheet.displayOf(_settings.volume).toString(),
              onChanged: (v) {
                setState(() => _settings.volume = VolumeSheet.volumeOf(v));
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
          _TrackLangTile(
            title: '首选音轨语言',
            hint: '多音轨的片子按这个顺序挑。选「自动」就跟随文件自己的默认轨。',
            value: _settings.audioPreference.primary,
            onChanged: (v) {
              setState(() => _settings.audioPreference =
                  _settings.audioPreference.copyWith(primary: v));
              _persist();
            },
          ),
          _TrackLangTile(
            title: '次选音轨语言',
            hint: '首选语言在文件里找不到时用这个；再找不到才用文件默认。',
            allowUnset: true,
            value: _settings.audioPreference.secondary,
            onChanged: (v) {
              setState(() => _settings.audioPreference =
                  _settings.audioPreference.copyWith(secondary: v));
              _persist();
            },
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
          _TrackLangTile(
            title: '首选字幕语言',
            hint: '内嵌多条字幕时按这个挑。找不到首选就用次选，再找不到用文件默认。',
            value: _settings.subtitlePreference.primary,
            onChanged: (v) {
              setState(() => _settings.subtitlePreference =
                  _settings.subtitlePreference.copyWith(primary: v));
              _persist();
            },
          ),
          _TrackLangTile(
            title: '次选字幕语言',
            hint: '首选语言不存在时用这个。',
            allowUnset: true,
            value: _settings.subtitlePreference.secondary,
            onChanged: (v) {
              setState(() => _settings.subtitlePreference =
                  _settings.subtitlePreference.copyWith(secondary: v));
              _persist();
            },
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

/// 「首选/次选语言」选择项：点开是一个下拉，列出常见语言。
///
/// 用 DropdownButton 而不是 RadioListTile 堆一列：语言有十来种，堆成单选
/// 会把设置页拉得很长，而这里本来就是个低频设置。
class _TrackLangTile extends StatelessWidget {
  const _TrackLangTile({
    required this.title,
    required this.hint,
    required this.value,
    required this.onChanged,
    this.allowUnset = false,
  });

  final String title;
  final String hint;
  final String value;
  final ValueChanged<String> onChanged;

  /// 次选语言允许「不设」，显示成「未设置」。
  final bool allowUnset;

  @override
  Widget build(BuildContext context) {
    // 注意：DropdownButton 要求 value 必须能在 items 里找到，否则直接断言失败。
    // 所以次选这一档不能把 'auto' 从 items 里剔掉 —— 剔掉之后既有配置里存的
    // 'auto' 就会把设置页整个打崩。改成保留在下拉里、只是文案显示为「未设置」。
    final unset = value.isEmpty || value == 'auto';
    // 还得挡住「配置里存了表上没有的码」（手改配置文件、或以后缩了语言表），
    // 否则 DropdownButton 一样会断言失败。
    final known = kLanguageOptions.any((o) => o.code == value);
    final selected = unset || !known ? 'auto' : value;
    return ListTile(
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hint, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          DropdownButton<String>(
            value: selected,
            isExpanded: true,
            items: [
              for (final o in kLanguageOptions)
                if (!(allowUnset && o.code == 'auto'))
                  DropdownMenuItem<String>(
                    value: o.code,
                    child: Text(o.label),
                  ),
              if (allowUnset)
                const DropdownMenuItem<String>(
                  value: 'auto',
                  child: Text('未设置'),
                ),
            ],
            onChanged: (v) => onChanged(v ?? 'auto'),
          ),
        ],
      ),
    );
  }
}
