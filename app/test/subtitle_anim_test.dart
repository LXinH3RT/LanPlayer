import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/data/subtitle_anim.dart';
import 'package:lanplayer/ui/widgets/subtitle_overlay.dart';

/// ASS 高级特性的 Dart 侧验证：`\t` 动画、`\k` 卡拉 OK、`\clip` 裁剪、`\p` 绘图。
///
/// 内核把 `anims` / `karaoke` / `clip` / `path` 原样放进事件，真正「此刻长
/// 什么样」由这一层算。屏幕截图在 Windows 上对播放页无效（外部纹理注册后
/// `PrintWindow` 与 `CopyFromScreen` 都读不到），所以这里断言三件事：
/// 解算出来的数值、画出来的 `TextSpan` 颜色、以及 `RepaintBoundary` 的像素。

SubtitleStyle _style({
  int color = 0xFFFFFFFF,
  int secondaryColor = 0xFFFFFFFF,
  int outlineColor = 0xFF000000,
  double playResX = 1920,
  double playResY = 1080,
}) =>
    SubtitleStyle(
      color: color,
      secondaryColor: secondaryColor,
      outlineColor: outlineColor,
      outline: 1,
      fontScale: 0.05,
      font: 'sans-serif',
      playResX: playResX,
      playResY: playResY,
    );

SubtitleSpan _run({
  String text = 'X',
  int color = 0,
  int outlineColor = 0,
  double alpha = 1.0,
  int karaokeKind = 0,
  double karaokeStart = 0,
  double karaokeEnd = 0,
  List<SubtitleAnim> anims = const [],
  List<double> clip = const [],
  int drawingScale = 0,
  List<SubtitlePathPoint> path = const [],
}) =>
    SubtitleSpan(
      text: text,
      color: color,
      outlineColor: outlineColor,
      alpha: alpha,
      karaokeKind: karaokeKind,
      karaokeStart: karaokeStart,
      karaokeEnd: karaokeEnd,
      anims: anims,
      clip: clip,
      drawingScale: drawingScale,
      path: path,
    );

SubtitleCue _cue({
  String text = 'LINE',
  List<SubtitleLine> lines = const [],
  SubtitleStyle? style,
  int nowUs = 0,
}) =>
    SubtitleCue(
      text: text,
      startUs: 0,
      endUs: 5000000,
      style: style ?? _style(),
      lines: lines,
      nowUs: nowUs,
    );

/// 收集所有可见文字的 span（跳过只有描边的层）。
List<TextSpan> _leaves(WidgetTester tester) {
  final out = <TextSpan>[];
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    final leaves = <TextSpan>[];
    void walk(InlineSpan s) {
      if (s is TextSpan) {
        if ((s.text ?? '').trim().isNotEmpty) leaves.add(s);
        for (final child in s.children ?? const <InlineSpan>[]) {
          walk(child);
        }
      }
    }

    walk(rich.text);
    if (leaves.isEmpty) continue;
    if (leaves.every((s) => s.style?.foreground != null)) continue;
    out.addAll(leaves);
  }
  return out;
}

/// 把字幕铺满 1000x800 的表面（视频 1000x800，画面高度就是 800）。
Future<void> _pump(WidgetTester tester, SubtitleCue cue, {Key? key}) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: const Color(0xFF000000),
            child: SubtitleOverlay(
              cue: cue,
              scale: 1.0,
              safeArea: 0,
              videoAspectRatio: 1.25,
            ),
          ),
        ),
      ),
    ),
  );
}

/// 数一数画面上有多少个指定颜色的像素。
Future<int> _count(
  WidgetTester tester,
  GlobalKey key, {
  required bool Function(int r, int g, int b) hit,
}) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await tester.runAsync(() => boundary.toImage());
  final data = await tester
      .runAsync(() => image!.toByteData(format: ui.ImageByteFormat.rawRgba));
  final rgba = data!.buffer.asUint8List();
  var n = 0;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (hit(rgba[i], rgba[i + 1], rgba[i + 2])) n++;
  }
  return n;
}

int _argb(Color c) =>
    ((c.a * 255).round() << 24) |
    ((c.r * 255).round() << 16) |
    ((c.g * 255).round() << 8) |
    (c.b * 255).round();

