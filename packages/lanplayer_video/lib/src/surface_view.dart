import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'channel.dart';

/// 移动端视频画面的载体：一块原生 `SurfaceView`，通过平台视图嵌进 Flutter。
///
/// 桌面端返回 null —— 那边走的是外部纹理，画面由 `Texture(textureId:)` 画。
///
/// 为什么移动端要这么绕：Flutter 引擎只要看到有活跃的外部纹理，就会在每个
/// vsync 上把整棵 layer tree 重新光栅化一次，与纹理有没有更新无关。120 Hz
/// 屏幕放 30 fps 内容时，四次合成里三次在重绘同一张图，栅格线程和 GPU 被
/// 白白占住（`flutter/flutter#188616`、`flutter/flutter#192181` 都在跟踪，
/// 维护者明确不打算暴露 `CADisplayLink.preferredFrameRateRange`）。把画面交给
/// 系统合成器就绕开了这条约束：内核算好一帧就上屏一次，屏幕刷多少次与内容帧率
/// 无关。
///
/// 走的平台视图实现是 `initSurfaceAndroidView`（`SurfaceAndroidViewController`），
/// **不是** `AndroidView` 默认的 `initAndroidView` —— 后者内部是
/// `TextureAndroidViewController`，把原生视图画进一块纹理再合成，那就又回到
/// 纹理路径上了，等于白改。
class VideoSurfaceView extends StatelessWidget {
  const VideoSurfaceView({super.key});

  /// 只有 Android 有平台视图实现（`VideoSurfaceView.kt`）。
  ///
  /// iOS 上还在用 `AVSampleBufferDisplayLayer` 之前的那条纹理路，等那边接好
  /// 之后这个判定要一起放开。
  static bool get isSupported => Platform.isAndroid;

  @override
  Widget build(BuildContext context) {
    if (!isSupported) {
      return const SizedBox.expand();
    }
    return PlatformViewLink(
      viewType: lanplayerVideoSurfaceViewType,
      surfaceFactory: (context, controller) =>
          _SurfaceHost(controller: controller),
      onCreatePlatformView: (params) {
        // initSurfaceAndroidView 优先用 SurfaceControl，老系统上退回
        // Hybrid Composition；两条都能把 SurfaceView 真正放进视图层级。
        return PlatformViewsService.initSurfaceAndroidView(
          id: params.id,
          viewType: params.viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: const <String, Object>{},
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
      },
    );
  }
}

/// 平台视图控制器给的那张「画布」。
///
/// [PlatformViewController] 本身不画东西；安卓这边要用 [AndroidViewSurface]，
/// 它会按控制器的 `requiresViewComposition` 选择 `_PlatformLayerBasedAndroidViewSurface`
/// （SurfaceView 走这条，原生视图直接进 Android 的视图层级）或
/// `_TextureBasedAndroidViewSurface`（退回 GL 纹理）。手写 `RenderObject`
/// 会漏掉它内部对 `pointTransformer` 与创建监听的处理。
///
/// 控制器类型对不上时退化成一块空画布 —— 那只会在引擎版本对不上时发生，
/// 不值得让整个播放页崩掉。
class _SurfaceHost extends StatelessWidget {
  const _SurfaceHost({required this.controller});

  final PlatformViewController controller;

  @override
  Widget build(BuildContext context) {
    final view = controller;
    if (view is AndroidViewController) {
      return AndroidViewSurface(
        controller: view,
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      );
    }
    return const SizedBox.expand();
  }
}
