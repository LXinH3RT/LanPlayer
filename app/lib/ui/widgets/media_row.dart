import 'package:flutter/material.dart';

import '../../data/location.dart';
import '../../data/models.dart';
import '../../data/progress.dart';
import '../../util/format.dart';
import 'thumbnail_tile.dart';

/// 列表里的一行媒体条目：目录、视频/音频、或没有归属的字幕。
///
/// 首页与浏览页渲染的是同一批行，所以把「一行长什么样」收在这里，两个界面
/// 只负责提供数据与两个回调。分开写两份的后果很具体：封面、字幕归属、
/// 续播进度条这些细节会慢慢只在一个界面上生效。
class MediaRow extends StatelessWidget {
  const MediaRow({
    super.key,
    required this.entry,
    required this.listing,
    required this.location,
    required this.onEnter,
    required this.onPlay,
  });

  final MediaEntry entry;

  /// 这条目所在的目录列表 —— 字幕归属与「未关联」判定都要看整份列表。
  final DirectoryListing listing;

  /// 解锁封面/播放所需的来源信息（SMB 凭据或本机路径）。
  final MediaLocation location;

  /// 点目录时进入下一层。
  final ValueChanged<MediaEntry> onEnter;

  /// 点视频/音频时开始播放；[subtitles] 是归属到它的外挂字幕。
  final void Function(MediaEntry entry, List<MediaEntry> subtitles) onPlay;

  @override
  Widget build(BuildContext context) {
    if (entry.isDir) {
      return ListTile(
        leading: const Icon(Icons.folder, color: Color(0xFFFFC107)),
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => onEnter(entry),
      );
    }

    // 没有视频认领的字幕：单独给一行，标「未关联」。直接隐藏会让用户
    // 以为播放器漏列了文件。
    if (entry.isSubtitle) {
      return ListTile(
        leading: Icon(Icons.subtitles_outlined,
            color: Theme.of(context).colorScheme.onSurfaceVariant),
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${formatBytes(entry.size)} · ${entry.ext.toUpperCase()} · 未关联到视频',
          style: const TextStyle(fontSize: 12),
        ),
        onTap: listing.videos.isEmpty
            ? null
            : () => onPlay(listing.videos.first, [entry]),
      );
    }

    final playable = entry.isVideo || entry.kind == 'audio';
    final subs =
        entry.isVideo ? listing.subtitlesFor(entry) : const <MediaEntry>[];

    final progress = playable ? ProgressStore.instance.entry(entry.path) : null;
    final watched = ProgressStore.instance.resumablePosition(
        entry.path, progress?.durationUs ?? 0);
    final watchedPct =
        (progress == null || progress.durationUs <= 0 || watched == null)
            ? null
            : (watched * 100 / progress.durationUs).clamp(0, 100);

    return ListTile(
      enabled: playable,
      // 视频显示真实封面（解一帧并缓存），音频只显示图标：
      // 音频文件取一帧封面图没有意义，还会白花一次网络往返。
      leading: entry.isVideo
          ? ThumbnailTile(
              url: entry.path,
              options: location.options,
              version: entry.version,
              fallback: Icons.movie_outlined,
            )
          : Icon(
              entry.kind == 'audio'
                  ? Icons.audiotrack_outlined
                  : Icons.insert_drive_file_outlined,
              color: playable
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).disabledColor,
            ),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              if (entry.size > 0) formatBytes(entry.size),
              entry.ext.toUpperCase(),
              if (subs.isNotEmpty) '字幕 ${subs.length}',
              if (watchedPct != null) '已看 ${watchedPct.toStringAsFixed(0)}%',
            ].join(' · '),
            style: const TextStyle(fontSize: 12),
          ),
          // 把归属到这个视频的字幕名直接列出来：用户不用再猜「这个目录里
          // 那一堆 .srt 到底哪条配这个片子」。只显示主干之外的语言后缀。
          if (subs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Icon(Icons.subtitles_outlined,
                      size: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      subs.map((s) => subtitleLabel(s, listing)).join('、'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (watchedPct != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: watchedPct / 100,
                  minHeight: 3,
                  backgroundColor:
                      Theme.of(context).disabledColor.withValues(alpha: 0.25),
                ),
              ),
            ),
        ],
      ),
      trailing:
          watchedPct != null ? const Icon(Icons.play_circle_outline, size: 20) : null,
      onTap: playable ? () => onPlay(entry, subs) : null,
    );
  }
}

/// 把字幕文件名显示成「相对视频主干多出来的那段」，没有就退回扩展名。
///
/// `电影.mkv` + `电影.zh-CN.srt` → `zh-CN`
/// `电影.mkv` + `电影.srt`      → `SRT`
String subtitleLabel(MediaEntry sub, DirectoryListing listing) {
  final dot = sub.name.lastIndexOf('.');
  final subStem = (dot > 0 ? sub.name.substring(0, dot) : sub.name);
  // 找到它归属的视频，减掉主干前缀。
  final owner = listing.videos.firstWhere(
    (v) => listing.subtitlesFor(v).any((s) => s.path == sub.path),
    orElse: () => sub,
  );
  final ownerDot = owner.name.lastIndexOf('.');
  final ownerStem =
      ownerDot > 0 ? owner.name.substring(0, ownerDot) : owner.name;
  var rest = subStem;
  if (subStem.length >= ownerStem.length &&
      subStem.substring(0, ownerStem.length).toLowerCase() ==
          ownerStem.toLowerCase()) {
    rest = subStem.substring(ownerStem.length);
  }
  rest = rest.replaceAll(RegExp(r'^[.\-_\s(]+'), '');
  return rest.isEmpty ? sub.ext.toUpperCase() : rest;
}
