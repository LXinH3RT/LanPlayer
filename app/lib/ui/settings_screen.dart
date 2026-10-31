import 'package:flutter/material.dart';

import '../core/bindings.dart';
import '../data/build_info.dart';
import '../data/models.dart' show PlaybackSettings, kLanguageOptions;
import '../data/probe.dart';
import '../data/stores.dart';
import '../data/thumbs.dart' show ThumbnailCache;
import 'widgets/number_field.dart';
import 'widgets/shortcut_section.dart';
import 'widgets/volume_sheet.dart' show VolumeSheet;

/// 设置页的分类。左侧目录、右侧内容，两侧都由这张表驱动。
///
/// 顺序就是用户从「最常动的」到「最少动的」的直觉顺序；「关于」固定压尾。
enum SettingsTab {
  decode('解码'),
  picture('画面'),
  audio('音频'),
  subtitle('字幕'),
  progress('进度'),
  autoplay('连播'),
  shortcuts('快捷键'),
  about('关于');

  const SettingsTab(this.label);

  final String label;

  /// 目录项自己的定位键。测试与真机脚本靠它点，不靠文案 —— 文案里
  /// 「字幕」同时是快捷键分组名，按文字点到的是哪一个说不清。
  Key get tabKey => ValueKey('settings-tab-$name');

  /// 目录项与正文标题共用的字号来源。
  ///
  /// 用户要求「目录标题和正文采用统一的字体字号」：以前分类标题是 12px
  /// 加字距的另一套样式，扫一眼就知道它和正文不是一家。现在两侧都取
  /// 主题里的 `titleMedium` —— Material 给 ListTile 标题用的就是这一项。
  /// 字体跟着全局的 MiSans 走，页面里不再另写 fontSize。
  TextStyle? textStyle(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium;
}

/// Module 4: the knobs advanced users reach for when a file misbehaves.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.initialTab});

  /// 打开时落在哪一格。默认是「解码」。
  ///
  /// 存在的意义是给测试和验证脚本一个确定的起点：设置页现在是分栏的，
  /// 一次只构建一格，不指定的话断言得先模拟点一次目录，纯属噪声。
  final SettingsTab? initialTab;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _settings = SettingsStore.instance.value;
  final _scroll = ScrollController();

  /// 当前选中的目录。默认落在第一项，和「打开设置先看到解码」的老习惯一致。
  late SettingsTab _tab = widget.initialTab ?? SettingsTab.decode;

