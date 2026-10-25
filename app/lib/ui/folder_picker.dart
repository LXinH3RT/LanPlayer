import 'dart:io';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'feedback.dart';

/// 用户选好的本机文件夹。
class FolderChoice {
  const FolderChoice({required this.label, required this.path});

  final String label;
  final String path;
}

/// 打开「挑一个本机文件夹」的对话框，返回用户确认的那一层目录。
///
/// 从常用位置起步，可以一层层往下点。为什么不用系统目录选择器：桌面端没有
/// 跨平台的目录选择插件；Android 的 SAF 交回的是 `content://` URI，内核打不开；
/// 而「列一层目录」内核本来就会做，用同一套实现反而让三个平台行为一致。
Future<FolderChoice?> pickLocalFolder(
    BuildContext context, List<({String label, String path})> roots) {
  return showDialog<FolderChoice>(
    context: context,
    builder: (ctx) => _FolderPickerDialog(roots: roots),
  );
}

class _FolderPickerDialog extends StatefulWidget {
  const _FolderPickerDialog({required this.roots});

  final List<({String label, String path})> roots;

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  final _repo = MediaRepository();

  /// 空栈表示正停在「常用位置」这一层。
  final List<({String title, String path})> _stack =
      <({String title, String path})>[];

  DirectoryListing? _listing;
  bool _loading = false;
  String? _error;

  String? get _currentPath => _stack.isEmpty ? null : _stack.last.path;

  Future<void> _enter(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await _repo.browseUrl('file://$path', const {});
      if (!mounted) return;
      setState(() {
        final segments = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
        _stack.add((
          title: segments.isEmpty ? path : segments.last,
          path: path,
        ));
        _listing = listing;
        _loading = false;
      });
    } on MediaSourceException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  void _up() {
    if (_stack.isEmpty) return;
    setState(() {
      _stack.removeLast();
      _listing = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final folders = _listing?.folders ?? const <MediaEntry>[];
    final title = _stack.isEmpty ? '选择文件夹' : _stack.last.title;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: _stack.isEmpty ? '关闭' : '上一级',
                    icon: Icon(_stack.isEmpty ? Icons.close : Icons.arrow_back),
                    onPressed: () {
                      if (_stack.isEmpty) {
                        Navigator.pop(context);
                      } else {
                        _up();
                      }
                    },
                  ),
                  Expanded(
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                ],
              ),
            ),
            if (_stack.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _stack.last.path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            const Divider(height: 12),
            Expanded(child: _body(folders)),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _currentPath == null ? '先挑一个常用位置' : '选中这一层目录',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _currentPath == null
                        ? null
                        : () => Navigator.pop(
                              context,
                              FolderChoice(
                                label: _stack.last.title,
                                path: _stack.last.path,
                              ),
                            ),
                    child: const Text('加进首页'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(List<MediaEntry> folders) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed:
                    _currentPath == null ? null : () => _enter(_currentPath!),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_stack.isEmpty) {
      return ListView(
        children: [
          for (final r in widget.roots)
            ListTile(
              leading: const Icon(Icons.sd_storage_outlined),
              title: Text(r.label),
              subtitle:
                  Text(r.path, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _enter(r.path),
            ),
        ],
      );
    }
    if (folders.isEmpty) {
      return const Center(child: Text('这一层没有子文件夹，可以直接选它'));
    }
    return ListView.builder(
      itemCount: folders.length,
      itemBuilder: (ctx, i) {
        final f = folders[i];
        return ListTile(
          leading: const Icon(Icons.folder, color: Color(0xFFFFC107)),
          title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _enter(f.path),
        );
      },
    );
  }
}

/// 让用户手写一个路径（网络盘符、隐藏目录这些点不到的位置）。
Future<String?> askFolderPath(BuildContext context, String hint) async {
  final ctrl = TextEditingController(text: hint);
  final picked = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('输入文件夹路径'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '路径',
          hintText: r'C:\Users\Public\Videos 或 /Users/me/Movies',
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  ctrl.dispose();
  if (picked == null || picked.isEmpty) return null;
  if (!Directory(picked).existsSync()) {
    if (context.mounted) {
      await showError(context, '这个路径不是一个可访问的文件夹：$picked');
    }
    return null;
  }
  return picked;
}
