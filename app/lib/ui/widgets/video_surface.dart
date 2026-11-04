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
    this.nativeSurface = false,
  });

  final int scaleMode;
  final double videoAspectRatio;
  final Widget child;
  final Color backgroundColor;

  /// [child] 是不是一块原生画面（`SurfaceView` 之类的平台视图），而不是
  /// Flutter 外部纹理。
  ///
  /// 两者的布局方式必须分开，因为原生视图的**物理尺寸就是缓冲区尺寸**：
  /// 纹理只是把位图画到目标矩形里，随便给多大都无所谓；而平台视图会被系统按
  /// 布局尺寸分配一块实实在在的图形缓冲。下面那个「1000 逻辑像素高的虚拟
  /// 盒子」在纹理路径上只是让 `FittedBox` 有个已知比例可算，到了平台视图上
  /// 却会被当成真实尺寸——逻辑 1778×1000 在 520 dpi 的屏幕上就是
  /// 5777×3250 物理像素，约 76 MB 一块、三缓冲合计两百多兆，比整屏还大四倍，
  /// 每帧都要按那个尺寸写满再让合成器缩小。
  ///
  /// 置位时改用 [applyBoxFit] 直接算出贴合后的目标矩形，原生视图按那个尺寸
  /// 布局，缓冲区就与屏幕尺寸同一量级。
  final bool nativeSurface;

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

  /// 按 [scaleMode] 把 [ratio] 宽高比的内容铺到 [area] 上时的目标矩形。
  ///
  /// 不用 `applyBoxFit`：它在 cover 模式下把 `destination` 记成整块输出区域，
  /// 真正被裁掉的是 `source`，拿到的尺寸永远是区域大小，看不出「铺满需要
  /// 放大到比区域更大」。这里直接按短边/长边算。
  static Size fittedSize(int scaleMode, double ratio, Size area) {
    switch (scaleMode) {
      case scaleModeStretch:
        return area;
      case scaleModeFill:
        // 铺满裁切：取较大的缩放系数，结果可能超出区域，由调用方裁掉。
        final byHeight = area.height;
        final byWidth = area.width / ratio;
        final height = byWidth > byHeight ? byWidth : byHeight;
        return Size(height * ratio, height);
      default:
        // 适应屏幕：取较小的缩放系数，结果不超出区域。
        final byHeight = area.height;
        final byWidth = area.width / ratio;
        final height = byWidth < byHeight ? byWidth : byHeight;
        return Size(height * ratio, height);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 用一个「按原位图比例」的盒子承载纹理，再由 FittedBox 决定怎么贴合。
    // Texture / Image 自己总是撑满父约束，不先固定比例就没法区分 contain 与
    // cover —— 这正是原来只写 AspectRatio 却看不出三种模式差别的原因。
    // 比例范围夹在 [1:16, 16:1]。异常宽高比（容器还没报字节、日志里出现过
    // 1000:1）会让 `1000 * ratio` 生成一个十几万宽的 SizedBox，布局与
    // 光栅化都要为这个空盒子付代价。
    double ratio = videoAspectRatio.isFinite && videoAspectRatio > 0
        ? videoAspectRatio
        : 16 / 9;
    if (ratio < 1 / 16) {
      ratio = 1 / 16;
    } else if (ratio > 16) {
      ratio = 16;
    }
    if (nativeSurface) {
      return ColoredBox(
        color: backgroundColor,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final area = Size(constraints.maxWidth, constraints.maxHeight);
            if (!area.isFinite || area.width <= 0 || area.height <= 0) {
              return child;
            }
            // 原生视图按贴合后的真实矩形布局，缓冲区不再随虚拟盒子放大。
            final size = fittedSize(scaleMode, ratio, area);
            return ClipRect(
              child: OverflowBox(
                // 放开约束，让下面的 SizedBox 说到多大就是多大；cover 时它会
                // 比可用区域大，由外层 ClipRect 裁掉溢出部分。四个边界都要
                // 显式给：`Positioned.fill` 传下来的是紧约束，只改 max 的话
                // 最小值仍是整块区域，留黑边的那些模式会被撑满。
                minWidth: 0,
                maxWidth: double.infinity,
                minHeight: 0,
                maxHeight: double.infinity,
                child: SizedBox.fromSize(size: size, child: child),
              ),
            );
          },
        ),
      );
    }
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
