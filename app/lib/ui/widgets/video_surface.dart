import 'package:flutter/material.dart';

/// 缩放方式：与 `PlaybackSettings.scaleMode` / 内核 `LpScaleMode` 同一套取值。
///
/// 0 = 适应屏幕（保持比例，留黑边）、1 = 铺满裁切、2 = 拉伸。
const int scaleModeFit = 0;
const int scaleModeFill = 1;
const int scaleModeStretch = 2;

/// 把一帧画面按 [scaleMode] 铺到给定的区域上。
///
/// 为什么缩放要在 Flutter 这一层做：内核里的 `scale_mode` 只有 Android 的
/// EGL 渲染器会读（`native/src/platform/android/egl_renderer.c` 用它算归一化
/// 顶点），Windows / macOS / iOS 走的是 Flutter 外部纹理，内核帧被原样交给
/// 引擎，`scale_mode` 在那边没有任何人读。于是「画面」面板里的三个选项在
/// 桌面上点了没反应 —— 用户报的就是这个。放到这里做，三端行为一致。
///
/// [videoAspectRatio] 必须是**视频原始画面**的宽高比，不能是窗口的：铺满裁切
/// 要按原画比例放大后再裁，用窗口比例会让画面变形。
class VideoSurface extends StatelessWidget {
  const VideoSurface({
    super.key,
    required this.scaleMode,
    required this.videoAspectRatio,
    required this.child,
    this.backgroundColor = Colors.black,
  });

  final int scaleMode;
  final double videoAspectRatio;
  final Widget child;
  final Color backgroundColor;

  /// 把缩放模式翻译成 [BoxFit]。
  static BoxFit fitFor(int scaleMode) {
    switch (scaleMode) {
      case scaleModeFill:
        return BoxFit.cover;
      case scaleModeStretch:
        return BoxFit.fill;
      default:
        return BoxFit.contain;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 用一个「按原位图比例」的盒子承载纹理，再由 FittedBox 决定怎么贴合。
    // Texture / Image 自己总是撑满父约束，不先固定比例就没法区分 contain 与
    // cover —— 这正是原来只写 AspectRatio 却看不出三种模式差别的原因。
    final ratio = videoAspectRatio.isFinite && videoAspectRatio > 0
        ? videoAspectRatio
        : 16 / 9;
    return ColoredBox(
      color: backgroundColor,
      child: FittedBox(
        fit: fitFor(scaleMode),
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: 1000 * ratio,
          height: 1000,
          child: child,
        ),
      ),
    );
  }
}
