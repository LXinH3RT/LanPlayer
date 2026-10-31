import 'shortcuts.dart';
import 'subtitle_match.dart';
import 'track_prefs.dart';

export 'shortcuts.dart';
export 'subtitle_match.dart';
export 'track_prefs.dart';

/// Mirrors LpState in native/include/lanplayer/lp_types.h
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

  /// 键盘快捷键的用户绑定。只存与出厂不同项，见 `shortcuts.dart`。
  ShortcutBindings shortcuts;

  /// 播放倍速只允许这几档（用户 2026-10-30 指定）。
  ///
  /// 播放页的倍速面板与设置页的「默认倍速」共用这一份 —— 两边档位不一致
  /// 会让用户以为设置没生效。0.25 比 0.5 更慢，适合逐句对字幕；超过 2.0
  /// 音调补偿会明显失真，所以不给。
  static const List<double> speedSteps = [
    0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0,
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
        subtitleScale: (j['subtitle_scale'] as num?)?.toDouble() ?? 1.0,
        subtitleDelayMs: (j['subtitle_delay_ms'] as num?)?.toInt() ?? 0,
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
        shortcuts: ShortcutBindings.fromJson(j['shortcuts']),
      );

  PlaybackSettings copy() => PlaybackSettings.fromJson(toJson());
}

/// A saved SMB endpoint: credentials live in the profile, stored locally.
class ServerProfile {
  final String id;
  String name;
  String host;
  int port;
  String share;
  String user;
  String password;
  DateTime createdAt;
  DateTime? lastUsedAt;

  ServerProfile({
    required this.id,
    this.name = '',
    this.host = '',
    this.port = 445,
    this.share = '',
    this.user = '',
    this.password = '',
    DateTime? createdAt,
    this.lastUsedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Root URL of the share, without credentials.
  String get rootUrl => 'smb://$host${port == 445 ? '' : ':$port'}/$share';

  /// Title of the server card.
  ///
  /// The edit screen no longer asks for a display name — it writes the share
  /// name into [name] — but a profile saved by an older build may have a real
  /// custom name, or an empty one. Falling back to [share] keeps every card
  /// readable instead of showing a blank row.
  String get displayName => name.trim().isEmpty ? share.trim() : name.trim();

  /// URL with userinfo, used for FFmpeg/transport calls.
  String get urlWithCredentials {
    final encodedUser = Uri.encodeComponent(user);
    final encodedPass = Uri.encodeComponent(password);
    return 'smb://$encodedUser:$encodedPass@$host${port == 445 ? '' : ':$port'}/$share';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'share': share,
        'user': user,
        'password': password,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'lastUsedAt': lastUsedAt?.millisecondsSinceEpoch,
      };

  factory ServerProfile.fromJson(Map<String, dynamic> j) => ServerProfile(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? 'SMB',
        host: j['host'] as String? ?? '',
        port: _intValue(j['port']) ?? 445,
        share: j['share'] as String? ?? '',
        user: j['user'] as String? ?? '',
        password: j['password'] as String? ?? '',
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(_intValue(j['createdAt']) ?? 0),
        lastUsedAt: j['lastUsedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                _intValue(j['lastUsedAt']) ?? 0),
      );

  /// Tolerates numbers, numeric strings and ISO-8601 timestamps: a profile
  /// written by an older build must never make the whole server list load fail
  /// (and take the user's saved shares with it).
  static int? _intValue(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) {
      return int.tryParse(raw) ??
          DateTime.tryParse(raw)?.millisecondsSinceEpoch;
    }
    return null;
  }

  Map<String, dynamic> transportOptions({int timeoutMs = 8000}) => {
        'user': user,
        'password': password,
        'timeout_ms': timeoutMs,
      };
}

/// One directory entry returned by the native source layer.
class MediaEntry {
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final DateTime? modified;
  final String kind; // dir | video | subtitle | audio | image | other
  final String ext;

  const MediaEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.kind,
    required this.ext,
    this.modified,
  });

  bool get isVideo => kind == 'video';
  bool get isSubtitle => kind == 'subtitle';

