import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/player_controller.dart';
import '../data/location.dart';
import '../data/models.dart';
import '../data/progress.dart';
import '../data/stores.dart';
import '../player/playlist.dart';
import '../util/format.dart';
import 'keyboard.dart';
import 'theme.dart';
import 'video_texture.dart';
import 'widgets/media_info_dialog.dart';
import 'widgets/subtitle_overlay.dart';
import 'widgets/video_surface.dart';
import 'widgets/volume_sheet.dart';

/// The playback surface: a Flutter texture fed by the FFmpeg core, plus the
/// transport UI from module 3.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.location,
    required this.playlist,
    required this.settings,
    this.subtitles = const [],
  });

  final MediaLocation location;
  final PlaylistController playlist;
  final PlaybackSettings settings;
  final List<MediaEntry> subtitles;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final PlayerController _player;
  late final PlaybackSettings _settings = widget.settings.copy();

  VideoTexture? _texture;
  Timer? _hideTimer;
  Timer? _progressTimer;
  bool _controls = true;
  bool _starting = true;
  double? _dragValue;
  int _subtitleDelay = 0;
  bool _showStats = false;
  int? _audioIndex;

  /// 语言偏好只在拿到轨道信息后应用一次，用户手动切换后不再干预。
  bool _prefsApplied = false;

  /// Simulated screen brightness (the app dims its own picture; changing the
  /// real panel brightness needs a platform call that Windows does not expose
  /// to desktop apps).
  double _brightness = 1.0;
  double? _speedBeforeHold;

  /// Short-lived on-screen readout for gestures ("音量 60%").
  String? _hud;
  Timer? _hudTimer;
  double _doubleTapX = 0;

  /// Which half of the screen the current vertical drag started on: the right
  /// half adjusts volume, the left half dims the picture.
  bool _dragOnVolume = true;
  bool _fullscreen = false;

  /// Where the user stopped last time, waiting for the first duration report so
  /// we never seek past the end of a shorter re-encode.
  int? _pendingResumeUs;
  bool _resumeHandled = false;
  int _progressSaves = 0;

  /// Keys for the two controls whose position was reported as wrong, so a test run
  /// can print their real on-screen rectangles instead of guessing from
  /// screenshots. Screen capture of this page is unreliable (the Flutter view is
  /// composited at a different offset than GetWindowRect reports), while a printed
  /// rect is exact.
  final GlobalKey _backKey = GlobalKey();
  final GlobalKey _pictureKey = GlobalKey();
  final GlobalKey _volumeValueKey = GlobalKey();

  /// 音量按钮本身（数值那一格）。布局探针用它打印真实矩形。
  final GlobalKey _volumeKey = GlobalKey();

  /// 底栏那条常驻音量条。用户按图指出「没有音量条」—— 只有图标和数字，
  /// 看不到自己在量程的哪个位置。
  final GlobalKey _volumeBarKey = GlobalKey();
  final GlobalKey _subtitleKey = GlobalKey();
  final GlobalKey _audioKey = GlobalKey();

  /// Set from LANPLAYER_LAYOUT_PROBE: once the transport UI is first up, print the
  /// global rectangles of the back button and the picture button, then stop.
  /// Added because pixel measurement kept disagreeing with the source code.
  bool _layoutProbeDone = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // The controller is created synchronously: build() already reads it, so
    // deferring it to the post-frame callback (which runs after the first
    // frame) left `_player` uninitialised and threw LateInitializationError.
    _player = PlayerController();
    _player.initialize();
    _player.addListener(_onPlayerChanged);
    _player.onEnded = _handleEnded;
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    if (!mounted) return;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(320, 3840);
    final height = (size.height * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(240, 2160);

    // LANPLAYER_NO_TEXTURE=1 skips the texture entirely.  The Windows embedder
    // composites external textures through a path that screen capture cannot
    // read, so this hook exists to verify the Flutter-side overlays (subtitles,
    // HUD, bars) independently of the video surface.
    final skipTexture = Platform.environment['LANPLAYER_NO_TEXTURE'] == '1';
    final texture = skipTexture
        ? null
        : await VideoTextureBridge.create(width: width, height: height);
    if (!mounted) {
      await VideoTextureBridge.destroy();
      return;
    }
    _texture = texture;

    await VideoTextureBridge.attachPlayer(_player.nativeHandle);
    if (!mounted) return;

    if (texture != null && texture.windowPtr != 0) {
      _player.attachVideo(
        textureId: texture.textureId,
        windowPtr: texture.windowPtr,
        width: width,
        height: height,
      );
    }
    _openCurrent();
    if (mounted) setState(() => _starting = false);
  }

  void _openCurrent() {
    final entry = widget.playlist.current;
    if (entry == null) return;
    final url = widget.location.credentialized(entry.path);
    // 关闭「记忆上次播放位置」时既不恢复旧位置，也不再往下写新记录。
    _pendingResumeUs = _settings.rememberProgress
        ? ProgressStore.instance.resumablePosition(entry.path, 0)
        : null;
    _resumeHandled = false;
    // 换片时把「已经按偏好挑过轨道」的标志清掉，否则连播下一集时
    // 新文件的音轨/字幕再也不会按设置挑。`_audioIndex` 同理：它是上一
    // 个文件的流索引，留着会让新文件选中一条不存在（或编号不同）的轨。
    _prefsApplied = false;
    _audioIndex = null;
    _player.open(url, _settings, extra: widget.location.options);
    if (_subtitleDelay != 0) {
      _player.setSubtitleDelay(_subtitleDelay);
    }
    _player.setOption('subtitle_delay', '$_subtitleDelay');
    _scheduleHide();
    _scheduleProgressSave();
  }

  /// Writes the position every few seconds instead of on every tick, so a hard
  /// kill loses at most a few seconds of history.
  void _scheduleProgressSave() {
    _progressTimer?.cancel();
    if (!_settings.rememberProgress) return;
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _saveProgress();
    });
  }

  void _saveProgress() {
    if (!_settings.rememberProgress) return;
    final entry = widget.playlist.current;
    if (entry == null) return;
    final dur = _player.durationUs;
    if (dur <= 0 || _player.state == PlayerState.idle) return;
    ProgressStore.instance.save(entry.path, _player.positionUs, dur);
    if (_progressSaves++ % 4 == 0) {
      // ignore: avoid_print
      print('LanPlayer progress: ${entry.name} '
          '${(_player.positionUs / Duration.microsecondsPerSecond).toStringAsFixed(1)}'
          ' / ${(dur / Duration.microsecondsPerSecond).toStringAsFixed(1)}s');
    }
  }

  void _onPlayerChanged() {
    if (!mounted) return;
    _applyPendingResume();
    _applyTrackPreferences();
    setState(() {});
  }

  /// 打开后按设置里的语言偏好选一次默认音轨和字幕轨。
  ///
  /// 内核默认用 `av_find_best_stream`，只会挑「第一条」——多音轨的片子
  /// 经常第一条是英语评论轨，用户报的就是这个。这里在轨道信息第一次到手时
  /// 按偏好重选一次；只做一次（`_prefsApplied`），用户手动切过之后不再干扰。
  void _applyTrackPreferences() {
    if (_prefsApplied) return;
    final info = _player.media;
    if (info.audio.isEmpty && info.subtitles.isEmpty) return;
    _prefsApplied = true;

    // 音轨：只在文件真的有多条时才切，避免无谓地重启音频。
    if (info.audio.length > 1) {
      final want = pickTrack(
        [
          for (final a in info.audio)
            TrackChoice(
              index: a.index,
              lang: a.lang,
              title: a.title,
              // 内核没有把 disposition 传上来，用「第一条」近似发行方默认。
              isDefault: a.index == info.audio.first.index,
            ),
        ],
        _settings.audioPreference,
      );
      final current = _currentAudioIndex(info);
      if (want != null && want != current) {
        // ignore: avoid_print
        print('LanPlayer audio pick: $current -> $want '
            '(${_settings.audioPreference.primary}/${_settings.audioPreference.secondary})');
        _audioIndex = want;
        _player.selectAudio(want);
      }
    }

    // 字幕：偏好是 auto 时不动（保持内核的「第一条」行为）。
    final subPref = _settings.subtitlePreference;
    final wantsSubtitle =
        subPref.primary != 'auto' || subPref.secondary != 'auto';
    if (wantsSubtitle && info.subtitles.isNotEmpty) {
      final want = pickTrack(
        [
          for (final s in info.subtitles)
            TrackChoice(
              index: s.index,
              lang: s.lang,
              title: s.title,
              isDefault: s.selected,
              external: s.external,
            ),
        ],
        subPref,
      );
      if (want != null && want != _currentSubtitleIndex(info)) {
        // ignore: avoid_print
        print(
            'LanPlayer subtitle pick: ${_currentSubtitleIndex(info)} -> $want '
            '(${subPref.primary}/${subPref.secondary})');
        _player.selectSubtitle(want);
      }
    }
  }

  /// The resume seek needs the real duration (a re-encode can be shorter than
  /// the file we remembered), so it waits for the first non-zero duration.
  void _applyPendingResume() {
    if (_resumeHandled) return;
    final pending = _pendingResumeUs;
    final dur = _player.durationUs;
    if (pending == null || dur <= 0) return;
    _resumeHandled = true;
    if (pending >= dur - ProgressStore.tailGuard.inMicroseconds) return;
    // ignore: avoid_print
    print('LanPlayer resume: ${widget.playlist.current?.name} -> '
        '${(pending / Duration.microsecondsPerSecond).toStringAsFixed(1)}s');
    _player.seekTo(pending);
  }

  void _handleEnded() {
    // Finished files must restart from the beginning next time.
    final finished = widget.playlist.current;
    if (finished != null && _settings.rememberProgress) {
      ProgressStore.instance.clear(finished.path);
    }
    if (!_settings.autoNext || !widget.playlist.hasNext) {
      _showControls();
      return;
    }
    widget.playlist.advance();
    _openCurrent();
  }

  /// 鼠标停在画面上不动多久后隐藏控件。桌面端比移动端短一点，
  /// 因为移动画面就是「我要看控制条」的明确意图。
  static const Duration _autoHideDelay = Duration(seconds: 2);

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_autoHideDelay, () {
      if (!mounted || !_controls) return;
      setState(() => _controls = false);
      // 验证用日志：scripts\send_keys.py 靠这一行断言「鼠标静止 2 秒后控件收起」。
      // 只在真正发生变化时打印，鼠标移动过程中不会刷屏。
      // ignore: avoid_print
      print('LanPlayer controls: hidden (idle ${_autoHideDelay.inSeconds}s)');
    });
  }

  void _showControls() {
    _hideTimer?.cancel();
    if (!_controls) {
      setState(() => _controls = true);
      // 与上面的 hidden 配对：证明鼠标一移动控件就重新出现。
      // ignore: avoid_print
      print('LanPlayer controls: shown');
    }
    _scheduleHide();
    _maybePrintLayoutProbe();
  }

  /// Prints the real global rectangles of the two controls whose position the
  /// user reported as wrong. Enabled with LANPLAYER_LAYOUT_PROBE=1.
  ///
  /// This exists because screenshot measurement was actively misleading here: a
  /// red probe icon measured at the vertical centre while the source put it in the
  /// top row, and crops of this page are known to land offset. `RenderBox`
  /// geometry comes from the layout tree, so it cannot be off by a DPI factor.
  void _maybePrintLayoutProbe() {
    if (_layoutProbeDone) return;
    if ((Platform.environment['LANPLAYER_LAYOUT_PROBE'] ?? '').isEmpty) return;
    _layoutProbeDone = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final media = MediaQuery.maybeSizeOf(context);
      // ignore: avoid_print
      print('LanPlayer layout probe: screen=${media?.width}x${media?.height}');
      _printRect('back', _backKey);
      _printRect('picture', _pictureKey);
      _printRect('volume', _volumeKey);
      _printRect('volumeBar', _volumeBarKey);
    });
  }

  void _printRect(String label, GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) {
      // ignore: avoid_print
      print('LanPlayer layout probe: $label=<not mounted>');
      return;
    }
    final origin = box.localToGlobal(Offset.zero);
    final size = box.size;
    // ignore: avoid_print
    print('LanPlayer layout probe: $label='
        'x=${origin.dx.toStringAsFixed(1)} y=${origin.dy.toStringAsFixed(1)} '
        'w=${size.width.toStringAsFixed(1)} '
        'h=${size.height.toStringAsFixed(1)}');
  }

  void _toggleControls() {
    if (_controls) {
      _hideTimer?.cancel();
      setState(() => _controls = false);
    } else {
      _showControls();
    }
  }

  /// 鼠标只要在画面上移动就重新显示控件，并重新开始 2 秒倒计时；
  /// 静止 2 秒后由 [_scheduleHide] 收起，不需要再点一下画面。
  void _onPointerHover(PointerHoverEvent event) {
    _showControls();
  }

  /// 滚轮调音量：往上滚变大，一格走 [VolumeSheet.wheelStep] 个显示刻度。
  ///
  /// 只处理 `PointerScrollEvent`，别的事件原样放过 —— 播放页眼下没有可滚动的
  /// 内容，但将来在画面上叠列表时这里不会被吞掉。静音状态不自动解除：用户按了
  /// 静音还在滚，多半是想把音量调回去，突然出声更糟；HUD 里写明当前是静音。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (event.scrollDelta.dy == 0) return;
    final next = VolumeSheet.wheelVolume(_player.volume, event.scrollDelta.dy);
    final shown = VolumeSheet.displayOf(next);
    if (next != _player.volume) {
      _player.setVolume(next);
      _settings.volume = next;
      // 与音量面板一致：写进 SettingsStore，下次开片按这次的音量来。
      SettingsStore.instance.value.volume = next;
      unawaited(SettingsStore.instance.save());
    }
    _showHud(_player.muted ? '静音（音量 $shown）' : '音量 $shown');
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hudTimer?.cancel();
    _progressTimer?.cancel();
    _saveProgress();
    _player.removeListener(_onPlayerChanged);
    _player.dispose();
    VideoTextureBridge.destroy();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ---------------------------------------------------------------- actions ---

  /// 快进/快退的步长，取自设置。播放页拿到的是开片那一刻的一份拷贝，
  /// 所以设置里改了要在下次进入播放页时生效 —— 与音量、倍速的处理一致。
  int get _seekStep => PlaybackSettings.clampSeekStep(_settings.seekStepSeconds);

  void _seekRelative(int seconds) {
    _player.seekBy(seconds * 1000000);
    _showControls();
  }

  /// 「音轨」面板：只列音频轨，标题是「音轨」。
  ///
  /// 以前音轨和字幕共用 [_openTracksSheet]，于是点「音轨」弹出的面板
  /// 标题写着「字幕」——用户明确报了这个错误。现在拆成两个入口。
  Future<void> _openAudioSheet() async {
    _hideTimer?.cancel();
    final info = _player.media;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              _SheetHeader('音轨（${info.audio.length} 条）'),
              if (info.audio.isEmpty)
                const ListTile(
                  title: Text('这个文件没有音轨'),
                  subtitle: Text('可能是无声视频'),
                ),
              for (final a in info.audio)
                RadioListTile<int>(
                  value: a.index,
                  groupValue: _currentAudioIndex(info),
                  title: Text(a.label),
                  subtitle: a.lang.isEmpty && a.title.isEmpty
                      ? const Text('文件未标注语言', style: TextStyle(fontSize: 11))
                      : null,
                  onChanged: (v) {
                    final picked = v ?? a.index;
                    setSheet(() => _audioIndex = picked);
                    _player.selectAudio(picked);
                  },
                ),
            ],
          ),
        ),
      ),
    );
    _scheduleHide();
  }

  /// 「字幕」面板：内嵌字幕轨 + 外挂字幕文件 + 同步微调。
  ///
  /// 面板整体跟着 `_player` 一起重建，不在打开时抓一份 `_player.media` 快照：
  /// 点一份外挂字幕之后内核会重算轨道表并发新的 LP_EVENT_TRACKS，用快照的话
  /// 选中项永远停在旧值（用户报的就是「点了之后确实选上了，但界面还显示默认
  /// 字幕」）。
  ///
  /// 两栏的分界是「有没有进轨道表」而不是「内嵌还是外挂」：单选清单列的是轨道
  /// 表里现有的每一条（内嵌的 + 已经加载过的外挂），下面那一栏只列还没加载的
  /// 文件。同一份外挂字幕不能在两处各出现一次，否则用户会以为有两个不同的字幕。
  Future<void> _openTracksSheet() async {
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            AnimatedBuilder(
              animation: _player,
              builder: (ctx, _) {
                final info = _player.media;
                final current = _currentSubtitleIndex(info);
                final embedded =
                    info.subtitles.where((s) => !s.external).length;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SheetHeader(info.subtitles.isEmpty
                        ? '字幕'
                        : '字幕（$embedded 条内嵌、'
                            '${info.subtitles.length - embedded} 条外挂）'),
                    RadioListTile<int>(
                      value: noSubtitleTrack,
                      groupValue: current,
                      title: const Text('关闭字幕'),
                      onChanged: (_) => _player.selectSubtitle(noSubtitleTrack),
                    ),
                    for (final s in info.subtitles)
                      RadioListTile<int>(
                        value: s.index,
                        groupValue: current,
                        title: Text(s.label),
                        onChanged: (_) => _player.selectSubtitle(s.index),
                      ),
                  ],
                );
              },
            ),
            AnimatedBuilder(
              animation: _player,
              builder: (ctx, _) {
                final info = _player.media;
                // 已经进轨道表的文件不在这里重复列，它们在上面的单选清单里。
                final pending = pendingSubtitleFiles(
                  widget.subtitles,
                  (f) => f.name,
                  info,
                );
                if (pending.isEmpty) return const SizedBox.shrink();
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _SheetHeader('外挂字幕文件'),
                    for (final f in pending) _externalSubtitleTile(ctx, f),
                  ],
                );
              },
            ),
            const _SheetHeader('字幕同步'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  OutlinedButton(
                    onPressed: () => _nudgeSubtitle(-100),
                    child: const Text('-0.1s'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Center(
                      child: Text(
                          '${(_subtitleDelay / 1000).toStringAsFixed(1)} s',
                          style: const TextStyle(
                              fontFamily: LanPlayerTheme.fontFamily,
                              fontFeatures: [FontFeature.tabularFigures()])),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () => _nudgeSubtitle(100),
                    child: const Text('+0.1s'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    _scheduleHide();
  }

  /// 一份**还没加载**的外挂字幕文件的行。
  ///
  /// 已经进轨道表的文件不走到这里（它们在单选清单里，有选中态）。这一栏只负责
  /// 「读进来」这个动作，所以点了之后轨道表会多一条、界面随之换成选中态。
  Widget _externalSubtitleTile(BuildContext ctx, MediaEntry f) {
    return ListTile(
      leading: const Icon(Icons.subtitles_outlined),
      title: Text(f.name),
      onTap: () async {
        final url = widget.location.credentialized(f.path);
        final rc = _player.addSubtitle(url, widget.location.options);
        if (rc < 0) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('字幕加载失败：请确认文件编码为 UTF-8')),
          );
        }
      },
    );
  }

  void _nudgeSubtitle(int deltaMs) {
    _subtitleDelay += deltaMs;
    _player.setSubtitleDelay(_subtitleDelay);
  }

  int _currentAudioIndex(MediaInfo info) {
    if (_audioIndex != null) return _audioIndex!;
    return info.audio.isEmpty ? -1 : info.audio.first.index;
  }

  int _currentSubtitleIndex(MediaInfo info) => selectedSubtitleIndex(info);

  Future<void> _openSpeedSheet() async {
    _hideTimer?.cancel();
    // 档位与设置页的「默认倍速」共用一份，见 PlaybackSettings.speedSteps。
    const speeds = PlaybackSettings.speedSteps;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetHeader('播放速度（音调不变）'),
            for (final s in speeds)
              RadioListTile<double>(
                value: s,
                // 吸附到档位：老设置里可能存着 1.3，不吸附就一个都不选中。
                groupValue: PlaybackSettings.clampSpeed(_player.speed),
                title: Text('${s}x'),
                onChanged: (v) {
                  _player.setSpeed(v ?? PlaybackSettings.speedDefault);
                  setState(() {});
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
    _scheduleHide();
  }

  /// 底栏常驻音量条拖动时走这里：按显示刻度（0–100）换算回增益写进内核。
  ///
  /// 拖动过程中只改内存里的值，落盘留到 [commitVolume]（onChangeEnd）——
  /// 滑杆一帧一个 onChanged，每帧写一次 json 会把磁盘拖住。
  /// 与滚轮、键盘上下键走同一套映射，三者对「100」的理解必须一致。
  void _setVolumeFromBar(double display) {
    final next = VolumeSheet.volumeOf(display);
    _player.setVolume(next);
    _settings.volume = next;
    _showControls();
  }

  /// 音量条松手时落盘。与音量面板里的滑杆同一套写法。
  void _commitVolume(double display) {
    final next = VolumeSheet.volumeOf(display);
    SettingsStore.instance.value.volume = next;
    unawaited(SettingsStore.instance.save());
  }

  /// 键盘上下键与手势共用的音量微调，统一按显示值给反馈。
  void _nudgeVolume(double delta) {
    _player.setVolume(_player.volume + delta);
    _showHud('音量 ${VolumeSheet.displayOf(_player.volume)}');
  }

  /// 底栏音量按钮点一下就走这里：静音 / 解除静音。
  ///
  /// 静音不改音量值本身，解除后回到原来的档位 —— 用户要的就是「按一下闭麦、
  /// 再按一下恢复」，不需要在两次点击之间记住别的东西。
  void _toggleMute() {
    _player.toggleMute();
    _showHud(
        _player.muted ? '静音' : '音量 ${VolumeSheet.displayOf(_player.volume)}');
  }

  /// 底部操作行的音量面板：滑杆调音量 + 静音开关 + 常用档位。
  ///
  /// 面板本身在 [VolumeSheet] 里，便于单元测试。底栏那颗按钮不再打开它 ——
  /// 用户要求「点击音量按钮即为静音/解除静音」，按音量值调档的事交给这个
  /// 面板（长按按钮或按上下键进来）。
  Future<void> _openVolumeSheet() async {
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => VolumeSheet(
          volume: _player.volume,
          muted: _player.muted,
          onVolumeChanged: (v) {
            _player.setVolume(v);
            _settings.volume = v;
            // 记住音量：下次开片按上次的来。写 SettingsStore 里那份，
            // 否则重开播放器还会回到 100%。
            SettingsStore.instance.value.volume = v;
            unawaited(SettingsStore.instance.save());
            setSheetState(() {});
          },
          onMutedChanged: (m) {
            if (m != _player.muted) _player.toggleMute();
            setSheetState(() {});
          },
        ),
      ),
    );
    setState(() {});
    _scheduleHide();
  }

  /// 底部操作行的「画面」入口：缩放方式、解码统计开关、媒体信息。
  Future<void> _openPictureSheet() async {
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // StatefulBuilder 是必须的：面板里的「解码统计」开关直接改的是
      // 本页 state，不重建面板自己，开关就停在旧位置上（用户报的现象是
      // 退出面板再进来才刷新）。
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _SheetHeader('画面'),
              for (final (label, mode) in [('适应屏幕', 0), ('铺满裁切', 1), ('拉伸', 2)])
                ListTile(
                  leading: Icon(mode == _settings.scaleMode
                      ? Icons.check
                      : Icons.crop_free),
                  title: Text(label),
                  onTap: () {
                    _settings.scaleMode = mode;
                    // 内核只把它当渲染提示（Android EGL 会读），真正决定
                    // 画面如何贴合这一块区域的是 build 里的 FittedBox。
                    _player.setScaleMode(mode);
                    setState(() {});
                    Navigator.pop(ctx);
                  },
                ),
              const Divider(),
              // 「媒体信息」和「解码统计」原本是两个入口：前者弹对话框看
              // 一遍就关，后者开一个常驻浮层。用户要的是同一件事 —— 看这
              // 一帧到底是哪路码流、解码器是谁、现在跑得怎么样 —— 所以并
              // 成一个「媒体信息」面板，静态参数和实时计数放在一起。
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('媒体信息'),
                subtitle: Text(
                    '${_player.hwActive} · ${_player.fps.toStringAsFixed(1)} fps '
                    '· 丢帧 ${_player.dropped}'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showMediaInfo();
                },
              ),
            ],
          ),
        ),
      ),
    );
    _scheduleHide();
  }

  /// 「媒体信息」面板：静态码流参数 + 实时解码计数 + 画面浮层开关。
  ///
  /// 原来是两个入口（一个对话框、一个常驻浮层），但用户要的是同一件事，
  /// 所以并成一个面板。实时数字靠面板里的 `AnimatedBuilder` 跟着控制器
  /// 重建 —— 控制器收到 stats 事件时只在 [PlayerController.wantsStats] 为
  /// 真才通知，一秒一次的重建会拖累整个播放页，所以打开期间强制打开它，
  /// 关掉后再还原。
  void _showMediaInfo() {
    final wasWantsStats = _player.wantsStats;
    _player.wantsStats = true;
    MediaStatsSnapshot read() => MediaStatsSnapshot(
          media: _player.media,
          decoder: _player.hwActive,
          fps: _player.fps,
          dropped: _player.dropped,
          avDiffUs: _player.avDiffUs,
          queuedPackets: _player.queuedPackets,
          positionUs: _player.positionUs,
        );
    showDialog<void>(
      context: context,
      builder: (ctx) => MediaInfoDialog(
        read: read,
        listen: _player,
        overlay: _showStats,
        onOverlayChanged: (v) {
          _player.wantsStats = v;
          setState(() => _showStats = v);
        },
      ),
    ).whenComplete(() {
      // 关掉面板后仍然要让浮层拿到数据（`_showStats` 还开着的话）。
      _player.wantsStats = wasWantsStats || _showStats;
    });
  }

  // ------------------------------------------------------------------ build ---

  @override
  Widget build(BuildContext context) {
    final duration = _player.durationUs > 0 ? _player.durationUs : 1;
    final position =
        _dragValue ?? _player.positionUs.clamp(0, duration).toDouble();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onFocusChange: (hasFocus) {
          if (!hasFocus) _keys.reset();
        },
        onKeyEvent: _onKey,
        // 桌面端：鼠标在画面上移动即显示控件，静止 2 秒后自动收起。
        // 用 Listener 而不是 MouseRegion，因为控件行里的按钮自带 MouseRegion
        // （用来设手型光标），会挡住外层 MouseRegion 的 onHover，
        // 导致鼠标在控制条上移动时计时器不重置、控件中途消失。
        child: Listener(
          onPointerHover: _onPointerHover,
          // 滚轮调音量（用户 2026-10-27 要求）。挂在整块画面上：播放页里的
          // 滚轮没有别的含义，压在字幕/画面上都能用。
          onPointerSignal: _onPointerSignal,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onDoubleTapDown: (d) => _doubleTapX = d.localPosition.dx,
            onDoubleTap: _handleDoubleTap,
            onLongPressStart: (_) => _beginSpeedBoost(),
            onLongPressEnd: (_) => _endSpeedBoost(),
            onVerticalDragStart: _beginVerticalDrag,
            onVerticalDragUpdate: _updateVerticalDrag,
            onVerticalDragEnd: (_) => _hideHud(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 画面如何贴合这一块区域：三种缩放模式都在 Dart 层做。
                //
                // 内核里的 `scale_mode` 只有 Android 的 EGL 渲染器会读
                // （`native/src/platform/android/egl_renderer.c`），Windows /
                // macOS / iOS 走的是 Flutter 外部纹理，帧被原样交给引擎，
                // 所以「铺满裁切」「拉伸」在桌面上一直是空操作 —— 用户点了
                // 三个按钮发现画面没变化就是这个原因。用 FittedBox 把纹理
                // 按视频原始尺寸摆进去，三种模式在三端一致生效。
                Positioned.fill(
                  child: ClipRect(
                    child: _videoSurface(),
                  ),
                ),
                // Simulated brightness: the picture is dimmed, subtitles are not.
                if (_brightness < 1)
                  IgnorePointer(
                    child: ColoredBox(
                        color: Colors.black.withValues(alpha: 1 - _brightness)),
                  ),
                // 字幕按**画面**而不是窗口定位：画面留黑边时，字幕的位置和
                // 字号都该跟着画面走，不然窗口一拉宽字幕就飞了。
                SubtitleOverlay(
                  cue: _player.cue,
                  scale: _settings.subtitleScale,
                  safeArea: _controls ? 110 : 28,
                  videoAspectRatio: _videoAspectRatio,
                  scaleMode: _settings.scaleMode,
                ),
                if (_player.buffering && !_starting)
                  const Center(
                    child: SizedBox(
                      width: 42,
                      height: 42,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                  ),
                if (_player.error != null) _errorOverlay(),
                // top bar
                AnimatedOpacity(
                  opacity: _controls ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_controls,
                    child: _topBar(),
                  ),
                ),
                // bottom transport
                AnimatedOpacity(
                  opacity: _controls ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_controls,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: _bottomBar(duration, position),
                    ),
                  ),
                ),
                if (_hud != null) _hudOverlay(_hud!),
                if (_showStats) _statsOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Centre readout for gestures: "音量 60%", "亮度 40%", "2.0x 快进中".
  Widget _hudOverlay(String text) {
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xCC000000),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------- gestures ---

  void _showHud(String text) {
    _hudTimer?.cancel();
    setState(() => _hud = text);
    _hudTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _hud = null);
    });
  }

  void _hideHud() {
    _hudTimer?.cancel();
    if (_hud != null) setState(() => _hud = null);
  }

  /// Double tap: left third rewinds 10 s, right third forwards 10 s, the middle
  /// keeps the classic play/pause toggle.
  void _handleDoubleTap() {
    final width = MediaQuery.sizeOf(context).width;
    final x = _doubleTapX;
    if (x > 0 && x < width / 3) {
      _player.seekBy(-10 * Duration.microsecondsPerSecond);
      _showHud('« 10 秒');
      _showControls();
    } else if (x > width * 2 / 3) {
      _player.seekBy(10 * Duration.microsecondsPerSecond);
      _showHud('10 秒 »');
      _showControls();
    } else {
      _player.togglePlay();
      _showHud(_player.isPlaying ? '播放' : '暂停');
      _showControls();
    }
  }

  void _beginVerticalDrag(DragStartDetails d) {
    final width = MediaQuery.sizeOf(context).width;
    _dragOnVolume = d.localPosition.dx > width / 2;
  }

  void _updateVerticalDrag(DragUpdateDetails d) {
    // Full screen height maps to the whole 0..1 range; upward is more.
    final delta = -d.delta.dy / 320;
    if (_dragOnVolume) {
      final v = (_player.volume + delta).clamp(0.0, VolumeSheet.maxVolume);
      _player.setVolume(v);
      _showHud('音量 ${VolumeSheet.displayOf(v)}');
    } else {
      final b = (_brightness + delta).clamp(0.25, 1.0);
      setState(() => _brightness = b);
      _showHud('亮度 ${(b * 100).round()}%');
    }
  }

  void _beginSpeedBoost() {
    _speedBeforeHold = _player.speed;
    _player.setSpeed(2.0);
    _showHud('2.0x 快进中');
  }

  void _endSpeedBoost() {
    final before = _speedBeforeHold;
    if (before == null) return;
    _speedBeforeHold = null;
    _player.setSpeed(before);
    _hideHud();
  }

  /// 播放页认的键。与 keyboard.dart 的约定一致：**抬起才执行**。
  ///
  /// 表来自用户绑定（设置 → 快捷键），不再是写死的一串 —— 用户改了键之后
  /// 这里必须跟着变，否则改完还是老键生效。
  bool _isPlayerKey(LogicalKeyboardKey key) =>
      _settings.shortcuts.ownsKey(key);

  /// 抬起触发状态（长按不生效）。
  late final KeyReleaseTrigger _keys = KeyReleaseTrigger(_isPlayerKey);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    return _keys.handle(event, (key) {
      final action = _settings.shortcuts.actionForKey(key);
      if (action == null) return;
      final handled = _handleAction(action);
      if (handled) {
        // ignore: avoid_print
        print('LanPlayer key: ${ShortcutBindings.label(key)} ($action)');
        _showControls();
      }
    });
  }

  /// 按「动作」执行，而不是按「键」—— 这样改键只影响查表，不影响行为。
  bool _handleAction(ShortcutAction action) {
    switch (action) {
      case ShortcutAction.playPause:
        _player.togglePlay();
        _showHud(_player.isPlaying ? '播放' : '暂停');
        return true;
      case ShortcutAction.seekBack:
        _seekRelative(-_seekStep);
        return true;
      case ShortcutAction.seekForward:
        _seekRelative(_seekStep);
        return true;
      case ShortcutAction.volumeUp:
        _nudgeVolume(0.05);
        return true;
      case ShortcutAction.volumeDown:
        _nudgeVolume(-0.05);
        return true;
      case ShortcutAction.mute:
        _player.toggleMute();
        _showHud(_player.muted ? '静音' : '取消静音');
        return true;
      case ShortcutAction.speedUp:
        _stepSpeed(1);
        return true;
      case ShortcutAction.speedDown:
        _stepSpeed(-1);
        return true;
      case ShortcutAction.speedReset:
        _player.setSpeed(PlaybackSettings.speedDefault);
        _settings.speed = PlaybackSettings.speedDefault;
        _showHud('1.0x');
        return true;
      case ShortcutAction.fullscreen:
        _toggleFullscreen();
        return true;
      case ShortcutAction.escape:
        if (_fullscreen) {
          _toggleFullscreen();
        } else {
          Navigator.of(context).maybePop();
        }
        return true;
      case ShortcutAction.subtitleEarlier:
        _shiftSubtitle(-100);
        return true;
      case ShortcutAction.subtitleLater:
        _shiftSubtitle(100);
        return true;
      case ShortcutAction.stats:
        setState(() => _showStats = !_showStats);
        _player.wantsStats = _showStats;
        return true;
      case ShortcutAction.back:
        // 播放页里没有「上一级列表」的概念，退格等同于返回。
        if (_fullscreen) {
          _toggleFullscreen();
        } else {
          Navigator.of(context).maybePop();
        }
        return true;
    }
  }

  /// 倍速按档位走一格。[dir] 为 +1 更快、-1 更慢。
  void _stepSpeed(int dir) {
    const steps = PlaybackSettings.speedSteps;
    final current = PlaybackSettings.clampSpeed(_player.speed);
    var index = steps.indexOf(current);
    if (index < 0) index = steps.indexOf(PlaybackSettings.speedDefault);
    final next = (index + dir).clamp(0, steps.length - 1);
    final value = steps[next];
    _player.setSpeed(value);
    _settings.speed = value;
    _showHud('${value.toStringAsFixed(2)}x');
  }

  void _shiftSubtitle(int deltaMs) {
    _subtitleDelay += deltaMs;
    _player.setSubtitleDelay(_subtitleDelay);
    _showHud('字幕 ${(_subtitleDelay / 1000).toStringAsFixed(1)}s');
  }

  void _toggleFullscreen() {
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    // On desktop the plugin owns the real window; on mobile SystemChrome hides
    // the bars, and both are harmless no-ops when the other one is missing.
    VideoTextureBridge.setFullscreen(next);
    SystemChrome.setEnabledSystemUIMode(
        next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    _showHud(next ? '全屏' : '退出全屏');
  }

  Widget _topBar() {
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xCC000000), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 返回键固定在左上角：紧贴安全区左上，不再跟着标题下移。
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 4),
                child: IconButton(
                  key: _backKey,
                  tooltip: '返回',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
              Expanded(
                child: Column(
                  // 必须 min：Column 默认 mainAxisSize.max 会撑满交给 Row 的高度上限
                  // （整屏），于是整个顶部栏变成满屏高，返回键被 Row 的
                  // crossAxisAlignment.center 摆到竖直中央——这正是「返回键在左侧中间」
                  // 的真实成因，光把 Align 改成 topCenter 解决不了。
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.playlist.current?.name ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${_player.media.format.toUpperCase()} · ${_player.hwActive}'
                      '${widget.playlist.length > 1 ? ' · ${widget.playlist.index + 1}/${widget.playlist.length}' : ''}',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.white60),
                    ),
                  ],
                ),
              ),
              // 右侧留白：画面/声音等入口已经移到底部操作行，
              // 这里不再放按钮，避免右上角出现一个孤立的圆点。
              const SizedBox(width: 56),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(int duration, double position) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xE6000000), Color(0x00000000)],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(formatDuration(position.round()),
                      style: const TextStyle(fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: position,
                      max: duration.toDouble(),
                      onChanged: (v) {
                        setState(() => _dragValue = v);
                        _hideTimer?.cancel();
                      },
                      onChangeEnd: (v) {
                        _player.seekTo(v.round());
                        setState(() => _dragValue = null);
                        _scheduleHide();
                      },
                    ),
                  ),
                  Text(formatDuration(duration),
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: '上一集',
                  icon: const Icon(Icons.skip_previous),
                  onPressed: widget.playlist.hasPrevious
                      ? () {
                          widget.playlist.previous();
                          _openCurrent();
                        }
                      : null,
                ),
                IconButton(
                  tooltip: '快退 $_seekStep 秒',
                  // replay_10 / forward_10 是写死「10」的图标，步长改成别的
                  // 秒数后图标就开始撒谎，所以换成不带数字的版本。
                  icon: const Icon(Icons.fast_rewind),
                  onPressed: () => _seekRelative(-_seekStep),
                ),
                IconButton.filled(
                  iconSize: 34,
                  onPressed: () {
                    _player.togglePlay();
                    _showControls();
                  },
                  icon:
                      Icon(_player.isPlaying ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(
                  tooltip: '快进 $_seekStep 秒',
                  icon: const Icon(Icons.fast_forward),
                  onPressed: () => _seekRelative(_seekStep),
                ),
                IconButton(
                  tooltip: '下一集',
                  icon: const Icon(Icons.skip_next),
                  onPressed: widget.playlist.hasNext
                      ? () {
                          widget.playlist.advance();
                          _openCurrent();
                        }
                      : null,
                ),
              ],
            ),
            // 画面/声音等设置入口集中在这一行：速度、画面、字幕、音轨，然后是
            // 音量图标 + 常驻音量条。
            //
            // 用 Wrap 而不是横向滚动：音量条是 Slider，横向拖动与横向滚动的
            // 手势会打架，滚起来就拖不动。Wrap 让窄屏自动折到第二行，宽屏
            // 保持一行。
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: _openSpeedSheet,
                    icon: const Icon(Icons.speed, size: 18),
                    label: Text('${_player.speed}x'),
                  ),
                  // 「画面」这颗按钮一肩挑两件事（用户按图指定）：
                  // 单击进/退全屏，长按才打开画面设置二级界面。
                  Tooltip(
                    message: _fullscreen ? '退出全屏（长按画面设置）' : '全屏（长按画面设置）',
                    child: InkWell(
                      key: _pictureKey,
                      onTap: _toggleFullscreen,
                      onLongPress: _openPictureSheet,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _fullscreen
                                  ? Icons.fullscreen_exit
                                  : Icons.crop_free,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            const Text('画面', style: TextStyle(fontSize: 14)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  TextButton.icon(
                    key: _subtitleKey,
                    onPressed: _openTracksSheet,
                    icon: const Icon(Icons.subtitles_outlined, size: 18),
                    label: const Text('字幕'),
                  ),
                  TextButton.icon(
                    key: _audioKey,
                    onPressed: _openAudioSheet,
                    icon: const Icon(Icons.graphic_eq, size: 18),
                    label: const Text('音轨'),
                  ),
                  // 音量：图标 + 数值。点一下是静音/解除静音（用户要求），
                  // 长按打开音量面板 —— 面板里还有档位和静音开关。
                  Tooltip(
                    message: _player.muted
                        ? '已静音，点击恢复'
                        : '音量 ${VolumeSheet.displayOf(_player.volume)}'
                            '（点击静音，长按调音量）',
                    child: InkWell(
                      key: _volumeKey,
                      onTap: _toggleMute,
                      onLongPress: _openVolumeSheet,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _player.muted
                                  ? Icons.volume_off
                                  : _player.volume < 0.5
                                      ? Icons.volume_down
                                      : Icons.volume_up,
                              size: 24,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${VolumeSheet.displayOf(_player.volume)}',
                              key: _volumeValueKey,
                              style: TextStyle(
                                fontSize: 13,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                                color: _player.muted
                                    ? Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.45)
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 常驻音量条。用户按图指出「没有音量条」：底栏只有图标和
                  // 数字，看不出自己在量程的哪个位置。宽度定死，Wrap 才能
                  // 在窄屏把它整块折下去。
                  SizedBox(
                    key: _volumeBarKey,
                    width: 168,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 6),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 14),
                      ),
                      child: Slider(
                        value: VolumeSheet.displayOf(_player.volume).toDouble(),
                        max: VolumeSheet.displayMax.toDouble(),
                        divisions: 40,
                        label: '${VolumeSheet.displayOf(_player.volume)}',
                        onChanged: _setVolumeFromBar,
                        onChangeEnd: _commitVolume,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _errorOverlay() {
    return ColoredBox(
      color: const Color(0xCC000000),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  size: 48, color: Color(0xFFFF6E6E)),
              const SizedBox(height: 12),
              Text(_player.error ?? '播放失败', textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _openCurrent,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 画面本体：一张纹理按选定的缩放方式铺到整块区域上。
  ///
  /// 缩放不能交给内核：`scale_mode` 只有 Android 的 EGL 渲染器会读，桌面和 iOS
  /// 走的是 Flutter 外部纹理，内核帧被原样交给引擎。所以在这里用
  /// [VideoSurface] 做，三端一致。
  Widget _videoSurface() {
    final texture = _texture;
    if (texture == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
            child: Text('无视频输出', style: TextStyle(color: Colors.white38))),
      );
    }
    return VideoSurface(
      scaleMode: _settings.scaleMode,
      videoAspectRatio: _videoAspectRatio,
      child: Texture(textureId: texture.textureId),
    );
  }

  /// 视频原始画面的宽高比；还没拿到媒体信息时按 16:9 兜底。
  double get _videoAspectRatio {
    final video = _player.media.video;
    if (video != null && video.width > 0 && video.height > 0) {
      return video.width / video.height;
    }
    return 16 / 9;
  }

  Widget _statsOverlay() {
    return Positioned(
      top: 90,
      left: 12,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xAA000000),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(
              fontSize: 11,
              fontFamily: LanPlayerTheme.fontFamily,
              fontFeatures: [FontFeature.tabularFigures()],
              color: Colors.greenAccent),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('hw      ${_player.hwActive}'),
              Text('fps     ${_player.fps.toStringAsFixed(2)}'),
              Text('dropped ${_player.dropped}'),
              Text(
                  'av_diff ${(_player.avDiffUs / 1000).toStringAsFixed(1)} ms'),
              Text('queued  ${_player.queuedPackets}'),
              Text('pos     ${formatDuration(_player.positionUs)}'),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            letterSpacing: 1,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
}
