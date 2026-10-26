import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../data/models.dart';
import 'video_surface.dart';

/// 字幕渲染在 Flutter 这一层，不在内核里：文字在任何分辨率下都保持清晰，
/// 不额外占用一张纹理，也能跟随界面缩放。
///
/// 为什么在这里而不是交给 libass：三端的 FFmpeg 不一样 —— Windows 随包的
/// `avfilter-12.dll` 静态链了 libass 但不导出 `ass_*` 符号，Apple 侧的
/// `scripts/build_apple_deps.py` 又用 `--disable-filters` 只启用了一小撮滤镜，
/// 根本没有 `ass`。三端统一只能自己做。
///
/// 坐标系用的是**视频画面**而不是窗口：ASS 的 `Fontsize`、`MarginV`、
/// `Outline`、`Shadow`、`Spacing`、`\pos` 全部以脚本分辨率（`PlayResX` /
/// `PlayResY`）为准，libass 把字幕烧在画面上。窗口留黑边时画面高度小于窗口
/// 高度，用窗口高度算字号会让字幕凭空变大 —— 这是用户报「字号明显过大」的
/// 第一层原因。
///
/// 第二层原因是单位换算：ASS 的 `Fontsize` 是字面高度（ascender 到
/// descender），Flutter 的 `TextStyle.fontSize` 是 em 尺寸，两者差一个
/// 约 1.26 的系数。这个系数是用同一种字体（Microsoft YaHei）在
/// Fontsize 30 / 45 / 60 / 90 四档上与 libass 逐档标定出来的。
///
/// 第三层是 `textScaler`：`app/lib/main.dart` 把系统文字缩放钳到 1.3 倍，
/// `Text` 会在这个字号基础上再乘一次。字幕要贴着画面走，不该跟着系统字号
/// 变大，所以这里再除回去。
class SubtitleOverlay extends StatelessWidget {
  const SubtitleOverlay({
    super.key,
    required this.cue,
    this.scale = 1.0,
    this.safeArea = 24,
    this.videoAspectRatio = 16 / 9,
    this.scaleMode = scaleModeFit,
  });

  final SubtitleCue cue;

  /// 用户在设置里调节的字幕缩放（1.0 = 与画面一致）。
  final double scale;

  /// 控制条占掉的高度，底部字幕要避开它。
  final double safeArea;

  /// 视频原始画面宽高比，决定画面在窗口里实际占多大一块。
  final double videoAspectRatio;

  /// 与 `PlaybackSettings.scaleMode` 同一套取值，决定画面是留黑边还是被裁。
  final int scaleMode;

  /// ASS 的字面高度换算成 Flutter 的 em 尺寸时的系数（1/1.26）。
  static const double scriptToEm = 1 / 1.26;

  /// 视频画面在给定区域里实际占据的矩形（与 [VideoSurface] 的贴合规则一致）。
  static Rect videoRect(Size area, double aspectRatio, int mode) {
    final ratio =
        aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9;
    if (!area.width.isFinite || !area.height.isFinite) {
      return Offset.zero & area;
    }
    double w;
    double h;
    switch (mode) {
      case scaleModeFill:
        // 铺满裁切：画面盖满整个区域，超出的部分被裁掉。
        if (area.width / area.height > ratio) {
          w = area.width;
          h = area.width / ratio;
        } else {
          h = area.height;
          w = area.height * ratio;
        }
        break;
      case scaleModeStretch:
        w = area.width;
        h = area.height;
        break;
      default:
        // 适应屏幕：整幅画面放进来，可能有黑边。
        if (area.width / area.height > ratio) {
          h = area.height;
          w = area.height * ratio;
        } else {
          w = area.width;
          h = area.width / ratio;
        }
    }
    return Rect.fromLTWH(
      (area.width - w) / 2,
      (area.height - h) / 2,
      w,
      h,
    );
  }

  /// 一个脚本单位等于多少逻辑像素：由画面高度和 `PlayResY` 决定。
  /// 每条字幕的 `PlayResY` 可能不同（不同 Style 来自不同脚本），所以按行取。
  double _unit(double videoHeight, [SubtitleStyle? styleOverride]) {
    final res = (styleOverride ?? cue.style).playResY;
    return videoHeight / (res > 0 ? res : 1080);
  }

  /// 这一行的样式：内核按行下发，缺省时回落到整条 cue 的样式。
  SubtitleStyle _styleOf(SubtitleLine line) => line.style ?? cue.style;

