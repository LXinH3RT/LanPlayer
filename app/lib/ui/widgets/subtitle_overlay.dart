import 'package:flutter/material.dart';

import '../../data/models.dart';

/// Subtitle rendering happens in Flutter, not in the native core: text stays
/// crisp at any resolution, scales with the system font settings and costs no
/// extra texture.
///
/// ASS override tags (`{\b1}`, `{\i1}`, `{\c&H0000FF&}`, `{\fs72}`) are parsed
/// by the core into ordered runs, so a single line can mix bold, italic,
/// colours and size changes.  A line without runs falls back to the plain
/// cue text and the cue style, which is the common SRT/WebVTT case.
///
/// The outline is stroked, not blurred: two identical text layers are stacked,
/// the lower one painting only the stroke. A blurred shadow thickens thin
/// strokes (Latin) far more than thick ones (CJK), which is what made some
/// glyphs in a line look heavier than their neighbours.
class SubtitleOverlay extends StatelessWidget {
  const SubtitleOverlay({
    super.key,
    required this.cue,
    this.scale = 1.0,
    this.safeArea = 24,
  });

  final SubtitleCue cue;
  final double scale;
  final double safeArea;

  /// The font family a cue or a run asks for, or null when it asks for none.
  ///
  /// ASS names a concrete family in its `Style:` line (`新宋体`,
  /// `Microsoft YaHei`, `Arial`) and an inline `\fn` can change it mid-line.
  /// `sans-serif` is the core's placeholder for "no preference", so it means
  /// the platform default rather than a family that has to exist.
  static String? _family(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.toLowerCase() == 'sans-serif') {
      return null;
    }
    return trimmed;
  }

  TextStyle _base(
    BuildContext context, {
    double scaleFactor = 1.0,
    bool outline = false,
    String fontOverride = '',
  }) {
    final style = cue.style;
    final screenHeight = MediaQuery.sizeOf(context).height;
    // ASS styles express size as a fraction of video height.
    final fontSize = (style.fontScale * screenHeight).clamp(12.0, 96.0) *
        scale *
        scaleFactor;
    // Only real weights are requested (w400 / w700): a missing w500 face makes
    // the fallback pick a different family for some scripts, which reads as
    // inconsistent stroke weight inside one line.
    final weight = style.bold ? FontWeight.w700 : FontWeight.w400;
    final decoration = style.underline || style.strikeout
        ? TextDecoration.combine([
            if (style.underline) TextDecoration.underline,
            if (style.strikeout) TextDecoration.lineThrough,
          ])
        : TextDecoration.none;
    final family = _family(fontOverride) ?? _family(style.font);

    if (outline) {
      final width = (style.outline.clamp(0, 4)) * 1.5 * scale;
      return TextStyle(
        fontSize: fontSize,
        fontWeight: weight,
        fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
        decoration: decoration,
        height: 1.25,
        fontFamily: family,
        // A named family can be missing (the file was authored on another
        // machine), so the CJK-capable family is always kept as a fallback.
        fontFamilyFallback: family == null ? null : _fallback,
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * 2
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = Color(style.outlineColor),
      );
    }

    return TextStyle(
      fontSize: fontSize,
      fontWeight: weight,
      fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
      decoration: decoration,
      color: Color(style.color),
      height: 1.25,
      fontFamily: family,
      fontFamilyFallback: family == null ? null : _fallback,
    );
  }

  /// Keeps scripts renderable when the requested family is not installed.
  /// Which of these exist depends on the platform, and Flutter skips the ones
  /// it cannot find, so the list is deliberately broad.
  static const List<String> _fallback = <String>[
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Sans CJK SC',
    'Source Han Sans SC',
    'WenQuanYi Micro Hei',
    'Arial',
  ];

  /// Merges one run's inline overrides onto the cue style.
  TextStyle _runStyle(
    BuildContext context,
    SubtitleSpan r, {
    required bool outline,
  }) {
    // A run's {\fs..} overwrites the size outright: the core normalises it to
    // a fraction of video height, so divide by the cue style's fraction.
    final cueFraction = cue.style.fontScale > 0 ? cue.style.fontScale : 0.05;
    final base = _base(
      context,
      scaleFactor: r.scale > 0 ? r.scale / cueFraction : 1.0,
      outline: outline,
      fontOverride: r.font,
    );
    final decorations = <TextDecoration>[
      if (cue.style.underline || r.underline) TextDecoration.underline,
      if (cue.style.strikeout || r.strikeout) TextDecoration.lineThrough,
    ];
    final bold = cue.style.bold || r.bold;
    final italic = cue.style.italic || r.italic;
    final color = r.color != 0 ? Color(r.color) : Color(cue.style.color);
    return TextStyle(
      fontSize: base.fontSize,
      height: base.height,
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      fontFamily: base.fontFamily,
      fontFamilyFallback: base.fontFamilyFallback,
      decoration: decorations.isEmpty
          ? TextDecoration.none
          : TextDecoration.combine(decorations),
      // Outline layers paint the stroke in the cue outline colour, ignoring
      // per-run colours so the edge stays one consistent shade.
      color: outline ? null : color,
      foreground: outline ? base.foreground : null,
    );
  }

  /// Builds the whole cue as one rich span so multi-line subtitles keep a
  /// single paragraph rhythm; each source line contributes its own runs.
  TextSpan _span(BuildContext context, {required bool outline}) {
    final base = _base(context, outline: outline);
    if (cue.lines.isEmpty) {
      return TextSpan(text: cue.text, style: base);
    }
    final children = <InlineSpan>[];
    for (var i = 0; i < cue.lines.length; i++) {
      final line = cue.lines[i];
      if (i > 0) {
        children.add(TextSpan(text: '\n', style: base));
      }
      if (!line.styled) {
        children.add(TextSpan(text: line.text, style: base));
        continue;
      }
      for (final run in line.runs) {
        children.add(
          TextSpan(
              text: run.text, style: _runStyle(context, run, outline: outline)),
        );
      }
    }
    return TextSpan(style: base, children: children);
  }

  Widget _layer(BuildContext context, {required bool outline}) {
    return Text.rich(
      _span(context, outline: outline),
      textAlign: TextAlign.center,
      style: _base(context, outline: outline),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (cue.isEmpty) {
      return const SizedBox.shrink();
    }
    final style = cue.style;

    Widget text = _layer(context, outline: false);
    if (style.outline > 0) {
      // Same text, same metrics: only the paint differs, so glyph weight stays
      // identical between the stroke and the fill.
      text = Stack(
        alignment: Alignment.center,
        children: [
          _layer(context, outline: true),
          _layer(context, outline: false),
        ],
      );
    }

    final alignment =
        style.isTop ? Alignment.topCenter : Alignment.bottomCenter;

    return IgnorePointer(
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            bottom: style.isTop ? 0 : safeArea,
            top: style.isTop ? safeArea : 0,
          ),
          child: Align(
            alignment: alignment,
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (style.posX >= 0 && style.posY >= 0) {
                  // Explicit ASS \pos is approximated with a fractional offset.
                  return Stack(
                    children: [
                      Positioned(
                        left: constraints.maxWidth * style.posX,
                        top: constraints.maxHeight *
                            (style.isTop ? style.posY : 1 - style.posY),
                        child: text,
                      ),
                    ],
                  );
                }
                return text;
              },
            ),
          ),
        ),
      ),
    );
  }
}