  @override
  void initState() {
    super.initState();
    // 验证钩子：移动端没有输入注入手段（devicectl 只能截图和启停进程），
    // 「关于」在目录最下面，没有这个开关就没法在真机上给它留证据。
    //   LANPLAYER_SETTINGS_SCROLL=end
    if (probeFlag('LANPLAYER_SETTINGS_SCROLL') == 'end') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _select(SettingsTab.about, jumpToEnd: true);
      });
    }
    // 分栏之后一次只构建一格，真机脚本靠点坐标翻页太脆（窗口一旦失焦，
    // 后续几次点击就落到别处去了）。这个开关让它直接落在指定那一格：
    //   LANPLAYER_SETTINGS_TAB=audio|subtitle|shortcuts|about|...
    final wantTab = probeFlag('LANPLAYER_SETTINGS_TAB');
    if (wantTab != null) {
      final hit = SettingsTab.values.firstWhere(
        (t) => t.name == wantTab,
        orElse: () => _tab,
      );
      _tab = hit;
    }
  }

  @override
  void didUpdateWidget(SettingsScreen old) {
    super.didUpdateWidget(old);
    // 同一个 State 被复用、而外面换了 initialTab 时也要跟着翻页。
    // `late _tab` 只会初始化一次，不在这里同步的话，第二次挂载看到的
    // 还是上一格。
    final want = widget.initialTab;
    if (want != null && want != old.initialTab) {
      _tab = want;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _select(SettingsTab tab, {bool jumpToEnd = false}) {
    setState(() => _tab = tab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      // 换目录后从顶上开始看，除非探针明确要求跳到底。
      final target = jumpToEnd ? _scroll.position.maxScrollExtent : 0.0;
      _scroll.jumpTo(target);
    });
  }

  Future<void> _persist() async {
    await SettingsStore.instance.save();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: LayoutBuilder(
        builder: (context, box) {
          // 窄屏（手机竖屏）放不下 220 的侧栏，改成顶部横滑的目录条：
          // 目录还在，只是从竖排变横排，不去掉。
          final wide = box.maxWidth >= 720;
          final body = _pane(context);
          if (!wide) {
            return Column(
              children: [
                _TabStrip(current: _tab, onSelect: _select),
                const Divider(height: 1),
                Expanded(child: body),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 220,
                child: _TabRail(current: _tab, onSelect: _select),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ],
          );
        },
      ),
    );
  }

  /// 右侧内容区。只构建当前目录的那几行 —— 以前整页是同一个 ListView，
  /// 在手机上滚到「关于」要经过七八屏。
  Widget _pane(BuildContext context) {
    final abi = _safeAbi();
    return ListView(
      // 跟着目录换 key：换目录等于换一页，滚动位置跟着归零。
      key: ValueKey('settings-pane-${_tab.name}'),
      controller: _scroll,
      padding: const EdgeInsets.only(top: 8, bottom: 32),
      children: [
        for (final w in _rowsFor(_tab, abi)) w,
      ],
    );
  }

  List<Widget> _rowsFor(SettingsTab tab, int? abi) {
    switch (tab) {
      case SettingsTab.decode:
        return [
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
          // 封面缓存没有过期时间，删掉的片子、换过的服务器都会留下文件。
          // 以前 `ThumbnailCache.clear()` 写好了却没有任何入口，用户只能
          // 去翻本地目录手动删 —— 这里补上。
          const _ClearThumbCacheTile(),
        ];

      case SettingsTab.picture:
        return [
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
        ];

      case SettingsTab.audio:
        return [
          ListTile(
            title: const Text('默认音量'),
            // 和播放页的音量面板用同一套刻度：显示 0–100，内部存 0–2.0 的
            // 增益。两处口径不一致的话，用户会以为设置没生效。
            //
            // 文案要按**显示值**说：100 是满刻度（增益 2.0，会削顶），
            // 原音量（增益 1.0）在显示刻度上是 50。以前这里写的是
            // 「100 为原音量，上限 200」，与实际映射正好反过来。
            subtitle: const Text('开片时的音量；50 为原音量，上限 100（再高会削顶）。'),
            trailing: NumberField(
              value: VolumeSheet.displayOf(_settings.volume),
              min: 0,
              max: VolumeSheet.displayMax,
              suffix: '%',
              onChanged: (v) {
                setState(() => _settings.volume = VolumeSheet.volumeOf(v));
                _persist();
              },
            ),
          ),
          ListTile(
            title: const Text('默认倍速'),
            subtitle: const Text('开片时的速度；播放页的倍速按钮用同一组档位。'),
            // 下拉而不是滑杆：档位是固定的八档，滑杆能拖出 1.3 这种值，
            // 播放页那边按档位精确匹配就一个都不选中。
            trailing: DropdownButton<double>(
              value: PlaybackSettings.clampSpeed(_settings.speed),
              underline: const SizedBox.shrink(),
              items: [
                for (final s in PlaybackSettings.speedSteps)
                  DropdownMenuItem<double>(value: s, child: Text('${s}x')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _settings.speed = v);
                _persist();
              },
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
        ];

      case SettingsTab.subtitle:
        return [
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
        ];

      case SettingsTab.progress:
        return [
          // 填数而不是滑杆/下拉：步长是 1..10 的整数，直接输比拖滑杆快。
          // 越界与非法输入由 NumberField 夹到 [seekStepMin, seekStepMax]，
          // 模型层 fromJson 里还有一道 clamp，手改 settings.json 也绕不过。
          ListTile(
            title: const Text('快进 / 快退步长'),
            subtitle: const Text('播放页的按钮与方向键一次跳过这么多秒'
                '（1–10）。'),
            trailing: NumberField(
              value: _settings.seekStepSeconds,
              min: PlaybackSettings.seekStepMin,
              max: PlaybackSettings.seekStepMax,
              suffix: '秒',
              onChanged: (v) {
                setState(() => _settings.seekStepSeconds =
                    PlaybackSettings.clampSeekStep(v));
                _persist();
              },
            ),
          ),
        ];

      case SettingsTab.autoplay:
        return [
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
        ];

      case SettingsTab.shortcuts:
        // 键盘绑定 + 鼠标手势都列在这里。手势是固定的（画面上的单击/双击
        // /长按由 GestureDetector 的位置判定决定），所以只展示不给改 ——
        // 用户要求「所有快捷键都在设置里列出来」，也包括这些。
        return [
          ShortcutSection(
            bindings: _settings.shortcuts,
            onBind: (action, key) {
              final steal = key == null
                  ? null
                  : _settings.shortcuts.conflictFor(action, key);
              setState(() {
                _settings.shortcuts = _settings.shortcuts.bind(action, key);
              });
              _persist();
              if (steal != null && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('「${steal.label}」原来的键被拿走了，已解绑。'),
                  ),
                );
              }
            },
            onResetAll: () {
              setState(
                  () => _settings.shortcuts = _settings.shortcuts.resetAll());
              _persist();
            },
          ),
        ];

      case SettingsTab.about:
        return [
          const ListTile(
            title: Text('版本'),
            subtitle: Text(kAppVersion),
          ),
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
        ];
    }
  }

  int? _safeAbi() {
    try {
      return NativeCore.instance.version;
    } catch (_) {
      return null;
    }
  }
}

