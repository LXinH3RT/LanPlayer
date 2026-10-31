import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import '../data/folders.dart';
import '../data/home_sources.dart';
import '../data/location.dart';
import '../data/models.dart';
import '../data/repository.dart';
import '../data/source_health.dart';
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
  const HomeScreen({super.key, this.repo});

  /// 目录列表的获取方式。默认真实仓库（走后台 isolate 调内核）；
  /// 测试可以塞一个不碰 SMB 的假实现。
  final MediaRepository? repo;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// 单块来源的加载状态。
///
/// [listing] 与 [loading] 可以同时存在：刷新时保留旧内容，只在顶部显示一条
/// 细进度条，避免整块内容闪一下空白。
class _SourceLoad {
  const _SourceLoad({this.listing, this.error, this.loading = false});

  final DirectoryListing? listing;
  final String? error;
  final bool loading;
}

class _HomeScreenState extends State<HomeScreen> {
  // late: 首页在没有来源时也要能渲染（空状态页、添加菜单），不该为了画一屏
  // 「还没有内容」就去加载 lanplayer.dll。等到真的列目录时才碰内核。
  late final MediaRepository _repo = widget.repo ?? MediaRepository();

  /// 添加流程（选服务器 / 挑文件夹）进行中时按下添加按钮不再重复触发。
  bool _busy = false;

  /// 按 [HomeSource.id] 记录每一块根目录的加载结果。
  final Map<String, _SourceLoad> _loads = {};

  /// 每个来源的加载代际。异步返回时若代际不匹配就丢弃，避免旧请求覆盖新结果。
  final Map<String, int> _loadGen = {};

  /// 只在多块来源时出现：点一下只看这一块。
  String? _only;

  /// 已经在首页上摊开的来源。
  ///
  /// 「还有 N 项」曾经是 push 一个浏览页，用户点完发现只是同一份列表换个
  /// 界面再列一遍。现在改成就地摊开：多出来的行直接接在后面，页面不跳转。
  final Set<String> _expanded = {};

  /// 一小节最多直接列这么多行，其余收在「还有 N 项」后面。
  static const _maxRows = 8;

  List<HomeSource> get _sources => buildHomeSources(
        ServerStore.instance.servers,
        LocalFolderStore.instance.folders,
      );

  /// 两个 store 都读完磁盘了吗。
  ///
  /// 启动动画把 [runApp] 提到了读取之前，所以首页第一帧的来源列表必然是空的。
  /// 在读完之后说「还没有内容」，用户会以为配置丢了 —— 那两点几秒里先画空，
  /// 由 store 的 notifyListeners 触发重建。
  bool get _storesReady =>
      ServerStore.instance.loaded && LocalFolderStore.instance.loaded;

