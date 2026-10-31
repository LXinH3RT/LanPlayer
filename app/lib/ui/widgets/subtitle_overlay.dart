import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../data/models.dart';
import '../../data/subtitle_anim.dart';
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
/// 第二层原因是单位换算：ASS 的 `Fontsize` 就是 em 尺寸，不需要再折算出
/// 一个「字面高度」。用 libass 对同一句、同一 PlayResY、同一画面高度逐档
/// 量墨迹高（Fontsize 20/288、52/480、52/1080、30/1080、90/1080），
/// libass 的墨迹高稳定在 0.933–0.942 em；本层按 em 直接排，SimHei 的墨迹
/// 高约 0.95 em，两者相差不到 2%。
///
/// 第三层是 `textScaler`：`app/lib/main.dart` 把系统文字缩放钳到 1.3 倍，
/// `Text` 会在这个字号基础上再乘一次。字幕要贴着画面走，不该跟着系统字号
/// 变大，所以这里再除回去。
class SubtitleOverlay extends StatefulWidget {
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

  /// ASS 的 `Fontsize` 与 Flutter 的 `TextStyle.fontSize` 同为 em 尺寸。
  ///
  /// 曾经这里取过 `1 / 1.26`，把 `Fontsize` 当成「字面高度」再折算一次，结果
  /// 整块字幕比 libass 小 20%。与 libass 逐档标定后确认：`Fontsize` 本身就是
  /// em，量出来的墨迹高只比 em 略小（libass 0.933–0.942，Flutter/SimHei 约
  /// 0.95），所以系数取 1。
  static const double scriptToEm = 1.0;

  @override
  State<SubtitleOverlay> createState() => _SubtitleOverlayState();
}

class _SubtitleOverlayState extends State<SubtitleOverlay> {
  SubtitleCue get cue => widget.cue;
  double get scale => widget.scale;
  int get scaleMode => widget.scaleMode;
  double get videoAspectRatio => widget.videoAspectRatio;
  double get safeArea => widget.safeArea;

  /// 这条 Dialogue 里已经播过去的毫秒数。内核每 20ms 重发一次带 `now` 的
  /// 事件（只在有动画/卡拉 OK 时），所以这里直接用内核给的时刻。
  double get _nowMs => cue.nowUs / 1000.0;

  /// 同一次 build 里每个 run 只解算一次动画。
  ///
  /// 一行要画三层（阴影、描边、正文），每层都过一遍 [_runStyle]；再加上
  /// 裁剪矩形和矢量绘图也要 `resolve`。带 `\t` 的字幕每 20 ms 就重画一次，
  /// 同一个 run 反复算 4~5 遍纯属浪费。解算结果只依赖 `nowMs` 与 run 本身，
  /// 一次 build 内复用是安全的；build 开头清空即可。
  final Map<SubtitleSpan, ResolvedSpan> _resolved =
      <SubtitleSpan, ResolvedSpan>{};

  ResolvedSpan _resolve(SubtitleSpan run) => _resolved.putIfAbsent(
      run, () => SubtitleAnimator.resolve(run, _nowMs));

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

