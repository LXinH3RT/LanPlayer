/// LanPlayer 的视频纹理桥。
///
/// 四份平台实现通过同一个方法通道把解码后的帧交给 Flutter：
///
/// ```
/// VideoTextureBridge（本包 lib/src/bridge.dart）
///         ↓  MethodChannel('lanplayer/video')
///   Windows  C++ 插件 → d3d11_output.c    （D3D11 共享纹理）
///   macOS    Swift 宿主 → apple_texture.c （CVPixelBuffer）
///   iOS      Swift 宿主 → apple_texture.c （CVPixelBuffer）
///   Android  Kotlin 宿主 → jni_bridge.c → egl_renderer.c（ANativeWindow）
/// ```
///
/// 这个包以前只有一句版本常量，真正的 API 长在 `app/lib/ui/video_texture.dart`
/// 里 —— 于是「通道叫什么、参数叫什么、返回什么」这份契约没有任何一处被完整
/// 写下过，四份宿主各自演进。现在契约在这里（`lib/src/channel.dart`），宿主
/// 只负责实现；`tool/check_all.py` 的 `check_video_bridge_contract()` 保证四份
/// 实现认同一套方法名。
library;

export 'src/bridge.dart';
export 'src/channel.dart';

/// 桥接契约的版本；与原生侧同步递增。
const String lanplayerVideoBridgeVersion = '1';
