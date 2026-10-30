import 'dart:async';

import 'package:flutter/material.dart';

import '../data/location.dart';
import '../data/models.dart';
import '../data/repository.dart';
import '../data/stores.dart';
import '../player/playlist.dart';
import 'feedback.dart';
import 'keyboard.dart';
import 'player_screen.dart';
import 'widgets/media_row.dart';

/// 媒体文件夹浏览屏幕，用于浏览 SMB 或本地文件夹中的内容。
///
/// 该屏幕负责展示当前目录列表、允许用户在嵌套文件夹之间导航，并在
/// 用户选择视频或音频文件时启动播放。它会在内存中保存当前浏览状态，
/// 同时保留返回栈，以支持类似面包屑式的导航体验。
///
/// 单行的样子交给 [MediaRow]：首页把各来源的根目录直接摊开，用的是同一个
/// 部件，两处才不会慢慢长成两种列表。
class BrowserScreen extends StatefulWidget {
  const BrowserScreen(
      {super.key, required this.location, required this.initial, this.repo});

  /// 当前正在浏览的媒体源，例如 SMB 共享或本地存储。
  final MediaLocation location;

  /// 屏幕首次创建时使用的初始目录列表。
  final DirectoryListing initial;

  /// 取数入口。默认真的去连共享；测试注入一个不碰网络的假实现。
  final MediaRepository? repo;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  /// 负责处理所有媒体源的网络/文件系统浏览逻辑的仓库。
  late final MediaRepository _repo = widget.repo ?? MediaRepository();

  /// 当前目录列表，这是用户正在查看的实时数据。
  late DirectoryListing _listing = widget.initial;

  /// 保存历史目录列表，用于返回上一层目录。每次进入新文件夹时，
  /// 当前列表都会被压入该栈中，以便恢复之前的视图。
  final List<DirectoryListing> _stack = [];

  /// 当正在异步加载新目录列表时为 true。
  bool _loading = false;

  /// Backspace 的抬起触发状态。
  ///
  /// 必须是实例字段：它记着「这颗键按下了还没抬起」，那是每个页面各自的
  /// 状态，不能做成全局函数。
  final BackKeyHandler _backKey = BackKeyHandler();

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
  ///
  /// 刷新期间把 [_loading] 置上：SMB 上列一个大目录要好几秒，没有进度条时
  /// 用户会以为按钮没反应，接着反复点击。这里也不做「正在刷新就忽略」的
  /// 守卫 —— 点两次就该真的去拉两次，否则第二次点击会被悄悄吞掉，看起来
  /// 更像按钮坏了。
  Future<void> _reload() async {
    if (mounted) setState(() => _loading = true);
    try {
      final listing =
          await _repo.browseUrl(_listing.url, widget.location.options);
      if (mounted) setState(() => _listing = listing);
    } on MediaSourceException catch (e) {
      if (mounted) await showError(context, e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 返回上一级目录（如果存在）。
  ///
  /// 返回栈里的那份列表是**进入子目录那一刻的快照**：用户可能已经在服务器
  /// 那边改了文件名，甚至就是在子目录里改的。所以先用快照把界面切回去
  /// （不闪空白），紧接着重新拉一次父目录 —— 只靠快照的话，返回后看到的
  /// 永远是旧名字，得再手动点一次刷新才对得上。
  void _up() {
    if (_stack.isNotEmpty) {
      setState(() => _listing = _stack.removeLast());
      unawaited(_reload());
      return;
    }
    if (_listing.parent.isNotEmpty) {
      _navigate(_listing.parent, push: false);
    }
  }

  /// 退一层；已经退到根目录时再退一次就离开浏览页。
  ///
  /// AppBar 那颗返回箭头和键盘上的 Backspace 共用这个入口。两处的判断必须
  /// 一致，否则会出现「鼠标退到根层后再按键盘，先关掉页面再关掉首页」这种
  /// 连跳两级的情况。
  void _upOrLeave() {
    if (_stack.isNotEmpty || _listing.parent.isNotEmpty) {
      _up();
    } else {
      Navigator.of(context).maybePop();
    }
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

    return Focus(
      // 整页包一层 Focus 而不是给 ListView 加：列表本身不接受焦点，
      // 没有这层的话按键事件根本没有节点可冒泡。
      autofocus: true,
      // 失焦时清掉「按住中」的记录，否则回来按一次会被当成第一次的抬起。
      onFocusChange: (hasFocus) {
        if (!hasFocus) _backKey.reset();
      },
      onKeyEvent: (node, event) => _backKey.handle(event, _upOrLeave),
      child: Scaffold(
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
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
              ),
            ],
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _upOrLeave,
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
                  return MediaRow(
                    entry: e,
                    listing: _listing,
                    location: widget.location,
                    onEnter: (dir) => _navigate(dir.path),
                    onPlay: (entry, subs) => _play(entry, subtitles: subs),
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
      ),
    );
  }
}