/// 「清空封面缓存」这一行。
///
/// 单独做成 StatefulWidget 而不是塞进设置页：它要显示当前占用、清完后
/// 立刻刷新数字，而这些状态跟 [PlaybackSettings] 一点关系都没有，塞进去
/// 只会让设置页的 `_persist()` 路径莫名多一次 setState。
class _ClearThumbCacheTile extends StatefulWidget {
  const _ClearThumbCacheTile();

  @override
  State<_ClearThumbCacheTile> createState() => _ClearThumbCacheTileState();
}

class _ClearThumbCacheTileState extends State<_ClearThumbCacheTile> {
  int? _bytes;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final bytes = await ThumbnailCache.instance.diskUsage();
    if (!mounted) return;
    setState(() => _bytes = bytes);
  }

  /// 小于 1 MB 时按 KB 显示：封面多半只有几百 KB，一律写成 0.0 MB
  /// 会让人以为缓存没在写。
  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _clear() async {
    if (_busy) return;
    setState(() => _busy = true);
    await ThumbnailCache.instance.clear();
    if (!mounted) return;
    setState(() => _busy = false);
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('封面缓存已清空，下次进目录会重新生成。')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final usage = _bytes == null ? '正在统计…' : _size(_bytes!);
    return ListTile(
      key: const ValueKey('settings-clear-thumb-cache'),
      title: const Text('清空封面缓存'),
      subtitle: Text('当前占用 $usage。'
          '删掉的片子、换过的服务器都会在这里留下文件；清空后重新进目录会再解一次。'),
      trailing: TextButton(
        onPressed: _busy ? null : _clear,
        child: Text(_busy ? '清理中…' : '清空'),
      ),
    );
  }
}

/// 宽屏的左侧目录栏。
class _TabRail extends StatelessWidget {
  const _TabRail({required this.current, required this.onSelect});

  final SettingsTab current;
  final ValueChanged<SettingsTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final tab in SettingsTab.values)
          _TabTile(
            tab: tab,
            selected: tab == current,
            onTap: () => onSelect(tab),
          ),
      ],
    );
  }
}

/// 窄屏的顶部目录条：同一个目录表，横排。
class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.current, required this.onSelect});

  final SettingsTab current;
  final ValueChanged<SettingsTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          for (final tab in SettingsTab.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _TabTile(
                tab: tab,
                selected: tab == current,
                onTap: () => onSelect(tab),
                compact: true,
              ),
            ),
        ],
      ),
    );
  }
}

class _TabTile extends StatelessWidget {
  const _TabTile({
    required this.tab,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final SettingsTab tab;
  final bool selected;
  final VoidCallback onTap;

  /// 横排时不留整行宽度，按内容撑开。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 字号与字体跟着正文走（见 SettingsTab.textStyle 的注释），
    // 选中与否只靠颜色和底色区分，不靠字号大小 —— 大小一变，扫视时会
    // 觉得那是两种层级的东西。
    final style = tab.textStyle(context)?.copyWith(
          color: selected ? scheme.primary : scheme.onSurface,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        );
    if (compact) {
      return InkWell(
        key: tab.tabKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? scheme.primary.withValues(alpha: 0.14) : null,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(tab.label, style: style),
        ),
      );
    }
    return InkWell(
      key: tab.tabKey,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.14) : null,
          border: Border(
            left: BorderSide(
              width: 3,
              color: selected ? scheme.primary : Colors.transparent,
            ),
          ),
        ),
        child: Text(tab.label, style: style),
      ),
    );
  }
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
