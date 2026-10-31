class SubtitleStyle {
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikeout;
  final int color; // 0xAARRGGBB
  final int secondaryColor; // 卡拉 OK 未唱部分的颜色
  final int outlineColor;
  final int backColor; // BorderStyle 3/4 的方框底色
  final int outline;
  final int shadow; // 阴影偏移，脚本单位
  final int borderStyle; // 1 = 描边+阴影，3/4 = 不透明方框
  final double spacing; // 字间距，脚本单位
  final double scaleX; // 百分比，100 = 原样
  final double scaleY;
  final double angle; // 旋转角度（度，顺时针）
  final double marginL; // 脚本单位
  final double marginR;
  final double marginV;
  final int align; // ASS 1..9
  final double fontScale;
  final double playResY; // 脚本分辨率高度，margin/描边按它折算成像素
  final double playResX; // 脚本分辨率宽度，\clip 与 \p 的 x 坐标按它折算
  final double posX;
  final double posY;
  final String font;

  const SubtitleStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikeout = false,
    this.color = 0xFFFFFFFF,
    this.outlineColor = 0xFF000000,
    this.secondaryColor = 0xFFFFFFFF,
    this.backColor = 0xFF000000,
    this.outline = 1,
    this.shadow = 0,
    this.borderStyle = 1,
    this.spacing = 0,
    this.scaleX = 100,
    this.scaleY = 100,
    this.angle = 0,
    this.marginL = 0,
    this.marginR = 0,
    this.marginV = 0,
    this.align = 2,
    this.fontScale = 0.05,
    this.playResY = 1080,
    this.playResX = 1920,
    this.posX = -1,
    this.posY = -1,
    this.font = 'sans-serif',
  });

  factory SubtitleStyle.fromJson(Map<String, dynamic> j) => SubtitleStyle(
        bold: j['bold'] == true,
        italic: j['italic'] == true,
        underline: j['underline'] == true,
        strikeout: j['strikeout'] == true,
        color: (j['color'] as num?)?.toInt() ?? 0xFFFFFFFF,
        outlineColor: (j['outline_color'] as num?)?.toInt() ?? 0xFF000000,
        secondaryColor: (j['secondary_color'] as num?)?.toInt() ?? 0xFFFFFFFF,
        backColor: (j['back_color'] as num?)?.toInt() ?? 0xFF000000,
        outline: (j['outline'] as num?)?.toInt() ?? 1,
        shadow: (j['shadow'] as num?)?.toInt() ?? 0,
        borderStyle: (j['border_style'] as num?)?.toInt() ?? 1,
        spacing: (j['spacing'] as num?)?.toDouble() ?? 0,
        scaleX: (j['scale_x'] as num?)?.toDouble() ?? 100,
        scaleY: (j['scale_y'] as num?)?.toDouble() ?? 100,
        angle: (j['angle'] as num?)?.toDouble() ?? 0,
        marginL: (j['margin_l'] as num?)?.toDouble() ?? 0,
        marginR: (j['margin_r'] as num?)?.toDouble() ?? 0,
        marginV: (j['margin_v'] as num?)?.toDouble() ?? 0,
        align: (j['align'] as num?)?.toInt() ?? 2,
        fontScale: (j['font_scale'] as num?)?.toDouble() ?? 0.05,
        playResY: (j['play_res_y'] as num?)?.toDouble() ?? 1080,
        playResX: (j['play_res_x'] as num?)?.toDouble() ?? 1920,
        posX: (j['pos_x'] as num?)?.toDouble() ?? -1,
        posY: (j['pos_y'] as num?)?.toDouble() ?? -1,
        font: j['font'] as String? ?? 'sans-serif',
      );

  /// 1 = left, 2 = center, 3 = right (vertical handled separately).
  int get horizontalAlign => ((align - 1) % 3) + 1;
  bool get isTop => align >= 7;
  bool get isMiddle => align >= 4 && align <= 6;
}

/// One inline-styled fragment of a subtitle line. ASS override tags such as
/// `{\b1}`, `{\i1}` or `{\c&H0000FF&}` arrive here as separate runs so the
/// renderer can mix fonts and colours inside a single sentence.
class SubtitleSpan {
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikeout;
  final int color; // 0 = inherit from the cue style
  final int outlineColor; // 0 = inherit; set by an inline \3c
  final int backColor; // 0 = inherit; set by an inline \4c
  final double scale; // 0 = inherit from the cue style
  final double scaleX; // 百分比，0 = 继承
  final double scaleY;
  final double spacing; // 脚本单位，0 = 继承
  final double angle; // 度，0 = 继承
  final int border; // 脚本单位，-1 = 继承
  final int shadow; // 脚本单位，-1 = 继承
  final String font; // '' = inherit from the cue style