void main() {
  group(r'\t 动画', () {
    test('进度按窗口归一化，accel 大于 1 时先慢后快', () {
      const anim = SubtitleAnim(t1: 400, t2: 1400, accel: 0);
      expect(SubtitleAnimator.progress(anim, 0), 0.0);
      expect(SubtitleAnimator.progress(anim, 400), 0.0);
      expect(SubtitleAnimator.progress(anim, 900), closeTo(0.5, 1e-6));
      expect(SubtitleAnimator.progress(anim, 1400), 1.0);
      expect(SubtitleAnimator.progress(anim, 9000), 1.0);

      const accel = SubtitleAnim(t1: 0, t2: 1000, accel: 2);
      // accel=2 → pow(p, 1/2)，过半时刻已经走完约 0.707。
      expect(SubtitleAnimator.progress(accel, 500), closeTo(0.7071, 1e-3));
      // 窗口长度为 0 时不炸，按「到点即完成」处理。
      const zero = SubtitleAnim(t1: 500, t2: 500);
      expect(SubtitleAnimator.progress(zero, 499), 0.0);
      expect(SubtitleAnimator.progress(zero, 500), 1.0);
    });

    test('颜色动画按时刻插值', () {
      final run = _run(
        anims: const [
          SubtitleAnim(
              t1: 0,
              t2: 1000,
              fields: SubtitleAnim.fieldColor,
              color: 0xFFFF0000),
        ],
      );
      final at0 = SubtitleAnimator.resolve(run, 0);
      final at50 = SubtitleAnimator.resolve(run, 500);
      final at100 = SubtitleAnimator.resolve(run, 1000);
      // 起点是 run 自己的颜色（0 = 继承），这里默认白色。
      expect(at0.color, 0xFFFFFFFF);
      expect(at100.color, 0xFFFF0000);
      // Flutter 3.27 起 `Color.r/g/b` 是 0..1 的 double，按 8 位通道比较。
      final mid = Color(at50.color);
      expect((mid.r * 255).round(), closeTo(255, 1));
      expect((mid.g * 255).round(), closeTo(127, 2));
      expect((mid.b * 255).round(), closeTo(127, 2));
    });

    test('多个动画依次覆盖，后写的赢', () {
      final run = _run(
        anims: const [
          SubtitleAnim(
              t1: 0, t2: 1000, fields: SubtitleAnim.fieldScaleX, scaleX: 200),
          SubtitleAnim(
              t1: 500, t2: 500, fields: SubtitleAnim.fieldScaleX, scaleX: 50),
        ],
      );
      expect(SubtitleAnimator.resolve(run, 0).scaleX, closeTo(100, 1e-6));
      expect(SubtitleAnimator.resolve(run, 1000).scaleX, closeTo(50, 1e-6));
    });

    test(r'\t 里的 \alpha 会真的改透明度', () {
      final run = _run(
        anims: const [
          SubtitleAnim(
              t1: 0, t2: 1000, fields: SubtitleAnim.fieldAlpha, alpha: 0.0),
        ],
      );
      expect(SubtitleAnimator.resolve(run, 0).alpha, closeTo(1.0, 1e-6));
      expect(SubtitleAnimator.resolve(run, 500).alpha, closeTo(0.5, 1e-6));
      expect(SubtitleAnimator.resolve(run, 1000).alpha, closeTo(0.0, 1e-6));
    });

    testWidgets('动画改的是画出来的颜色', (tester) async {
      final cue = _cue(
        nowUs: 1000000,
        lines: [
          SubtitleLine(
            text: 'RED',
            runs: [
              _run(
                text: 'RED',
                anims: const [
                  SubtitleAnim(
                      t1: 0,
                      t2: 1000,
                      fields: SubtitleAnim.fieldColor,
                      color: 0xFFFF0000),
                ],
              ),
            ],
          ),
        ],
      );
      await _pump(tester, cue);
      final leaves = _leaves(tester);
      expect(leaves, isNotEmpty);
      expect(_argb(leaves.first.style!.color!), 0xFFFF0000);
    });
  });

  group(r'\k 卡拉 OK', () {
    test('填色进度随时间推进', () {
      final run = _run(karaokeKind: 1, karaokeStart: 100, karaokeEnd: 600);
      expect(SubtitleAnimator.karaokeFill(run, 0), 0.0);
      expect(SubtitleAnimator.karaokeFill(run, 100), 0.0);
      expect(SubtitleAnimator.karaokeFill(run, 350), closeTo(0.5, 1e-6));
      expect(SubtitleAnimator.karaokeFill(run, 600), 1.0);
      expect(SubtitleAnimator.karaokeFill(run, 9999), 1.0);
      // 不是卡拉 OK 的 run 永远是满的。
      expect(SubtitleAnimator.karaokeFill(_run(), 0), 1.0);
    });

    testWidgets('未唱用副色、唱完用主色、中途是两者之间', (tester) async {
      Future<Color> sample(int nowUs) async {
        final cue = _cue(
          nowUs: nowUs,
          style: _style(color: 0xFFFF0000, secondaryColor: 0xFF00FF00),
          lines: [
            SubtitleLine(
              text: 'K',
              runs: [
                _run(
                  text: 'K',
                  karaokeKind: 1,
                  karaokeStart: 100,
                  karaokeEnd: 600,
                ),
              ],
            ),
          ],
        );
        await _pump(tester, cue);
        final leaves = _leaves(tester);
        expect(leaves, isNotEmpty);
        return leaves.first.style!.color!;
      }

      // libass 的规矩：没唱到的字用 SecondaryColour，唱完是 PrimaryColour。
      // 注意 `nowUs` 是微秒，而卡拉 OK 的时间片是毫秒。
      final before = await sample(0);
      expect(before.r, closeTo(0.0, 0.02));
      expect(before.g, closeTo(1.0, 0.02));

      final after = await sample(600000);
      expect(after.r, closeTo(1.0, 0.02));
      expect(after.g, closeTo(0.0, 0.02));

      // 中途两种颜色都在场，谁也不该是纯色。
      final mid = await sample(350000);
      expect(mid.r, greaterThan(0.25));
      expect(mid.g, greaterThan(0.25));
    });

    testWidgets(r'\ko 唱过之后淡出', (tester) async {
      final cue = _cue(
        nowUs: 600000,
        style: _style(color: 0xFFFF0000),
        lines: [
          SubtitleLine(
            text: 'K',
            runs: [
              _run(
                text: 'K',
                karaokeKind: 3,
                karaokeStart: 100,
                karaokeEnd: 600,
              ),
            ],
          ),
        ],
      );
      await _pump(tester, cue);
      final leaves = _leaves(tester);
      expect(leaves.first.style!.color!.a, lessThan(0.2));
    });
  });

  group(r'\clip 裁剪', () {
    testWidgets('裁剪之外的文字一个像素都不画', (tester) async {
      final key = GlobalKey();
      final cue = _cue(
        style: _style(color: 0xFFFFFFFF),
        lines: [
          SubtitleLine(
            text: 'CLIPPED',
            runs: [
              _run(text: 'CLIPPED', clip: const [0, 0, 20, 1080]),
            ],
          ),
        ],
      );
      await _pump(tester, cue, key: key);
      // 居中的整条字幕落在 x∈[0,20] 之外，裁完应当是纯黑。
      final white = await _count(
        tester,
        key,
        hit: (r, g, b) => r > 200 && g > 200 && b > 200,
      );
      expect(white, 0, reason: 'the clipped text must not paint at all');
    });

    testWidgets('不裁剪时同样的字会画出来（负向对照）', (tester) async {
      final key = GlobalKey();
      final cue = _cue(
        style: _style(color: 0xFFFFFFFF),
        lines: [
          SubtitleLine(text: 'CLIPPED', runs: [_run(text: 'CLIPPED')]),
        ],
      );
      await _pump(tester, cue, key: key);
      final white = await _count(
        tester,
        key,
        hit: (r, g, b) => r > 200 && g > 200 && b > 200,
      );
      expect(white, greaterThan(300));
    });

    testWidgets(r'裁剪窗口足够大时不影响显示（\t 动画的终点）', (tester) async {
      final key = GlobalKey();
      final cue = _cue(
        style: _style(color: 0xFFFFFFFF),
        lines: [
          SubtitleLine(
            text: 'CLIPPED',
            runs: [
              _run(
                text: 'CLIPPED',
                clip: const [0, 0, 40, 1080],
                anims: const [
                  SubtitleAnim(
                    t1: 0,
                    t2: 300,
                    fields: SubtitleAnim.fieldClip,
                    clip: [0, 0, 1920, 1080],
                  ),
                ],
              ),
            ],
          ),
        ],
        nowUs: 300000,
      );
      await _pump(tester, cue, key: key);
      final white = await _count(
        tester,
        key,
        hit: (r, g, b) => r > 200 && g > 200 && b > 200,
      );
      expect(white, greaterThan(300),
          reason: r'after the \t animation the clip covers the whole frame');
    });
  });

  group(r'\p 矢量绘图', () {
    testWidgets('一个三角形会真的画到画布上', (tester) async {
      final key = GlobalKey();
      // `\p1` 的坐标是脚本单位，原点由 `\pos` 或 `n` 决定；给了
      // `\pos(0,0)` 才是「左上角零点的画面绝对坐标」。
      final cue = _cue(
        style: _style(color: 0xFFFF0000, playResX: 1920, playResY: 1080),
        lines: [
          SubtitleLine(
            text: '',
            posX: 0,
            posY: 0,
            align: 7,
            runs: [
              _run(
                text: '',
                drawingScale: 1,
                path: const [
                  SubtitlePathPoint(sub: 0, x: 300, y: 300),
                  SubtitlePathPoint(sub: 0, x: 900, y: 300),
                  SubtitlePathPoint(sub: 0, x: 600, y: 800),
                  SubtitlePathPoint(sub: 0, x: 300, y: 300),
                ],
              ),
            ],
          ),
        ],
      );
      await _pump(tester, cue, key: key);
      final red = await _count(
        tester,
        key,
        hit: (r, g, b) => r > 200 && g < 60 && b < 60,
      );
      expect(red, greaterThan(10000),
          reason: 'the triangle must cover a visible area');
    });

    testWidgets('没有 path 的绘图 run 不会被画', (tester) async {
      final key = GlobalKey();
      final cue = _cue(
        style: _style(color: 0xFFFF0000),
        lines: [
          SubtitleLine(
            text: '',
            runs: [_run(text: '', drawingScale: 2)],
          ),
        ],
      );
      await _pump(tester, cue, key: key);
      final red = await _count(
        tester,
        key,
        hit: (r, g, b) => r > 200 && g < 60 && b < 60,
      );
      expect(red, 0);
    });
  });
}