  @override
  void initState() {
    super.initState();
    // store 是 ChangeNotifier：读取完成、增删改都会通知，界面不需要自己补
    // setState。以前的写法是首帧读一次单例列表，读完没人通知，桌面端就永远
    // 停在空状态。
    ServerStore.instance.addListener(_onStoreChanged);
    LocalFolderStore.instance.addListener(_onStoreChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  @override
  void dispose() {
    ServerStore.instance.removeListener(_onStoreChanged);
    LocalFolderStore.instance.removeListener(_onStoreChanged);
    super.dispose();
  }

  /// store 变化：读完磁盘、增删来源、改名都会走到这里。
  ///
  /// 只重画一次，然后按「已加载的块」与「现在的来源」是否对得上决定要不要
  /// 补拉。改名/换标签不动目录，不该再发一轮请求。
  void _onStoreChanged() {
    if (!mounted) return;
    final ids = _sources.map((s) => s.id).toSet();
    final needsLoad = !setEquals(ids, _loads.keys.toSet());
    setState(() {});
    if (needsLoad) unawaited(_loadAll());
  }

  /// 统一的错误文案：网络/IO 异常也要给用户一个可读的提示，
  /// 不能让来源永远卡在「加载中」。
  String _errorText(Object e) =>
      e is MediaSourceException ? e.message : '加载失败：$e';

  /// 重新加载所有来源。调用时会给每个来源递增代际，之前在飞的请求自动作废。
  Future<void> _loadAll() async {
    final sources = _sources;
    if (sources.isEmpty) return;
    final gens = <String, int>{};
    for (final s in sources) {
      gens[s.id] = (_loadGen[s.id] ?? 0) + 1;
    }
    setState(() {
      for (final s in sources) {
        _loadGen[s.id] = gens[s.id]!;
        _loads[s.id] =
            _SourceLoad(listing: _loads[s.id]?.listing, loading: true);
      }
    });
    await Future.wait(sources.map((s) => _loadOne(s, gens[s.id]!)));
  }

  /// 重新加载一块来源（用于单块重试、从子目录返回后的回填）。
  ///
  /// 这里不做「正在加载就跳过」的守卫：从浏览页返回时、以及用户连点重试时，
  /// 请求本来就该真的再发一次。以前那句 `if (loading) return` 会把这种请求
  /// 悄悄吞掉，界面停留在旧列表上，看上去就是「刷新没生效」。
  /// 过期结果由 [_loadGen] 的代际比较丢弃，不需要靠入口判断。
  Future<void> _load(HomeSource s) async {
    final gen = (_loadGen[s.id] ?? 0) + 1;
    _loadGen[s.id] = gen;
    setState(() => _loads[s.id] =
        _SourceLoad(listing: _loads[s.id]?.listing, loading: true));
    await _loadOne(s, gen);
  }

  Future<void> _loadOne(HomeSource s, int gen) async {
    try {
      final folder = s.folder;
      final listing = (folder != null && folder.isFile)
          ? await _repo.browseFile(folder.path)
          : await _repo.browseUrl(s.location.rootUrl, s.location.options);
      if (!mounted || _loadGen[s.id] != gen) return;
      // 连上了：把上一次的离线标记清掉。这块来源接下来点「全部」可以照常进。
      SourceHealth.instance.markOnline(s.id);
      setState(() => _loads[s.id] = _SourceLoad(listing: listing));
    } catch (e) {
      if (!mounted || _loadGen[s.id] != gen) return;
      // 连不上：记下来。用户点「全部」时直接按这个结论给提示，不必再等
      // 一次 socket 超时 —— 那十几秒里界面什么都不说，看起来就像卡死了。
      SourceHealth.instance.markOffline(s.id, _errorText(e));
      setState(() => _loads[s.id] =
          _SourceLoad(listing: _loads[s.id]?.listing, error: _errorText(e)));
    }
  }

  /// 进入某一块来源里的子目录：先取一次列表，再把浏览页推到栈上。
  ///
  /// 浏览页需要初始列表，这样它首帧就有内容，不会先闪一下空白再填。
  Future<void> _enterSubdir(HomeSource s, MediaEntry dir) async {
    final offline = SourceHealth.instance.offlineReason(s.id);
    if (offline != null) {
      await showError(context, offlineHint(dir.path, offline));
      return;
    }
    try {
      final listing = await _repo.browseUrl(dir.path, s.location.options);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(
            location: s.location, initial: listing, sourceId: s.id),
      ));
      if (mounted) unawaited(_load(s));
    } catch (e) {
      if (mounted) await showError(context, _errorText(e));
    }
  }

