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
    registry = controller.registrar(forPlugin: "lanplayer")?.textures()

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

      case "resizeTexture":
        // The texture is laid out by Flutter; nothing to resize natively.
        result(nil)

      case "destroyTexture":
        self.removeFrameCallback()
        if let tex = self.texture, let registry = self.registry {
          registry.unregisterTexture(tex.textureId)
        }
        self.texture = nil
        result(nil)

      case "setFullscreen":
        // macOS keeps its own fullscreen mode and owns the menu bar, so answer
        // false and let Dart fall back to the Flutter-only behaviour.
        result(false)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// The core notifies us from its decode thread; hop to the main thread before
  /// touching the Flutter texture registry.
  private func installFrameCallback() {
    guard let player else { return }
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    lp_player_install_frame_callback(
      player,
      { user in
        guard let user else { return }
        let delegate = Unmanaged<MainFlutterWindow>.fromOpaque(user).takeUnretainedValue()
        DispatchQueue.main.async {
          if let tex = delegate.texture, let registry = delegate.registry {
            registry.textureFrameAvailable(tex.textureId)
          }
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
  var player: OpaquePointer?
  var textureId: Int64 = -1

  init(player: OpaquePointer?) {
    self.player = player
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    guard let player, let buffer = lp_player_copy_pixel_buffer(player) else {
      return nil
    }
    // The core returns a +1 reference; Flutter takes ownership of it.
    return Unmanaged<CVPixelBuffer>.fromOpaque(buffer)
  }
}
