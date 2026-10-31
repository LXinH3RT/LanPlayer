import 'media_models.dart';
import 'subtitle_match.dart';

class DirectoryListing {
  final String url;
  final String parent;
  final List<MediaEntry> entries;

  DirectoryListing(
      {required this.url, required this.parent, required this.entries});

  // 下面几个派生列表都用 `late final` 懒算一次就记住。
  //
  // 原来 `videos`/`folders`/`subtitles` 每次读都 `entries.where(...).toList()`
  // —— 一个 500 条的目录，每个视频行读一次 `videos`、每个未关联字幕行再读
  // 一次，滚动时这几次遍历按帧重复。`entries` 构造后不再变，所以算一次就
  // 够，代价是这里不能再是 `const` 构造。

  late final List<MediaEntry> videos =
      entries.where((e) => e.isVideo).toList(growable: false);
  late final List<MediaEntry> folders =
      entries.where((e) => e.isDir).toList(growable: false);
  late final List<MediaEntry> subtitles =
      entries.where((e) => e.isSubtitle).toList(growable: false);

  /// 视频 path → 认领到的字幕，以及字幕 path → 认领它的视频。
  ///
  /// 两张表一趟建好：`O(V×S)` 的配对判定只跑一次。
  ///
  /// 以前 `subtitlesFor` 每次都重新扫一遍 `subtitles` 并逐条做配对判定，
  /// 而调用方是「每个视频行一次、每行字幕再各一次」，滚动时退化成
  /// O(n²)/O(n³)。配对结果只取决于 `entries`，所以建表。
  late final ({
    Map<String, List<MediaEntry>> byVideo,
    Map<String, MediaEntry> owner
  }) _subtitleIndex = () {
    final byVideo = <String, List<MediaEntry>>{};
    final owner = <String, MediaEntry>{};
    if (subtitles.isEmpty) return (byVideo: byVideo, owner: owner);
    for (final v in videos) {
      List<MediaEntry>? owned;
      for (final s in subtitles) {
        if (!subtitleBelongsTo(v.name, s.name)) continue;
        (owned ??= <MediaEntry>[]).add(s);
        owner.putIfAbsent(s.path, () => v);
      }
      if (owned != null) byVideo[v.path] = owned;
    }
    return (byVideo: byVideo, owner: owner);
  }();

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
    return _subtitleIndex.byVideo[video.path] ?? const [];
  }

  /// [sub] 归属的视频；没有任何视频认领时返回 `null`。
  ///
  /// 行里的字幕标签要拿它去减主干前缀，以前是用
  /// `videos.firstWhere((v) => subtitlesFor(v).any(...))` 现找，等于每行字幕
  /// 都把整张表重扫一遍。
  MediaEntry? ownerOfSubtitle(MediaEntry sub) => _subtitleIndex.owner[sub.path];

  /// 没有被任何视频认领的字幕。
  ///
  /// 现实里确实会出现（比如最后一集还没下载、或文件名对不上）。这些文件
  /// **不能悄悄消失** —— 用户会以为播放器漏列了东西。所以让它们单独显示，
  /// 并标注「未关联」，同时仍然可以点开手动加载。
  late final List<MediaEntry> orphanSubtitles = subtitles
      .where((s) => !_subtitleIndex.owner.containsKey(s.path))
      .toList(growable: false);

  /// 浏览列表里真正要显示的行：目录 + 视频 + 音频 + 无主字幕。
  ///
  /// **有归属的字幕不单独占一行** —— 它们已经被挂到对应视频下面（见
  /// [subtitlesFor]）。`.txt`/`.docx` 之类则由内核在列目录时就滤掉了
  /// （`lp_is_listable_media`），这里再兜一层，防止历史数据或其它来源漏进来。
  late final List<MediaEntry> browsable = () {
    // 原来是「对每一行都扫一遍未关联列表」，整张表 O(n²)。改成先收成 Set
    // 再逐行查。
    final orphanPaths = <String>{for (final s in orphanSubtitles) s.path};
    return entries
        .where((e) =>
            e.isDir ||
            e.isVideo ||
            e.kind == 'audio' ||
            orphanPaths.contains(e.path))
        .toList(growable: false);
  }();

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
