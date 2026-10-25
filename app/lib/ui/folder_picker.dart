import 'dart:io';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'feedback.dart';

/// 用户选好的本机路径：可能是一块目录，也可能是一个文件。
class LocalChoice {
  const LocalChoice({
    required this.label,
    required this.path,
    this.isFile = false,
  });

  final String label;
  final String path;
  final bool isFile;
}

/// 打开「挑一个本机文件或文件夹」的对话框。
///
/// 从常用位置和盘符起步，可以一层层往下点；目录本身也能选中（和以前一样
/// 「把这一层加进首页」），文件则点一下选中、再按底部按钮加进首页。
///
/// 为什么不用系统对话框：桌面端没有跨平台的目录选择插件；Android 的 SAF
/// 交回的是 `content://` URI，内核打不开。自己画还能让三个平台行为一致。
Future<LocalChoice?> pickLocalPath(
    BuildContext context, List<({String label, String path})> roots) {
  return showDialog<LocalChoice>(
    context: context,
    builder: (ctx) => _LocalPickerDialog(roots: roots),
  );
}

class _LocalPickerDialog extends StatefulWidget {
  const _LocalPickerDialog({required this.roots});

  final List<({String label, String path})> roots;

  @override
  State<_LocalPickerDialog> createState() => _LocalPickerDialogState();
}

class _LocalPickerDialogState extends State<_LocalPickerDialog> {
  // late: the first screen only lists the known roots, and building it should
  // not touch the native library at all.
  late final MediaRepository _repo = MediaRepository();

  /// 空栈表示正停在「常用位置 / 盘符」这一层。
  final List<({String title, String path})> _stack =
      <({String title, String path})>[];

  DirectoryListing? _listing;
  bool _loading = false;
  String? _error;

  /// 当前被点中的文件（目录由 [_currentPath] 表达）。
  MediaEntry? _pickedFile;

  String? get _currentPath => _stack.isEmpty ? null : _stack.last.path;

  /// 内核列出来的条目带 `file://` 前缀，而这里压栈、存盘用的都是裸路径
  /// （`LocalFolder.rootUrl` 自己会补前缀）。混用会拼出 `file://file://…`。
  static String _plain(String path) {
    const prefix = 'file://';
    if (!path.startsWith(prefix)) return path;
    final rest = path.substring(prefix.length);
    // `file:///C:/x` 这种三元斜杠，去掉前缀后还剩 `/C:/x`。
    if (rest.length > 2 && rest[0] == '/' && rest[2] == ':') {
      return rest.substring(1);
    }
    return rest;
  }

  /// 完整列目录：文件也要看得见，否则「选一个文件」无从选起。
  ///
  /// 内核返回的条目 `path` 已经带 `file://` 前缀（列表里点进来就是它），
  /// 而常用位置与盘符这些根是裸路径。两种都要接住，否则会拼出
  /// `file://file://D:/x`，内核报「not found」。
  Future<DirectoryListing> _list(String path) => _repo.browseUrl(
        path.startsWith('file://') ? path : 'file://$path',
        const {'list_all': 1},
      );