  /// 打开某一块来源的完整浏览页（从它的根目录开始）。
  ///
  /// 单文件来源没有「完整浏览页」可言：那块的根就是文件所在的目录，
  /// 直接播这个文件更贴近用户点「全部」时想干的事。
  Future<void> _openRoot(HomeSource s) async {
    // 已知离线就直接给结论，不去连。这颗按钮以前每次都真的连一遍，服务器
    // 不在线时要等满 socket 超时才弹窗 —— 而同一块来源上早就写着连不上了。
    final offline = SourceHealth.instance.offlineReason(s.id);
    if (offline != null) {
      await showError(context, offlineHint(s.location.rootUrl, offline));
      return;
    }
    if (s.isFile) {
      final entry = _loads[s.id]?.listing?.entries.firstOrNull;
      if (entry != null) await _play(s, entry, const []);
      return;
    }
    final loaded = _loads[s.id]?.listing;
    try {
      final listing = loaded ??
          await _repo.browseUrl(s.location.rootUrl, s.location.options);
      if (!mounted) return;
      // 「最近访问」只是锦上添花，写失败不影响浏览，直接忽略。
      try {
        if (s.folder != null) {
          await LocalFolderStore.instance.touch(s.folder!.id);
        } else if (s.profile != null) {
          await ServerStore.instance.touch(s.profile!.id);
        }
      } catch (_) {}
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(
            location: s.location, initial: listing, sourceId: s.id),
      ));
      if (mounted) unawaited(_load(s));
    } catch (e) {
      if (mounted) await showError(context, _errorText(e));
    }
  }

  Future<void> _play(
      HomeSource s, MediaEntry entry, List<MediaEntry> subtitles) async {
    final listing = _loads[s.id]?.listing;
    // 单文件来源只有这一条，播完就停；拿父目录里的其它片子接着连播会
    // 让用户莫名其妙地跳到别的片子上。
    final playlist = (listing == null || s.isFile)
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

  // 让用户选择手动添加服务器，或把本机文件/文件夹加进首页。
  Future<void> _addMenu() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _addMenuInner();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 弹出「添加」菜单，并且**等它完全收回去**再把选中项交给调用方。
  ///
  /// `showModalBottomSheet` 返回的 future 是路由的 `popped`，在导航栈开始 pop
  /// 的那一刻就完成了，可 sheet 的退场动画还有 200ms。iOS 上紧接着 push 新页面
  /// 时 UIKit 还在收拾模态视图，新压上去的路由会被丢掉 —— 用户看到的就是
  /// 「点加号弹出的二级页面立刻自己收回」。所以这里自己 push 路由，再等
  /// `completed`（动画结束、路由 dispose）才继续。
  Future<String?> _showAddSheet() async {
    final navigator = Navigator.of(context);
    final localizations = MaterialLocalizations.of(context);
    final route = ModalBottomSheetRoute<String>(
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('添加服务器'),
              subtitle: const Text('填写 IP、共享名与账号密码'),
              onTap: () => Navigator.pop(ctx, 'manual'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('添加本地文件/文件夹'),
              subtitle: const Text('浏览本机目录，挑一个文件或一块目录'),
              onTap: () => Navigator.pop(ctx, 'local'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('直接输入路径'),
              subtitle: const Text('网络盘符、隐藏目录这些点不到的位置'),
              onTap: () => Navigator.pop(ctx, 'path'),
            ),
          ],
        ),
      ),
      showDragHandle: true,
      isScrollControlled: false,
      capturedThemes:
          InheritedTheme.capture(from: context, to: navigator.context),
      barrierLabel: localizations.scrimLabel,
      barrierOnTapHint:
          localizations.scrimOnTapHint(localizations.bottomSheetLabel),
    );
    final choice = await navigator.push(route);
    await route.completed;
    return choice;
  }

  Future<void> _addMenuInner() async {
    final choice = await _showAddSheet();
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'manual':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const ServerEditScreen()),
        );
        break;
      case 'local':
        // 已经在 _busy 保护中，走内部实现，避免重复置 busy。
        await _addLocalFolderInner();
        break;
      case 'path':
        await _addFolderByPathInner();
        break;
    }
    if (mounted) {
      setState(() {});
      unawaited(_loadAll());
    }
  }

  /// 挑一个本机文件夹并加进首页。
  Future<void> _addLocalFolder() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _addLocalFolderInner();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addLocalFolderInner() async {
    // Android 13+ 把存储权限拆成了按类型的媒体权限，必须运行时申请；
    // 没申请时列出来是空目录，看起来像本地浏览坏了。
    final perm = await MediaPermission.request();
    if (!perm.granted) {
      if (mounted) {
        await showError(
            context, '没有读取视频的权限，无法浏览本地文件。可以在系统设置里给 LanPlayer 打开「视频」权限。');
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

    // 盘符探测会同步 stat，放到后台 isolate 上去，这里只等结果（评审 4.8）。
    final roots = await _repo.localRoots();
    if (!mounted) return;
    final choice = await pickLocalPath(context, roots,
        backKey:
            SettingsStore.instance.value.shortcuts.keyFor(ShortcutAction.back));
    if (choice == null || !mounted) return;
    await LocalFolderStore.instance.add(
      label: choice.label,
      path: choice.path,
      isFile: choice.isFile,
    );
    if (mounted) setState(() {});
  }

  Future<void> _addFolderByPathInner() async {
    // 盘符探测在后台 isolate 上跑；等结果期间页面可能已经被弹走。
    final home = await _repo.localRoots();
    if (!mounted) return;
    final path =
        await askLocalPath(context, home.isEmpty ? '' : home.first.path);
    if (path == null || !mounted) return;
    final segments = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
    final isFile = File(path).existsSync() && !Directory(path).existsSync();
    await LocalFolderStore.instance.add(
      label: segments.isEmpty ? path : segments.last,
      path: path,
      isFile: isFile,
    );
    if (mounted) {
      setState(() {});
      unawaited(_loadAll());
    }
  }

  // 删除前确认；服务器只移除本机记录，本地来源只是从首页摘掉。
  Future<void> _confirmRemove(HomeSource s) async {
    final what = s.isServer ? '服务器' : (s.isFile ? '文件' : '文件夹');
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
    _loadGen.remove(s.id);
    // 这块来源没了，它的离线标记也一起清掉：同 id 万一被新来源复用，
    // 别让它一上来就带着上一个的「连不上」。
    SourceHealth.instance.forget(s.id);
    // 正被过滤的那一块被移除后要回到「全部」，否则页面会空白。
    if (_only == s.id) _only = null;
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

  Future<String?> _askLabel(String initial) {
    return showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: initial),
    );
  }

  /// 把每一块来源摊平成一串列表项：标题栏、若干行、收尾按钮、分隔线。
  ///
  /// 这里只造描述体（[_HomeItem]），真正的 `MediaRow` 要等
  /// `ListView.builder` 滚到那一行才建。整块塞进一个 `Column` 的写法会把
  /// 一块来源的所有行一次挂载，每行一个 `ThumbnailTile`，于是进首页就排起
  /// 两百个封面请求。
  List<_HomeItem> _homeItems(List<HomeSource> visible) {
    final items = <_HomeItem>[];
    for (final s in visible) {
      final load = _loads[s.id];
      final listing = load?.listing;
      final rows = listing == null ? const <MediaEntry>[] : homeRows(listing);
      final expanded = _expanded.contains(s.id);
      final shown = !expanded && rows.length > _maxRows
          ? rows.take(_maxRows).toList(growable: false)
          : rows;
      items.add(_FixedItem(_SourceSection(
        key: ValueKey('section-${s.id}'),
        source: s,
        load: load,
        empty: listing != null && rows.isEmpty,
        onRetry: () => _load(s),
        onOpenRoot: () => _openRoot(s),
        onEdit: () => _editSource(s),
        onRemove: () => _confirmRemove(s),
      )));
      if (listing == null) continue;
      for (final e in shown) {
        items.add(_RowItem(
          entry: e,
          listing: listing,
          location: s.location,
          onEnter: (entry) => _enterSubdir(s, entry),
          onPlay: (entry, subs) => _play(s, entry, subs),
        ));
      }
      if (rows.length > shown.length || (expanded && rows.length > _maxRows)) {
        items.add(_FixedItem(_SectionFooter(
          key: ValueKey('footer-${s.id}'),
          hidden: rows.length - shown.length,
          expanded: expanded,
          onExpand: () => setState(() => _expanded.add(s.id)),
          onCollapse: () => setState(() => _expanded.remove(s.id)),
        )));
      }
      items.add(const _FixedItem(Divider(height: 1)));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final sources = _sources;
    final visible =
        _only == null ? sources : sources.where((s) => s.id == _only).toList();
    // 先摊平成「行」，Widget 本身留给 builder 按需创建。见 [_HomeItem]。
    final items = _homeItems(visible);
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
              onPressed: () => unawaited(_loadAll()),
            ),
          if (sources.isNotEmpty)
            IconButton(
              tooltip: '添加',
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.add),
              onPressed: _busy ? null : _addMenu,
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
      // 添加入口只在顶栏出现，且只在已经有来源时出现：空状态页面中央
      // 本来就摆着两颗按钮，再顶一个「+」就是重复。
      //
      // 还没读完磁盘时先留空：这时候说「还没有内容」是错的，用户会以为
      // 保存的服务器丢了。读取只占开头几毫秒到几十毫秒，空一帧看不出来。
      body: sources.isEmpty
          ? (_storesReady
              ? _EmptyState(
                  onAdd: _addMenu,
                  onLocal: _addLocalFolder,
                )
              : const SizedBox.expand())
          : Column(
              children: [
                if (showSourceFilter(sources.length))
                  _SourceFilter(
                    sources: sources,
                    only: _only,
                    onPick: (id) => setState(() => _only = id),
                  ),
                Expanded(
                  // 展平成一条条「行」交给 builder：一份来源摊开后有几百行，
                  // 如果按小节整块建出来，`children:` 会把每个 `MediaRow`
                  // 都造一遍，每行都起一次封面请求 —— 几百个请求排在闸门后面，
                  // 滚动时看到的就是一路转圈。展平之后只建视口内的那些行。
                  child: ListView.builder(
                    padding: const EdgeInsets.only(top: 4, bottom: 24),
                    itemCount: items.length,
                    itemBuilder: (ctx, i) => items[i].build(),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 重命名对话框。抽成 StatefulWidget，让 TextEditingController 的释放
/// 跟着对话框自身生命周期走，避免在退场动画期间被提前 dispose。
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _ctrl.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: const InputDecoration(labelText: '显示名称'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
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

/// 首页列表里的一项。真正建 Widget 的动作推迟到 `ListView.builder` 请求它时。
///
/// 只要「摊平」这一步不顺手把 `MediaRow` 建出来，滚出屏幕的行就会被正常
/// 回收，封面请求也就跟着停在那里，不会继续排队。
abstract class _HomeItem {
  Widget build();
}

/// 已经建好的 Widget（标题栏、收尾按钮、分隔线）。
class _FixedItem implements _HomeItem {
  const _FixedItem(this.child);

  final Widget child;

  @override
  Widget build() => child;
}

/// 媒体行：只记住数据与回调，等被请求时再建 [MediaRow]。
class _RowItem implements _HomeItem {
  const _RowItem({
    required this.entry,
    required this.listing,
    required this.location,
    required this.onEnter,
    required this.onPlay,
  });

  final MediaEntry entry;
  final DirectoryListing listing;
  final MediaLocation location;
  final ValueChanged<MediaEntry> onEnter;
  final void Function(MediaEntry entry, List<MediaEntry> subtitles) onPlay;

  @override
  Widget build() => MediaRow(
        key: ValueKey('row-${entry.path}'),
        entry: entry,
        listing: listing,
        location: location,
        onEnter: onEnter,
        onPlay: onPlay,
      );
}

/// 一块来源的标题栏：图标、名称、全部/编辑/移除，以及加载与错误提示。
///
/// 它**不再**负责画行：行已经由 [HomeScreen._homeItems] 摊平成独立的列表项，
/// 这样 `ListView.builder` 才能只为视口内的行建 Widget。
class _SourceSection extends StatelessWidget {
  const _SourceSection({
    super.key,
    required this.source,
    required this.load,
    required this.empty,
    required this.onRetry,
    required this.onOpenRoot,
    required this.onEdit,
    required this.onRemove,
  });

  final HomeSource source;
  final _SourceLoad? load;

  /// 这一块的根目录里没有任何可播放的东西。
  final bool empty;
  final VoidCallback onRetry;
  final VoidCallback onOpenRoot;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final loading = load?.loading ?? true;
    final error = load?.error;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 2),
          child: Row(
            children: [
              Icon(
                  source.isServer
                      ? Icons.dns_outlined
                      : source.isFile
                          ? Icons.movie_outlined
                          : Icons.folder_outlined,
                  size: 20,
                  color: scheme.primary),
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
                child: Text(source.isFile ? '播放' : '全部'),
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
        if (loading) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 16, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(error,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: scheme.error)),
                ),
                TextButton(onPressed: onRetry, child: const Text('重试')),
              ],
            ),
          ),
        if (empty && error == null && !loading)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 14),
            child: Text('这个目录里没有视频', style: TextStyle(fontSize: 12)),
          ),
      ],
    );
  }
}