  /// 「这个文件现在这一版」的标记。
  ///
  /// 同名文件被替换后，修改时间或大小至少有一个会变，所以把它拼进缩略图的
  /// 缓存键，刷新后封面才会跟着换。两者都没有（老服务器不给 mtime、空文件
  /// 也不该复用别人的封面）时返回 null，调用方退回只按 URL 缓存。
  String? get version {
    if (modified == null && size == 0) return null;
    return '${modified?.millisecondsSinceEpoch ?? 0}-$size';
  }

  factory MediaEntry.fromJson(Map<String, dynamic> j) {
    final mtime = (j['mtime'] as num?)?.toInt() ?? 0;
    return MediaEntry(
      name: j['name'] as String? ?? '',
      path: j['path'] as String? ?? '',
      isDir: j['is_dir'] == true,
      size: (j['size'] as num?)?.toInt() ?? 0,
      kind: j['kind'] as String? ?? 'other',
      ext: j['ext'] as String? ?? '',
      modified:
          mtime > 0 ? DateTime.fromMillisecondsSinceEpoch(mtime * 1000) : null,
    );
  }
}

class DirectoryListing {
  final String url;
  final String parent;
  final List<MediaEntry> entries;

  const DirectoryListing(
      {required this.url, required this.parent, required this.entries});

  List<MediaEntry> get videos => entries.where((e) => e.isVideo).toList();
  List<MediaEntry> get folders => entries.where((e) => e.isDir).toList();
  List<MediaEntry> get subtitles => entries.where((e) => e.isSubtitle).toList();

  /// 找出属于 [video] 的外挂字幕。
  ///
  /// 常见命名有这几类，都要能对上：
  ///   `电影.mkv` + `电影.srt`
  ///   `电影.mkv` + `电影.zh-CN.srt` / `电影.zh.srt` / `电影.eng.ass`
  ///   `S01E01.mkv` + `S01E01.简体.srt`
  ///   `电影.mkv` + `电影.chs&eng.ass`
  ///
  /// 判定规则见 `subtitle_match.dart`：主干相同、主干 + 分隔符前缀、集数相同、
  /// 或去掉发布组/语言标签后仍能对上。单纯的主干前缀不算 —— `电影2.srt`
  /// 不会错配到 `电影.mkv` 上。
  ///
  /// 同一组里保持原有顺序（通常已按名称排序），方便按语言习惯挑默认项。
  List<MediaEntry> subtitlesFor(MediaEntry video) {
    if (!video.isVideo) return const [];
    final out = <MediaEntry>[];
    for (final s in subtitles) {
      if (subtitleBelongsTo(video.name, s.name)) {
        out.add(s);
      }
    }
    return out;
  }

  /// 没有被任何视频认领的字幕。
  ///
  /// 现实里确实会出现（比如最后一集还没下载、或文件名对不上）。这些文件
  /// **不能悄悄消失** —— 用户会以为播放器漏列了东西。所以让它们单独显示，
  /// 并标注「未关联」，同时仍然可以点开手动加载。
  List<MediaEntry> get orphanSubtitles {
    final owned = <String>{};
    for (final v in videos) {
      for (final s in subtitlesFor(v)) {
        owned.add(s.path);
      }
    }
    return subtitles.where((s) => !owned.contains(s.path)).toList();
  }

  /// 浏览列表里真正要显示的行：目录 + 视频 + 音频 + 无主字幕。
  ///
  /// **有归属的字幕不单独占一行** —— 它们已经被挂到对应视频下面（见
  /// [subtitlesFor]）。`.txt`/`.docx` 之类则由内核在列目录时就滤掉了
  /// （`lp_is_listable_media`），这里再兜一层，防止历史数据或其它来源漏进来。
  List<MediaEntry> get browsable {
    final orphans = orphanSubtitles;
    return entries
        .where((e) =>
            e.isDir ||
            e.isVideo ||
            e.kind == 'audio' ||
            orphans.any((o) => o.path == e.path))
        .toList();
  }