  Future<void> _enter(String rawPath) async {
    final path = _plain(rawPath);
    setState(() {
      _loading = true;
      _error = null;
      _pickedFile = null;
    });
    try {
      final listing = await _list(path);
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

  /// 重试当前层：只重新拉数据，不往栈里再压一层。
  Future<void> _reload() async {
    final path = _currentPath;
    if (path == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await _list(path);
      if (!mounted) return;
      setState(() {
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
      _pickedFile = null;
    });
  }

  /// 底部按钮的结果：选中的文件优先，否则就是当前这一层目录。
  LocalChoice? get _choice {
    final file = _pickedFile;
    if (file != null) {
      return LocalChoice(
          label: file.name, path: _plain(file.path), isFile: true);
    }
    final top = _stack.isEmpty ? null : _stack.last;
    if (top == null) return null;
    return LocalChoice(label: top.title, path: _plain(top.path));
  }

  @override
  Widget build(BuildContext context) {
    final title = _stack.isEmpty ? '添加本地文件/文件夹' : _stack.last.title;
    final choice = _choice;
    // The dialog needs an explicit height: a Column that sizes itself to its
    // children cannot contain an Expanded list, and letting it hug its content
    // means the list never scrolls and the footer gets pushed out.  Reserve the
    // parent's height minus the inset, cap it at 660 so it stays a dialog on a
    // tall screen, and let the list take whatever is left.
    final media = MediaQuery.of(context);
    final maxWidth = media.size.width - 48;
    final maxHeight = media.size.height - 64;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: SizedBox(
        width: maxWidth < 620 ? maxWidth : 620,
        height: maxHeight < 660 ? maxHeight : 660,
        child: Column(
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
            Expanded(child: _body()),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      choice == null
                          ? '先挑一个位置'
                          : choice.isFile
                              ? '选中文件：${choice.label}'
                              : '选中这一层目录',
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
                  // The app theme gives every FilledButton
                  // minimumSize: Size.fromHeight(48), i.e. an *infinite*
                  // minimum width.  Inside a Row the button then asks for
                  // unbounded width, the flexible text collapses to zero and
                  // the button itself is painted outside the row and clipped:
                  // the footer looked like it only had 取消.  Pin a finite
                  // minimum here.
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    onPressed: choice == null
                        ? null
                        : () => Navigator.pop(context, choice),
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

  Widget _body() {
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
                onPressed: _currentPath == null ? null : _reload,
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
              leading: Icon(_rootIcon(r.label)),
              title: Text(r.label),
              subtitle:
                  Text(r.path, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _enter(r.path),
            ),
        ],
      );
    }
    final entries = _listing?.entries ?? const <MediaEntry>[];
    if (entries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('这一层是空的，可以直接选它'),
        ),
      );
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (ctx, i) {
        final e = entries[i];
        final picked = _pickedFile?.path == e.path;
        if (e.isDir) {
          return ListTile(
            leading: const Icon(Icons.folder, color: Color(0xFFFFC107)),
            title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _enter(e.path),
          );
        }
        final playable = e.kind == 'video' || e.kind == 'audio';
        return ListTile(
          selected: picked,
          enabled: playable,
          leading: Icon(
            playable ? _fileIcon(e.kind) : Icons.insert_drive_file_outlined,
            color: playable ? null : Theme.of(context).disabledColor,
          ),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            playable
                ? _describe(e)
                : '${_describe(e)} · 这个类型不能播放',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: picked ? const Icon(Icons.check_circle) : null,
          onTap: playable ? () => setState(() => _pickedFile = e) : null,
        );
      },
    );
  }

  static IconData _rootIcon(String label) {
    if (label.endsWith('盘') || label.endsWith(':')) return Icons.storage;
    if (label == '下载') return Icons.download_outlined;
    if (label == '主目录') return Icons.home_outlined;
    return Icons.sd_storage_outlined;
  }

  static IconData _fileIcon(String kind) => kind == 'audio'
      ? Icons.audiotrack_outlined
      : Icons.movie_outlined;

  static String _describe(MediaEntry e) {
    final parts = <String>[];
    if (e.ext.isNotEmpty) parts.add(e.ext.toUpperCase());
    if (e.size > 0) parts.add(_bytes(e.size));
    return parts.isEmpty ? '文件' : parts.join('  ·  ');
  }

  static String _bytes(int n) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = n.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    final text = v >= 100 || i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '$text ${units[i]}';
  }
}

/// 让用户手写一个路径（网络盘符、隐藏目录这些点不到的位置）。
///
/// 目录和文件都接受：填文件夹就是把它加进首页，填文件就是单文件来源。
Future<String?> askLocalPath(BuildContext context, String hint) async {
  final ctrl = TextEditingController(text: hint);
  final picked = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('输入文件或文件夹路径'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '路径',
          hintText: r'C:\Users\Public\Videos 或 D:\影片\电影.mkv',
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
  final dir = Directory(picked);
  final file = File(picked);
  if (!dir.existsSync() && !file.existsSync()) {
    if (context.mounted) {
      await showError(context, '这个路径不存在或者打不开：$picked');
    }
    return null;
  }
  return picked;
}
