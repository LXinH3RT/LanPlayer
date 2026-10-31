import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../data/models.dart';
import 'bindings.dart';

typedef _EventCbNative = Void Function(
    Pointer<Void> user, Int32 event, Pointer<Utf8> json, Int64 value);

/// Owns one native player instance and mirrors its state into Flutter.
///
/// The native core pushes events from its own worker threads; they arrive here
/// through NativeCallable.listener (isolate event loop) with an owned JSON
/// string that must be released with lp_string_free.
class PlayerController extends ChangeNotifier {
  PlayerController({NativeCore? core}) : _core = core ?? NativeCore.instance;

  final NativeCore _core;
  Pointer<Void>? _player;
  late final NativeCallable<_EventCbNative> _eventCb =
      NativeCallable<_EventCbNative>.listener(_handleEvent);

  /// 播放位置与字幕的高频通道。
  ///
  /// 内核每 200 ms 推一次 POSITION；带 `\t` 动画或 `\k` 的片子每 20 ms 推
  /// 一次 SUBTITLE。这两个事件只影响进度条和字幕层，走 [notifyListeners]
  /// 会让整页控件树（顶栏、底栏、按钮行列）跟着 50 Hz 重建 —— 界面上看不
  /// 出差别，白白烧掉一个核。监听方按需订阅这两个 notifier 即可。
  final ValueNotifier<int> positionUsNotifier = ValueNotifier<int>(0);
  final ValueNotifier<SubtitleCue> cueNotifier =
      ValueNotifier<SubtitleCue>(SubtitleCue.empty);

  PlayerState state = PlayerState.idle;
  int positionUs = 0;
  int durationUs = 0;
  MediaInfo media = MediaInfo.empty;
  SubtitleCue cue = SubtitleCue.empty;
  String? error;
  String hwActive = 'none';
  double fps = 0;
  int dropped = 0;
  int avDiffUs = 0;
  int queuedPackets = 0;
  bool buffering = false;
  double speed = 1.0;
  double volume = 1.0;
  bool muted = false;
  int? textureId;

  /// Set by the player screen; used for auto-advance.
  void Function()? onEnded;

  /// Address of the native player, handed to the platform texture bridge.
  Pointer<Void>? get nativeHandle => _player;

  bool get isPlaying => state == PlayerState.playing;
  bool get hasVideo => media.video != null;
  double get aspectRatio {
    final v = media.video;
    if (v == null || v.height == 0) return 16 / 9;
    return v.width / v.height;
  }

  Pointer<Void> get _handle {
    final p = _player;
    if (p == null) {
      throw StateError('player not initialised');
    }
    return p;
  }

  void initialize() {
    if (_player != null) return;
    final p = _core.createPlayer();
    _player = p;
    _core.setEventCallback(p, _eventCb.nativeFunction, nullptr);
  }

  /// Android: attach the SurfaceTexture owned by the platform view — the
  /// native side draws straight into `windowPtr`.
  ///
  /// Desktop: the window is drawn by the platform plugin, so the core never
  /// sees the window handle; `textureId` is only recorded here so the UI can
  /// build a `Texture` widget.
  void attachVideo(
      {int? textureId,
      int windowPtr = 0,
      int width = 1080,
      int height = 1920}) {
    this.textureId = textureId;
    final p = _player;
    if (p == null) return;
    if (windowPtr != 0) {
      _core.setSurface(p, windowPtr, width, height);
    }
  }

  void setSurfaceSize(int width, int height) {
    final p = _player;
    if (p == null) return;
    _core.setSurfaceSize(p, width, height);
  }

