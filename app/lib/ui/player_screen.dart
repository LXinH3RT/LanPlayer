import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/player_controller.dart';
import '../data/location.dart';
import '../data/models.dart';
import '../data/progress.dart';
import '../player/playlist.dart';
import '../util/format.dart';
import 'video_texture.dart';
import 'widgets/subtitle_overlay.dart';

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
    setState(() {});
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
      // 验证用日志：scripts\send_keys.ps1 靠这一行断言「鼠标静止 2 秒后控件收起」。
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

  void _seekRelative(int seconds) {
    _player.seekBy(seconds * 1000000);
    _showControls();
  }

  Future<void> _openTracksSheet() async {
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
              if (info.audio.length > 1) ...[
                const _SheetHeader('音轨'),
                for (final a in info.audio)
                  RadioListTile<int>(
                    value: a.index,
                    groupValue: _currentAudioIndex(info),
                    title: Text(a.label),
                    onChanged: (v) {
                      setSheet(() => _audioIndex = v ?? a.index);
                      _player.selectAudio(v ?? a.index);
                    },
                  ),
              ],
              const _SheetHeader('字幕'),
              RadioListTile<int>(
                value: -1,
                groupValue: _currentSubtitleIndex(info),
                title: const Text('关闭字幕'),
                onChanged: (_) {
                  _player.selectSubtitle(-1);
                  setSheet(() {});
                },
              ),
              for (final s in info.subtitles)
                RadioListTile<int>(
                  value: s.index,
                  groupValue: _currentSubtitleIndex(info),
                  title: Text(s.label),
                  onChanged: (_) {
                    _player.selectSubtitle(s.index);
                    setSheet(() {});
                  },
                ),
              if (widget.subtitles.isNotEmpty) ...[
                const _SheetHeader('外挂字幕文件'),
                for (final f in widget.subtitles)
                  ListTile(
                    leading: const Icon(Icons.subtitles_outlined),
                    title: Text(f.name),
                    onTap: () {
                      final url = widget.location.credentialized(f.path);
                      final rc =
                          _player.addSubtitle(url, widget.location.options);
                      if (rc < 0) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('字幕加载失败：请确认文件编码为 UTF-8')),
                        );
                      }
                      setSheet(() {});
                    },
                  ),
              ],
              const _SheetHeader('字幕同步'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    OutlinedButton(
                      onPressed: () => _nudgeSubtitle(-100, setSheet),
                      child: const Text('-0.1s'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Center(
                        child: Text(
                            '${(_subtitleDelay / 1000).toStringAsFixed(1)} s',
                            style: const TextStyle(fontFamily: 'monospace')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: () => _nudgeSubtitle(100, setSheet),
                      child: const Text('+0.1s'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
    _scheduleHide();
  }

  void _nudgeSubtitle(int deltaMs, StateSetter setSheet) {
    _subtitleDelay += deltaMs;
    _player.setSubtitleDelay(_subtitleDelay);
    setSheet(() {});
  }

  int _currentAudioIndex(MediaInfo info) {
    if (_audioIndex != null) return _audioIndex!;
    return info.audio.isEmpty ? -1 : info.audio.first.index;
  }

  int _currentSubtitleIndex(MediaInfo info) {
    for (final s in info.subtitles) {
      if (s.selected) return s.index;
    }
    return -1;
  }

  Future<void> _openSpeedSheet() async {
    _hideTimer?.cancel();
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
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
                groupValue: _player.speed,
                title: Text('${s}x'),
                onChanged: (v) {
                  _player.setSpeed(v ?? 1.0);
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

  /// 底部操作行的「画面」入口：缩放方式、解码统计开关、媒体信息。
  Future<void> _openPictureSheet() async {
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
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
                  _player.setScaleMode(mode);
                  setState(() {});
                  Navigator.pop(ctx);
                },
              ),
            const Divider(),
            SwitchListTile(
              title: const Text('解码统计'),
              subtitle: Text(
                  '${_player.hwActive} · ${_player.fps.toStringAsFixed(1)} fps '
                  '· 丢帧 ${_player.dropped}'),
              value: _showStats,
              onChanged: (v) {
                _player.wantsStats = v;
                setState(() => _showStats = v);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('媒体信息'),
              onTap: () {
                Navigator.pop(ctx);
                _showMediaInfo();
              },
            ),
          ],
        ),
      ),
    );
    _scheduleHide();
  }

  void _showMediaInfo() {
    final m = _player.media;
    final v = m.video;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('媒体信息'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _infoRow('容器', m.format),
              if (v != null) ...[
                _infoRow('视频', v.label),
                _infoRow('像素格式', v.pixFmt),
              ],
              _infoRow('解码', _player.hwActive),
              _infoRow('音频', m.audio.map((a) => a.label).join(', ')),
              _infoRow(
                  '字幕',
                  m.subtitles.isEmpty
                      ? '无'
                      : m.subtitles.map((s) => s.label).join(', ')),
              _infoRow('时长', formatDuration(m.durationUs)),
              _infoRow('A/V 偏差',
                  '${(_player.avDiffUs / 1000).toStringAsFixed(0)} ms'),
              _infoRow('丢帧', '${_player.dropped}'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  Widget _infoRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 76,
                child: Text(k, style: const TextStyle(fontSize: 12))),
            Expanded(
                child: SelectableText(v, style: const TextStyle(fontSize: 12))),
          ],
        ),
      );

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
        onKeyEvent: _onKey,
        // 桌面端：鼠标在画面上移动即显示控件，静止 2 秒后自动收起。
        // 用 Listener 而不是 MouseRegion，因为控件行里的按钮自带 MouseRegion
        // （用来设手型光标），会挡住外层 MouseRegion 的 onHover，
        // 导致鼠标在控制条上移动时计时器不重置、控件中途消失。
        child: Listener(
          onPointerHover: _onPointerHover,
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
                Center(
                  child: AspectRatio(
                    aspectRatio:
                        _player.hasVideo ? _player.aspectRatio : 16 / 9,
                    child: _texture == null
                        ? const ColoredBox(
                            color: Colors.black,
                            child: Center(
                                child: Text('无视频输出',
                                    style: TextStyle(color: Colors.white38))),
                          )
                        : Texture(textureId: _texture!.textureId),
                  ),
                ),
                // Simulated brightness: the picture is dimmed, subtitles are not.
                if (_brightness < 1)
                  IgnorePointer(
                    child: ColoredBox(
                        color: Colors.black.withValues(alpha: 1 - _brightness)),
                  ),
                SubtitleOverlay(
                  cue: _player.cue,
                  scale: _settings.subtitleScale,
                  safeArea: _controls ? 110 : 28,
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
      final v = (_player.volume + delta).clamp(0.0, 1.0);
      _player.setVolume(v);
      _showHud('音量 ${(v * 100).round()}%');
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

  /// Readable name for the verification log.  `keyLabel` is empty for keys
  /// like space, and `keyId` alone would be an opaque number, so both get a
  /// readable spelling here.
  ///
  /// A `const` map cannot be used: `LogicalKeyboardKey` overrides `==`, and
  /// constant maps reject keys with a custom equality operator.
  static String _keyName(LogicalKeyboardKey key) {
    final label = key.keyLabel.trim();
    if (label.isNotEmpty) return label;
    if (key == LogicalKeyboardKey.space) return 'Space';
    if (key == LogicalKeyboardKey.escape) return 'Escape';
    if (key == LogicalKeyboardKey.arrowLeft) return 'Arrow Left';
    if (key == LogicalKeyboardKey.arrowRight) return 'Arrow Right';
    if (key == LogicalKeyboardKey.arrowUp) return 'Arrow Up';
    if (key == LogicalKeyboardKey.arrowDown) return 'Arrow Down';
    if (key == LogicalKeyboardKey.bracketLeft) return 'Bracket Left';
    if (key == LogicalKeyboardKey.bracketRight) return 'Bracket Right';
    return key.debugName ?? key.keyId.toString();
  }

  /// Desktop keys: the transport tablet/remote convention (space, arrows, F,
  /// Esc).  Returning handled keeps them from leaking to ancestor shortcuts.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final handled = _handleKey(key, event is KeyRepeatEvent);
    if (handled) {
      // ignore: avoid_print
      print('LanPlayer key: ${_keyName(key)}');
      _showControls();
    }
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  bool _handleKey(LogicalKeyboardKey key, bool repeat) {
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
      _player.togglePlay();
      _showHud(_player.isPlaying ? '播放' : '暂停');
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seekRelative(repeat ? -5 : -10);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seekRelative(repeat ? 5 : 10);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _player.setVolume(_player.volume + 0.05);
      _showHud('音量 ${(_player.volume * 100).round()}%');
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _player.setVolume(_player.volume - 0.05);
      _showHud('音量 ${(_player.volume * 100).round()}%');
      return true;
    }
    if (key == LogicalKeyboardKey.keyM) {
      _player.toggleMute();
      _showHud(_player.muted ? '静音' : '取消静音');
      return true;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_fullscreen) {
        _toggleFullscreen();
      } else {
        Navigator.of(context).maybePop();
      }
      return true;
    }
    if (key == LogicalKeyboardKey.bracketLeft) {
      _shiftSubtitle(-100);
      return true;
    }
    if (key == LogicalKeyboardKey.bracketRight) {
      _shiftSubtitle(100);
      return true;
    }
    if (key == LogicalKeyboardKey.keyS) {
      setState(() => _showStats = !_showStats);
      _player.wantsStats = _showStats;
      return true;
    }
    return false;
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
                  tooltip: '快退 10 秒',
                  icon: const Icon(Icons.replay_10),
                  onPressed: () => _seekRelative(-10),
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
                  tooltip: '快进 10 秒',
                  icon: const Icon(Icons.forward_10),
                  onPressed: () => _seekRelative(10),
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
            // 画面/声音等设置入口集中在这一行：速度、画面、字幕、音轨，最后是音量。
            // 用横向滚动兜住窄屏，避免手机上被挤成两行或溢出。
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    onPressed: _openSpeedSheet,
                    icon: const Icon(Icons.speed, size: 18),
                    label: Text('${_player.speed}x'),
                  ),
                  TextButton.icon(
                    key: _pictureKey,
                    onPressed: _openPictureSheet,
                    icon: const Icon(Icons.crop_free, size: 18),
                    label: const Text('画面'),
                  ),
                  TextButton.icon(
                    onPressed: _openTracksSheet,
                    icon: const Icon(Icons.subtitles_outlined, size: 18),
                    label: const Text('字幕'),
                  ),
                  TextButton.icon(
                    onPressed: _openTracksSheet,
                    icon: const Icon(Icons.graphic_eq, size: 18),
                    label: const Text('音轨'),
                  ),
                  IconButton(
                    tooltip: '音量',
                    icon: Icon(
                        _player.muted ? Icons.volume_off : Icons.volume_up),
                    onPressed: () {
                      _player.toggleMute();
                      _showControls();
                    },
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
              fontSize: 11, fontFamily: 'monospace', color: Colors.greenAccent),
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
