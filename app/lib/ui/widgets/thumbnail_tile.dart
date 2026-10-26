import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/thumbs.dart';

/// 列表左侧的封面方块：正在取的时候显示占位图标，取到了淡入图片。
///
/// 为什么不让缩略图自己组 URL：调用方（浏览页）手里才有完整的选项
/// （SMB 账号密码），把 URL 和 options 一起传进来可以保证解码用的凭据
/// 与列目录时完全一致。
class ThumbnailTile extends StatefulWidget {
  const ThumbnailTile({
    super.key,
    required this.url,
    required this.options,
    this.version,
    this.size = 56,
    this.fallback,
  });

  /// 媒体文件的绝对 URL（不带账号密码）。
  final String url;

  /// 传给内核的选项（含 user/password）。
  final Map<String, dynamic> options;

  /// 这个文件「这一版」的标记（修改时间 + 大小）。
  ///
  /// 缓存键里带上它，同名文件被替换后才能重新解一帧；不传就退回只按 URL
  /// 缓存，那样换了内容的文件会一直显示旧封面。
  final String? version;

  /// 方块边长（逻辑像素）。
  final double size;

  /// 取不到封面时显示的图标，默认是通用视频图标。
  final IconData? fallback;

  @override
  State<ThumbnailTile> createState() => _ThumbnailTileState();
}

class _ThumbnailTileState extends State<ThumbnailTile> {
  ui.Image? _image;
  bool _loading = true;

  /// 请求序号：`didUpdateWidget` 换文件后，上一个请求的迟到结果必须丢弃，
  /// 否则会把 A 的封面画到 B 那一行上。
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(covariant ThumbnailTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列表是复用的：同一个 State 可能被挪去显示另一个文件，这时必须重新
    // 取图，否则会显示上一行的封面。同一个 URL 但文件被替换过（version 变了）
    // 也要重取 —— 否则刷新完还是旧封面。
    if (oldWidget.url != widget.url || oldWidget.version != widget.version) {
      _image = null;
      _loading = true;
      _fetch();
    }
  }

  Future<void> _fetch() async {
    final seq = ++_seq;
    final image = await ThumbnailCache.instance
        .load(widget.url, widget.options, version: widget.version);
    // 这一行已经被复用去显示别的文件了，本次结果作废。
    if (!mounted || seq != _seq) return;
    if (_image == image && !_loading) return;
    setState(() {
      _image = image;
      _loading = false;
    });
  }

  @override
  void dispose() {
    // ui.Image 由缓存持有，这里只丢掉引用，不能 dispose
    // （否则缓存里的那张图会变成已释放状态）。
    _image = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(widget.size * 0.14);

    Widget content;
    final image = _image;
    if (image != null) {
      content = RawImage(
        image: image,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
      );
    } else {
      content = ColoredBox(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        child: Center(
          child: _loading
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                )
              : Icon(
                  widget.fallback ?? Icons.movie_outlined,
                  size: widget.size * 0.4,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(width: widget.size, height: widget.size, child: content),
    );
  }
}
