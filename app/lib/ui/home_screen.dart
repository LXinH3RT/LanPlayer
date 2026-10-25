import 'dart:async';

import 'package:flutter/material.dart';

import '../data/folders.dart';
import '../data/home_sources.dart';
import '../data/models.dart';
import '../data/repository.dart';
import '../data/stores.dart';
import '../player/playlist.dart';
import 'browser_screen.dart';
import 'feedback.dart';
import 'folder_picker.dart';
import 'media_permission.dart';
import 'player_screen.dart';
import 'server_edit_screen.dart';
import 'settings_screen.dart';
import 'widgets/media_row.dart';

/// 首页：把每一块来源的根目录直接摊开。
///
/// 之前是「卡片列表 → 点一次 → 才看到目录」。多一层点击意味着每次找片都要
/// 多点一下，而且首页除了名字之外什么都看不出来。现在首页本身就是目录：
/// 每块来源一小节，直接列出根目录里的文件夹与视频。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// 单块来源的加载状态。
class _SourceLoad {
  const _SourceLoad({this.listing, this.error, this.loading = false});

  final DirectoryListing? listing;
  final String? error;
  final bool loading;
}

class _HomeScreenState extends State<HomeScreen> {
  final _repo = MediaRepository();

  /// 添加流程（选服务器 / 挑文件夹）进行中时按下添加按钮不再重复触发。
  bool _busy = false;

  /// 按 [HomeSource.id] 记录每一块根目录的加载结果。
  final Map<String, _SourceLoad> _loads = {};

  /// 只在多块来源时出现：点一下只看这一块。
  String? _only;

  /// 一小节最多直接列这么多行，再多就交给「查看全部」。
  static const _maxRows = 8;

