import 'shortcuts.dart';
import 'track_prefs.dart';

enum PlayerState {
  idle,
  opening,
  ready,
  playing,
  paused,
  stopped,
  ended,
  error
}

PlayerState playerStateFromInt(int v) => v >= 0 && v < PlayerState.values.length
    ? PlayerState.values[v]
    : PlayerState.idle;

/// 界面配色。`system` 跟随操作系统的深浅色设置。
///
/// 存进 settings.json 的是 [id] 而不是枚举名：枚举名是重构就会变的东西，
/// 而用户的偏好不该跟着代码改名一起丢。
enum AppThemeMode {
  system('system', '跟随系统'),
  dark('dark', '黑色'),
  light('light', '白色');

  const AppThemeMode(this.id, this.label);

  final String id;
  final String label;

  static AppThemeMode fromId(Object? raw,
      [AppThemeMode fallback = defaultMode]) {
    if (raw is String) {
      for (final m in AppThemeMode.values) {
        if (m.id == raw) return m;
      }
    }
    return fallback;
  }

  /// 默认是黑色：播放页本来就要把界面消失掉，深色是主场景。
  static const AppThemeMode defaultMode = AppThemeMode.dark;
}

/// User facing playback preferences, persisted as one JSON blob.
class PlaybackSettings {
  bool hardwareDecoding;
  bool deinterlace;
  int scaleMode; // 0 fit, 1 fill, 2 stretch
  double speed;
  double volume;
  bool autoNext;
  double subtitleScale;
  int subtitleDelayMs;

  /// 是否记住上次播放位置。关闭后既不恢复旧进度，也不再写入新的进度记录，
  /// 但已经存下的历史不会被删除（重新打开开关就能接着用）。
  bool rememberProgress;

  /// 默认音轨的语言偏好（首选 / 次选）。`auto` = 跟随容器默认标记。
  TrackPreference audioPreference;

  /// 默认字幕轨的语言偏好。
  TrackPreference subtitlePreference;

  /// 快进/快退一次跳多少秒。播放页的按钮与方向键共用这一个步长。
  ///
  /// 用户要求「必须是整数且大于等于 1 小于等于 10」，所以读写两头都夹紧：
  /// 只在界面上限制不够，`settings.json` 是可以手改的，读到 0 会让快进退
  /// 变成原地不动，读到 999 一点就跳到片尾。
  int seekStepSeconds;

  static const int seekStepMin = 1;
  static const int seekStepMax = 10;
  static const int seekStepDefault = 10;

  /// 界面配色。默认黑色（见 [AppThemeMode.defaultMode]）。
  AppThemeMode themeMode;

  /// 手机上打开片子时是否强制横屏。
  ///
  /// 默认开着：竖屏看横片，画面只占中间一条，字幕和底栏全挤在一起。但平板
  /// 上有人就是习惯竖着看，所以它留成可关的一项，而不是写死在播放页里 ——
  /// 桌面端不读这个字段，窗口由用户自己拉。
  bool lockLandscape;

  /// 字幕字号允许的档位（用户 2026-11-01 要求把滑杆换成下拉）。
  ///
  /// 固定档位而不是连续值：滑杆拖出来的 1.37 这种值在界面上既说不清是
  /// 「大一点」还是「很大」，也没法和别人的配置对比。0.6–2.0 覆盖了实际
  /// 需要的范围（0.6 给小屏叠满中文双行，2.0 给远距离观看）。
  static const List<double> subtitleScaleSteps = [
    0.6,
    0.7,
    0.8,
    0.9,
    1.0,
    1.1,
    1.2,
    1.3,
    1.5,
    1.75,
    2.0,
  ];

  /// 字幕延迟允许的档位（毫秒）。负数是提前。
  ///
  /// 步长 100 ms：人眼能分辨的字幕错位大约是 100 ms 量级，再细的档位在
  /// 观感上和相邻档没有区别，只会让下拉列表长到要滚动。
  static const List<int> subtitleDelaySteps = [
    -3000,
    -2000,
    -1500,
    -1000,
    -500,
    -300,
    -200,
    -100,
    0,
    100,
    200,
    300,
    500,
    1000,
    1500,
    2000,
    3000,
  ];

  /// 把任意来源的字号吸附到最近的合法档位。
  ///
  /// 只夹区间不够：老配置里存过 1.37 这类值，下拉框按值精确匹配，
  /// 不吸附就一个档位都不选中。
  static double clampSubtitleScale(Object? raw) {
    final v = raw is num ? raw.toDouble() : 1.0;
    var best = subtitleScaleSteps.first;
    var bestGap = (v - best).abs();
    for (final s in subtitleScaleSteps.skip(1)) {
      final gap = (v - s).abs();
      if (gap < bestGap) {
        best = s;
        bestGap = gap;
      }
    }
    return best;
  }

  /// 把任意来源的延迟吸附到最近的合法档位。
  static int clampSubtitleDelay(Object? raw) {
    final v = raw is num ? raw.toInt() : 0;
    var best = subtitleDelaySteps.first;
    var bestGap = (v - best).abs();
    for (final s in subtitleDelaySteps.skip(1)) {
      final gap = (v - s).abs();
      if (gap < bestGap) {
        best = s;
        bestGap = gap;
      }
    }
    return best;
  }

  /// 键盘快捷键的用户绑定。只存与默认不同项，见 `shortcuts.dart`。
  ShortcutBindings shortcuts;

