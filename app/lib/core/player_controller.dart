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
  void Function()? onReady;

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

  /// Android: attach the SurfaceTexture owned by the platform view.
  /// Apple: installs the frame callback used by the FlutterTexture bridge.
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
    _core.seek(p, positionUs);
    notifyListeners();
  }

  void seekBy(int deltaUs) => seekTo(positionUs + deltaUs);

  void setSpeed(double value) {
    final p = _player;
    if (p == null) return;
    speed = value.clamp(0.5, 2.0);
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
      case 1: // state
        state = playerStateFromInt((map['state'] as num?)?.toInt() ?? 0);
        if (state == PlayerState.error) {
          buffering = false;
        }
        break;
      case 2: // position
        positionUs = (map['pos'] as num?)?.toInt() ?? 0;
        final dur = (map['dur'] as num?)?.toInt() ?? 0;
        if (dur > 0) durationUs = dur;
        break;
      case 3: // media info
      case 10: // tracks
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
        onReady?.call();
        buffering = false;
        break;
      case 4: // error
        error = map['message'] as String? ?? '播放失败';
        state = PlayerState.error;
        buffering = false;
        break;
      case 5: // ended
        state = PlayerState.ended;
        final cb = onEnded;
        if (cb != null) cb();
        break;
      case 6: // subtitle
        cue = SubtitleCue.fromJson(map);
        break;
      case 7: // stats
        fps = (map['fps'] as num?)?.toDouble() ?? 0;
        dropped = (map['dropped'] as num?)?.toInt() ?? 0;
        avDiffUs = (map['av_diff'] as num?)?.toInt() ?? 0;
        queuedPackets = (map['queued'] as num?)?.toInt() ?? 0;
        final hw = map['hw'] as String?;
        if (hw != null) hwActive = hw;
        // Lighter cadence: stats change constantly, do not rebuild the tree
        // unless the user asked for the debugging overlay.
        if (!_wantsStats) return;
        break;
      case 9: // buffering
        buffering = map['buffering'] == true;
        break;
      default:
        return;
    }
    notifyListeners();
  }

  bool _wantsStats = false;

  set wantsStats(bool v) {
    _wantsStats = v;
  }

  Future<void> disposePlayer() async {
    final p = _player;
    _player = null;
    if (p != null) {
      _core.close(p);
      _core.destroyPlayer(p);
    }
    _eventCb.close();
    super.dispose();
  }

  @override
  void dispose() {
    // Fire and forget: closing is synchronous on the native side.
    final p = _player;
    _player = null;
    if (p != null) {
      _core.close(p);
      _core.destroyPlayer(p);
    }
    _eventCb.close();
    super.dispose();
  }
}