  void open(
    String url,
    PlaybackSettings settings, {
    bool autoPlay = true,
    Map<String, dynamic> extra = const {},
  }) {
    initialize();
    error = null;
    buffering = true;
    // 换片必须把上一集的运行时状态清零。留着的话：连播切集后时长条还是上一集
    // 的长度、字幕还停在上一集最后一句、进度从上一集的位置跳一下再回来。
    // 内核那边 open 成功后才发 MEDIA_INFO/POSITION，中间这几百毫秒界面读到的
    // 就是这些陈旧值。
    positionUs = 0;
    durationUs = 0;
    media = MediaInfo.empty;
    cue = SubtitleCue.empty;
    speed = settings.speed;
    positionUsNotifier.value = 0;
    cueNotifier.value = SubtitleCue.empty;
    final options = <String, dynamic>{
      // Transport credentials first: the core needs them to auto-load sidecar
      // subtitles from the same SMB directory.
      ...extra,
      'hw': settings.hardwareDecoding ? 'auto' : 'sw',
      'deinterlace': settings.deinterlace,
      'scale_mode': settings.scaleMode,
      'speed': settings.speed,
      'volume': settings.volume,
      'subtitle_delay': settings.subtitleDelayMs,
      'auto_play': autoPlay,
    };
    final rc = _core.open(_handle, url, options);
    if (rc != 0) {
      error = '无法打开媒体 (code $rc)';
      state = PlayerState.error;
      notifyListeners();
    }
  }

  void play() {
    final p = _player;
    if (p != null) _core.play(p);
  }

  void pause() {
    final p = _player;
    if (p != null) _core.pause(p);
  }

  void togglePlay() => isPlaying ? pause() : play();

  void seekTo(int micros) {
    final p = _player;
    if (p == null) return;
    positionUs = micros.clamp(0, durationUs == 0 ? micros : durationUs);
    positionUsNotifier.value = positionUs;
    _core.seek(p, positionUs);
    notifyListeners();
  }

  void seekBy(int deltaUs) => seekTo(positionUs + deltaUs);

  void setSpeed(double value) {
    final p = _player;
    if (p == null) return;
    // 区间与 PlaybackSettings.speedSteps 一致：这里如果比档位窄，0.25× 会被
    // 静默钳成 0.5，用户点两次「减速」看到的是同一个速度。
    speed = value.clamp(PlaybackSettings.speedMin, PlaybackSettings.speedMax);
    _core.setSpeed(p, speed);
    notifyListeners();
  }

  void setVolume(double value) {
    final p = _player;
    if (p == null) return;
    volume = value.clamp(0.0, 2.0);
    _core.setVolume(p, volume);
    notifyListeners();
  }

  void toggleMute() {
    final p = _player;
    if (p == null) return;
    muted = !muted;
    _core.setMute(p, muted);
    notifyListeners();
  }

  void selectAudio(int streamIndex) {
    final p = _player;
    if (p == null) return;
    _core.selectTrack(p, 1, streamIndex);
  }

  void selectSubtitle(int trackIndex) {
    final p = _player;
    if (p == null) return;
    _core.selectTrack(p, 2, trackIndex);
  }

  int addSubtitle(String url, Map<String, dynamic> transportOptions) {
    final p = _player;
    if (p == null) return -1;
    return _core.addSubtitle(p, url, transportOptions);
  }

  void setSubtitleDelay(int delayMs) {
    final p = _player;
    if (p == null) return;
    _core.setSubtitleDelay(p, delayMs);
  }

  void setScaleMode(int mode) {
    final p = _player;
    if (p == null) return;
    _core.setScaleMode(p, mode);
  }

  void setOption(String key, String value) {
    final p = _player;
    if (p == null) return;
    _core.setOption(p, key, value);
  }

  Map<String, dynamic>? mediaInfoJson() {
    final p = _player;
    return p == null ? null : _core.mediaInfo(p);
  }