  /// 整段文字的不透明度，1.0 = 不变。`\alpha` / `\1a` 给的是透明度，
  /// 内核已经换算成透明度反转后的值。
  final double alpha;

  /// 卡拉 OK：`kind` 1 = `\k` 逐字填色、2 = `\kf`、3 = `\ko` 逐字淡出。
  /// 起止时间是**这条 Dialogue 内的相对毫秒**。
  final int karaokeKind;
  final double karaokeStart;
  final double karaokeEnd;

  /// `\t(...)` 动画。播放时要按当前时刻求值，所以整条留到渲染层算。
  final List<SubtitleAnim> anims;

  /// `\clip(x1,y1,x2,y2)`，脚本坐标。
  final List<double> clip;
  final bool clipInverse;

  /// `\clip` 是否生效（`	` 的动画里可以打开/关掉裁剪）。
  bool get clipOn => clip.length == 4;

  /// `\p<n>` 矢量绘图：`drawingScale` 是 `\p` 的指数，`path` 是折线点列，
  /// 每个点自带子路径编号（`m` 开启一条新子路径）。
  final int drawingScale;
  final List<SubtitlePathPoint> path;

  const SubtitleSpan({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikeout = false,
    this.color = 0,
    this.outlineColor = 0,
    this.backColor = 0,
    this.scale = 0,
    this.scaleX = 0,
    this.scaleY = 0,
    this.spacing = 0,
    this.angle = 0,
    this.border = -1,
    this.shadow = -1,
    this.font = '',
    this.alpha = 1.0,
    this.karaokeKind = 0,
    this.karaokeStart = 0,
    this.karaokeEnd = 0,
    this.anims = const [],
    this.clip = const [],
    this.clipInverse = false,
    this.drawingScale = 0,
    this.path = const [],
  });

  factory SubtitleSpan.fromJson(Map<String, dynamic> j) => SubtitleSpan(
        text: j['text'] as String? ?? '',
        bold: j['bold'] == true,
        italic: j['italic'] == true,
        underline: j['underline'] == true,
        strikeout: j['strikeout'] == true,
        color: (j['color'] as num?)?.toInt() ?? 0,
        outlineColor: (j['outline_color'] as num?)?.toInt() ?? 0,
        backColor: (j['back_color'] as num?)?.toInt() ?? 0,
        scale: (j['scale'] as num?)?.toDouble() ?? 0,
        scaleX: (j['scale_x'] as num?)?.toDouble() ?? 0,
        scaleY: (j['scale_y'] as num?)?.toDouble() ?? 0,
        spacing: (j['spacing'] as num?)?.toDouble() ?? 0,
        angle: (j['angle'] as num?)?.toDouble() ?? 0,
        border: (j['border'] as num?)?.toInt() ?? -1,
        shadow: (j['shadow'] as num?)?.toInt() ?? -1,
        font: j['font'] as String? ?? '',
        alpha: (j['alpha'] as num?)?.toDouble() ?? 1.0,
        karaokeKind: (j['karaoke'] as num?)?.toInt() ?? 0,
        karaokeStart: (j['karaoke_start'] as num?)?.toDouble() ?? 0,
        karaokeEnd: (j['karaoke_end'] as num?)?.toDouble() ?? 0,
        anims: j['anims'] is List
            ? (j['anims'] as List)
                .whereType<Map<String, dynamic>>()
                .map(SubtitleAnim.fromJson)
                .toList(growable: false)
            : const [],
        clip: j['clip'] is List
            ? (j['clip'] as List)
                .whereType<num>()
                .map((e) => e.toDouble())
                .toList(growable: false)
            : const [],
        clipInverse: j['clip_inverse'] == true,
        drawingScale: (j['draw'] as num?)?.toInt() ?? 0,
        path: j['path'] is List
            ? (j['path'] as List)
                .whereType<List<dynamic>>()
                .map(SubtitlePathPoint.fromJson)
                .toList(growable: false)
            : const [],
      );
}

/// 矢量绘图的一个顶点。`sub` 是同一条 `m` 里的子路径编号，用来断开折线。
class SubtitlePathPoint {
  final int sub;
  final double x;
  final double y;

  const SubtitlePathPoint(
      {required this.sub, required this.x, required this.y});

