import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/ui/widgets/subtitle_overlay.dart';

/// Widget-level proof for subtitles.
///
/// Screen capture cannot be used to verify subtitle paint on Windows: as soon
/// as the external video texture is registered the embedder composites the
/// window through a path `PrintWindow` and `CopyFromScreen` both fail to read,
/// so every capture of the player page is black.  These tests assert the
/// actually-rendered `TextSpan` tree instead, which is the part of the chain
/// the Dart code owns (the native side is covered by `lp_smoke_test --dump`).
SubtitleCue _cue({
  String text = 'PLAIN',
  List<SubtitleLine> lines = const [],
  SubtitleStyle? override,
}) {
  return SubtitleCue(
    text: text,
    startUs: 0,
    endUs: 3000000,
    style: override ??
        const SubtitleStyle(
          color: 0xFFFFFFFF,
          outlineColor: 0xFF000000,
          outline: 1,
          fontScale: 0.05,
          font: 'sans-serif',
        ),
    lines: lines,
  );
}

/// Collects every `TextSpan` reachable from [span] that carries visible text
/// (the renderer inserts `'\n'` separators between lines, which are structure,
/// not content).
List<TextSpan> _leaves(InlineSpan span) {
  final out = <TextSpan>[];
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      if ((s.text ?? '').trim().isNotEmpty) out.add(s);
      for (final child in s.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  walk(span);
  return out;
}

/// Pins the surface to 1000x800 so the expectations below are exact.
///
/// The test video is forced to 1000x800 (`videoAspectRatio: 1.25`), so the
/// picture fills the whole surface and the overlay's "video height" is the
/// full 800 px.  Font size then follows ASS semantics: `font_scale` is a
/// fraction of the *picture* height, and that is already an em size, so the
/// glyph size is `font_scale * picture height * scriptToEm`.
///
/// Every line is painted as its own block (each Dialogue keeps its own colour,
/// box and margins), so the helper collects the *fill* layer of every block and
/// returns them as one synthetic span.  Stroke layers are skipped: their runs
/// carry a `foreground` paint instead of a colour.
Future<InlineSpan> _pump(
  WidgetTester tester,
  SubtitleCue cue, {
  double scale = 1.0,
}) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SubtitleOverlay(
          cue: cue,
          scale: scale,
          safeArea: 24,
          videoAspectRatio: 1.25,
        ),
      ),
    ),
  );
  final collected = <InlineSpan>[];
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    final leaves = _leaves(rich.text);
    if (leaves.isEmpty) continue;
    final stroke = leaves.every((s) => s.style?.foreground != null);
    if (stroke) continue;
    collected.addAll(leaves);
  }
  return TextSpan(children: collected);
}

/// `0.05` of an 800 px picture.  ASS `Fontsize` is an em size, so this is the
/// em the overlay should ask Flutter for (modulo the `scriptToEm` factor).
const double _plainFontSize = 0.05 * 800 * SubtitleOverlay.scriptToEm;

/// `Color.value` is deprecated; the channels are the stable way to spell the
/// same comparison, and this keeps the expectations readable.
int _argb(Color c) =>
    ((c.a * 255).round() << 24) |
    ((c.r * 255).round() << 16) |
    ((c.g * 255).round() << 8) |
    (c.b * 255).round();