  /// 播放倍速只允许这几档（用户 2026-10-30 指定）。
  ///
  /// 播放页的倍速面板与设置页的「默认倍速」共用这一份 —— 两边档位不一致
  /// 会让用户以为设置没生效。0.25 比 0.5 更慢，适合逐句对字幕；超过 2.0
  /// 音调补偿会明显失真，所以不给。
  static const List<double> speedSteps = [
    0.25,
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
  ];

  static const double speedDefault = 1.0;

  /// 档位区间的两端，给 `PlayerController.setSpeed` 做夹紧用。
  ///
  /// 写成 getter 而不是常量字面量，是为了只有一个地方能改档位：改
  /// `speedSteps` 就自动跟着变。
  static double get speedMin => speedSteps.first;
  static double get speedMax => speedSteps.last;

  /// 把任意来源的值吸附到最近的合法档位。
  ///
  /// 只做区间夹紧不够：内核对任意小数都收，但界面上的 RadioListTile 用
  /// groupValue 精确匹配，1.3 这种老值会让所有档位都不选中。吸附到最近
  /// 档位后界面总有落点。
  static double clampSpeed(Object? raw) {
    final v = raw is num ? raw.toDouble() : speedDefault;
    var best = speedSteps.first;
    var bestGap = (v - best).abs();
    for (final s in speedSteps.skip(1)) {
      final gap = (v - s).abs();
      if (gap < bestGap) {
        best = s;
        bestGap = gap;
      }
    }
    return best;
  }

  /// 把任意来源的值夹到 [seekStepMin]..[seekStepMax]。
  static int clampSeekStep(Object? raw) {
    final v = raw is num ? raw.toInt() : seekStepDefault;
    if (v < seekStepMin) return seekStepMin;
    if (v > seekStepMax) return seekStepMax;
    return v;
  }

  PlaybackSettings({
    this.hardwareDecoding = true,
    this.deinterlace = false,
    this.scaleMode = 0,
    this.speed = 1.0,
    this.volume = 1.0,
    this.autoNext = true,
    this.subtitleScale = 1.0,
    this.subtitleDelayMs = 0,
    this.rememberProgress = true,
    // 默认偏中文：用户报的就是多音轨片子落到英文轨上。
    this.audioPreference = const TrackPreference(primary: 'zh'),
    this.subtitlePreference = const TrackPreference(primary: 'zh'),
    this.seekStepSeconds = seekStepDefault,
    this.themeMode = AppThemeMode.defaultMode,
    this.lockLandscape = true,
    ShortcutBindings? shortcuts,
  }) : shortcuts = shortcuts ?? ShortcutBindings.empty;

  Map<String, dynamic> toJson() => {
        'hardware_decoding': hardwareDecoding,
        'deinterlace': deinterlace,
        'scale_mode': scaleMode,
        'speed': speed,
        'volume': volume,
        'auto_next': autoNext,
        'subtitle_scale': subtitleScale,
        'subtitle_delay_ms': subtitleDelayMs,
        'remember_progress': rememberProgress,
        'audio_primary': audioPreference.primary,
        'audio_secondary': audioPreference.secondary,
        'subtitle_primary': subtitlePreference.primary,
        'subtitle_secondary': subtitlePreference.secondary,
        'seek_step_seconds': seekStepSeconds,
        'theme_mode': themeMode.id,
        'lock_landscape': lockLandscape,
        // 空表就整个不写：老版本读到未知字段会原样保留，但没必要让
        // settings.json 多一个空对象。
        if (!shortcuts.isDefault) 'shortcuts': shortcuts.toJson(),
      };

  factory PlaybackSettings.fromJson(Map<String, dynamic> j) => PlaybackSettings(
        hardwareDecoding: j['hardware_decoding'] as bool? ?? true,
        deinterlace: j['deinterlace'] as bool? ?? false,
        scaleMode: (j['scale_mode'] as num?)?.toInt() ?? 0,
        // 吸附到最近的合法档位：老配置里存过 1.3 这类值，界面上的
        // RadioListTile 精确匹配，不吸附就一个档位都不选中。
        speed: clampSpeed(j['speed']),
        volume: (j['volume'] as num?)?.toDouble() ?? 1.0,
        autoNext: j['auto_next'] as bool? ?? true,
        subtitleScale: clampSubtitleScale(j['subtitle_scale']),
        subtitleDelayMs: clampSubtitleDelay(j['subtitle_delay_ms']),
        // 默认开启：老版本没有这个字段时就应当继续记进度。
        rememberProgress: j['remember_progress'] as bool? ?? true,
        // 老配置没有这两个字段时：音频和字幕都偏中文。
        // 默认给中文是因为用户报的就是「多音轨的片子默认播了英文轨」——
        // 留成 auto 等于把 bug 留着让用户自己去设置里改。
        audioPreference: TrackPreference(
          primary: j['audio_primary'] as String? ?? 'zh',
          secondary: j['audio_secondary'] as String? ?? 'auto',
        ),
        subtitlePreference: TrackPreference(
          primary: j['subtitle_primary'] as String? ?? 'zh',
          secondary: j['subtitle_secondary'] as String? ?? 'auto',
        ),
        // 老配置里没有这个字段，用默认的 10 秒，与改动前的行为一致。
        seekStepSeconds: clampSeekStep(j['seek_step_seconds']),
        // 老配置里没有这个字段时按默认设置（黑色）走。
        themeMode: AppThemeMode.fromId(j['theme_mode']),
        // 老配置没有这个字段：手机从这一版起默认横屏。
        lockLandscape: j['lock_landscape'] as bool? ?? true,
        shortcuts: ShortcutBindings.fromJson(j['shortcuts']),
      );

  PlaybackSettings copy() => PlaybackSettings.fromJson(toJson());
}