  /// 字幕字号：`Fontsize / PlayResY` 是内核给出的比例，乘画面高度就是 em
  /// 尺寸（与 libass 同语义），再抵消掉 `Text` 层会施加的 textScaler。
  double _fontSize(
    BuildContext context,
    double videoHeight, {
    double scaleFactor = 1.0,
    SubtitleStyle? styleOverride,
  }) {
    final style = styleOverride ?? cue.style;
    final fraction = style.fontScale > 0 ? style.fontScale : 0.05;
    final textScale = MediaQuery.textScalerOf(context).scale(10) / 10;
    final raw = fraction *
        videoHeight *
        SubtitleOverlay.scriptToEm *
        scale *
        scaleFactor;
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
    int outlineColorOverride = 0,
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
          ..color = Color(outlineColorOverride != 0
              ? outlineColorOverride
              : style.outlineColor),
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
    ResolvedSpan? resolved,
  }) {
    final style = styleOverride ?? cue.style;
    final res = resolved ?? _resolve(r);
    // A run's {\fs..} overwrites the size outright: the core normalises it to
    // a fraction of video height, so divide by the line style's fraction.
    final cueFraction = style.fontScale > 0 ? style.fontScale : 0.05;
    final unit = _unit(videoHeight, style);
    final base = _base(
      context,
      videoHeight,
      scaleFactor: res.scale > 0 ? res.scale / cueFraction : 1.0,
      outline: outline,
      fontOverride: r.font,
      // 行内 \bord 会覆盖整条字幕的描边粗细。
      strokePx: res.border >= 0 ? res.border * unit : null,
      // 行内 \3c 只改描边色，不影响文字主色。
      outlineColorOverride: res.outlineColor,
      spacing: res.spacing != 0 ? res.spacing : 0,
      styleOverride: style,
    );
    final decorations = <TextDecoration>[
      if (style.underline || r.underline) TextDecoration.underline,
      if (style.strikeout || r.strikeout) TextDecoration.lineThrough,
    ];
    final bold = style.bold || r.bold;
    final italic = style.italic || r.italic;
    var color = res.color != 0 ? Color(res.color) : Color(style.color);
    if (r.karaokeKind != 0) {
      color = _karaokeColor(color, style, res.karaoke, r.karaokeKind);
    }
    if (res.alpha < 1.0) {
      color = color.withValues(alpha: color.a * res.alpha);
    }
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
      // per-run text colours so the edge stays one consistent shade.  An inline
      // \3c still overrides that shade through `outlineColorOverride`.
      color: outline ? null : color,
      foreground: outline ? base.foreground : null,
    );
  }

  /// 这条行里第一个带 `\clip` 的 run 的裁剪矩形（脚本坐标），没有就是 null。
  ///
  /// `\t(...\clip(...))` 的动画会改这个矩形，所以每帧都要重新解算。
  /// `inverse` 对应 `\iclip`：保留矩形**外面**的内容。
  ({List<double> rect, bool inverse})? _clipOf(SubtitleLine line) {
    for (final run in line.runs) {
      if (run.drawingScale > 0) continue;
      final r = _resolve(run);
      if (!r.clipOn || r.clip.length != 4) continue;
      return (rect: r.clip, inverse: r.clipInverse);
    }
    return null;
  }

  /// 整条 cue 里所有矢量绘图 run。
  /// 每个绘图 run 所属那一行的样式与位置。
  ///
  /// ASS 里 `\p1` 画出来的东西仍然属于某条 Dialogue：`\pos` / `n` /
  /// 边距都照常作用于它，坐标是「以这一行的锚点为零点」的。把绘图当全域
  /// 绝对坐标会把它钉在左上角，`\pos` 全然失效。
  List<({SubtitleSpan run, SubtitleStyle style, SubtitleLine line})>
      _drawingsWithPlacement() {
    final out =
        <({SubtitleSpan run, SubtitleStyle style, SubtitleLine line})>[];
    for (final line in cue.lines) {
      final style = _styleOf(line);
      for (final run in line.runs) {
        if (run.drawingScale > 0 && run.path.length >= 2) {
          out.add((run: run, style: style, line: line));
        }
      }
    }
    return out;
  }

  /// 这组行里第一个带 `\clip` 的 run 的裁剪矩形（脚本坐标），没有就是 null。
  ({List<double> rect, bool inverse})? _clipOfLineGroup(
      List<SubtitleLine> lines) {
    for (final line in lines) {
      final c = _clipOf(line);
      if (c != null) return c;
    }
    return null;
  }

  /// 把 [child] 裁到脚本坐标 [clip] 对应的那块区域里。
  ///
  /// `\clip` 是画面绝对坐标，而 [child] 是摆好位置之后的块，所以这里用
  /// [ClipPath] 裁「整块画面上的一块」——把裁剪矩形换算成相对块的偏移。
  /// [inverse] 为真时（`\iclip`）保留矩形外面的部分，这是卡拉 OK 里「让字只在
  /// 一块区域外可见」的唯一写法。
  Widget _clipWidget(
    Widget child,
    List<double> clip,
    bool inverse,
    SubtitleStyle style,
    double videoHeight,
    Rect video,
  ) {
    final prx = style.playResX > 0 ? style.playResX : 1920.0;
    final pry = style.playResY > 0 ? style.playResY : 1080.0;
    // 横向必须用画面矩形**实际**的宽度，不能拿 `PlayResX / PlayResY` 乘高度
    // 推出来：脚本分辨率与视频宽高比不一定相等（1280x720 的脚本套 2.39:1 的
    // 电影就会差出十几个百分点），推出来的宽度一旦偏大，裁剪框整体左移，
    // 该露出来的字就被切掉了。
    final videoWidth = video.width;
    // 矩形要落在**覆盖层**的坐标系里：[_RenderClipRelative] 拿到的是块在这个
    // 坐标系里的偏移，而块已经被摆到画面矩形里了（偏移里含 `video.left` /
    // `video.top`）。只按画面内坐标算，一旦视频上下留了黑边，裁剪窗就被整体
    // 上移几百像素，整行字幕凭空消失 —— 竖屏 iPad 上就是这个现象。
    final rect = Rect.fromLTRB(
      video.left + clip[0] * videoWidth / prx,
      video.top + clip[1] * videoHeight / pry,
      video.left + clip[2] * videoWidth / prx,
      video.top + clip[3] * videoHeight / pry,
    );
    if (rect.width <= 0 || rect.height <= 0) {
      // 正裁剪的退化矩形什么都裁掉了，整块不画；逆裁剪的退化矩形等于「不裁」，
      // 照常画。
      return inverse ? child : const SizedBox.shrink();
    }
    // clip 给的是画面坐标，块本身尺寸未知，所以交给 _ClipRelative 在布局后
    // 用 RenderBox 的全局位置换算。
    return _ClipRelative(rect: rect, inverse: inverse, child: child);
  }

  /// 卡拉 OK 的逐字填色。
  ///
  /// libass 的规则（`.tools/tmp/libass/k_color.py` 实测过）：没唱到的字用
  /// `SecondaryColour`，唱过之后渐变到 `PrimaryColour`；`\ko` 则是反过来
  /// 让唱过的字淡出。头一段是 SecondaryColour，不是「半透明的原色」 ——
  /// 上面这条差别在真实素材里一眼就能看出来。
  Color _karaokeColor(Color base, SubtitleStyle style, double fill, int kind) {
    final sung = Color(style.color);
    final unsung = Color(style.secondaryColor);
    if (kind == 3) {
      // \ko: once the syllable has been sung it fades out instead of filling.
      return base.withValues(alpha: base.a * (1.0 - 0.85 * fill));
    }
    final target = unsung == sung ? sung : unsung;
    return Color.lerp(target, sung, fill) ?? sung;
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
        for (final line in lines) _lineBlock(context, videoHeight, line, align),
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
        // \p 画出来的图形没有文字，走 CustomPaint；它和文字共享同一条行的
        // 对齐与位置，所以两边都放进同一个 Stack。
        // \p 的图形是画面绝对坐标，交给 build 里的整幅画布处理。
        if (run.drawingScale > 0 && run.path.length >= 2) continue;
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
    // \clip 的坐标是画面绝对坐标，必须等这一块摆到画面上之后再裁（见 _placed），
    // 在 _lineBlock 里裁会被父容器的坐标系带偏。

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

      final clip = _clipOfLineGroup(lines);
      Widget block = _paragraph(context, videoHeight, lines, align);
      if (clip != null) {
        block = _clipWidget(
            block, clip.rect, clip.inverse, style, videoHeight, video);
      }

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
    // 每条 cue 的 nowMs 是新的，上一帧的解算结果不再有效。
    _resolved.clear();
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
          // 一帧只算一次：这个函数会把 cue 里所有 run 遍历一遍并 resolve
          // 每个动画，带 `\t` 的字幕每 20 ms 重建一次，算两遍等于白烧一半。
          final drawings = _drawingsWithPlacement();
          return Stack(
            children: [
              Positioned(
                left: video.left,
                top: video.top,
                width: video.width,
                height: video.height,
                child: Stack(children: [
                  ..._placed(context, videoHeight, video),
                  if (drawings.isNotEmpty)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _DrawingsPainter(
                          items: drawings,
                          nowMs: _nowMs,
                          cue: cue,
                        ),
                      ),
                    ),
                ]),
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

/// 把子节点裁到「画面坐标系里的一个矩形」。
///
/// 子节点的位置由 `_placed` 决定（可能是 `Positioned` + 对齐），布局阶段拿不到
/// 它在画面里的绝对位置，所以这里用 `Stack` + `Positioned` 的已知偏移在
/// 布局后由 [RenderClipRelative] 换算：先在 `paint` 里取块的全局矩形的父级
/// 坐标系，再把 `rect` 转成局部坐标。
class _ClipRelative extends SingleChildRenderObjectWidget {
  const _ClipRelative(
      {required this.rect, required this.inverse, required Widget child})
      : super(child: child);

  final Rect rect;

  /// `\iclip`：保留 [rect] 外面的内容。
  final bool inverse;

  @override
  _RenderClipRelative createRenderObject(BuildContext context) =>
      _RenderClipRelative(rect, inverse);

  @override
  void updateRenderObject(
      BuildContext context, _RenderClipRelative renderObject) {
    renderObject
      ..rect = rect
      ..inverse = inverse;
  }
}

class _RenderClipRelative extends RenderProxyBox {
  _RenderClipRelative(this._rect, this._inverse);

  Rect _rect;
  bool _inverse;

  set rect(Rect value) {
    if (value == _rect) return;
    _rect = value;
    markNeedsPaint();
  }

  set inverse(bool value) {
    if (value == _inverse) return;
    _inverse = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    // 这一块在画面坐标系里的起点 = offset（父级已把块摆好）。
    final local = _rect.shift(-offset);
    if (!_inverse) {
      context.pushClipRect(needsCompositing, offset, local,
          (inner, innerOffset) => super.paint(inner, innerOffset));
      return;
    }
    // 逆裁剪：用「整块减去矩形」的奇偶规则。矩形贴在块外时就等于不裁，
    // clipPath 会返回 true 直接把块画出来。
    if (!offset.isFinite || size.isEmpty) {
      super.paint(context, offset);
      return;
    }
    final outer = Offset.zero & size;
    final clip = Path.combine(
      PathOperation.difference,
      Path()..addRect(outer),
      Path()..addRect(local),
    );
    context.pushClipPath(needsCompositing, offset, outer, clip,
        (inner, innerOffset) => super.paint(inner, innerOffset));
  }
}

/// 一条 cue 里所有 `{\p1}...{\p0}` 画出来的图形。
///
/// 绘图不参与文字排版（没有字宽、没有折行），但它仍然属于某条 Dialogue：
/// `\pos` / `\an` / 边距决定它的原点，坐标本身是脚本单位。所以它单独画在
/// 画面矩形这一层，而不是塞进某一行文字的 Widget 树里。
class _DrawingsPainter extends CustomPainter {
  _DrawingsPainter({required this.items, required this.nowMs, this.cue});

  final List<({SubtitleSpan run, SubtitleStyle style, SubtitleLine line})>
      items;
  final double nowMs;

  /// 这批绘图来自哪条 cue。
  ///
  /// [shouldRepaint] 用它判断要不要重绘。原来比的是 `items`，而这个列表
  /// 每帧都是新建的，`!=` 永远成立 —— 即使字幕一个字都没变，带 `\p` 的
  /// 片子也会按 60 Hz 重画整幅画布。内核在字幕没有动画时不会重发 SUBTITLE
  /// 事件，所以 `identical(cue)` 能真实反映「内容变了没有」。
  final SubtitleCue? cue;

  @override
  void paint(Canvas canvas, Size size) {
    for (final item in items) {
      final style = item.style;
      final run = item.run;
      final prx = style.playResX > 0 ? style.playResX : 1920.0;
      final pry = style.playResY > 0 ? style.playResY : 1080.0;
      final res = SubtitleAnimator.resolve(run, nowMs);
      // `\p<n>` 的坐标单位是 `2^(n-1)` 个脚本像素：`\p1` 原样，每加一档
      // 坐标值减半（libass 实测 `\p2` 画出的宽度正好是 `\p1` 的一半）。
      final k = math.pow(2, 1 - run.drawingScale).toDouble();
      final sx = size.width / prx * k;
      final sy = size.height / pry * k;

      // 先在脚本坐标里把图形摆到它该在的位置，再一次性换算成像素。
      final origin = _origin(item.line, style, prx, pry);
      final path = Path();
      var started = false;
      var sub = -1;
      for (final pt in run.path) {
        final x = (origin.dx + pt.x / k) * sx;
        final y = (origin.dy + pt.y / k) * sy;
        if (pt.sub != sub) {
          if (started) path.close();
          sub = pt.sub;
          path.moveTo(x, y);
          started = true;
        } else if (started) {
          path.lineTo(x, y);
        }
      }
      if (!started) continue;
      path.close();

      var color = res.color != 0 ? Color(res.color) : Color(style.color);
      if (res.alpha < 1.0) {
        color = color.withValues(alpha: color.a * res.alpha);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill,
      );
    }
  }

  /// 绘图坐标系的原点（脚本单位）。
  ///
  /// `\pos` 给定的是「这一行的对齐点」的坐标；没有 `\pos` 时按 `\an` 与
  /// 边距从画面边缘推算。`\an7`（左上）是最常见的写法，此时原点就等于
  /// `\pos`，与 libass 一致。
  static Offset _origin(
      SubtitleLine line, SubtitleStyle style, double prx, double pry) {
    final align = (line.align ?? style.align).clamp(1, 9);
    final horizontal = (align - 1) % 3; // 0 左 1 中 2 右
    final vertical = (align - 1) ~/ 3; // 0 下 1 中 2 上
    final posX = line.posX ?? style.posX;
    final posY = line.posY ?? style.posY;
    final marginL = line.marginL ?? style.marginL;
    final marginR = line.marginR ?? style.marginR;
    final marginV = line.marginV ?? style.marginV;
    final x = posX >= 0
        ? posX * prx
        : (horizontal == 0
            ? marginL
            : (horizontal == 2 ? prx - marginR : prx / 2));
    final y = posY >= 0
        ? posY * pry
        : (vertical == 2 ? marginV : (vertical == 0 ? pry - marginV : pry / 2));
    return Offset(x, y);
  }

  @override
  bool shouldRepaint(_DrawingsPainter oldDelegate) =>
      oldDelegate.nowMs != nowMs ||
      !identical(oldDelegate.cue, cue) ||
      oldDelegate.items.length != items.length;
}
