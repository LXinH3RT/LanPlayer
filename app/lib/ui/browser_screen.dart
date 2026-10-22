import 'package:flutter/material.dart';

import '../data/location.dart';
import '../data/models.dart';
import '../data/progress.dart';
import '../data/repository.dart';
import '../data/stores.dart';
import '../player/playlist.dart';
import '../util/format.dart';
import 'feedback.dart';
import 'player_screen.dart';
import 'widgets/thumbnail_tile.dart';

/// 媒体文件夹浏览屏幕，用于浏览 SMB 或本地文件夹中的内容。
///
/// 该屏幕负责展示当前目录列表、允许用户在嵌套文件夹之间导航，并在
/// 用户选择视频或音频文件时启动播放。它会在内存中保存当前浏览状态，
/// 同时保留返回栈，以支持类似面包屑式的导航体验。
class BrowserScreen extends StatefulWidget {
  const BrowserScreen(
      {super.key, required this.location, required this.initial});

  /// 当前正在浏览的媒体源，例如 SMB 共享或本地存储。
  final MediaLocation location;

  /// 屏幕首次创建时使用的初始目录列表。
  final DirectoryListing initial;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  /// 负责处理所有媒体源的网络/文件系统浏览逻辑的仓库。
  final _repo = MediaRepository();

  /// 当前目录列表，这是用户正在查看的实时数据。
  late DirectoryListing _listing = widget.initial;

  /// 保存历史目录列表，用于返回上一层目录。每次进入新文件夹时，
  /// 当前列表都会被压入该栈中，以便恢复之前的视图。
  final List<DirectoryListing> _stack = [];

  /// 当正在异步加载新目录列表时为 true。
  bool _loading = false;