  List<HomeSource> get _sources => buildHomeSources(
        ServerStore.instance.servers,
        LocalFolderStore.instance.folders,
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  Future<void> _loadAll() async {
    for (final s in _sources) {
      unawaited(_load(s));
    }
  }

  Future<void> _load(HomeSource s) async {
    if (_loads[s.id]?.loading == true) return;
    setState(() => _loads[s.id] = const _SourceLoad(loading: true));
    try {
      final listing =
          await _repo.browseUrl(s.location.rootUrl, s.location.options);
      if (!mounted) return;
      setState(() => _loads[s.id] = _SourceLoad(listing: listing));
    } on MediaSourceException catch (e) {
      if (!mounted) return;
      setState(() => _loads[s.id] = _SourceLoad(error: e.message));
    }
  }

  /// 进入某一块来源里的子目录：先取一次列表，再把浏览页推到栈上。
  ///
  /// 浏览页需要初始列表，这样它首帧就有内容，不会先闪一下空白再填。
  Future<void> _enterSubdir(HomeSource s, MediaEntry dir) async {
    try {
      final listing =
          await _repo.browseUrl(dir.path, s.location.options);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(location: s.location, initial: listing),
      ));
      if (mounted) unawaited(_load(s));
    } on MediaSourceException catch (e) {
      if (mounted) await showError(context, e.message);
    }
  }

  /// 打开某一块来源的完整浏览页（从它的根目录开始）。
  Future<void> _openRoot(HomeSource s) async {
    final loaded = _loads[s.id]?.listing;
    try {
      final listing = loaded ??
          await _repo.browseUrl(s.location.rootUrl, s.location.options);
      if (!mounted) return;
      if (s.folder != null) {
        await LocalFolderStore.instance.touch(s.folder!.id);
      } else if (s.profile != null) {
        await ServerStore.instance.touch(s.profile!.id);
      }
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(location: s.location, initial: listing),
      ));
      if (mounted) unawaited(_load(s));
    } on MediaSourceException catch (e) {
      if (mounted) await showError(context, e.message);
    }
  }

  Future<void> _play(HomeSource s, MediaEntry entry,
      List<MediaEntry> subtitles) async {
    final listing = _loads[s.id]?.listing;
    final playlist = listing == null
        ? PlaylistController(items: [entry], index: 0)
        : PlaylistController.fromListing(listing, entry.path);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlayerScreen(
        location: s.location,
        playlist: playlist,
        settings: SettingsStore.instance.value,
        subtitles: subtitles,
      ),
    ));
    if (mounted) unawaited(_load(s));
  }

  // 让用户选择手动添加 SMB 服务器，或把本机文件夹加进首页。
  Future<void> _addMenu() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _addMenuInner();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addMenuInner() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('添加 SMB 服务器'),
              subtitle: const Text('填写 IP、共享名与账号密码'),
              onTap: () => Navigator.pop(ctx, 'manual'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('添加本机文件夹'),
              subtitle: const Text('把本机的一块目录固定到首页'),
              onTap: () => Navigator.pop(ctx, 'local'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'manual':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const ServerEditScreen()),
        );
        break;
      case 'local':
        await _addLocalFolder();
        break;
    }
    if (mounted) {
      setState(() {});
      unawaited(_loadAll());
    }
  }

  /// 挑一个本机文件夹并加进首页。
  Future<void> _addLocalFolder() async {
    // Android 13+ 把存储权限拆成了按类型的媒体权限，必须运行时申请；
    // 没申请时列出来是空目录，看起来像本地浏览坏了。
    final perm = await MediaPermission.request();
    if (!perm.granted) {
      if (mounted) {
        await showError(context,
            '没有读取视频的权限，无法浏览本地文件。可以在系统设置里给 LanPlayer 打开「视频」权限。');
      }
      return;
    }
    if (perm.partial && mounted) {
      // Android 14 的「选择部分」只放出用户勾中的那几个文件，目录会缺一大半。
      await showError(
          context,
          '当前只授予了「部分视频」的访问权限，这个文件夹里只会显示你勾选过的文件。'
          '要看全部，请在系统设置 → 权限 里改成「允许访问全部」。');
    }
    if (!mounted) return;

    final choice = await pickLocalFolder(context, _repo.localRoots());
    if (choice == null || !mounted) return;
    await LocalFolderStore.instance.add(
      label: choice.label,
      path: choice.path,
    );
    if (mounted) setState(() {});
  }

  Future<void> _addFolderByPath() async {
    final home = _repo.localRoots();
    final path = await askFolderPath(
        context, home.isEmpty ? '' : home.first.path);
    if (path == null || !mounted) return;
    final segments = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
    await LocalFolderStore.instance.add(
      label: segments.isEmpty ? path : segments.last,
      path: path,
    );
    if (mounted) {
      setState(() {});
      unawaited(_loadAll());
    }
  }

  // 删除前确认；服务器只移除本机记录，文件夹只是从首页摘掉。
  Future<void> _confirmRemove(HomeSource s) async {
    final what = s.isServer ? '服务器' : '文件夹';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('移除 $what「${s.label}」？'),
        content: Text(s.isServer
            ? '只会从本机移除这条记录，不会修改服务端的共享设置。'
            : '只会把它从首页摘掉，磁盘上的文件不会有任何变化。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('移除')),
        ],
      ),
    );
    if (ok != true) return;
    if (s.profile != null) {
      await ServerStore.instance.remove(s.profile!.id);
    } else if (s.folder != null) {
      await LocalFolderStore.instance.remove(s.folder!.id);
    }
    _loads.remove(s.id);
    if (mounted) setState(() {});
  }

  Future<void> _editSource(HomeSource s) async {
    if (s.profile != null) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ServerEditScreen(profile: s.profile),
      ));
    } else if (s.folder != null) {
      final name = await _askLabel(s.label);
      if (name != null && name.isNotEmpty) {
        await LocalFolderStore.instance.rename(s.folder!.id, name);
      }
    }
    if (mounted) {
      setState(() {});
      unawaited(_loadAll());
    }
  }

  Future<String?> _askLabel(String initial) async {
    final ctrl = TextEditingController(text: initial);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '显示名称'),
          onSubmitted: (s) => Navigator.pop(ctx, s.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return v;
  }

  @override
  Widget build(BuildContext context) {
    final sources = _sources;
    final visible =
        _only == null ? sources : sources.where((s) => s.id == _only).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('LanPlayer'),
            Text('局域网播放器',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400)),
          ],
        ),
        actions: [
          if (sources.isNotEmpty)
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                setState(_loads.clear);
                unawaited(_loadAll());
              },
            ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.tune),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        // 连接中禁用添加按钮，并用进度指示器反馈当前状态。
        onPressed: _busy ? null : _addMenu,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.add),
        label: Text(_busy ? '连接中…' : '添加'),
      ),
      body: sources.isEmpty
          ? _EmptyState(
              onAdd: _addMenu,
              onLocal: _addLocalFolder,
              onPath: _addFolderByPath,
            )
          : Column(
              children: [
                if (showSourceFilter(sources.length))
                  _SourceFilter(
                    sources: sources,
                    only: _only,
                    onPick: (id) => setState(() => _only = id),
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(top: 4, bottom: 96),
                    children: [
                      for (final s in visible)
                        _SourceSection(
                          source: s,
                          load: _loads[s.id],
                          maxRows: _maxRows,
                          onRetry: () => _load(s),
                          onOpenRoot: () => _openRoot(s),
                          onEnter: (e) => _enterSubdir(s, e),
                          onPlay: (e, subs) => _play(s, e, subs),
                          onEdit: () => _editSource(s),
                          onRemove: () => _confirmRemove(s),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// 顶部那一排来源按钮：多块来源时用来只看其中一块。
class _SourceFilter extends StatelessWidget {
  const _SourceFilter({
    required this.sources,
    required this.only,
    required this.onPick,
  });

  final List<HomeSource> sources;
  final String? only;
  final ValueChanged<String?> onPick;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          ChoiceChip(
            label: const Text('全部'),
            selected: only == null,
            onSelected: (_) => onPick(null),
          ),
          const SizedBox(width: 8),
          for (final s in sources) ...[
            ChoiceChip(
              avatar: Icon(
                s.isServer ? Icons.dns_outlined : Icons.folder_outlined,
                size: 16,
              ),
              label: Text(s.label),
              selected: only == s.id,
              onSelected: (_) => onPick(s.id),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

/// 一块来源：标题栏 + 根目录里的若干行。
class _SourceSection extends StatelessWidget {
  const _SourceSection({
    required this.source,
    required this.load,
    required this.maxRows,
    required this.onRetry,
    required this.onOpenRoot,
    required this.onEnter,
    required this.onPlay,
    required this.onEdit,
    required this.onRemove,
  });

  final HomeSource source;
  final _SourceLoad? load;
  final int maxRows;
  final VoidCallback onRetry;
  final VoidCallback onOpenRoot;
  final ValueChanged<MediaEntry> onEnter;
  final void Function(MediaEntry entry, List<MediaEntry> subtitles) onPlay;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final listing = load?.listing;
    final rows = listing == null ? const <MediaEntry>[] : homeRows(listing);
    final shown = rows.length > maxRows ? rows.take(maxRows).toList() : rows;
    final hidden = rows.length - shown.length;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 2),
          child: Row(
            children: [
              Icon(source.isServer ? Icons.dns_outlined : Icons.folder_outlined,
                  size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(source.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    Text(source.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              TextButton(
                onPressed: onOpenRoot,
                child: const Text('全部'),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  switch (v) {
                    case 'edit':
                      onEdit();
                      break;
                    case 'remove':
                      onRemove();
                      break;
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(value: 'remove', child: Text('从首页移除')),
                ],
              ),
            ],
          ),
        ),
        if (load == null || load!.loading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: LinearProgressIndicator(minHeight: 2),
          )
        else if (load!.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 18, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(load!.error!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: scheme.error)),
                ),
                TextButton(onPressed: onRetry, child: const Text('重试')),
              ],
            ),
          )
        else if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 14),
            child: Text('这个目录里没有视频', style: TextStyle(fontSize: 12)),
          )
        else ...[
          for (final e in shown)
            MediaRow(
              entry: e,
              listing: listing!,
              location: source.location,
              onEnter: onEnter,
              onPlay: onPlay,
            ),
          if (hidden > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: TextButton.icon(
                onPressed: onOpenRoot,
                icon: const Icon(Icons.expand_more, size: 18),
                label: Text('还有 $hidden 项'),
              ),
            ),
        ],
        const Divider(height: 1),
      ],
    );
  }
}

// 无来源时展示的引导页面。
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.onAdd,
    required this.onLocal,
    required this.onPath,
  });

  final VoidCallback onAdd;
  final VoidCallback onLocal;
  final VoidCallback onPath;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_filter_outlined,
                size: 72, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 20),
            const Text('还没有内容',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text(
              '把 SMB 服务器或本机文件夹加进来，首页就会直接列出里面的内容。\n'
              '在 Windows 上共享文件夹：右键 → 属性 → 共享。',
              textAlign: TextAlign.center,
              style: TextStyle(height: 1.5),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.dns_outlined),
              label: const Text('添加 SMB 服务器'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onLocal,
              icon: const Icon(Icons.folder_outlined),
              label: const Text('添加本机文件夹'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onPath,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('直接输入路径'),
            ),
          ],
        ),
      ),
    );
  }
}