  factory SubtitlePathPoint.fromJson(List<dynamic> j) => SubtitlePathPoint(
        sub: (j.isNotEmpty ? j[0] as num : 0).toInt(),
        x: (j.length > 1 ? j[1] as num : 0).toDouble(),
        y: (j.length > 2 ? j[2] as num : 0).toDouble(),
      );
}

/// 一个 `\t(t1,t2,accel,tags)` 动画。字段用位掩码标出「这次动画改了什么」，
/// 没标到的字段沿用 run 自己的值。
class SubtitleAnim {
  const SubtitleAnim({
    this.t1 = 0,
    this.t2 = 0,
    this.accel = 0,
    this.fields = 0,
    this.color = 0,
    this.scaleX = 0,
    this.scaleY = 0,
    this.scale = 0,
    this.angle = 0,
    this.spacing = 0,
    this.border = -1,
    this.shadow = -1,
    this.alpha = 1.0,
    this.clip = const [],
  });

  final double t1;
  final double t2;
  final double accel;
  final int fields;
  final int color;
  final double scaleX;
  final double scaleY;
  final double scale;
  final double angle;
  final double spacing;
  final int border;
  final int shadow;
  final double alpha;
  final List<double> clip;

  static const int fieldColor = 0x1;
  static const int fieldScaleX = 0x2;
  static const int fieldScaleY = 0x4;
  static const int fieldFont = 0x8;
  static const int fieldAngle = 0x10;
  static const int fieldSpacing = 0x20;
  static const int fieldBorder = 0x40;
  static const int fieldShadow = 0x80;
  static const int fieldAlpha = 0x100;
  static const int fieldClip = 0x200;

  bool has(int bit) => (fields & bit) != 0;

  factory SubtitleAnim.fromJson(Map<String, dynamic> j) => SubtitleAnim(
        t1: (j['t1'] as num?)?.toDouble() ?? 0,
        t2: (j['t2'] as num?)?.toDouble() ?? 0,
        accel: (j['accel'] as num?)?.toDouble() ?? 0,
        fields: (j['f'] as num?)?.toInt() ?? 0,
        color: (j['color'] as num?)?.toInt() ?? 0,
        scaleX: (j['scale_x'] as num?)?.toDouble() ?? 0,
        scaleY: (j['scale_y'] as num?)?.toDouble() ?? 0,
        scale: (j['scale'] as num?)?.toDouble() ?? 0,
        angle: (j['angle'] as num?)?.toDouble() ?? 0,
        spacing: (j['spacing'] as num?)?.toDouble() ?? 0,
        border: (j['border'] as num?)?.toInt() ?? -1,
        shadow: (j['shadow'] as num?)?.toInt() ?? -1,
        alpha: (j['alpha'] as num?)?.toDouble() ?? 1.0,
        clip: j['clip'] is List
            ? (j['clip'] as List)
                .whereType<num>()
                .map((e) => e.toDouble())
                .toList(growable: false)
            : const [],
      );
}

/// A single displayed subtitle line: the plain text plus, when the source
/// styled it inline, the ordered runs that make it up.
///
/// 同一时刻画面上可能有多条字幕（ASS 里是几条独立的 `Dialogue`），它们各有
/// 自己的对齐、边距和 `\pos`。这些字段为 null 表示「跟随整条 cue 的样式」，
/// 只有该行确实覆盖了样式时内核才输出。
class SubtitleLine {
  final String text;
  final List<SubtitleSpan> runs;

  /// 这一行自己的样式。同一时刻在屏上的几条字幕各按自己的 `Style:` 渲染
  /// （颜色、粗细、边框盒、字号都可能不同），所以样式跟着行走而不是整条
  /// cue 共用一份。纯文本的老载荷没有这个字段，回落到 cue 的样式。
  final SubtitleStyle? style;
  final int? align;
  final double? marginL;
  final double? marginR;
  final double? marginV;
  final double? posX;
  final double? posY;
  final double? playResY;

  const SubtitleLine({
    required this.text,
    this.runs = const [],
    this.style,
    this.align,
    this.marginL,
    this.marginR,
    this.marginV,
    this.posX,
    this.posY,
    this.playResY,
  });

