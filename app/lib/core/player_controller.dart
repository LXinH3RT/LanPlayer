import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../data/trace.dart';
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

  /// 内核已按时交帧、但宿主没来得及取走而被覆盖的帧数（仅 Apple 平台非零）。
  ///
  /// 与 [dropped] 分开：那个是内核自己判定「这一帧晚了，不显示」，
  /// 这个是「内核照常出帧，交付环节丢的」。画面卡顿而音频正常时，
  /// 两者要分别看才能判断该修同步逻辑还是修纹理交付。
  int droppedDelivery = 0;

  /// 最近一个统计周期内，相邻两次取帧的最大间隔（毫秒，仅 Apple 平台非零）。
  ///
  /// [droppedDelivery] 统计的是「这一帧根本没被取走」；[pullGapMs] 统计的是
  /// 「取走了，但隔了很久才取」。后者更接近卡顿的观感：一秒交满 24 帧、一帧
  /// 不丢，只要其中几帧晚到 100 ms 以上，屏幕就是一跳一跳的。正常值应当
  /// 贴着帧周期（24 fps ≈ 42 ms），超过 100 ms 就能看出来。
  int pullGapMs = 0;

  /// 同一周期内，取帧间隔超过 1.5 个帧周期的次数。
  ///
  /// 每秒有 3 次以上就说明节奏是坏的，而 fps / dropped 两项都可能完全正常。
  int pullStalls = 0;

  /// 同一周期内，内核相邻两次「交出帧」的最大间隔与平均间隔（毫秒）。
  ///
  /// [pullGapMs] 量的是引擎按 vsync 来要帧的间隔，天生被刷新率量化
  /// （60 Hz 上只会出现 50 / 66 / 83 这种台阶），分不清「解码吐得不均」
  /// 与「引擎取帧对不齐」。这两个数在内核侧量，两个一对比就能定性：
  /// 内核侧也很乱 → 解码节奏有问题；内核侧很稳而 [pullGapMs] 在跳
  /// → 问题在引擎侧，改内核没用。
  int pushGapMs = 0;
  int pushAvgMs = 0;

  /// 本周期内引擎调用 `copyPixelBuffer` 的次数与其中真的拿到新帧的次数。
  ///
  /// [pullGapMs] 只统计「交出去了」的那些调用，所以它天生被内核的出帧节奏
  /// 限住：内核每秒给 24 帧，这个值就不低于 41.7 ms，此时它反映的是内核而
  /// 不是引擎。计数才能看出引擎自己有没有掉队：60 Hz 屏正常应接近 60 / 24，
  /// 120 Hz ProMotion 应接近 120 / 24。次数明显偏低说明 raster 线程在丢
  /// vsync，那是引擎侧的问题，调内核出帧节奏解决不了。
  int pullCalls = 0;
  int pullHits = 0;

  /// 连续「来取了但没有新帧」的最长次数，等价于画面停住了几个 vsync。
  ///
  /// 内核每秒给 24 帧时，60 Hz 屏上连续空 1–2 次是正常的（3-2-3-2 交替）；
  /// 出现二十几次就是肉眼可见的停顿。这是唯一直接对应观感的量。
  int pullNullRun = 0;

  /// 帧「准备好了」到「被取走」之间的等待（毫秒），本周期最大值与均值。
  ///
  /// 前面几个量都只看同向相邻的间隔：[pushGapMs] 是两次 publish 之间，
  /// [pullGapMs] 是两次 pull 之间。两者可以完全正常，而整条流水线一直恒定
  /// 落后几百毫秒——间隔不变，只是整体平移，所有指标照旧全绿。
  /// 观感上的「流畅一段、卡住一段」正是这种落后在来回摆。
  /// 这是唯一跨方向的一对量，超过一两帧就是「帧在那儿摆着没人取」。
  int pullWaitMs = 0;
  int pullWaitAvgMs = 0;

  /// 取帧间隔按帧周期分档的次数：少于一个帧周期、一到一点五个、超过
  /// 一点五个。
  ///
  /// 24 fps 放在 60 Hz 屏上，每帧要么占 2 个 vsync 要么占 3 个，这是
  /// 3:2 pulldown，本身正常。能不能看出来全看这两个比例是不是均匀交替：
  /// 均匀交替只是轻微的顿挫感，连续几个 2 再连续几个 3 就成了肉眼可见的
  /// 一顿一顿。24 fps 每秒 24 次取帧，正常应当 fast 与 mid 各占一半左右，
  /// 而 slow 必须接近 0 —— slow 出现的次数就是画面上真正「停住」的次数。
  int pullFast = 0;
  int pullMid = 0;
  int pullSlow = 0;

  /// 解码器内部丢掉的帧数（累计）。
  ///
  /// 与 [dropped]、[droppedDelivery] 都不是一回事：VideoToolbox 的输出队列
  /// 满了会顶掉最旧的一帧，MediaCodec 的输出缓冲交不回去也会丢。这些帧从来
  /// 没进过内核，所以既不在 decoded 里也不在 dropped 里 —— 只看那两个数会
  /// 以为一帧都没丢，而画面确实少了一帧。
  int decoderDropped = 0;

  /// 帧数守恒的差额：解码器交出的帧减去上屏、迟到丢帧、seek 作废三者之和。
  ///
  /// 正常恒为 0。不为 0 就说明有一帧在某条分支里被无声吞掉 —— 这正是
  /// 「一帧没丢、画面却在卡」时唯一能自证的东西。
  int framesUnaccounted = 0;

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
    // 每开一片都从设置里的增益起步（1.0 = 跟随系统音量）。播放中调的音量
    // 只活在这一次播放里，不写回设置 —— 它是「这一片想听大声点」，不是
    // 「以后每一片都这样」。
    volume = settings.volumeGain;
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
      'volume': settings.volumeGain,
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

  /// 把目标位置夹进 `[0, durationUs]`。
  ///
  /// 时长未知时（`durationUs == 0`，解复用还没结束、或者直播）只能保证非负。
  /// 直接写 `micros.clamp(0, durationUs)` 在这里是错的：durationUs 为 0 而
  /// micros 为负（回到片头、键盘连按左方向）时，上界比下界小，clamp 会抛
  /// `ArgumentError: Invalid argument(s): 0`。
  static int clampPosition(int micros, int durationUs) {
    if (durationUs <= 0) return micros < 0 ? 0 : micros;
    return micros.clamp(0, durationUs);
  }

  void seekTo(int micros) {
    final p = _player;
    if (p == null) return;
    positionUs = clampPosition(micros, durationUs);
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
        droppedDelivery = (map['dropped_delivery'] as num?)?.toInt() ?? 0;
        pullGapMs = (map['pull_gap_ms'] as num?)?.toInt() ?? 0;
        pullStalls = (map['pull_stalls'] as num?)?.toInt() ?? 0;
        pushGapMs = (map['push_gap_ms'] as num?)?.toInt() ?? 0;
        pushAvgMs = (map['push_avg_ms'] as num?)?.toInt() ?? 0;
        pullCalls = (map['pull_calls'] as num?)?.toInt() ?? 0;
        pullHits = (map['pull_hits'] as num?)?.toInt() ?? 0;
        pullNullRun = (map['pull_null_run'] as num?)?.toInt() ?? 0;
        pullWaitMs = (map['pull_wait_ms'] as num?)?.toInt() ?? 0;
        pullWaitAvgMs = (map['pull_wait_avg_ms'] as num?)?.toInt() ?? 0;
        pullFast = (map['pull_fast'] as num?)?.toInt() ?? 0;
        pullMid = (map['pull_mid'] as num?)?.toInt() ?? 0;
        pullSlow = (map['pull_slow'] as num?)?.toInt() ?? 0;
        decoderDropped = (map['decoder_dropped'] as num?)?.toInt() ?? 0;
        framesUnaccounted = (map['frames_unaccounted'] as num?)?.toInt() ?? 0;
        avDiffUs = (map['av_diff'] as num?)?.toInt() ?? 0;
        queuedPackets = (map['queued'] as num?)?.toInt() ?? 0;
        final hw = map['hw'] as String?;
        if (hw != null) hwActive = hw;
        // 「音频正常、画面卡顿」的三种成因要分开看：内核没出帧（解码 / 同步
        // 问题，看 dropped）；内核按时出帧了但 Flutter 侧没画出来
        // （纹理交付问题，看 dropped_delivery）；两样都正常但帧到得忽快忽慢
        // （看 pull_gap / pull_stalls）。第三种最常见，也最难看出来 ——
        // fps 显示 24、dropped 显示 0，屏幕照样一跳一跳。
        // 只有 LANPLAYER_TRACE=1 时落盘。
        trace('stats fps=$fps dropped=$dropped '
            'dropped_delivery=$droppedDelivery gap=${pullGapMs}ms '
            'stalls=$pullStalls push=$pushGapMs/$pushAvgMs ms '
            'decoded=${map['decoded']} '
            'av_diff=${map['av_diff']} queued=$queuedPackets '
            'buffered=${map['buffered_ms']} hw=$hwActive '
            'pull=$pullCalls/$pullHits null=$pullNullRun '
            'wait=$pullWaitMs/${pullWaitAvgMs}ms '
            'seq=$pullFast/$pullMid/$pullSlow '
            'decdrop=$decoderDropped unacc=$framesUnaccounted');
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
