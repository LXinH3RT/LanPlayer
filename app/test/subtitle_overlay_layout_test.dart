import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/ui/widgets/subtitle_overlay.dart';

/// 字幕几何：单位换算的两条回归。
///
/// ASS 脚本里的 `MarginL` / `MarginR` / `MarginV` 都是相对 `PlayResY` 的脚本
/// 单位，而 `safeArea` 是宿主（播放页）给的**窗口逻辑像素**。这两条以前都
/// 少了换算：
///
/// - 左右边距只加了 8 px 常量、没乘 `u`，竖画幅或宽画幅时字幕横着贴死画面
///   边缘，而上下边距是对的 —— 一眼看不出是单位错了，像「样式没生效」。
/// - `safeArea` 直接和画面单位的 `marginV` 比大小，画面有黑边时两者差一个
///   `windowToVideo` 系数，字幕会被顶得过高（黑边越多顶得越狠）。
void main() {
  const area = Size(1000, 800);

  SubtitleCue cueWith(SubtitleLine line) => SubtitleCue(
        text: line.text,
        startUs: 0,
        endUs: 3000000,
        style: const SubtitleStyle(
          color: 0xFFFFFFFF,
          outlineColor: 0xFF000000,
          outline: 1,
          fontScale: 0.05,
          font: 'sans-serif',
        ),
        lines: [line],
      );

  Future<void> pump(
    WidgetTester tester,
    SubtitleCue cue, {
    double videoAspectRatio = 2.0,
    double safeArea = 0,
  }) async {
    tester.view.physicalSize = area;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SubtitleOverlay(
          cue: cue,
          scale: 1.0,
          safeArea: safeArea,
          videoAspectRatio: videoAspectRatio,
        ),
      ),
    ));
  }

  /// 取承载字幕那层 `Padding` 的内边距。
  EdgeInsets paddingOf(WidgetTester tester) {
    return tester
        .widgetList<Padding>(find.byType(Padding))
        .map((p) => p.padding.resolve(TextDirection.ltr))
        .firstWhere(
      (e) => e.left > 0 || e.right > 0 || e.top > 0 || e.bottom > 0,
      orElse: () => EdgeInsets.zero,
    );
  }

  testWidgets('左右边距按 PlayResY 换算，与上下边距同一把尺子', (tester) async {
    // 1000x800 的窗口放 2:1 的画面 → 画面 1000x500，垂直居中。
    // PlayResY 288 → 一个脚本单位是 500/288 px。
    const playResY = 288.0;
    const margin = 100.0;
    const unit = 500 / playResY;

    final cue = cueWith(const SubtitleLine(
      text: 'margin',
      align: 2,
      marginL: margin,
      marginR: margin,
      marginV: 0,
      playResY: playResY,
    ));
    await pump(tester, cue);
    final padding = paddingOf(tester);

    // +8 是防止贴边的常量留白，两边都加。
    expect(padding.left, closeTo(margin * unit + 8, 1.0),
        reason: 'MarginL 没乘以画面单位，字幕会按 1080 的尺度横着贴边');
    expect(padding.right, closeTo(margin * unit + 8, 1.0));
    // 换算之后左右边距应该落在画面内，而不是被窗口宽度直接吃掉。
    expect(padding.left, lessThan(500));
  });

  testWidgets('safeArea 从窗口像素换算到画面像素', (tester) async {
    // 画面 1000x500 落在 1000x800 的窗口里 → windowToVideo = 500/800 = 0.625。
    // safeArea 给 200 窗口像素，应当在画面坐标系里变成 125。
    const safeArea = 200.0;
    const playResY = 288.0;
    const unit = 500 / playResY;

    final cue = cueWith(const SubtitleLine(
      text: 'safe',
      align: 2,
      marginV: 10,
      playResY: playResY,
    ));
    await pump(tester, cue, safeArea: safeArea);
    final padding = paddingOf(tester);

    final safePx = safeArea * (500 / area.height);
    expect(padding.bottom, closeTo(safePx, 1.0),
        reason: 'safeArea 没换算，宽画面上的字幕会被顶得过高');
    // 反过来确认它没有被当成画面单位直接使用（那样会是 200）。
    expect(padding.bottom, lessThan(safeArea));
    expect(padding.bottom, greaterThan(10 * unit));
  });

  testWidgets('画面铺满窗口时两个单位一致，safeArea 不需要换算', (tester) async {
    // 16:9 画面在 1000x800 的窗口里留上下黑边，但取 1.25 就正好铺满。
    const safeArea = 120.0;
    final cue = cueWith(const SubtitleLine(
      text: 'full',
      align: 2,
      marginV: 0,
      playResY: 288,
    ));
    await pump(tester, cue, videoAspectRatio: 1.25, safeArea: safeArea);
    final padding = paddingOf(tester);
    // 铺满时 windowToVideo == 1，换算系数是恒等的。
    expect(padding.bottom, closeTo(safeArea, 1.0));
  });

  testWidgets('顶部字幕的 MarginV 与 safeArea 取较大者', (tester) async {
    const playResY = 288.0;
    const unit = 500 / playResY;
    final cue = cueWith(const SubtitleLine(
      text: 'top',
      align: 8,
      marginV: 60,
      playResY: playResY,
    ));
    await pump(tester, cue, safeArea: 20);
    final padding = paddingOf(tester);
    // marginV = 60 * unit ≈ 104 px，大于 safeArea 换算后的 12.5 px。
    expect(padding.top, closeTo(60 * unit, 1.0));
  });
}
