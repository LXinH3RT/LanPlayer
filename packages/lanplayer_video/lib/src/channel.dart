/// 平台通道的名字与每个方法的参数形状。
///
/// 这一层是「三个宿主共用的契约」：Windows 的 C++ 插件、macOS 的 Swift 宿主、
/// iOS 的 Swift 宿主都注册同名通道、认同名方法、读同名参数。以前这份契约只
/// 存在于三处 `switch (method)` 里，改一个键名要三边同时改，漏掉一边的症状是
/// 运行时 `MissingPluginException` 或一个静默为 0 的字段。
///
/// 现在键名只写在这里，Dart 侧的调用点也跟着用；原生侧由
/// `tool/check_all.py` 的 `check_video_bridge_contract()` 钉住「三份宿主都认
/// 这些方法名」。
library;

/// 通道名。三个宿主与 Dart 侧都必须用它。
const String lanplayerVideoChannel = 'lanplayer/video';

/// 移动端视频输出的平台视图类型名。
///
/// Android 侧注册同一个字符串（`VideoSurfaceView.VIEW_TYPE`）。名字对不上时
/// 现象是「一块永远黑的区域」，没有任何异常，所以 `tool/check_all.py` 会逐字
/// 比对两边的字面量。
///
/// 为什么移动端不用纹理而用平台视图：Flutter 引擎只要看到有活跃的外部纹理，
/// 就会在每个 vsync 上重绘整棵 layer tree，与纹理有没有更新无关。120 Hz 屏幕
/// 放 30 fps 内容时四分之三的合成是白做的，而这条约束在引擎层面没有开关
/// （`flutter/flutter#188616`、`flutter/flutter#192181`）。SurfaceView 的
/// Surface 由系统合成器直接叠加，完全不进引擎的合成循环。
const String lanplayerVideoSurfaceViewType = 'dev.lanplayer/video_surface';

/// `createTexture` 的返回键。
abstract final class TextureReplyKey {
  /// 平台侧注册的 Flutter 纹理 id；[platformView] 为真时是 -1。
  static const String textureId = 'textureId';

  /// 原生窗口指针；0 表示「内核直接投递帧」，见 [TextureWindowPtr.inProcess]。
  static const String window = 'window';

  /// 真：这块画面由平台视图提供，Dart 侧应建 `VideoSurfaceView` 而不是
  /// `Texture`。Android 目前总是如此。
  static const String platformView = 'platformView';
}

/// `createTexture` 的参数键，以及它们的默认值（与原生侧一致）。
abstract final class TextureRequestKey {
  static const String width = 'width';
  static const String height = 'height';

  /// 没传尺寸时的回退值。播放器总会显式传，这两个默认值只服务于
  /// 「先建纹理、后拿到视频尺寸」的调用点。
  static const int defaultWidth = 1920;
  static const int defaultHeight = 1080;
}

/// `attachPlayer` 的参数键：内核句柄的地址。
const String attachPlayerKey = 'player';

/// `createTexture` 返回的 `window` 字段的特殊值。
abstract final class TextureWindowPtr {
  /// 非 0：Android，平台给出的是 `ANativeWindow*`，内核直接把像素画进去。
  /// 这时 Dart 侧必须把指针交给 `lp_player_set_surface`。
  ///
  /// 0：Windows / iOS / macOS，内核把帧交给平台插件（D3D11 共享纹理或
  /// CVPixelBuffer），Dart 侧不要调 `lp_player_set_surface`，否则内核会往一个
  /// 不存在的窗口上画。
  static const int inProcess = 0;
}

/// 通道上出现过的方法名。原生侧认的就是这几个。
abstract final class VideoChannelMethod {
  static const String createTexture = 'createTexture';
  static const String attachPlayer = 'attachPlayer';
  static const String destroyTexture = 'destroyTexture';
  static const String setFullscreen = 'setFullscreen';

  /// 请宿主把播放页转成横屏（`true`）以后再还回去（`false`）。
  ///
  /// 各平台的做法不同，因为「窗口朝向」在它们那里不是同一件事：
  ///
  /// - Android：`SystemChrome.setPreferredOrientations` 把「左右两个横屏」
  ///   翻译成 `SCREEN_ORIENTATION_FULL_USER`，而 FULL_USER 仍然受系统那个
  ///   「自动旋转」开关管 —— 用户在控制中心关掉自动旋转之后，播放页就再也
  ///   转不过来。原生的 `SCREEN_ORIENTATION_SENSOR_LANDSCAPE` 不听那个开关，
  ///   只听加速度计与陀螺仪，所以走这条通道切过去。
  /// - iOS / iPadOS：`SystemChrome.setPreferredOrientations` 在 iPad 上**不
  ///   生效**。Flutter 文档原话是 "This setting will only be respected on iPad
  ///   if multitasking is disabled"；而 iPadOS 26 起所有 app 都跑在可调整大小
  ///   的窗口里，`UIRequiresFullScreen` 也已经不起作用（实测：加上它之后
  ///   `devicectl device info displays` 仍报 `Main display orientation:
  ///   portrait`）。于是由宿主自己向 window scene 发
  ///   `requestGeometryUpdate(.iOS(interfaceOrientations:))`。
  ///
  /// 桌面端不认这个方法，`MissingPluginException` 被静默吞掉。
  static const String lockLandscape = 'lockLandscape';
}
