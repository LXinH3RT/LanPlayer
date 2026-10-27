import 'dart:math' as math;

import 'models.dart';

/// ASS 高级特性在**播放时刻**的解算：`\t(...)` 动画、`\k` 卡拉 OK。
///
/// 内核把一条 Dialogue 拆成若干 run，每个 run 带上自己的动画表和卡拉 OK
/// 时间片；真正「现在长什么样」要到渲染时才知道。这里只做纯计算，不碰
/// Widget，方便单测。
class SubtitleAnimator {
  const SubtitleAnimator._();

  /// 把一个动画的 `t1..t2` 窗口换算成 0..1 的进度。
  ///
  /// ASS 的 `accel` 是加速度：大于 1 表示先慢后快，小于 1 表示先快后慢，
  /// 0 或 1 都是线性。libass 的公式是 `pow(p, 1/accel)`，这里照抄。
  static double progress(SubtitleAnim anim, double nowMs) {
    final span = anim.t2 - anim.t1;
    if (span <= 0) {
      return nowMs >= anim.t2 ? 1.0 : 0.0;
    }
    if (nowMs <= anim.t1) {
      return 0.0;
    }
    if (nowMs >= anim.t2) {
      return 1.0;
    }
    final raw = (nowMs - anim.t1) / span;
    final accel = anim.accel;
    if (accel <= 0 || (accel - 1.0).abs() < 1e-6) {
      return raw;
    }
    return math.pow(raw, 1.0 / accel).toDouble();
  }

  /// 把 run 上所有动画按当前时刻折算成一份「生效后的样式」。
  ///
  /// 多个动画可以同时存在（`\t(0,300,\fscx120)\t(300,600,\fscx100)`），
  /// 后写的覆盖先写的，与 libass 一致。
  static ResolvedSpan resolve(SubtitleSpan run, double nowMs) {
    var color = run.color;
    final outlineColor = run.outlineColor;
    var scaleX = run.scaleX;
    var scaleY = run.scaleY;
    var scale = run.scale;
    var angle = run.angle;
    var spacing = run.spacing;
    var border = run.border;
    var shadow = run.shadow;
    var alpha = run.alpha;
    var clip = run.clip;
    final clipOn = run.clipOn;

    for (final anim in run.anims) {
      final p = progress(anim, nowMs);
      if (anim.has(SubtitleAnim.fieldColor)) {
        // 动画的起点是 run 自己的颜色，终点是 anim 给的颜色。
        final from = _colorOr(run.color, 0xFFFFFFFF);
        color = _lerpColor(from, anim.color, p);
      }
      if (anim.has(SubtitleAnim.fieldScaleX)) {
        scaleX = _lerp(scaleX == 0 ? 100.0 : scaleX, anim.scaleX, p);
      }
      if (anim.has(SubtitleAnim.fieldScaleY)) {
        scaleY = _lerp(scaleY == 0 ? 100.0 : scaleY, anim.scaleY, p);
      }
      if (anim.has(SubtitleAnim.fieldFont)) {
        scale = _lerp(scale, anim.scale, p);
      }
      if (anim.has(SubtitleAnim.fieldAngle)) {
        angle = _lerp(angle, anim.angle, p);
      }
      if (anim.has(SubtitleAnim.fieldSpacing)) {
        spacing = _lerp(spacing, anim.spacing, p);
      }
      if (anim.has(SubtitleAnim.fieldBorder)) {
        border = _lerp(
                border < 0 ? 1.0 : border.toDouble(), anim.border.toDouble(), p)
            .round();
      }
      if (anim.has(SubtitleAnim.fieldShadow)) {
        shadow = _lerp(
                shadow < 0 ? 0.0 : shadow.toDouble(), anim.shadow.toDouble(), p)
            .round();
      }
      if (anim.has(SubtitleAnim.fieldAlpha)) {
        alpha = _lerp(alpha, anim.alpha, p);
      }
      if (anim.has(SubtitleAnim.fieldClip) && anim.clip.length == 4) {
        clip = _lerpRect(clip, anim.clip, p);
      }
    }

    return ResolvedSpan(
      color: color,
      outlineColor: outlineColor,
      scaleX: scaleX,
      scaleY: scaleY,
      scale: scale,
      angle: angle,
      spacing: spacing,
      border: border,
      shadow: shadow,
      alpha: alpha,
      clip: clip,
      clipOn: clipOn,
      karaoke: karaokeFill(run, nowMs),
    );
  }

  /// 卡拉 OK：`\k` 把一条 Dialogue 的时间切成若干片，每片对应几个字。
  /// 返回 0..1 表示这一片已经「唱」了多少。
  ///
  /// - `\k` / `\kf`：唱到的字换成主色（这里用进度当作填充比例）
  /// - `\ko`：唱过的字开始淡出，进度直接映射成透明度
  static double karaokeFill(SubtitleSpan run, double nowMs) {
    if (run.karaokeKind == 0) {
      return 1.0;
    }
    if (nowMs <= run.karaokeStart) {
      return 0.0;
    }
    if (nowMs >= run.karaokeEnd) {
      return 1.0;
    }
    final span = run.karaokeEnd - run.karaokeStart;
    if (span <= 0) {
      return 1.0;
    }
    return ((nowMs - run.karaokeStart) / span).clamp(0.0, 1.0);
  }

  static int _colorOr(int value, int fallback) => value == 0 ? fallback : value;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  static int _lerpColor(int a, int b, double t) {
    int ch(int shift) {
      final ca = (a >> shift) & 0xFF;
      final cb = (b >> shift) & 0xFF;
      return (ca + (cb - ca) * t).round().clamp(0, 255);
    }

    return (ch(24) << 24) | (ch(16) << 16) | (ch(8) << 8) | ch(0);
  }

  static List<double> _lerpRect(List<double> from, List<double> to, double t) {
    final src = from.length == 4 ? from : to;
    return <double>[
      for (var i = 0; i < 4; i++) _lerp(src[i], to[i], t),
    ];
  }
}

/// 一个 run 在某一时刻的最终观感。字段语义与 [SubtitleSpan] 相同，
/// 只是动画已经求值完。
class ResolvedSpan {
  const ResolvedSpan({
    required this.color,
    required this.outlineColor,
    required this.scaleX,
    required this.scaleY,
    required this.scale,
    required this.angle,
    required this.spacing,
    required this.border,
    required this.shadow,
    required this.alpha,
    required this.clip,
    required this.clipOn,
    required this.karaoke,
  });

  final int color;
  final int outlineColor;
  final double scaleX;
  final double scaleY;
  final double scale;
  final double angle;
  final double spacing;
  final int border;
  final int shadow;
  final double alpha;
  final List<double> clip;

  /// `\clip` 是否生效（动画里可能把裁剪打开或关掉）。
  final bool clipOn;
  final double karaoke;
}