  factory DirectoryListing.fromJson(Map<String, dynamic> j) {
    final raw = (j['entries'] as List?) ?? const [];
    return DirectoryListing(
      url: j['url'] as String? ?? '',
      parent: j['parent'] as String? ?? '',
      entries: raw
          .whereType<Map<String, dynamic>>()
          .map(MediaEntry.fromJson)
          .toList(growable: false),
    );
  }
}

class AudioTrack {
  final int index;
  final String codec;
  final int channels;
  final int sampleRate;
  final String lang;
  final String title;

  const AudioTrack({
    required this.index,
    required this.codec,
    required this.channels,
    required this.sampleRate,
    required this.lang,
    required this.title,
  });

  String get label {
    final parts = <String>[];
    if (title.isNotEmpty) parts.add(title);
    if (lang.isNotEmpty) parts.add(lang.toUpperCase());
    parts.add('$channels ch');
    parts.add(codec);
    return parts.join(' · ');
  }

  factory AudioTrack.fromJson(Map<String, dynamic> j) => AudioTrack(
        index: (j['index'] as num?)?.toInt() ?? -1,
        codec: j['codec'] as String? ?? '',
        channels: (j['channels'] as num?)?.toInt() ?? 0,
        sampleRate: (j['rate'] as num?)?.toInt() ?? 0,
        lang: j['lang'] as String? ?? '',
        title: j['title'] as String? ?? '',
      );
}

class SubtitleTrack {
  final int index;
  final String codec;
  final String lang;
  final String title;
  final bool external;
  final bool selected;

  /// Graphics subtitle (PGS / VobSub / DVB): the core composites the bitmaps
  /// itself, so there is no text event to render in Flutter.
  final bool bitmap;

  const SubtitleTrack({
    required this.index,
    required this.codec,
    required this.lang,
    required this.title,
    required this.external,
    required this.selected,
    this.bitmap = false,
  });

  String get label {
    final parts = <String>[];
    if (title.isNotEmpty) parts.add(title);
    if (lang.isNotEmpty) parts.add(lang.toUpperCase());
    if (external) parts.add('外挂');
    if (bitmap) parts.add('图形');
    return parts.isEmpty ? '字幕 #$index' : parts.join(' · ');
  }

  factory SubtitleTrack.fromJson(Map<String, dynamic> j) => SubtitleTrack(
        index: (j['index'] as num?)?.toInt() ?? -1,
        codec: j['codec'] as String? ?? '',
        lang: j['lang'] as String? ?? '',
        title: j['title'] as String? ?? '',
        external: j['external'] == true,
        selected: j['selected'] == true,
        bitmap: j['bitmap'] == true,
      );
}

class VideoInfo {
  final int width;
  final int height;
  final String codec;
  final double fps;
  final String pixFmt;
  final int bitrate;

  const VideoInfo({
    required this.width,
    required this.height,
    required this.codec,
    required this.fps,
    required this.pixFmt,
    required this.bitrate,
  });

  String get label => '$codec ${width}x$height ${fps.toStringAsFixed(2)}fps';

  factory VideoInfo.fromJson(Map<String, dynamic> j) => VideoInfo(
        width: (j['width'] as num?)?.toInt() ?? 0,
        height: (j['height'] as num?)?.toInt() ?? 0,
        codec: j['codec'] as String? ?? '',
        fps: (j['fps'] as num?)?.toDouble() ?? 0,
        pixFmt: j['pix_fmt'] as String? ?? '',
        bitrate: (j['bitrate'] as num?)?.toInt() ?? 0,
      );
}

class MediaInfo {
  final int durationUs;
  final String format;
  final int bitrate;
  final VideoInfo? video;
  final List<AudioTrack> audio;
  final List<SubtitleTrack> subtitles;
  final String hw;

  const MediaInfo({
    required this.durationUs,
    required this.format,
    required this.bitrate,
    required this.video,
    required this.audio,
    required this.subtitles,
    required this.hw,
  });

  static const empty = MediaInfo(
    durationUs: 0,
    format: '',
    bitrate: 0,
    video: null,
    audio: [],
    subtitles: [],
    hw: 'none',
  );