  factory SubtitleLine.fromJson(Map<String, dynamic> j) {
    final raw = j['runs'];
    final style = j['style'];
    return SubtitleLine(
      text: j['text'] as String? ?? '',
      runs: raw is List
          ? raw
              .whereType<Map<String, dynamic>>()
              .map(SubtitleSpan.fromJson)
              .toList(growable: false)
          : const [],
      style:
          style is Map<String, dynamic> ? SubtitleStyle.fromJson(style) : null,
      align: (j['align'] as num?)?.toInt(),
      marginL: (j['margin_l'] as num?)?.toDouble(),
      marginR: (j['margin_r'] as num?)?.toDouble(),
      marginV: (j['margin_v'] as num?)?.toDouble(),
      posX: (j['pos_x'] as num?)?.toDouble(),
      posY: (j['pos_y'] as num?)?.toDouble(),
      playResY: (j['play_res_y'] as num?)?.toDouble(),
    );
  }

  bool get styled => runs.any(
        (r) =>
            r.bold ||
            r.italic ||
            r.underline ||
            r.strikeout ||
            r.color != 0 ||
            // 行内 \3c / \4c 只改描边、底色，也算「这一行有内联样式」——
            // 否则整行会退回 cue 的样式，描边色又变回黑色。
            r.outlineColor != 0 ||
            r.backColor != 0 ||
            r.scale != 0 ||
            r.scaleX != 0 ||
            r.scaleY != 0 ||
            r.spacing != 0 ||
            r.angle != 0 ||
            r.border >= 0 ||
            r.shadow >= 0 ||
            r.font.isNotEmpty ||
            // 高级特性同样算「这一行有内联样式」：只带 \alpha / \clip /
            // \p 或卡拉 OK 的行，整行退回纯文本就把这些效果全丢了。
            r.alpha < 1.0 ||
            r.karaokeKind != 0 ||
            r.anims.isNotEmpty ||
            r.clipOn ||
            r.drawingScale > 0,
      );

  /// 这一行是否自己指定了位置/对齐（否则跟 cue 走）。
  bool get placed =>
      align != null ||
      (posX != null && posY != null) ||
      (marginV ?? 0) > 0 ||
      (marginL ?? 0) > 0 ||
      (marginR ?? 0) > 0;
}

class SubtitleCue {
  final String text;
  final int startUs;
  final int endUs;
  final SubtitleStyle style;
  final List<SubtitleLine> lines;

  /// 这条 Dialogue 里已经播过去的微秒数（内核随事件下发）。`\t` 动画和
  /// `\k` 卡拉 OK 都要靠它求值；0 表示「刚开始」。
  final int nowUs;

  const SubtitleCue({
    required this.text,
    required this.startUs,
    required this.endUs,
    required this.style,
    this.lines = const [],
    this.nowUs = 0,
  });

  static const empty = SubtitleCue(
    text: '',
    startUs: 0,
    endUs: 0,
    style: SubtitleStyle(),
  );

  factory SubtitleCue.fromJson(Map<String, dynamic> j) {
    final raw = j['runs'];
    return SubtitleCue(
      text: j['text'] as String? ?? '',
      startUs: (j['start'] as num?)?.toInt() ?? 0,
      endUs: (j['end'] as num?)?.toInt() ?? 0,
      style: SubtitleStyle.fromJson(
          (j['style'] as Map<String, dynamic>?) ?? const {}),
      lines: raw is List
          ? raw
              .whereType<Map<String, dynamic>>()
              .map(SubtitleLine.fromJson)
              .toList(growable: false)
          : const [],
      nowUs: (j['now'] as num?)?.toInt() ?? 0,
    );
  }

  /// 同一时刻再生成一份，只换 `nowUs`。播放器每个 POSITION 周期都要重算
  /// 动画，复用解析好的 lines 比重新 fromJson 便宜得多。
  SubtitleCue at(int nowUs) => SubtitleCue(
        text: text,
        startUs: startUs,
        endUs: endUs,
        style: style,
        lines: lines,
        nowUs: nowUs,
      );

  /// 整条字幕是不是没有任何可见内容。
  ///
  /// 不能只看 `text`：只含 `\p1` 矢量绘图的行没有文字，但渲染器
  /// （`subtitle_overlay.dart` 的 `_drawingsWithPlacement`）确实会把图形画出来。
  /// 早先这里只判 `text.trim().isEmpty`，OP/ED 的矢量标题与特效字幕整段消失，
  /// 而内核那边 `has_drawing_runs()` 是把这类行当作「有内容」保留的。
  bool get isEmpty => text.trim().isEmpty && !lines.any(_hasDrawing);

  /// 这一行里有没有矢量绘图（`\p1` 之类）需要画。
  static bool _hasDrawing(SubtitleLine line) =>
      line.runs.any((run) => run.path.isNotEmpty);
}
