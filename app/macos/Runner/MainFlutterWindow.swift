import Cocoa
import CoreVideo
import FlutterMacOS

// LanPlayer macOS host.
//
// This mirrors app/ios/Runner/AppDelegate.swift: it registers the same
// `lanplayer/video` method channel and hands the core's CVPixelBuffer frames
// straight to the Flutter texture registry, so app/lib/ui/video_texture.dart
// runs unchanged on both Apple targets.
//
// The `lp_*` declarations come from Runner/Runner-Bridging-Header.h, which
// Runner.xcodeproj points at via SWIFT_OBJC_BRIDGING_HEADER.  The core itself is
// a static library (native/CMakeLists.txt builds it with BUILD_SHARED_LIBS=OFF
// on Apple), linked in through OTHER_LDFLAGS in Flutter/Flutter-*.xcconfig.
class MainFlutterWindow: NSWindow {
  private var channel: FlutterMethodChannel?
  private var registry: FlutterTextureRegistry?
  private var texture: PlayerTexture?
  private var player: OpaquePointer?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    installVideoChannel(controller: flutterViewController)

    super.awakeFromNib()
  }

  private func installVideoChannel(controller: FlutterViewController) {
    // macOS 的 API 与 iOS 不同，这里两处都不通用：
    //   1. `registrarForPlugin:` 在 FlutterPluginRegistry 协议里标的是 nonnull，
    //      Swift 侧不带 `?`，写 `?.` 会报
    //        error: cannot use optional chaining on non-optional value
    //   2. macOS 的 registrar 把纹理注册表暴露成【属性】`textures`
    //      （FlutterPluginRegistrarMacOS.h:39），不是 iOS 那样的 `textures()` 方法，
    //      写 `textures()` 会报
    //        error: cannot call value of non-function type 'any FlutterTextureRegistry'
    registry = controller.registrar(forPlugin: "lanplayer").textures

    let ch = FlutterMethodChannel(
      name: "lanplayer/video",
      binaryMessenger: controller.engine.binaryMessenger)
    channel = ch
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "gone", message: nil, details: nil))
        return
      }
      switch call.method {
      case "createTexture":
        guard let registry = self.registry else {
          result(
            FlutterError(
              code: "no-registry", message: "texture registry unavailable", details: nil))
          return
        }
        let tex = PlayerTexture(player: self.player)
        let textureId = registry.register(tex)
        tex.textureId = textureId
        self.texture = tex
        result(["textureId": textureId, "window": 0])

      case "attachPlayer":
        let args = call.arguments as? [String: Any]
        if let raw = args?["player"] as? Int {
          self.player = OpaquePointer(bitPattern: raw)
          self.texture?.player = self.player
          self.installFrameCallback()
        }
        result(nil)

      case "destroyTexture":
        self.removeFrameCallback()
        if let tex = self.texture, let registry = self.registry {
          // 先摘指针再注销：注销之后引擎不会再调 copyPixelBuffer，而 detach
          // 会等已经进去的那一次返回。Dart 侧是 await 这个方法之后才释放
          // 播放器，所以到这里返回时，内核对象已经没人引用了。
          tex.detach()
          registry.unregisterTexture(tex.textureId)
        }
        self.texture = nil
        result(nil)

      case "setFullscreen":
        // Windows 侧是自己改窗口 style；macOS 上必须走 AppKit 的原生全屏，
        // 只改 styleMask 会让菜单栏和 Dock 留在原地，用户按 F11 看到的
        // 只是一个铺满屏幕但还带着标题栏的窗口。
        let on = (call.arguments as? Bool) ?? false
        self.setWindowFullscreen(on)
        result(true)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 真正的全屏：走 AppKit 的 `toggleFullScreen`，让系统把菜单栏、Dock 和
  /// 标题栏一起收走，退出时再原样还原尺寸与位置。
  ///
  /// 这里不用改 `styleMask` 的老办法 —— Windows 那套 `WS_POPUP` 搬到 macOS 上
  /// 只会得到一个铺满屏幕但菜单栏还压在顶上的窗口，用户看不出区别。
  private func setWindowFullscreen(_ on: Bool) {
    // 成员名是 `.fullScreen`（大写 S）。写成 `.fullscreen` 时 AppKit 里没有
    // 这个成员，swiftc 报 "type 'NSWindow.StyleMask' has no member 'fullscreen'"。
    if on == styleMask.contains(.fullScreen) {
      return
    }
    toggleFullScreen(nil)
  }

  /// The core notifies us from its decode thread. `textureFrameAvailable` is
  /// documented to be safe from any thread ("This will trigger a call to
  /// -copyPixelBuffer on the raster thread"), so it is called directly —
  /// hopping through DispatchQueue.main.async added a whole main-runloop
  /// worth of latency to every single frame, and on a busy main thread the
  /// core had already replaced the single pixel buffer slot before the
  /// notification even arrived. That is what made video stutter while audio
  /// stayed smooth.
  private func installFrameCallback() {
    guard let player else { return }
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    lp_player_install_frame_callback(
      player,
      { user in
        guard let user else { return }
        let delegate = Unmanaged<MainFlutterWindow>.fromOpaque(user).takeUnretainedValue()
        if let tex = delegate.texture, let registry = delegate.registry {
          registry.textureFrameAvailable(tex.textureId)
        }
      }, ctx)
  }

  private func removeFrameCallback() {
    guard let player else { return }
    lp_player_install_frame_callback(player, nil, nil)
  }
}

/// Bridges CVPixelBufferRef frames from the core into a Flutter texture with no
/// copy: the pixel buffer is IOSurface backed and handed straight to the engine.
final class PlayerTexture: NSObject, FlutterTexture {
  /// 播放器裸指针只在主线程赋值、在 raster 线程读，所以走同一把锁。
  /// 以前它是普通存储属性：主线程释放播放器与 raster 线程取帧之间没有任何
  /// 同步，取帧那一侧可能正好锁在已销毁的 mutex 上。
  private let lock = NSLock()
  private var storedPlayer: OpaquePointer?

  var player: OpaquePointer? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedPlayer
    }
    set {
      lock.lock()
      storedPlayer = newValue
      lock.unlock()
    }
  }

  var textureId: Int64 = -1

  init(player: OpaquePointer?) {
    self.storedPlayer = player
  }

  /// 释放播放器之前调用。锁在这里不只是防数据竞争：它保证已经进到
  /// copyPixelBuffer 里的那一次调用走完，之后内核对象才可以被 free。
  func detach() {
    lock.lock()
    storedPlayer = nil
    lock.unlock()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    // 整段持有锁：先取指针、再调内核，两步之间不能被 detach 挤进来。
    lock.lock()
    defer { lock.unlock() }
    guard let player = storedPlayer, let buffer = lp_player_copy_pixel_buffer(player) else {
      return nil
    }
    // The core returns a +1 reference; Flutter takes ownership of it.
    return Unmanaged<CVPixelBuffer>.fromOpaque(buffer)
  }
}
