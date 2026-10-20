import Flutter
import UIKit
import CoreVideo

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var channel: FlutterMethodChannel?
  private var texture: PlayerTexture?
  private var player: OpaquePointer?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    let ch = FlutterMethodChannel(
      name: "lanplayer/video", binaryMessenger: controller.binaryMessenger)
    channel = ch
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "gone", message: nil, details: nil))
        return
      }
      switch call.method {
      case "createTexture":
        let registry = self.registrar(forPlugin: "lanplayer")!.textures()
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
        if let tex = self.texture {
          self.registrar(forPlugin: "lanplayer")?.textures().unregisterTexture(tex.textureId)
        }
        self.texture = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// The core notifies us from its decode thread; hop to the main thread before
  /// touching the Flutter texture registry.
  private func installFrameCallback() {
    guard let player else { return }
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    lp_player_install_frame_callback(player, { user in
      guard let user else { return }
      let delegate = Unmanaged<AppDelegate>.fromOpaque(user).takeUnretainedValue()
      DispatchQueue.main.async {
        if let tex = delegate.texture {
          delegate.registrar(forPlugin: "lanplayer")?.textures().textureFrameAvailable(tex.textureId)
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
