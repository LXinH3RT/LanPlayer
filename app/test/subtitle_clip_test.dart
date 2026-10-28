import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/ui/widgets/subtitle_overlay.dart';

/// 一条 `\clip(...)` 到底把字画在了哪里。
///
/// 视口被钉成 1280x720 且 `devicePixelRatio` 为 1，所以脚本坐标、逻辑像素与
/// 截图像素是同一个单位，可以直接拿画出来的包围盒跟脚本里的矩形比。测试用的
/// 那句话比每个裁剪窗口都宽，四条边都是真的被切掉的。
Future<({int left, int top, int right, int bottom, int count})> _bounds(
  WidgetTester tester,
  SubtitleCue cue, {
  double aspectRatio = 16 / 9,
}) async {
  // 默认测试视口是 800x600，不钉死的话下面的 1280x720 会被悄悄缩掉，脚本
  // 坐标就不再等于截图像素。
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final key = GlobalKey();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: const Color(0xFF202020),
          child: SubtitleOverlay(cue: cue, videoAspectRatio: aspectRatio),
        ),
      ),
    ),
  ));
  await tester.pump();

  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  // `toImage()` 要靠一次真实的事件循环才完成，而 `testWidgets` 默认的假时钟
  // 永远不会给这一次 —— 不套 `runAsync` 会一直等下去。
  late ui.Image image;
  await tester.runAsync(() async {
    image = await boundary.toImage();
  });
  final data = await tester
      .runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba));
  final bytes = data!.buffer.asUint8List();
  final w = image.width, h = image.height;

  var left = w, top = h, right = -1, bottom = -1, count = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      if (bytes[i] > 225 && bytes[i + 1] > 225 && bytes[i + 2] > 225) {
        count++;
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
  }
  return (left: left, top: top, right: right, bottom: bottom, count: count);
}

const SubtitleStyle _style = SubtitleStyle(
  color: 0xFFFFFFFF,
  outlineColor: 0xFF000000,
  outline: 1,
  fontScale: 56 / 720,
  font: 'sans-serif',
  playResX: 1280,
  playResY: 720,
  align: 5,
);

SubtitleCue _cueWithClip(List<double> clip) => SubtitleCue(
      text: '裁剪之外的两端都看不见',
      startUs: 0,
      endUs: 1000000,
      style: _style,
      lines: [
        SubtitleLine(
          text: '裁剪之外的两端都看不见',
          runs: [
            SubtitleSpan(text: '裁剪之外的两端都看不见', clip: clip),
          ],
          style: _style,
          posX: 0.5,
          posY: 0.5,
          playResY: 720,
        ),
      ],
    );

void main() {
  testWidgets('没有裁剪时这一行横跨画面中央', (tester) async {
    final b = await _bounds(tester, _cueWithClip(const []));
    expect(b.count, greaterThan(100));
    expect(b.left, lessThan(500), reason: '句子从 500px 左边就开始画');
    expect(b.right, greaterThan(780), reason: '句子越过 780px 还在继续');
  });

  testWidgets('窄裁剪窗口把左右两边都切掉', (tester) async {
    final b = await _bounds(tester, _cueWithClip(const [560, 200, 700, 520]));
    expect(b.count, greaterThan(50), reason: '窗口里还能看见一部分字');
    expect(b.left, greaterThanOrEqualTo(558), reason: '裁剪左边界外不许有像素');
    expect(b.right, lessThanOrEqualTo(702), reason: '裁剪右边界外不许有像素');
  });

  testWidgets('矮裁剪窗口把字的上半截切掉', (tester) async {
    final open = await _bounds(tester, _cueWithClip(const []));
    final mid = (open.top + open.bottom) ~/ 2;
    final b =
        await _bounds(tester, _cueWithClip([0, mid.toDouble(), 1280, 720]));
    expect(b.count, greaterThan(0), reason: '下半截仍然看得见');
    expect(b.top, greaterThanOrEqualTo(mid - 2), reason: '裁剪上边界外不许有像素');
  });

  testWidgets('画面有黑边时裁剪框按画面实际宽度换算', (tester) async {
    // 1280x720 的脚本套在 2.39:1 的电影上：画面只占中间一条，
    // `PlayResX / PlayResY` 乘高度推出来的宽度比实际窄一大截。
    const wide = 2.39;
    final open =
        await _bounds(tester, _cueWithClip(const []), aspectRatio: wide);
    final clipped = await _bounds(
      tester,
      _cueWithClip(const [700, 0, 1280, 720]),
      aspectRatio: wide,
    );
    expect(open.left, lessThan(430), reason: '不裁剪时句子从很左边开始');
    // 裁剪框左边界是脚本的 700/1280 处。若用 PlayResX/PlayResY 乘高度推宽度，
    // 这个边界会被算到 520 附近，于是 520..700 之间的字全都漏出来。
    expect(clipped.left, greaterThanOrEqualTo(690),
        reason: '裁剪左边界必须落在画面的 700/1280 处，不能被黑边带偏');
  });
}
