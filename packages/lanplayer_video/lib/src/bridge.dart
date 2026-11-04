import 'dart:ffi';

import 'package:flutter/services.dart';

import 'channel.dart';

export 'channel.dart';

/// 一块由平台侧创建的视频输出。
///
/// Android：[platformView] 为真，画面由平台视图（原生 `SurfaceView`）提供，
/// 内核直接画进那块 Surface，Dart 侧不碰纹理也不碰窗口指针。
/// iOS / macOS： [windowPtr] 为 [TextureWindowPtr.inProcess]，内核发布
/// `CVPixelBuffer`，Swift 的 `FlutterTexture` 去取。
/// Windows： 同样为 [TextureWindowPtr.inProcess]，插件用 D3D11 共享纹理把帧
/// 推给 Flutter。
class VideoTexture {
  const VideoTexture({
    required this.textureId,
    required this.windowPtr,
    required this.width,
    required this.height,
    this.platformView = false,
  });

  final int textureId;
  final int windowPtr;
  final int width;
  final int height;

  /// 画面由原生平台视图提供（Android）。为真时 [textureId] 无意义，Dart 侧
  /// 应该建 `VideoSurfaceView` 而不是 `Texture`。
  final bool platformView;

  /// 内核要不要自己往窗口里画，且这个窗口指针是否需要 Dart 转交。
  ///
  /// 平台视图自己管窗口，Dart 不转交，所以这里明确要求「不是平台视图」。
  bool get needsSurface =>
      !platformView && windowPtr != TextureWindowPtr.inProcess;
}

/// 视频纹理通道的 Dart 侧。
///
/// 四份宿主（Windows C++ 插件 / macOS Swift / iOS Swift / Android Kotlin）注册
/// 同一个方法通道，所以这里的调用点在整个工程里只有一份。通道名、方法名、
/// 参数键都在 `src/channel.dart` 里；原生侧由静态检查保证四份实现认同一套名字。
///
/// 所有方法都对 `MissingPluginException` / `PlatformException` 保持静默并返回
/// 「没做成」：桌面测试宿主、`flutter test`、以及没有插件的平台上，播放器应该
/// 退化成「没有视频纹理」而不是崩掉。
class VideoTextureBridge {
  static const MethodChannel _channel = MethodChannel(lanplayerVideoChannel);

  static VideoTexture? _current;

  static VideoTexture? get current => _current;

  static Future<VideoTexture?> create({
    int width = TextureRequestKey.defaultWidth,
    int height = TextureRequestKey.defaultHeight,
  }) async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>(
        VideoChannelMethod.createTexture,
        {
          TextureRequestKey.width: width,
          TextureRequestKey.height: height,
        },
      );
      if (map == null) return null;
      final tex = VideoTexture(
        textureId: (map[TextureReplyKey.textureId] as num?)?.toInt() ?? -1,
        windowPtr: (map[TextureReplyKey.window] as num?)?.toInt() ?? 0,
        width: width,
        height: height,
        platformView: map[TextureReplyKey.platformView] == true,
      );
      _current = tex;
      return tex;
    } on PlatformException catch (_) {
      return null;
    } on MissingPluginException catch (_) {
      // 桌面测试宿主 / 没有插件的平台。
      return null;
    }
  }

  /// 告诉平台侧该桥接哪个内核播放器（iOS / macOS 需要它来装帧回调）。
  static Future<void> attachPlayer(Pointer<Void>? player) async {
    if (player == null) return;
    try {
      await _channel.invokeMethod<void>(
        VideoChannelMethod.attachPlayer,
        {attachPlayerKey: player.address},
      );
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  /// 在窗口全屏与窗口化之间切换。
  ///
  /// `SystemChrome.setEnabledSystemUIMode` 在桌面只隐藏状态栏，所以桌面由
  /// 平台侧去改真实窗口。返回 false 表示没有桌面插件，调用方应退回 Flutter
  /// 内部的「假全屏」并提示用户。
  static Future<bool> setFullscreen(bool on) async {
    try {
      final res = await _channel.invokeMethod<bool>(
        VideoChannelMethod.setFullscreen,
        on,
      );
      return res ?? false;
    } on PlatformException catch (_) {
      return false;
    } on MissingPluginException catch (_) {
      return false;
    }
  }

  /// 请宿主按平台能力把播放页转成横屏 / 还回去。
  ///
  /// `on == true`：
  /// - Android 切到 `SCREEN_ORIENTATION_SENSOR_LANDSCAPE`：只听加速度计与
  ///   陀螺仪，把机身从左侧横放翻到右侧横放，画面立刻跟着翻，不受系统
  ///   「自动旋转」开关影响。
  /// - iOS / iPadOS 向 window scene 请求横屏几何。Dart 侧的
  ///   `SystemChrome.setPreferredOrientations` 在 iPad 上不生效（系统要
  ///   自己分配窗口，程序无权转向），必须由宿主直接请求。
  ///
  /// `on == false`：Android 还回 `SCREEN_ORIENTATION_UNSPECIFIED`，iOS 请求
  /// 竖屏几何，都不再干预系统。
  ///
  /// 桌面端没有这个方法，`MissingPluginException` 会被吞掉。
  static Future<void> lockLandscape(bool on) async {
    try {
      await _channel.invokeMethod<void>(
        VideoChannelMethod.lockLandscape,
        on,
      );
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  static Future<void> destroy() async {
    _current = null;
    try {
      await _channel.invokeMethod<void>(VideoChannelMethod.destroyTexture);
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }
}