  /// 字幕字号：`Fontsize / PlayResY` 是内核给出的比例，乘画面高度得到的是
  /// 字面高度，再换算成 em，并抵消掉 `Text` 层会施加的 textScaler。
  double _fontSize(
    BuildContext context,
    double videoHeight, {
    double scaleFactor = 1.0,
    SubtitleStyle? styleOverride,
  }) {
    final style = styleOverride ?? cue.style;
    final fraction = style.fontScale > 0 ? style.fontScale : 0.05;
    final textScale = MediaQuery.textScalerOf(context).scale(10) / 10;
    final raw = fraction * videoHeight * scriptToEm * scale * scaleFactor;
    return (raw / (textScale <= 0 ? 1 : textScale)).clamp(1.0, 400.0);
  }

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
    BuildContext context,
    double videoHeight, {
    double scaleFactor = 1.0,
    bool outline = false,
    String fontOverride = '',
    double? strokePx,
    int? colorOverride,
    double spacing = 0,
    SubtitleStyle? styleOverride,
  }) {
    final style = styleOverride ?? cue.style;
    final unit = _unit(videoHeight, style);
    final fontSize = _fontSize(context, videoHeight,
        scaleFactor: scaleFactor, styleOverride: style);
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
    // ASS 的 Spacing 是脚本单位，换算成像素就是 letterSpacing。
    final letterSpacing = spacing != 0 ? spacing * unit : null;

    if (outline) {
      final width = (strokePx ?? (style.outline * unit)).clamp(0.0, 64.0);
      return TextStyle(
        fontSize: fontSize,
        fontWeight: weight,
        fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
        decoration: decoration,
        height: 1.2,
        letterSpacing: letterSpacing,
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
      color: Color(colorOverride ?? style.color),
      height: 1.2,
      letterSpacing: letterSpacing,
      fontFamily: family,
      fontFamilyFallback: family == null ? null : _fallback,
    );
  }

  /// Keeps scripts renderable when the requested family is not installed.
  /// Which of these exist depends on the platform, and Flutter skips the ones
  /// it cannot find, so the list is deliberately broad. MiSans is bundled with
  /// the app (`app/assets/fonts/MiSansVF.ttf`) and is the UI default, so it is
  /// the first choice for files that do not name a font at all.
  static const List<String> _fallback = <String>[
    'MiSans',
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
    double videoHeight,
    SubtitleSpan r, {
    required bool outline,
    SubtitleStyle? styleOverride,
  }) {
    final style = styleOverride ?? cue.style;
    // A run's {\fs..} overwrites the size outright: the core normalises it to
    // a fraction of video height, so divide by the line style's fraction.
    final cueFraction = style.fontScale > 0 ? style.fontScale : 0.05;
    final unit = _unit(videoHeight, style);
    final base = _base(
      context,
      videoHeight,
      scaleFactor: r.scale > 0 ? r.scale / cueFraction : 1.0,
      outline: outline,
      fontOverride: r.font,
      // 行内 \bord 会覆盖整条字幕的描边粗细。
      strokePx: r.border >= 0 ? r.border * unit : null,
      spacing: r.spacing != 0 ? r.spacing : 0,
      styleOverride: style,
    );
    final decorations = <TextDecoration>[
      if (style.underline || r.underline) TextDecoration.underline,
      if (style.strikeout || r.strikeout) TextDecoration.lineThrough,
    ];
    final bold = style.bold || r.bold;
    final italic = style.italic || r.italic;
    final color = r.color != 0 ? Color(r.color) : Color(style.color);
    return TextStyle(
      fontSize: base.fontSize,
      height: base.height,
      letterSpacing: base.letterSpacing,
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

  /// 把一个 TextSpan 包成一层带描边/阴影/方框的 Widget。
  Widget _decorateText(Widget text, double unit, SubtitleStyle style) {
    if (style.borderStyle == 3 || style.borderStyle == 4) {
      return DecoratedBox(
        decoration: BoxDecoration(color: Color(style.backColor)),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 6 * unit,
            vertical: 2 * unit,
          ),
          child: text,
        ),
      );
    }
    return text;
  }

  TextAlign _textAlignOf(int align) {
    final horizontal = ((align - 1) % 3) + 1;
    switch (horizontal) {
      case 1:
        return TextAlign.left;
      case 3:
        return TextAlign.right;
      default:
        return TextAlign.center;
    }
  }

  /// 一组行的交叉轴对齐：左对齐贴左、右对齐贴右，其余居中。
  CrossAxisAlignment _crossAxisOf(int align) {
    switch (((align - 1) % 3) + 1) {
      case 1:
        return CrossAxisAlignment.start;
      case 3:
        return CrossAxisAlignment.end;
      default:
        return CrossAxisAlignment.center;
    }
  }

  /// 同一条 Dialogue 里的多行（`\N` 折行）排成一列，每一行仍按自己的样式画。
  Widget _paragraph(
    BuildContext context,
    double videoHeight,
    List<SubtitleLine> lines,
    int align,
  ) {
    if (lines.length == 1) {
      return _lineBlock(context, videoHeight, lines.first, align);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: _crossAxisOf(align),
      children: [
        for (final line in lines)
          _lineBlock(context, videoHeight, line, align),
      ],
    );
  }

  /// 一条 Dialogue：用它自己的样式画描边、阴影、底色框和变换。
  Widget _lineBlock(
    BuildContext context,
    double videoHeight,
    SubtitleLine line,
    int align,
  ) {
    final style = _styleOf(line);
    final unit = _unit(videoHeight, style);
    final borderPx = (style.borderStyle == 1 ? style.outline : 0) * unit;
    final shadowPx = style.shadow > 0 ? style.shadow * unit : 0.0;
    final base = _base(context, videoHeight, styleOverride: style);

    final children = <InlineSpan>[];
    if (!line.styled) {
      children.add(TextSpan(text: line.text, style: base));
    } else {
      for (final run in line.runs) {
        children.add(
          TextSpan(
            text: run.text,
            style: _runStyle(context, videoHeight, run,
                outline: false, styleOverride: style),
          ),
        );
      }
    }
    final span = TextSpan(style: base, children: children);

    Widget text;
    final layers = <Widget>[];
    if (shadowPx > 0) {
      layers.add(
        Transform.translate(
          offset: Offset(shadowPx, shadowPx),
          child: Text.rich(
            TextSpan(
              style: _base(context, videoHeight, styleOverride: style),
              children: _outlineChildren(context, videoHeight, [line],
                  colorOverride: style.backColor, styleOverride: style),
            ),
            textAlign: _textAlignOf(align),
          ),
        ),
      );
    }
    if (borderPx > 0) {
      layers.add(
        Text.rich(
          TextSpan(
            style: _base(context, videoHeight,
                outline: true, styleOverride: style),
            children: _outlineChildren(context, videoHeight, [line],
                stroke: true, styleOverride: style),
          ),
          textAlign: _textAlignOf(align),
        ),
      );
    }
    layers.add(Text.rich(span, textAlign: _textAlignOf(align)));

    text = layers.length == 1
        ? layers.single
        : Stack(alignment: Alignment.center, children: layers);
    text = _decorateText(text, unit, style);

    // \fscx / \fscy 与 \frz：整块文字一起变换（ASS 是逐字形缩放，这里按整块
    // 近似，差异只在多行混合缩放的极端情况下可见）。
    final sx = style.scaleX > 0 ? style.scaleX / 100 : 1.0;
    final sy = style.scaleY > 0 ? style.scaleY / 100 : 1.0;
    if (sx != 1.0 || sy != 1.0) {
      text = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(sx, sy, 1),
        child: text,
      );
    }
    if (style.angle != 0) {
      text = Transform.rotate(angle: style.angle * math.pi / 180, child: text);
    }
    return text;
  }

  /// Children for the outline (or shadow) pass: every glyph is stroked with the
  /// same colour, so run-level colours are dropped but weights and sizes stay.
  List<InlineSpan> _outlineChildren(
    BuildContext context,
    double videoHeight,
    List<SubtitleLine> lines, {
    bool stroke = false,
    int? colorOverride,
    SubtitleStyle? styleOverride,
  }) {
    final style = styleOverride ?? cue.style;
    final base = _base(
      context,
      videoHeight,
      outline: stroke,
      colorOverride: colorOverride,
      styleOverride: style,
    );
    final children = <InlineSpan>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
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
            text: run.text,
            style: _runStyle(context, videoHeight, run,
                outline: stroke, styleOverride: style),
          ),
        );
      }
    }
    return children;
  }

  /// 每一行带上自己的对齐/边距/`\pos`（内核按行输出）。按对齐编号分组：
  /// 同一角上的多行竖直排开（libass 里也是这么叠的，先出现的贴锚点，
  /// 后面的依次向外让位 —— 底部对齐时就是先出现的在下）。
  List<Widget> _placed(BuildContext context, double videoHeight, Rect video) {
    final style = cue.style;
    // 摆位相同的行才叠成一摞；边距/坐标不同的行各占各的。libass 里每条
    // Dialogue 都按自己的 MarginV 单独定位，共用一组边距会把它们摞到一起。
    final groups = <String, List<SubtitleLine>>{};
    final keys = <String, _Placement>{};
    if (cue.lines.isEmpty) {
      final line = SubtitleLine(text: cue.text);
      (groups['${style.align}|${style.posX}|${style.posY}|'
                  '${style.marginL}|${style.marginR}|${style.marginV}'] ??=
              <SubtitleLine>[])
          .add(line);
    } else {
      for (final line in cue.lines) {
        final ls = _styleOf(line);
        final p = _Placement(
          align: line.align ?? ls.align,
          posX: line.posX ?? ls.posX,
          posY: line.posY ?? ls.posY,
          marginL: line.marginL ?? ls.marginL,
          marginR: line.marginR ?? ls.marginR,
          marginV: line.marginV ?? ls.marginV,
          playResY: line.playResY ?? ls.playResY,
        );
        (groups[p.key] ??= <SubtitleLine>[]).add(line);
        keys[p.key] = p;
      }
    }

    final out = <Widget>[];
    for (final entry in groups.entries) {
      final lines = entry.value;
      final p = keys[entry.key] ??
          _Placement(
            align: style.align,
            posX: style.posX,
            posY: style.posY,
            marginL: style.marginL,
            marginR: style.marginR,
            marginV: style.marginV,
            playResY: style.playResY,
          );
      final align = p.align;
      final res = p.playResY > 0 ? p.playResY : 1080;
      final u = videoHeight / res;

      final block = _paragraph(context, videoHeight, lines, align);

      if (p.posX >= 0 && p.posY >= 0) {
        final anchor = _anchorFor(align);
        out.add(
          Positioned(
            left: video.width * p.posX,
            top: video.height * p.posY,
            child: FractionalTranslation(
              translation: Offset(-(anchor.x + 1) / 2, -(anchor.y + 1) / 2),
              child: block,
            ),
          ),
        );
        continue;
      }

      final marginL = (p.marginL + 8).clamp(0.0, 8000.0);
      final marginR = (p.marginR + 8).clamp(0.0, 8000.0);
      final marginV = p.marginV * u;
      final isTop = align >= 7;
      final isBottom = align <= 3;
      final vertical = isBottom
          ? math.max(marginV, safeArea)
          : (isTop ? math.max(marginV, safeArea) : marginV);
      final padded = Padding(
        padding: EdgeInsets.only(
          left: marginL,
          right: marginR,
          top: isTop ? vertical : marginV,
          bottom: isBottom ? vertical : marginV,
        ),
        child: block,
      );
      out.add(
        Positioned.fill(
          child: Align(alignment: _alignmentFor(align), child: padded),
        ),
      );
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    if (cue.isEmpty) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final area = Size(
            constraints.maxWidth.isFinite ? constraints.maxWidth : 0,
            constraints.maxHeight.isFinite ? constraints.maxHeight : 0,
          );
          final video = videoRect(area, videoAspectRatio, scaleMode);
          final videoHeight = video.height;
          if (videoHeight <= 0) {
            return const SizedBox.shrink();
          }
          return Stack(
            children: [
              Positioned(
                left: video.left,
                top: video.top,
                width: video.width,
                height: video.height,
                child: Stack(children: _placed(context, videoHeight, video)),
              ),
            ],
          );
        },
      ),
    );
  }

  /// ASS 的 1..9 对齐编号 → Flutter 的 [Alignment]。
  static Alignment _alignmentFor(int align) {
    final a = align.clamp(1, 9);
    final horizontal = (a - 1) % 3; // 0 左 1 中 2 右
    final vertical = (a - 1) ~/ 3; // 0 下 1 中 2 上
    final x = horizontal == 0 ? -1.0 : (horizontal == 2 ? 1.0 : 0.0);
    final y = vertical == 0 ? 1.0 : (vertical == 2 ? -1.0 : 0.0);
    return Alignment(x, y);
  }

  /// `\pos` 锚点：与对齐方式对应，用来把文字的一角/一边钉在给定坐标上。
  static Alignment _anchorFor(int align) {
    final a = align.clamp(1, 9);
    final horizontal = (a - 1) % 3;
    final vertical = (a - 1) ~/ 3;
    final x = horizontal == 0 ? 0.0 : (horizontal == 2 ? 1.0 : 0.5);
    final y = vertical == 0 ? 1.0 : (vertical == 2 ? 0.0 : 0.5);
    return Alignment(x * 2 - 1, y * 2 - 1);
  }
}

/// 一组摆位相同的行（同一条 Dialogue 折出来的多行）。两条同时在场、边距或
/// `\pos` 不同的 Dialogue 会被分到不同的组里，各自定位。
class _Placement {
  const _Placement({
    required this.align,
    required this.posX,
    required this.posY,
    required this.marginL,
    required this.marginR,
    required this.marginV,
    required this.playResY,
  });

  final int align;
  final double posX;
  final double posY;
  final double marginL;
  final double marginR;
  final double marginV;
  final double playResY;

  String get key => '$align|$posX|$posY|$marginL|$marginR|$marginV|$playResY';
}
