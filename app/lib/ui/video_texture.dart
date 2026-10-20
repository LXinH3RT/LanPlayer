import 'dart:ffi';

import 'package:flutter/services.dart';

/// A video texture created by the platform side.
///
/// Android: [windowPtr] is an ANativeWindow* the native core draws into (EGL
/// for software decode, MediaCodec for hardware decode).
/// iOS/macOS: [windowPtr] is 0; the core publishes CVPixelBuffers and the
/// Swift FlutterTexture pulls them.
class VideoTexture {
  const VideoTexture(
      {required this.textureId,
      required this.windowPtr,
      required this.width,
      required this.height});

  final int textureId;
  final int windowPtr;
  final int width;
  final int height;
}

class VideoTextureBridge {
  static const MethodChannel _channel = MethodChannel('lanplayer/video');

  static VideoTexture? _current;

  static VideoTexture? get current => _current;

  static Future<VideoTexture?> create(
      {int width = 1920, int height = 1080}) async {
    try {
      final map =
          await _channel.invokeMapMethod<String, dynamic>('createTexture', {
        'width': width,
        'height': height,
      });
      if (map == null) return null;
      final tex = VideoTexture(
        textureId: (map['textureId'] as num?)?.toInt() ?? -1,
        windowPtr: (map['window'] as num?)?.toInt() ?? 0,
        width: width,
        height: height,
      );
      _current = tex;
      return tex;
    } on PlatformException catch (_) {
      return null;
    } on MissingPluginException catch (_) {
      // Desktop / test host without the platform channel.
      return null;
    }
  }

  /// Tells the platform side which native player to bridge (iOS only needs it).
  static Future<void> attachPlayer(Pointer<Void>? player) async {
    if (player == null) return;
    try {
      await _channel
          .invokeMethod<void>('attachPlayer', {'player': player.address});
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  static Future<void> resize(int width, int height) async {
    try {
      await _channel.invokeMethod<void>(
          'resizeTexture', {'width': width, 'height': height});
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  /// Toggles the desktop window between windowed and fullscreen.
  ///
  /// `SystemChrome.setEnabledSystemUIMode` only hides the status bar on mobile,
  /// so on desktop the platform side resizes the real window.  Returns whether
  /// the host accepted the request; false means there is no desktop plugin and
  /// the caller should fall back to the Flutter-only behaviour.
  static Future<bool> setFullscreen(bool on) async {
    try {
      final res = await _channel.invokeMethod<bool>('setFullscreen', on);
      return res ?? false;
    } on PlatformException catch (_) {
      return false;
    } on MissingPluginException catch (_) {
      return false;
    }
  }

  static Future<void> destroy() async {
    _current = null;
    try {
      await _channel.invokeMethod<void>('destroyTexture');
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }
}
