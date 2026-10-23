import 'package:flutter/material.dart';

import '../data/location.dart';
import '../data/models.dart';
import '../data/repository.dart';
import '../data/stores.dart';
import 'browser_screen.dart';
import 'feedback.dart';
import 'media_permission.dart';
import 'server_edit_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _repo = MediaRepository();
  // 防止连接期间重复触发服务器打开操作。
  bool _busy = false;

  // 读取服务器目录后记录最近访问时间，并进入浏览页面。
  Future<void> _openServer(ServerProfile p) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final listing = await _repo.browse(p);
      await ServerStore.instance.touch(p.id);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(
            location: MediaLocation.fromProfile(p), initial: listing),
      ));
      if (mounted) setState(() {});
    } on MediaSourceException catch (e) {
      if (mounted) await showError(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // 让用户选择手动添加 SMB 服务器，或浏览本机存储。
  Future<void> _addMenu() async {
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
              leading: const Icon(Icons.sd_storage_outlined),
              title: const Text('播放本地视频'),
              subtitle: const Text('打开本机存储中的文件，使用同一套内核'),
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
        await _openLocal();
        break;
    }
    if (mounted) setState(() {});
  }

  // 选择本地存储位置并加载其目录。
  Future<void> _openLocal() async {
    final roots = _repo.localRoots();
    final picked = await showModalBottomSheet<({String label, String path})>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final r in roots)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(r.label),
                subtitle: Text(r.path),
                onTap: () => Navigator.pop(ctx, r),
              ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) return;
    // Android 13+ 把存储权限拆成了按类型的媒体权限，必须运行时申请；
    // 没申请时读出来是空目录，用户会以为本地浏览坏了。
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
    try {
      final listing = await _repo.browseLocal(picked.path);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(
          location: MediaLocation.local(picked.label, picked.path),
          initial: listing,
        ),
      ));
    } on MediaSourceException catch (e) {
      if (mounted) await showError(context, e.message);
    }
  }

  // 删除前确认；此操作只移除本机保存的服务器记录。
  Future<void> _confirmDelete(ServerProfile p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${p.displayName}？'),
        content: const Text('只会从本机移除这条记录，不会修改服务端的共享设置。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await ServerStore.instance.remove(p.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final servers = ServerStore.instance.servers;
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
      body: servers.isEmpty
          // 尚未保存服务器时，提供添加服务器和打开本地视频的入口。
          ? _EmptyState(onAdd: _addMenu, onLocal: _openLocal)
          : ListView.builder(
              padding: const EdgeInsets.only(top: 8, bottom: 96),
              itemCount: servers.length,
              itemBuilder: (ctx, i) {
                final p = servers[i];
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.folder_shared),
                    ),
                    title: Text(p.displayName,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      describeServer(p),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) async {
                        switch (v) {
                          case 'edit':
                            await Navigator.of(context)
                                .push(MaterialPageRoute<void>(
                              builder: (_) => ServerEditScreen(profile: p),
                            ));
                            if (mounted) setState(() {});
                            break;
                          case 'delete':
                            await _confirmDelete(p);
                            break;
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('编辑')),
                        PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                    onTap: () => _openServer(p),
                  ),
                );
              },
            ),
    );
  }
}

// 无服务器记录时展示的引导页面。
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd, required this.onLocal});

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
            const Text('还没有服务器',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text(
              '在 Windows 上把文件夹设为共享（右键 → 属性 → 共享），\n'
              '把地址 / 共享名 / 用户名 / 密码填进来即可。',
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
              icon: const Icon(Icons.sd_storage_outlined),
              label: const Text('播放本地视频'),
            ),
          ],
        ),
      ),
    );
  }
}