/// 小节末尾的「还有 N 项」/「收起」。同样是一个独立的列表项。
class _SectionFooter extends StatelessWidget {
  const _SectionFooter({
    super.key,
    required this.hidden,
    required this.expanded,
    required this.onExpand,
    required this.onCollapse,
  });

  /// 还没列出来的行数；0 表示已经全部摊开。
  final int hidden;
  final bool expanded;
  final VoidCallback onExpand;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    if (hidden > 0) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: TextButton.icon(
          onPressed: onExpand,
          icon: const Icon(Icons.expand_more, size: 18),
          label: Text('还有 $hidden 项'),
        ),
      );
    }
    if (!expanded) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: TextButton.icon(
        onPressed: onCollapse,
        icon: const Icon(Icons.expand_less, size: 18),
        label: const Text('收起'),
      ),
    );
  }
}

// 无来源时展示的引导页面。
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.onAdd,
    required this.onLocal,
  });

  final VoidCallback onAdd;
  final VoidCallback onLocal;

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
            const SizedBox(height: 24),
            // 两颗按钮同宽同高：主题给 FilledButton 设了
            // minimumSize: Size.fromHeight(48)（宽度是无穷大），它在 Column 里
            // 会撑满可用宽度，而 OutlinedButton 没有这条约束，于是蓝色那颗
            // 明显比下面那颗宽。这里统一钉成同一个宽度和高度。
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      onPressed: onAdd,
                      icon: const Icon(Icons.dns_outlined),
                      label: const Text('添加服务器'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      onPressed: onLocal,
                      icon: const Icon(Icons.folder_open_outlined),
                      label: const Text('添加本地文件/文件夹'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
