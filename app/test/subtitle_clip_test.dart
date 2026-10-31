import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/ui/widgets/subtitle_overlay.dart';

/// 一条带 `\clip` 的字幕被画到了哪里。
///
/// 视口与 `devicePixelRatio` 都钉死，脚本坐标、逻辑像素和截图像素是同一个
/// 单位，于是画出来的包围盒可以直接和脚本里的矩形比。
Future<({int left, int top, int right, int bottom, int count})> _bounds(
  WidgetTester tester,
  SubtitleCue cue, {
  Size viewport = const Size(1280, 720),
  double aspectRatio = 16 / 9,
}) async {
  tester.view.physicalSize = viewport;
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
  // `toImage()` 要靠一次真实的事件循环才完成，`testWidgets` 的假时钟永远不给
  // 这一次 —— 不套 `runAsync` 会一直等下去。
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

SubtitleCue _cueWithClip(List<double> clip, {bool inverse = false}) =>
    SubtitleCue(
      text: '裁剪之外的两端都看不见',
      startUs: 0,
      endUs: 1000000,
      style: _style,
      lines: [
        SubtitleLine(
          text: '裁剪之外的两端都看不见',
          runs: [
            SubtitleSpan(
              text: '裁剪之外的两端都看不见',
              clip: clip,
              clipInverse: inverse,
            ),
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

  testWidgets('画面上下有黑边时裁剪框不能被整体挪走', (tester) async {
    // 竖屏 iPad 的实测现象：视频只占中间一条，上下都是黑边；同一份字幕在
    // 桌面端（视频贴顶、`video.top == 0`）正常，在 iPad 上整行消失。
    const portrait = Size(900, 1600);
    final open =
        await _bounds(tester, _cueWithClip(const []), viewport: portrait);
    final clipped = await _bounds(
      tester,
      _cueWithClip(const [560, 200, 700, 520]),
      viewport: portrait,
    );
    expect(open.count, greaterThan(100), reason: '不裁剪时这一行看得见');
    expect(clipped.count, greaterThan(20), reason: '有上下黑边时裁剪窗里的一部分字仍然必须画出来');
    // 16:9 的画面塞进 900 宽之后高 506.25，脚本 560..700 落在 393..492。
    expect(clipped.left, greaterThanOrEqualTo(390), reason: '裁掉左边的字');
    expect(clipped.right, lessThanOrEqualTo(495), reason: '裁掉右边的字');
  });

  testWidgets('画面左右有黑边时裁剪框跟着画面横向偏移', (tester) async {
    // 宽扁窗口里放 4:3 的素材：画面居中，左右各留一条黑边。裁剪框若不加上
    // `video.left`，会整体偏到左边的黑边上，框里的字一个都留不下。
    const flat = Size(1200, 400);
    const ratio = 4 / 3;
    // 1200x400 里 4:3 的画面是 533.3x400，居中后 `video.left == 333.3`。
    // 脚本 100..400（宽 1280）落在 375..500。
    final clipped = await _bounds(
      tester,
      _cueWithClip(const [100, 0, 400, 720]),
      viewport: flat,
      aspectRatio: ratio,
    );
    expect(clipped.count, greaterThan(20), reason: '裁剪窗里必须还有字');
    expect(clipped.left, greaterThanOrEqualTo(370),
        reason: '裁剪窗要落在画面里的 375px 处，不能停在左边的黑边上');
    expect(clipped.right, lessThanOrEqualTo(505), reason: '右边界同样要跟着挪');
  });

  testWidgets('\\iclip 反过来只保留窗口外面的字', (tester) async {
    // 中间的窄窗口被挖空，左右两端留下来。负向对照是上面那条 `\clip`：
    // 同一个矩形，普通裁剪只剩窗口里的字，逆裁剪只剩窗口外的字。
    const window = <double>[560, 0, 720, 720];
    final normal = await _bounds(tester, _cueWithClip(window));
    final inverse = await _bounds(tester, _cueWithClip(window, inverse: true));
    expect(normal.count, greaterThan(20));
    expect(normal.left, greaterThanOrEqualTo(558));
    expect(normal.right, lessThanOrEqualTo(722));
    expect(inverse.count, greaterThan(20), reason: '窗口外的字必须画出来');
    expect(inverse.right, greaterThanOrEqualTo(780),
        reason: '右侧的字不该被 \\iclip 的窗口吞掉');
    expect(inverse.left, lessThan(500), reason: '左侧的字同样要留着');
  });
}
