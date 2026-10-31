import 'scheme.dart';

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
  String get rootUrl => LpScheme.smbRoot(host, port, share);

  /// Title of the server card.
  ///
  /// The edit screen no longer asks for a display name — it writes the share
  /// name into [name] — but a profile saved by an older build may have a real
  /// custom name, or an empty one. Falling back to [share] keeps every card
  /// readable instead of showing a blank row.
  String get displayName => name.trim().isEmpty ? share.trim() : name.trim();

  /// URL with userinfo, used for FFmpeg/transport calls.
  String get urlWithCredentials => LpScheme.smbRootWithCredentials(
        host,
        port,
        share,
        user: user,
        password: password,
      );

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