  /// 导航到指定路径，并在替换为新目录内容前可选择性地把当前列表
  /// 压入返回栈中，方便后退浏览。
  Future<void> _navigate(String url, {bool push = true}) async {
    setState(() => _loading = true);
    try {
      final listing = await _repo.browseUrl(url, widget.location.options);
      setState(() {
        if (push) _stack.add(_listing);
        _listing = listing;
      });
    } on MediaSourceException catch (e) {
      if (mounted) await showError(context, e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 刷新当前目录，但不会修改导航栈。
  Future<void> _reload() async {
    try {
      final listing =
          await _repo.browseUrl(_listing.url, widget.location.options);
      if (mounted) setState(() => _listing = listing);
    } on MediaSourceException catch (e) {
      if (mounted) await showError(context, e.message);
    }
  }

  /// 返回上一级目录（如果存在）。
  ///
  /// 优先使用内存中的返回栈；如果没有历史目录，
  /// 则回退到当前列表的父级 URL 进行导航。
  void _up() {
    if (_stack.isNotEmpty) {
      setState(() => _listing = _stack.removeLast());
      return;
    }
    if (_listing.parent.isNotEmpty) {
      _navigate(_listing.parent, push: false);
    }
  }

  /// 把字幕文件名显示成「相对视频主干多出来的那段」，没有就退回扩展名。
  ///
  /// `电影.mkv` + `电影.zh-CN.srt` → `zh-CN`
  /// `电影.mkv` + `电影.srt`      → `SRT`
  String _subtitleLabel(MediaEntry sub) {
    final dot = sub.name.lastIndexOf('.');
    final subStem = (dot > 0 ? sub.name.substring(0, dot) : sub.name);
    // 找到它归属的视频，减掉主干前缀。
    final owner = _listing.videos.firstWhere(
      (v) => _listing.subtitlesFor(v).any((s) => s.path == sub.path),
      orElse: () => sub,
    );
    final ownerDot = owner.name.lastIndexOf('.');
    final ownerStem = ownerDot > 0 ? owner.name.substring(0, ownerDot) : owner.name;
    var rest = subStem;
    if (subStem.length >= ownerStem.length &&
        subStem.substring(0, ownerStem.length).toLowerCase() ==
            ownerStem.toLowerCase()) {
      rest = subStem.substring(ownerStem.length);
    }
    rest = rest.replaceAll(RegExp(r'^[.\-_\s(]+'), '');
    return rest.isEmpty ? sub.ext.toUpperCase() : rest;
  }

  /// 创建播放列表并跳转到播放器界面。
  ///
  /// [subtitles] 是归属到这条视频的外挂字幕；只把它们传给播放器，
  /// 而不是整个目录的字幕列表 —— 否则「字幕」面板里会混进别的片子的字幕。
  Future<void> _play(MediaEntry entry,
      {List<MediaEntry> subtitles = const []}) async {
    final playlist = PlaylistController.fromListing(_listing, entry.path);
    final settings = SettingsStore.instance.value;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(
        location: widget.location,
        playlist: playlist,
        settings: settings,
        subtitles: subtitles,
      ),
    ));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // 每次 build 都重算目录项，列表随刷新与导航实时更新。
    //
    // 用 `browsable` 而不是 `entries`：目录 + 视频 + 音频。字幕不单独占一行，
    // 它们被归到对应视频下面；.txt/.docx 这类已由内核在列目录时滤掉。
    final entries = _listing.browsable;

    // 把 URL 按路径段拆分后，AppBar 可以显示当前文件夹名，
    // 而不必展示完整的远程/本地路径。
    final segments =
        _listing.url.split('/').where((s) => s.isNotEmpty).toList();
    final folderName = segments.isEmpty ? '' : segments.last;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 根目录下显示媒体源名称，进入子目录后显示当前文件夹名，
            // 这样页面标题更像面包屑导航，阅读起来更清晰。
            Text(_stack.isEmpty ? widget.location.label : folderName,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              // 字幕不单独计数：它们已经被归属到视频下面，单独报个数会让
              // 用户以为列表里还有没显示出来的东西。
              '${entries.where((e) => e.isVideo).length} 个视频 · '
              '${entries.where((e) => e.isDir).length} 个文件夹'
              '${_listing.subtitles.isNotEmpty ? ' · ${_listing.subtitles.length} 个字幕已关联' : ''}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            // 如果存在历史目录项，就直接返回上一层，而不需要重新请求网络；
            // 反之则视为离开当前浏览器界面，执行正常的页面退出逻辑。
            if (_stack.isNotEmpty || _listing.parent.isNotEmpty) {
              _up();
            } else {
              Navigator.of(context).maybePop();
            }
          },
        ),
        actions: [
          // 刷新会重新拉取当前目录的列表，但不会丢失当前定位或历史导航栈。
          IconButton(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              tooltip: '刷新'),
        ],
      ),
      body: Stack(
        children: [
          if (entries.isEmpty)
            const Center(child: Text('这个文件夹是空的'))
          else
            ListView.builder(
              padding: const EdgeInsets.only(top: 4, bottom: 24),
              itemCount: entries.length,
              itemBuilder: (ctx, i) {
                final e = entries[i];

                // 文件夹通过进入其路径来打开，右侧箭头也明确提示这是“深入浏览”的交互。
                if (e.isDir) {
                  return ListTile(
                    leading: const Icon(Icons.folder, color: Color(0xFFFFC107)),
                    title: Text(e.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _navigate(e.path),
                  );
                }

                // 没有视频认领的字幕：单独给一行，标「未关联」。
                // 直接隐藏会让用户以为播放器漏列了文件。
                if (e.isSubtitle) {
                  return ListTile(
                    leading: Icon(Icons.subtitles_outlined,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                    title: Text(e.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${formatBytes(e.size)} · ${e.ext.toUpperCase()} · 未关联到视频',
                      style: const TextStyle(fontSize: 12),
                    ),
                    // 点一下可以直接播当前目录的第一条视频并挂上这条字幕。
                    onTap: _listing.videos.isEmpty
                        ? null
                        : () => _play(_listing.videos.first, subtitles: [e]),
                  );
                }

                // 当文件是视频或音频时，才视为可播放内容；
                // 其他类型文件虽然可见，但会被禁用，避免误入不支持播放的项目。
                final playable = e.isVideo || e.kind == 'audio';

                // 这个视频自带的外挂字幕（已按主干匹配好，见 subtitlesFor）。
                // 字幕不再单独占一行，而是挂在这里展示。
                final subs = e.isVideo ? _listing.subtitlesFor(e) : const <MediaEntry>[];

                // 播放进度从持久化的进度存储中读取，
                // 这样界面就能显示某个文件已观看到什么程度。
                final progress =
                    playable ? ProgressStore.instance.entry(e.path) : null;
                final watched = ProgressStore.instance
                    .resumablePosition(e.path, progress?.durationUs ?? 0);
                final watchedPct = (progress == null ||
                        progress.durationUs <= 0 ||
                        watched == null)
                    ? null
                    : (watched * 100 / progress.durationUs).clamp(0, 100);

                return ListTile(
                  enabled: playable,
                  // 视频显示真实封面（解一帧并缓存），音频只显示图标：
                  // 音频文件取一帧封面图没有意义，还会白花一次网络往返。
                  leading: e.isVideo
                      ? ThumbnailTile(
                          url: e.path,
                          options: widget.location.options,
                          fallback: Icons.movie_outlined,
                        )
                      : Icon(
                          e.kind == 'audio'
                              ? Icons.audiotrack_outlined
                              : Icons.insert_drive_file_outlined,
                          color: playable
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).disabledColor,
                        ),
                  title: Text(e.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 这行元数据汇总了文件大小、扩展名、字幕提示以及已观看百分比，
                      // 让每个条目能快速展示其基本状态。
                      Text(
                        [
                          if (e.size > 0) formatBytes(e.size),
                          e.ext.toUpperCase(),
                          if (subs.isNotEmpty) '字幕 ${subs.length}',
                          if (watchedPct != null)
                            '已看 ${watchedPct.toStringAsFixed(0)}%',
                        ].join(' · '),
                        style: const TextStyle(fontSize: 12),
                      ),
                      // 把归属到这个视频的字幕名直接列出来：用户不用再猜
                      // 「这个目录里那一堆 .srt 到底哪条配这个片子」。
                      // 只显示主干之外的语言后缀，太长就省略。
                      if (subs.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            children: [
                              Icon(Icons.subtitles_outlined,
                                  size: 13,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  subs.map(_subtitleLabel).join('、'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
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
                                  Theme.of(context).disabledColor.withValues(
                                        alpha: 0.25,
                                      ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  trailing: watchedPct != null
                      ? const Icon(Icons.play_circle_outline, size: 20)
                      : null,
                  onTap: playable ? () => _play(e, subtitles: subs) : null,
                );
              },
            ),
          if (_loading)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
      ),
    );
  }
}