void main() {
  testWidgets('plain cue renders its text with the style colour',
      (tester) async {
    final span = await _pump(tester, _cue(text: 'PLAIN WHITE'));
    final leaves = _leaves(span);
    expect(leaves, isNotEmpty, reason: 'subtitle must produce a TextSpan');
    expect(leaves.map((s) => s.text).join(), contains('PLAIN WHITE'));
    final style = leaves.first.style!;
    expect(style.color, const Color(0xFFFFFFFF));
    expect(style.fontSize, closeTo(_plainFontSize, 0.01));
  });

  testWidgets('runs become separate spans with their own colours',
      (tester) async {
    final cue = _cue(
      text: 'AAAABBBBCCCC',
      lines: const [
        SubtitleLine(
          text: 'AAAABBBBCCCC',
          runs: [
            SubtitleSpan(text: 'AAAA'),
            SubtitleSpan(text: 'BBBB', color: 0xFFFF0000),
            SubtitleSpan(text: 'CCCC', color: 0xFF00FF00),
          ],
        ),
      ],
    );
    final span = await _pump(tester, cue);
    final leaves = _leaves(span);
    expect(leaves.length, 3, reason: 'one span per run');
    expect(leaves[0].text, 'AAAA');
    expect(leaves[0].style!.color, const Color(0xFFFFFFFF),
        reason: 'a run without a colour inherits the cue style');
    expect(leaves[1].text, 'BBBB');
    expect(leaves[1].style!.color, const Color(0xFFFF0000));
    expect(leaves[2].text, 'CCCC');
    expect(leaves[2].style!.color, const Color(0xFF00FF00));
  });

  testWidgets('bold and italic runs set their text style', (tester) async {
    final cue = _cue(
      text: 'normalBOLDitalic',
      lines: const [
        SubtitleLine(
          text: 'normalBOLDitalic',
          runs: [
            SubtitleSpan(text: 'normal'),
            SubtitleSpan(text: 'BOLD', bold: true),
            SubtitleSpan(text: 'italic', italic: true, underline: true),
          ],
        ),
      ],
    );
    final span = await _pump(tester, cue);
    final leaves = _leaves(span);
    expect(leaves[0].style!.fontWeight, isNot(FontWeight.bold));
    expect(leaves[1].style!.fontWeight, FontWeight.bold);
    expect(leaves[2].style!.fontStyle, FontStyle.italic);
    expect(leaves[2].style!.decoration, TextDecoration.underline);
  });

  testWidgets('a run can override the font size', (tester) async {
    final cue = _cue(
      text: 'sameticker',
      lines: const [
        SubtitleLine(
          text: 'sameticker',
          runs: [
            SubtitleSpan(text: 'same'),
            SubtitleSpan(text: 'ticker', scale: 0.1),
          ],
        ),
      ],
    );
    final span = await _pump(tester, cue);
    final leaves = _leaves(span);
    expect(leaves[0].style!.fontSize, closeTo(_plainFontSize, 0.01));
    // 0.10 of the picture height, not 0.05.
    expect(leaves[1].style!.fontSize, closeTo(_plainFontSize * 2, 0.01));
  });

  testWidgets('multi-line cue renders one span per line', (tester) async {
    final cue = _cue(
      text: 'first\nsecond',
      lines: const [
        SubtitleLine(text: 'first'),
        SubtitleLine(text: 'second'),
      ],
    );
    final span = await _pump(tester, cue);
    final leaves = _leaves(span);
    expect(leaves.length, 2);
    expect(leaves[0].text, 'first');
    expect(leaves[1].text, 'second');
  });

  // ASS 允许多条 Dialogue 同时出现在画面上，各带自己的对齐和边距。内核把
  // 每行的位置一起发下来，渲染层按对齐分组摆：同一角上的多行竖直排开，
  // 不同角的各占一处 —— 否则三条字幕会叠在同一行上（用户报的「样式渲染
  // 依然有问题」就是这个）。
  testWidgets('lines with different alignments are placed separately',
      (tester) async {
    final cue = _cue(
      text: 'bottom\nbox\nright',
      lines: const [
        SubtitleLine(text: 'bottom', align: 2, marginV: 50),
        SubtitleLine(text: 'box', align: 2, marginV: 260),
        SubtitleLine(text: 'right', align: 9, marginR: 40),
      ],
    );
    await _pump(tester, cue);
    // 底部的两行边距不同，各自定位；右边那行在另一个角上。三块互不重叠，
    // 所以每个文本块里只应当出现自己的字。
    final blocks = <Set<String>>[];
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      final leaves = _leaves(rich.text);
      if (leaves.isEmpty) continue;
      if (leaves.every((s) => s.style?.foreground != null)) continue;
      blocks.add(leaves.map((e) => e.text ?? '').toSet());
    }
    expect(blocks.length, 3, reason: '每行都该有自己的文本块');
    for (final block in blocks) {
      expect(block.length, 1, reason: '一个块里不应混进别的行');
    }
    expect(blocks.any((s) => s.contains('right')), isTrue);
  });

  // 两条 Dialogue 同时在场、各自带不同的 Style:，必须按各自的颜色/粗细/方框
  // 画，而不是全用最后一条的样式 —— 用户报的「样式渲染依然存在问题」是
  // 三行不同样式叠成一模一样的一团。
  testWidgets('each line keeps its own style', (tester) async {
    final cue = _cue(
      text: 'white\nred',
      lines: const [
        SubtitleLine(
          text: 'white',
          align: 2,
          marginV: 50,
          style: SubtitleStyle(color: 0xFFFFFFFF, outline: 1),
        ),
        SubtitleLine(
          text: 'red',
          align: 2,
          marginV: 260,
          style: SubtitleStyle(
            color: 0xFFFF0000,
            outline: 3,
            borderStyle: 3,
            backColor: 0xFF102030,
            bold: true,
          ),
        ),
      ],
    );
    await _pump(tester, cue);
    final fill = <TextSpan>[];
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      final leaves = _leaves(rich.text);
      if (leaves.isEmpty) continue;
      if (leaves.every((s) => s.style?.foreground != null)) continue;
      fill.addAll(leaves);
    }
    final white = fill.firstWhere((s) => s.text == 'white');
    final red = fill.firstWhere((s) => s.text == 'red');
    expect(white.style!.color, const Color(0xFFFFFFFF));
    expect(white.style!.fontWeight, isNot(FontWeight.bold));
    expect(red.style!.color, const Color(0xFFFF0000));
    expect(red.style!.fontWeight, FontWeight.bold,
        reason: '第二条字幕自己声明了 Bold，不能被第一条覆盖');
    // BorderStyle 3 是实心方框，底色来自它自己的 back_color。
    final boxes = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((d) => d.decoration)
        .whereType<BoxDecoration>()
        .map((d) => d.color)
        .toList();
    expect(boxes, contains(const Color(0xFF102030)));
  });

  testWidgets('a line keeps its own margin in pixels', (tester) async {
    // 1000x800 的画面，PlayResY 1080 → 一个脚本单位是 800/1080 px。
    const unit = 800 / 1080;
    final cue = _cue(
      text: 'margin',
      lines: const [SubtitleLine(text: 'margin', align: 2, marginV: 60)],
    );
    await _pump(tester, cue);
    final padding = tester
        .widgetList<Padding>(find.byType(Padding))
        .map((p) => p.padding.resolve(TextDirection.ltr))
        .whereType<EdgeInsets>()
        .firstWhere((e) => e.bottom > 0 && e.bottom < 800,
            orElse: () => EdgeInsets.zero);
    expect(padding.bottom, greaterThanOrEqualTo(60 * unit));
  });

  testWidgets('an empty cue paints nothing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SubtitleOverlay(
            cue: SubtitleCue.empty,
            scale: 1.0,
            safeArea: 24,
          ),
        ),
      ),
    );
    expect(find.byType(RichText), findsNothing);
  });

  // The JSON below is copied verbatim from
  // `lp_smoke_test.exe <clip.mp4> 3` with `LP_DUMP_SUBS=1` on a fixture whose
  // dialogue is `AAAA{\c&H0000FF&}BBBB{\c&H00FF00&}CCCC`, so this test pins the
  // native event format and the Dart reader together.
  testWidgets('the core event JSON renders as coloured runs', (tester) async {
    final json = <String, dynamic>{
      'text': 'AAAABBBBCCCC',
      'start': 0,
      'end': 9000000,
      'style': <String, dynamic>{
        'bold': false,
        'italic': false,
        'underline': false,
        'strikeout': false,
        'color': 4294967295,
        'outline_color': 4278190080,
        'outline': 1,
        'align': 2,
        'font_scale': 0.05,
        'pos_x': -1.0,
        'pos_y': -1.0,
        'font': 'sans-serif',
      },
      'runs': [
        {
          'text': 'AAAABBBBCCCC',
          'runs': [
            {'text': 'AAAA'},
            {'text': 'BBBB', 'color': 4294901760},
            {'text': 'CCCC', 'color': 4278255360},
          ],
        },
      ],
    };
    final cue = SubtitleCue.fromJson(json);
    expect(cue.lines.length, 1);
    expect(cue.lines.single.styled, isTrue);
    final span = await _pump(tester, cue);
    final leaves = _leaves(span);
    expect(leaves.map((s) => s.text).join(), 'AAAABBBBCCCC');
    expect(leaves[1].style!.color, const Color(0xFFFF0000));
    expect(leaves[2].style!.color, const Color(0xFF00FF00));
  });

  // A style line names a concrete family (`新宋体`, `Microsoft YaHei`) and the
  // renderer has to pass it through, otherwise every cue is painted in the
  // platform default and the file's typography is lost.
  testWidgets('the cue style font reaches the span as a font family',
      (tester) async {
    final cue = _cue(
      text: 'FONTED',
      override: const SubtitleStyle(
        color: 0xFFFFFFFF,
        outlineColor: 0xFF000000,
        outline: 1,
        fontScale: 0.05,
        font: '新宋体',
      ),
    );
    final span = await _pump(tester, cue);
    final style = _leaves(span).first.style!;
    expect(style.fontFamily, '新宋体');
    // A family can be missing on the machine that plays the file, so the
    // CJK-capable list is always kept behind it.
    expect(style.fontFamilyFallback, isNotNull);
    expect(style.fontFamilyFallback, isNotEmpty);
  });

  testWidgets('a run can override the font family of the cue', (tester) async {
    final cue = _cue(
      text: 'sameshift',
      override: const SubtitleStyle(
        color: 0xFFFFFFFF,
        outlineColor: 0xFF000000,
        outline: 1,
        fontScale: 0.05,
        font: '新宋体',
      ),
      lines: const [
        SubtitleLine(
          text: 'sameshift',
          runs: [
            SubtitleSpan(text: 'same'),
            SubtitleSpan(text: 'shift', font: 'Microsoft YaHei'),
          ],
        ),
      ],
    );
    final span = await _pump(tester, cue);
    final leaves = _leaves(span);
    expect(leaves[0].style!.fontFamily, '新宋体',
        reason: 'a run without a font inherits the cue style');
    expect(leaves[1].style!.fontFamily, 'Microsoft YaHei',
        reason: 'an inline \\fn must reach the span');
  });

  // `sans-serif` is the core's placeholder for "no preference", not a family
  // that has to exist on the machine - requesting it as a family would defeat
  // the platform default and could fall back to a face without CJK glyphs.
  testWidgets('the sans-serif placeholder means the platform default',
      (tester) async {
    final cue = _cue(text: 'PLAIN');
    expect(cue.style.font, 'sans-serif');
    final span = await _pump(tester, cue);
    final style = _leaves(span).first.style!;
    expect(style.fontFamily, isNull);
    expect(style.fontFamilyFallback, isNull);
  });

  testWidgets('the core JSON carries the run font through to the span',
      (tester) async {
    // Copied from `lp_smoke_test.exe` on the ASS fixture whose first style is
    // `CHS,新宋体,52` and whose line starts with `{\fnMicrosoft YaHei}`.
    final json = <String, dynamic>{
      'text': '神奇动物在哪里',
      'start': 12870000,
      'end': 25810000,
      'style': <String, dynamic>{
        'bold': true,
        'italic': false,
        'underline': false,
        'strikeout': false,
        'color': 4294967295,
        'outline_color': 2164260863,
        'outline': 1,
        'align': 2,
        'font_scale': 0.065,
        'pos_x': -1.0,
        'pos_y': -1.0,
        'font': '新宋体',
      },
      'runs': [
        {
          'text': '神奇动物在哪里',
          'runs': [
            {
              'text': '神奇动物在哪里',
              'bold': true,
              'color': 4279834903,
              'scale': 0.125,
              'font': '新宋体',
            },
          ],
        },
      ],
    };
    final cue = SubtitleCue.fromJson(json);
    expect(cue.style.font, '新宋体');
    expect(cue.lines.single.runs.single.font, '新宋体');
    final span = await _pump(tester, cue);
    expect(_leaves(span).first.style!.fontFamily, '新宋体');
  });

  // 行内 \3c 只换描边色，字还是白的。内核已经把它下发到 run 的
  // `outline_color` 上；Dart 这边如果 `SubtitleLine.styled` 漏掉这个字段，
  // 整行会退回 cue 的样式，描边又变回 Style 行里的黑色 —— 真机上就是这样
  // 复现的（字幕白字黑边，`\3c&H006C3300&` 完全没生效）。
  testWidgets('an inline \\3c repaints the stroke, not the text',
      (tester) async {
    final json = <String, dynamic>{
      'text': 'OUTLINED',
      'start': 0,
      'end': 9000000,
      'style': <String, dynamic>{
        'color': 4294967295,
        'outline_color': 4278190080,
        'outline': 2,
        'align': 2,
        'font_scale': 0.05,
        'pos_x': -1.0,
        'pos_y': -1.0,
        'font': 'sans-serif',
      },
      'runs': [
        {
          'text': 'OUTLINED',
          'runs': [
            {
              'text': 'OUTLINED',
              // 内核把 ASS 的 &H006C3300 拆成 0xAARRGGBB 下发。
              'outline_color': 4278203244,
            },
          ],
        },
      ],
    };
    final cue = SubtitleCue.fromJson(json);
    expect(cue.lines.single.styled, isTrue,
        reason: '只改描边色的行也算有内联样式，否则描边退回 cue 的颜色');
    expect(cue.lines.single.runs.single.outlineColor, 4278203244);

    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubtitleOverlay(cue: cue, scale: 1.0, safeArea: 24),
        ),
      ),
    );
    final stroke = <TextSpan>[];
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      for (final span in _leaves(rich.text)) {
        final paint = span.style?.foreground;
        if (paint is Paint) stroke.add(span);
      }
    }
    expect(stroke, isNotEmpty, reason: '这一行有描边，应当有一层描边文字');
    final color = stroke.first.style!.foreground!.color;
    expect(_argb(color), 0xFF00336C,
        reason: '描边必须是 \\3c 指定的深蓝，而不是 Style 行里的黑色');
    final filled = _leaves(
      TextSpan(
        children: [
          for (final rich in tester.widgetList<RichText>(find.byType(RichText)))
            ..._leaves(rich.text).where((s) => s.style?.color != null),
        ],
      ),
    );
    expect(_argb(filled.first.style!.color!), 0xFFFFFFFF,
        reason: '\\3c 不该动文字主色，白字要保持白色');
  });

  // The tests above assert the *span tree*; this one asserts actual painted
  // pixels.  flutter_test rasterises the scene itself, so it needs no window
  // and cannot be confused by the DPI virtualisation that makes screen capture
  // of the real player page unreliable on Windows.
  //
  // It counts pixels instead of comparing against a golden file on purpose:
  // goldens embed the host's font rasteriser and hinting, so a macOS runner
  // disagreed with the Windows-generated reference by 2.63 % of the pixels
  // while the colours themselves were identical.  Counting exact solid-colour
  // pixels is portable - antialiased edges differ, the glyph interiors do not.
  testWidgets('the painted pixels contain the run colours', (tester) async {
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final cue = _cue(
      text: 'AAAABBBBCCCC',
      override: const SubtitleStyle(
        color: 0xFFFFFFFF,
        outlineColor: 0xFF000000,
        outline: 0,
        fontScale: 0.25,
        font: 'sans-serif',
      ),
      lines: const [
        SubtitleLine(
          text: 'AAAABBBBCCCC',
          runs: [
            SubtitleSpan(text: 'AAAA'),
            SubtitleSpan(text: 'BBBB', color: 0xFFFF0000),
            SubtitleSpan(text: 'CCCC', color: 0xFF00FF00),
          ],
        ),
      ],
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: const Color(0xFF000000),
            child: SubtitleOverlay(cue: cue, scale: 1.0, safeArea: 0),
          ),
        ),
      ),
    );

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    // `toImage`/`toByteData` talk to the raster thread, which a widget test does
    // not pump on its own - without `runAsync` they wait forever.
    final image = await tester.runAsync(() => boundary.toImage());
    final data = await tester
        .runAsync(() => image!.toByteData(format: ui.ImageByteFormat.rawRgba));
    expect(data, isNotNull);
    final rgba = data!.buffer.asUint8List();

    var red = 0, green = 0, white = 0;
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      if (r > 200 && g < 60 && b < 60) red++;
      if (g > 200 && r < 60 && b < 60) green++;
      if (r > 200 && g > 200 && b > 200) white++;
    }
    expect(red, greaterThan(300), reason: 'the red run must actually paint');
    expect(green, greaterThan(300),
        reason: 'the green run must actually paint');
    expect(white, greaterThan(300), reason: 'the default white run must paint');
  });
}
