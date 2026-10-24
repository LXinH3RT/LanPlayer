import 'track_prefs.dart';

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
  });

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
      };

  factory PlaybackSettings.fromJson(Map<String, dynamic> j) => PlaybackSettings(
        hardwareDecoding: j['hardware_decoding'] as bool? ?? true,
        deinterlace: j['deinterlace'] as bool? ?? false,
        scaleMode: (j['scale_mode'] as num?)?.toInt() ?? 0,
        speed: (j['speed'] as num?)?.toDouble() ?? 1.0,
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
  /// 判定规则：字幕去掉扩展名后的主干，**等于**视频主干，或者**以
  /// 「视频主干 + 分隔符」开头**。用「主干 + 分隔符」而不是裸 `startsWith`，
  /// 是为了不把 `电影2.srt` 错配到 `电影.mkv` 上。
  ///
  /// 同一组里保持原有顺序（通常已按名称排序），方便按语言习惯挑默认项。
  List<MediaEntry> subtitlesFor(MediaEntry video) {
    if (!video.isVideo) return const [];
    final stem = _stemOf(video.name);
    if (stem.isEmpty) return const [];
    final out = <MediaEntry>[];
    for (final s in subtitles) {
      final subStem = _stemOf(s.name);
      if (subStem == stem) {
        out.add(s);
        continue;
      }
      if (subStem.length > stem.length &&
          subStem.startsWith(stem) &&
          _isSeparator(subStem[stem.length])) {
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

  /// 去掉最后一个扩展名并转小写。`movie.zh-CN.srt` → `movie.zh-cn`。
  static String _stemOf(String name) {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return base.toLowerCase();
  }

  /// 视频主干与字幕附加部分之间的分隔符。
  ///
  /// `movie.zh.srt` 用 `.`；也有 `movie - zh.srt`、`movie_zh.srt` 这类写法。
  /// 中文字幕常见 `movie.简体.srt`，点号已经覆盖。
  static bool _isSeparator(String ch) {
    return ch == '.' || ch == '_' || ch == '-' || ch == ' ' || ch == '(';
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
  final int outlineColor;
  final int outline;
  final int align; // ASS 1..9
  final double fontScale;
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
    this.outline = 1,
    this.align = 2,
    this.fontScale = 0.05,
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
        outline: (j['outline'] as num?)?.toInt() ?? 1,
        align: (j['align'] as num?)?.toInt() ?? 2,
        fontScale: (j['font_scale'] as num?)?.toDouble() ?? 0.05,
        posX: (j['pos_x'] as num?)?.toDouble() ?? -1,
        posY: (j['pos_y'] as num?)?.toDouble() ?? -1,
        font: j['font'] as String? ?? 'sans-serif',
      );

  /// 1 = left, 2 = center, 3 = right (vertical handled separately).
  int get horizontalAlign => ((align - 1) % 3) + 1;
  bool get isTop => align >= 7;
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
  final double scale; // 0 = inherit from the cue style
  final String font; // '' = inherit from the cue style

  const SubtitleSpan({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikeout = false,
    this.color = 0,
    this.scale = 0,
    this.font = '',
  });

  factory SubtitleSpan.fromJson(Map<String, dynamic> j) => SubtitleSpan(
        text: j['text'] as String? ?? '',
        bold: j['bold'] == true,
        italic: j['italic'] == true,
        underline: j['underline'] == true,
        strikeout: j['strikeout'] == true,
        color: (j['color'] as num?)?.toInt() ?? 0,
        scale: (j['scale'] as num?)?.toDouble() ?? 0,
        font: j['font'] as String? ?? '',
      );
}

/// A single displayed subtitle line: the plain text plus, when the source
/// styled it inline, the ordered runs that make it up.
class SubtitleLine {
  final String text;
  final List<SubtitleSpan> runs;

  const SubtitleLine({required this.text, this.runs = const []});

  factory SubtitleLine.fromJson(Map<String, dynamic> j) {
    final raw = j['runs'];
    return SubtitleLine(
      text: j['text'] as String? ?? '',
      runs: raw is List
          ? raw
              .whereType<Map<String, dynamic>>()
              .map(SubtitleSpan.fromJson)
              .toList(growable: false)
          : const [],
    );
  }

  bool get styled => runs.any(
        (r) =>
            r.bold ||
            r.italic ||
            r.underline ||
            r.strikeout ||
            r.color != 0 ||
            r.scale != 0 ||
            r.font.isNotEmpty,
      );
}

class SubtitleCue {
  final String text;
  final int startUs;
  final int endUs;
  final SubtitleStyle style;
  final List<SubtitleLine> lines;

  const SubtitleCue({
    required this.text,
    required this.startUs,
    required this.endUs,
    required this.style,
    this.lines = const [],
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
    );
  }

  bool get isEmpty => text.trim().isEmpty;
}