  factory MediaInfo.fromJson(Map<String, dynamic> j) {
    final hw = (j['hw'] as Map<String, dynamic>?) ?? const {};
    final audio = ((j['audio'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(AudioTrack.fromJson)
        .toList(growable: false);
    final subs = ((j['subtitle'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SubtitleTrack.fromJson)
        .toList(growable: false);
    final v = j['video'];
    return MediaInfo(
      durationUs: (j['duration_us'] as num?)?.toInt() ?? 0,
      format: j['format'] as String? ?? '',
      bitrate: (j['bitrate'] as num?)?.toInt() ?? 0,
      video: v is Map<String, dynamic> ? VideoInfo.fromJson(v) : null,
      audio: audio,
      subtitles: subs,
      hw: hw['active'] as String? ?? 'none',
    );
  }
}

/// 当前正在显示的外挂字幕的文件名，没有则 null。
String? activeExternalSubtitleTitle(MediaInfo info) {
  for (final s in info.subtitles) {
    if (s.selected && s.external) return s.title;
  }
  return null;
}

/// 按文件名找外挂轨的索引；没加载过就返回 [noSubtitleTrack]。
///
/// 已经读进来的文件不该再读一次 —— `lp_player_add_subtitle` 每调一次就多一条
/// 轨；内核现在也会对同一个 URL 直接返回已有索引，这里先用文件名挡一遍，好让
/// 界面把「已加载」的文件从待选列表里拿掉。
int externalSubtitleIndexOf(String name, MediaInfo info) {
  for (final s in info.subtitles) {
    if (s.external && s.title == name) return s.index;
  }
  return noSubtitleTrack;
}

/// 还没进轨道表的外挂文件，顺序与 [files] 一致。
///
/// 字幕面板因此可以分成两栏而不重复：单选清单列出轨道表里现有的每一条，这一栏
/// 只列「点一下就能读进来」的文件。已经加载过的不再出现，避免同一份字幕在两处
/// 各显示一次。
List<T> pendingSubtitleFiles<T>(
  List<T> files,
  String Function(T) nameOf,
  MediaInfo info,
) {
  return [
    for (final f in files)
      if (externalSubtitleIndexOf(nameOf(f), info) == noSubtitleTrack) f,
  ];
}

/// 弹框里清单顶部的「关闭字幕」那一项用到的哨兵值：内核用负数表示不选。
const int noSubtitleTrack = -1;

/// 当前选中的字幕轨索引；没有选中时返回 [noSubtitleTrack]。
int selectedSubtitleIndex(MediaInfo info) {
  for (final s in info.subtitles) {
    if (s.selected) return s.index;
  }
  return noSubtitleTrack;
}

class SubtitleStyle {
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikeout;
  final int color; // 0xAARRGGBB
  final int secondaryColor; // 卡拉 OK 未唱部分的颜色
  final int outlineColor;
  final int backColor; // BorderStyle 3/4 的方框底色
  final int outline;
  final int shadow; // 阴影偏移，脚本单位
  final int borderStyle; // 1 = 描边+阴影，3/4 = 不透明方框
  final double spacing; // 字间距，脚本单位
  final double scaleX; // 百分比，100 = 原样
  final double scaleY;
  final double angle; // 旋转角度（度，顺时针）
  final double marginL; // 脚本单位
  final double marginR;
  final double marginV;
  final int align; // ASS 1..9
  final double fontScale;
  final double playResY; // 脚本分辨率高度，margin/描边按它折算成像素
  final double playResX; // 脚本分辨率宽度，\clip 与 \p 的 x 坐标按它折算
  final double posX;
  final double posY;
  final String font;

  const SubtitleStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikeout = false,
    this.color = 0xFFFFFFFF,
    this.outlineColor = 0xFF000000,
    this.secondaryColor = 0xFFFFFFFF,
    this.backColor = 0xFF000000,
    this.outline = 1,
    this.shadow = 0,
    this.borderStyle = 1,
    this.spacing = 0,
    this.scaleX = 100,
    this.scaleY = 100,
    this.angle = 0,
    this.marginL = 0,
    this.marginR = 0,
    this.marginV = 0,
    this.align = 2,
    this.fontScale = 0.05,
    this.playResY = 1080,
    this.playResX = 1920,
    this.posX = -1,
    this.posY = -1,
    this.font = 'sans-serif',
  });

  factory SubtitleStyle.fromJson(Map<String, dynamic> j) => SubtitleStyle(
        bold: j['bold'] == true,
        italic: j['italic'] == true,
        underline: j['underline'] == true,
        strikeout: j['strikeout'] == true,
        color: (j['color'] as num?)?.toInt() ?? 0xFFFFFFFF,
        outlineColor: (j['outline_color'] as num?)?.toInt() ?? 0xFF000000,
        secondaryColor: (j['secondary_color'] as num?)?.toInt() ?? 0xFFFFFFFF,
        backColor: (j['back_color'] as num?)?.toInt() ?? 0xFF000000,
        outline: (j['outline'] as num?)?.toInt() ?? 1,
        shadow: (j['shadow'] as num?)?.toInt() ?? 0,
        borderStyle: (j['border_style'] as num?)?.toInt() ?? 1,
        spacing: (j['spacing'] as num?)?.toDouble() ?? 0,
        scaleX: (j['scale_x'] as num?)?.toDouble() ?? 100,
        scaleY: (j['scale_y'] as num?)?.toDouble() ?? 100,
        angle: (j['angle'] as num?)?.toDouble() ?? 0,
        marginL: (j['margin_l'] as num?)?.toDouble() ?? 0,
        marginR: (j['margin_r'] as num?)?.toDouble() ?? 0,
        marginV: (j['margin_v'] as num?)?.toDouble() ?? 0,
        align: (j['align'] as num?)?.toInt() ?? 2,
        fontScale: (j['font_scale'] as num?)?.toDouble() ?? 0.05,
        playResY: (j['play_res_y'] as num?)?.toDouble() ?? 1080,
        playResX: (j['play_res_x'] as num?)?.toDouble() ?? 1920,
        posX: (j['pos_x'] as num?)?.toDouble() ?? -1,
        posY: (j['pos_y'] as num?)?.toDouble() ?? -1,
        font: j['font'] as String? ?? 'sans-serif',
      );

  /// 1 = left, 2 = center, 3 = right (vertical handled separately).
  int get horizontalAlign => ((align - 1) % 3) + 1;
  bool get isTop => align >= 7;
  bool get isMiddle => align >= 4 && align <= 6;
}

/// One inline-styled fragment of a subtitle line. ASS override tags such as
/// `{\b1}`, `{\i1}` or `{\c&H0000FF&}` arrive here as separate runs so the
/// renderer can mix fonts and colours inside a single sentence.
class SubtitleSpan {
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikeout;
  final int color; // 0 = inherit from the cue style
  final int outlineColor; // 0 = inherit; set by an inline \3c
  final int backColor; // 0 = inherit; set by an inline \4c
  final double scale; // 0 = inherit from the cue style
  final double scaleX; // 百分比，0 = 继承
  final double scaleY;
  final double spacing; // 脚本单位，0 = 继承
  final double angle; // 度，0 = 继承
  final int border; // 脚本单位，-1 = 继承
  final int shadow; // 脚本单位，-1 = 继承
  final String font; // '' = inherit from the cue style

  /// 整段文字的不透明度，1.0 = 不变。`\alpha` / `\1a` 给的是透明度，
  /// 内核已经换算成透明度反转后的值。
  final double alpha;

  /// 卡拉 OK：`kind` 1 = `\k` 逐字填色、2 = `\kf`、3 = `\ko` 逐字淡出。
  /// 起止时间是**这条 Dialogue 内的相对毫秒**。
  final int karaokeKind;
  final double karaokeStart;
  final double karaokeEnd;

  /// `\t(...)` 动画。播放时要按当前时刻求值，所以整条留到渲染层算。
  final List<SubtitleAnim> anims;

  /// `\clip(x1,y1,x2,y2)`，脚本坐标。
  final List<double> clip;
  final bool clipInverse;

  /// `\clip` 是否生效（`	` 的动画里可以打开/关掉裁剪）。
  bool get clipOn => clip.length == 4;

  /// `\p<n>` 矢量绘图：`drawingScale` 是 `\p` 的指数，`path` 是折线点列，
  /// 每个点自带子路径编号（`m` 开启一条新子路径）。
  final int drawingScale;
  final List<SubtitlePathPoint> path;

  const SubtitleSpan({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikeout = false,
    this.color = 0,
    this.outlineColor = 0,
    this.backColor = 0,
    this.scale = 0,
    this.scaleX = 0,
    this.scaleY = 0,
    this.spacing = 0,
    this.angle = 0,
    this.border = -1,
    this.shadow = -1,
    this.font = '',
    this.alpha = 1.0,
    this.karaokeKind = 0,
    this.karaokeStart = 0,
    this.karaokeEnd = 0,
    this.anims = const [],
    this.clip = const [],
    this.clipInverse = false,
    this.drawingScale = 0,
    this.path = const [],
  });

  factory SubtitleSpan.fromJson(Map<String, dynamic> j) => SubtitleSpan(
        text: j['text'] as String? ?? '',
        bold: j['bold'] == true,
        italic: j['italic'] == true,
        underline: j['underline'] == true,
        strikeout: j['strikeout'] == true,
        color: (j['color'] as num?)?.toInt() ?? 0,
        outlineColor: (j['outline_color'] as num?)?.toInt() ?? 0,
        backColor: (j['back_color'] as num?)?.toInt() ?? 0,
        scale: (j['scale'] as num?)?.toDouble() ?? 0,
        scaleX: (j['scale_x'] as num?)?.toDouble() ?? 0,
        scaleY: (j['scale_y'] as num?)?.toDouble() ?? 0,
        spacing: (j['spacing'] as num?)?.toDouble() ?? 0,
        angle: (j['angle'] as num?)?.toDouble() ?? 0,
        border: (j['border'] as num?)?.toInt() ?? -1,
        shadow: (j['shadow'] as num?)?.toInt() ?? -1,
        font: j['font'] as String? ?? '',
        alpha: (j['alpha'] as num?)?.toDouble() ?? 1.0,
        karaokeKind: (j['karaoke'] as num?)?.toInt() ?? 0,
        karaokeStart: (j['karaoke_start'] as num?)?.toDouble() ?? 0,
        karaokeEnd: (j['karaoke_end'] as num?)?.toDouble() ?? 0,
        anims: j['anims'] is List
            ? (j['anims'] as List)
                .whereType<Map<String, dynamic>>()
                .map(SubtitleAnim.fromJson)
                .toList(growable: false)
            : const [],
        clip: j['clip'] is List
            ? (j['clip'] as List)
                .whereType<num>()
                .map((e) => e.toDouble())
                .toList(growable: false)
            : const [],
        clipInverse: j['clip_inverse'] == true,
        drawingScale: (j['draw'] as num?)?.toInt() ?? 0,
        path: j['path'] is List
            ? (j['path'] as List)
                .whereType<List<dynamic>>()
                .map(SubtitlePathPoint.fromJson)
                .toList(growable: false)
            : const [],
      );
}

/// 矢量绘图的一个顶点。`sub` 是同一条 `m` 里的子路径编号，用来断开折线。
class SubtitlePathPoint {
  final int sub;
  final double x;
  final double y;

  const SubtitlePathPoint(
      {required this.sub, required this.x, required this.y});

  factory SubtitlePathPoint.fromJson(List<dynamic> j) => SubtitlePathPoint(
        sub: (j.isNotEmpty ? j[0] as num : 0).toInt(),
        x: (j.length > 1 ? j[1] as num : 0).toDouble(),
        y: (j.length > 2 ? j[2] as num : 0).toDouble(),
      );
}

/// 一个 `\t(t1,t2,accel,tags)` 动画。字段用位掩码标出「这次动画改了什么」，
/// 没标到的字段沿用 run 自己的值。
class SubtitleAnim {
  const SubtitleAnim({
    this.t1 = 0,
    this.t2 = 0,
    this.accel = 0,
    this.fields = 0,
    this.color = 0,
    this.scaleX = 0,
    this.scaleY = 0,
    this.scale = 0,
    this.angle = 0,
    this.spacing = 0,
    this.border = -1,
    this.shadow = -1,
    this.alpha = 1.0,
    this.clip = const [],
  });

  final double t1;
  final double t2;
  final double accel;
  final int fields;
  final int color;
  final double scaleX;
  final double scaleY;
  final double scale;
  final double angle;
  final double spacing;
  final int border;
  final int shadow;
  final double alpha;
  final List<double> clip;

  static const int fieldColor = 0x1;
  static const int fieldScaleX = 0x2;
  static const int fieldScaleY = 0x4;
  static const int fieldFont = 0x8;
  static const int fieldAngle = 0x10;
  static const int fieldSpacing = 0x20;
  static const int fieldBorder = 0x40;
  static const int fieldShadow = 0x80;
  static const int fieldAlpha = 0x100;
  static const int fieldClip = 0x200;

  bool has(int bit) => (fields & bit) != 0;

  factory SubtitleAnim.fromJson(Map<String, dynamic> j) => SubtitleAnim(
        t1: (j['t1'] as num?)?.toDouble() ?? 0,
        t2: (j['t2'] as num?)?.toDouble() ?? 0,
        accel: (j['accel'] as num?)?.toDouble() ?? 0,
        fields: (j['f'] as num?)?.toInt() ?? 0,
        color: (j['color'] as num?)?.toInt() ?? 0,
        scaleX: (j['scale_x'] as num?)?.toDouble() ?? 0,
        scaleY: (j['scale_y'] as num?)?.toDouble() ?? 0,
        scale: (j['scale'] as num?)?.toDouble() ?? 0,
        angle: (j['angle'] as num?)?.toDouble() ?? 0,
        spacing: (j['spacing'] as num?)?.toDouble() ?? 0,
        border: (j['border'] as num?)?.toInt() ?? -1,
        shadow: (j['shadow'] as num?)?.toInt() ?? -1,
        alpha: (j['alpha'] as num?)?.toDouble() ?? 1.0,
        clip: j['clip'] is List
            ? (j['clip'] as List)
                .whereType<num>()
                .map((e) => e.toDouble())
                .toList(growable: false)
            : const [],
      );
}

/// A single displayed subtitle line: the plain text plus, when the source
/// styled it inline, the ordered runs that make it up.
///
/// 同一时刻画面上可能有多条字幕（ASS 里是几条独立的 `Dialogue`），它们各有
/// 自己的对齐、边距和 `\pos`。这些字段为 null 表示「跟随整条 cue 的样式」，
/// 只有该行确实覆盖了样式时内核才输出。
class SubtitleLine {
  final String text;
  final List<SubtitleSpan> runs;

  /// 这一行自己的样式。同一时刻在屏上的几条字幕各按自己的 `Style:` 渲染
  /// （颜色、粗细、边框盒、字号都可能不同），所以样式跟着行走而不是整条
  /// cue 共用一份。纯文本的老载荷没有这个字段，回落到 cue 的样式。
  final SubtitleStyle? style;
  final int? align;
  final double? marginL;
  final double? marginR;
  final double? marginV;
  final double? posX;
  final double? posY;
  final double? playResY;

  const SubtitleLine({
    required this.text,
    this.runs = const [],
    this.style,
    this.align,
    this.marginL,
    this.marginR,
    this.marginV,
    this.posX,
    this.posY,
    this.playResY,
  });

  factory SubtitleLine.fromJson(Map<String, dynamic> j) {
    final raw = j['runs'];
    final style = j['style'];
    return SubtitleLine(
      text: j['text'] as String? ?? '',
      runs: raw is List
          ? raw
              .whereType<Map<String, dynamic>>()
              .map(SubtitleSpan.fromJson)
              .toList(growable: false)
          : const [],
      style:
          style is Map<String, dynamic> ? SubtitleStyle.fromJson(style) : null,
      align: (j['align'] as num?)?.toInt(),
      marginL: (j['margin_l'] as num?)?.toDouble(),
      marginR: (j['margin_r'] as num?)?.toDouble(),
      marginV: (j['margin_v'] as num?)?.toDouble(),
      posX: (j['pos_x'] as num?)?.toDouble(),
      posY: (j['pos_y'] as num?)?.toDouble(),
      playResY: (j['play_res_y'] as num?)?.toDouble(),
    );
  }

  bool get styled => runs.any(
        (r) =>
            r.bold ||
            r.italic ||
            r.underline ||
            r.strikeout ||
            r.color != 0 ||
            // 行内 \3c / \4c 只改描边、底色，也算「这一行有内联样式」——
            // 否则整行会退回 cue 的样式，描边色又变回黑色。
            r.outlineColor != 0 ||
            r.backColor != 0 ||
            r.scale != 0 ||
            r.scaleX != 0 ||
            r.scaleY != 0 ||
            r.spacing != 0 ||
            r.angle != 0 ||
            r.border >= 0 ||
            r.shadow >= 0 ||
            r.font.isNotEmpty ||
            // 高级特性同样算「这一行有内联样式」：只带 lpha / \clip /
            // \p 或卡拉 OK 的行，整行退回纯文本就把这些效果全丢了。
            r.alpha < 1.0 ||
            r.karaokeKind != 0 ||
            r.anims.isNotEmpty ||
            r.clipOn ||
            r.drawingScale > 0,
      );

  /// 这一行是否自己指定了位置/对齐（否则跟 cue 走）。
  bool get placed =>
      align != null ||
      (posX != null && posY != null) ||
      (marginV ?? 0) > 0 ||
      (marginL ?? 0) > 0 ||
      (marginR ?? 0) > 0;
}

class SubtitleCue {
  final String text;
  final int startUs;
  final int endUs;
  final SubtitleStyle style;
  final List<SubtitleLine> lines;

  /// 这条 Dialogue 里已经播过去的微秒数（内核随事件下发）。`\t` 动画和
  /// `\k` 卡拉 OK 都要靠它求值；0 表示「刚开始」。
  final int nowUs;

  const SubtitleCue({
    required this.text,
    required this.startUs,
    required this.endUs,
    required this.style,
    this.lines = const [],
    this.nowUs = 0,
  });

  static const empty = SubtitleCue(
    text: '',
    startUs: 0,
    endUs: 0,
    style: SubtitleStyle(),
  );

  factory SubtitleCue.fromJson(Map<String, dynamic> j) {
    final raw = j['runs'];
    return SubtitleCue(
      text: j['text'] as String? ?? '',
      startUs: (j['start'] as num?)?.toInt() ?? 0,
      endUs: (j['end'] as num?)?.toInt() ?? 0,
      style: SubtitleStyle.fromJson(
          (j['style'] as Map<String, dynamic>?) ?? const {}),
      lines: raw is List
          ? raw
              .whereType<Map<String, dynamic>>()
              .map(SubtitleLine.fromJson)
              .toList(growable: false)
          : const [],
      nowUs: (j['now'] as num?)?.toInt() ?? 0,
    );
  }

  /// 同一时刻再生成一份，只换 `nowUs`。播放器每个 POSITION 周期都要重算
  /// 动画，复用解析好的 lines 比重新 fromJson 便宜得多。
  SubtitleCue at(int nowUs) => SubtitleCue(
        text: text,
        startUs: startUs,
        endUs: endUs,
        style: style,
        lines: lines,
        nowUs: nowUs,
      );

  /// 整条字幕是不是没有任何可见内容。
  ///
  /// 不能只看 `text`：只含 `\p1` 矢量绘图的行没有文字，但渲染器
  /// （`subtitle_overlay.dart` 的 `_drawingsWithPlacement`）确实会把图形画出来。
  /// 早先这里只判 `text.trim().isEmpty`，OP/ED 的矢量标题与特效字幕整段消失，
  /// 而内核那边 `has_drawing_runs()` 是把这类行当作「有内容」保留的。
  bool get isEmpty => text.trim().isEmpty && !lines.any(_hasDrawing);

  /// 这一行里有没有矢量绘图（`\p1` 之类）需要画。
  static bool _hasDrawing(SubtitleLine line) =>
      line.runs.any((run) => run.path.isNotEmpty);
}
