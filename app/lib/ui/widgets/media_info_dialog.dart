import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../util/format.dart';

/// 打开「媒体信息」那一刻要展示的全部数字。
///
/// 分成「媒体」与「解码」两段是刻意的：前者来自 `avformat`，整场播放不会
/// 变；后者每秒刷一次。原来它们是两个入口（一个是对话框、一个是常驻浮
/// 层），用户要的其实是同一件事，所以并成一个面板。
class MediaStatsSnapshot {
  const MediaStatsSnapshot({
    required this.media,
    required this.decoder,
    required this.fps,
    required this.dropped,
    required this.avDiffUs,
    required this.queuedPackets,
    required this.positionUs,
  });

  final MediaInfo media;
  final String decoder;
  final double fps;
  final int dropped;
  final int avDiffUs;
  final int queuedPackets;
  final int positionUs;
}

/// 「媒体信息」面板：静态码流参数 + 实时解码计数 + 画面浮层开关。
///
/// 实时数字通过 [listen] 驱动重建。调用方必须在打开期间让统计数据真的
/// 推上来（否则数字是死的），关闭后再还原。
class MediaInfoDialog extends StatefulWidget {
  const MediaInfoDialog({
    super.key,
    required this.read,
    required this.listen,
    required this.overlay,
    required this.onOverlayChanged,
  });

  /// 每次重建时取一份最新快照。
  final MediaStatsSnapshot Function() read;

  /// 统计数据变化时会通知的对象（通常是播放控制器）。
  final Listenable listen;

  /// 画面上是否已经开着解码浮层。
  final bool overlay;

  final ValueChanged<bool> onOverlayChanged;

  @override
  State<MediaInfoDialog> createState() => _MediaInfoDialogState();
}

class _MediaInfoDialogState extends State<MediaInfoDialog> {
  late bool _overlay = widget.overlay;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('媒体信息'),
      content: SizedBox(
        width: 420,
        // 窗口矮的时候数据行可以滚，但「在画面上显示」这个开关得一直露在
        // 底部：它是面板里唯一的可操作项，滚出视野等于没有。
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: AnimatedBuilder(
                  animation: widget.listen,
                  builder: (context, _) {
                    final s = widget.read();
                    final m = s.media;
                    final v = m.video;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const _InfoSection('媒体'),
                        _infoRow('容器', m.format),
                        if (v != null) ...[
                          _infoRow('视频', v.label),
                          _infoRow('像素格式', v.pixFmt),
                          if (v.bitrate > 0)
                            _infoRow(
                                '码率', '${(v.bitrate / 1000).round()} kbps'),
                        ],
                        _infoRow('音频', m.audio.map((a) => a.label).join(', ')),
                        _infoRow(
                            '字幕',
                            m.subtitles.isEmpty
                                ? '无'
                                : m.subtitles.map((s) => s.label).join(', ')),
                        _infoRow('时长', formatDuration(m.durationUs)),
                        const _InfoSection('解码'),
                        _infoRow('解码器', s.decoder),
                        _infoRow('帧率', '${s.fps.toStringAsFixed(2)} fps'),
                        _infoRow('丢帧', '${s.dropped}'),
                        _infoRow('A/V 偏差',
                            '${(s.avDiffUs / 1000).toStringAsFixed(1)} ms'),
                        _infoRow('队列', '${s.queuedPackets} 包'),
                        _infoRow(
                            '位置',
                            '${formatDuration(s.positionUs)} / '
                                '${formatDuration(m.durationUs)}'),
                      ],
                    );
                  },
                ),
              ),
            ),
            const Divider(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('在画面上显示', style: TextStyle(fontSize: 13)),
              subtitle: const Text('把解码计数浮在左上角，播放时也能看',
                  style: TextStyle(fontSize: 11)),
              value: _overlay,
              onChanged: (v) {
                setState(() => _overlay = v);
                widget.onOverlayChanged(v);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    );
  }

  Widget _infoRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 76,
                child: Text(k, style: const TextStyle(fontSize: 12))),
            Expanded(
                child: SelectableText(v, style: const TextStyle(fontSize: 12))),
          ],
        ),
      );
}

class _InfoSection extends StatelessWidget {
  const _InfoSection(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
}
