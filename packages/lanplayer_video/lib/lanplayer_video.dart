/// LanPlayer 的视频输出桥。
///
/// 桌面端（Windows / macOS）通过方法通道把解码后的帧交给 Flutter 外部纹理：
///
/// ```
/// VideoTextureBridge（本包 lib/src/bridge.dart）
///         ↓  MethodChannel('lanplayer/video')
///   Windows  C++ 插件 → d3d11_output.c    （D3D11 共享纹理）
///   macOS    Swift 宿主 → apple_texture.c （CVPixelBuffer）
///   iOS      Swift 宿主 → apple_texture.c （CVPixelBuffer）
/// ```
///
/// Android 不走纹理：画面由 `SurfaceView` 直接提供，经平台视图嵌进 Flutter
/// （见 `lib/src/surface_view.dart`）。原因是引擎只要看到有活跃的外部纹理就会
/// 在每个 vsync 上重绘整棵 layer tree，与纹理有没有更新无关 —— 120 Hz 屏幕放
/// 30 fps 内容时四分之三的合成是白做的，而 SurfaceView 由系统合成器直接叠加，
/// 不进引擎的合成循环。
///
/// 这个包以前只有一句版本常量，真正的 API 长在 `app/lib/ui/video_texture.dart`
/// 里 —— 于是「通道叫什么、参数叫什么、返回什么」这份契约没有任何一处被完整
/// 写下过，四份宿主各自演进。现在契约在这里（`lib/src/channel.dart`），宿主
/// 只负责实现；`tool/check_all.py` 的 `check_video_bridge_contract()` 保证四份
/// 实现认同一套方法名，也保证平台视图的类型名两边逐字相同。
library;

export 'src/bridge.dart';
export 'src/channel.dart';
export 'src/surface_view.dart';

/// 桥接契约的版本；与原生侧同步递增。
const String lanplayerVideoBridgeVersion = '2';
