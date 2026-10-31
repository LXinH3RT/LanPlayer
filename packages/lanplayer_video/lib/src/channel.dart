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

/// `createTexture` 的返回键。
abstract final class TextureReplyKey {
  /// 平台侧注册的 Flutter 纹理 id。
  static const String textureId = 'textureId';

  /// 原生窗口指针；0 表示「内核直接投递帧」，见 [TextureWindowPtr.inProcess]。
  static const String window = 'window';
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
}