  void _handleEvent(
      Pointer<Void> user, int event, Pointer<Utf8> jsonPtr, int value) {
    String raw;
    try {
      raw = jsonPtr.address == 0 ? '{}' : jsonPtr.toDartString();
    } finally {
      _core.freeNativeString(jsonPtr);
    }
    final map = decodeJson(raw) ?? const <String, dynamic>{};
    switch (event) {
      case LpEvent.state:
        state = playerStateFromInt((map['state'] as num?)?.toInt() ?? 0);
        if (state == PlayerState.error) {
          buffering = false;
        }
        break;
      case LpEvent.position:
        // 进度条与时间标签自己订阅 positionUsNotifier，不走整页重建。
        // 只有时长第一次确定（或换片后变了）时才需要通知整页。
        final pos = (map['pos'] as num?)?.toInt() ?? 0;
        final dur = (map['dur'] as num?)?.toInt() ?? 0;
        positionUs = pos;
        positionUsNotifier.value = pos;
        if (dur > 0 && dur != durationUs) {
          durationUs = dur;
          notifyListeners();
        }
        return;
      case LpEvent.mediaInfo:
      case LpEvent.tracks:
        // An empty payload means "the core had nothing to say", not "this file
        // has no tracks". Older cores emitted exactly that on open, which wiped
        // the list MEDIA_INFO had just delivered and made the sheets claim the
        // file had 0 embedded subtitles. Keep the previous list in that case.
        if (map.isEmpty) {
          break;
        }
        media = MediaInfo.fromJson(map);
        if (media.durationUs > 0) durationUs = media.durationUs;
        hwActive = media.hw;
        buffering = false;
        break;
      case LpEvent.error:
        error = map['message'] as String? ?? '播放失败';
        state = PlayerState.error;
        buffering = false;
        break;
      case LpEvent.ended:
        state = PlayerState.ended;
        final cb = onEnded;
        if (cb != null) cb();
        break;
      case LpEvent.subtitle:
        cue = SubtitleCue.fromJson(map);
        // 字幕层自己订阅这个通道，别再触发整页重建。
        cueNotifier.value = cue;
        return;
      case LpEvent.stats:
        fps = (map['fps'] as num?)?.toDouble() ?? 0;
        dropped = (map['dropped'] as num?)?.toInt() ?? 0;
        avDiffUs = (map['av_diff'] as num?)?.toInt() ?? 0;
        queuedPackets = (map['queued'] as num?)?.toInt() ?? 0;
        final hw = map['hw'] as String?;
        if (hw != null) hwActive = hw;
        // Lighter cadence: stats change constantly, do not rebuild the tree
        // unless the user asked for the debugging overlay.
        if (!wantsStats) return;
        break;
      case LpEvent.buffering:
        buffering = map['buffering'] == true;
        break;
      case LpEvent.log:
        // 内核当前只在调试构建里发这条，桌面/发布版永远收不到。留一个空
        // 分支而不是掉进 default，是为了让「这个编号是已知的」写进代码。
        return;
      default:
        return;
    }
    notifyListeners();
  }

  /// 关掉时 stats 事件不再通知，省掉每秒一次的重建；界面要在面板里显示
  /// 实时数字之前必须先把这里打开。
  bool wantsStats = false;

  bool _torn = false;

  /// 关掉内核播放器并回收资源。同步完成 —— 内核侧的 close / destroy 都是
  /// 同步调用，这里只是把 FFI 调用和通知器收尾集中到一处。
  ///
  /// 返回 true 表示这次调用真的收拾了；重复调用返回 false，调用方据此决定
  /// 要不要再走 `super.dispose()`（重复 dispose 在 debug 下会抛）。
  bool _teardown() {
    if (_torn) return false;
    _torn = true;
    final p = _player;
    _player = null;
    if (p != null) {
      _core.close(p);
      _core.destroyPlayer(p);
    }
    _eventCb.close();
    positionUsNotifier.dispose();
    cueNotifier.dispose();
    return true;
  }

  /// 与 [dispose] 同义，保留异步签名给「先关页面、再等一拍」的调用点。
  Future<void> disposePlayer() async {
    if (!_teardown()) return;
    super.dispose();
  }

  @override
  void dispose() {
    if (!_teardown()) return;
    super.dispose();
  }
}
