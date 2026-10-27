import AVFoundation
import Flutter
import UIKit
import CoreVideo

/// iOS 26/27 SDK 起必须采用 UIScene 生命周期，否则启动时会命中
/// `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption` 的
/// EXC_BREAKPOINT。采用 scene 之后 Main.storyboard 不再在
/// `didFinishLaunching` 之前加载，所以这里自己持有一个 FlutterEngine：
/// 插件注册、纹理通道、窗口都由 scene 连接阶段驱动（见 SceneDelegate）。
@main
@objc class AppDelegate: FlutterAppDelegate {
  /// 全局唯一的引擎；SceneDelegate 用它创建 FlutterViewController。
  private(set) lazy var engine: FlutterEngine = FlutterEngine(name: "lanplayer")
  private var channel: FlutterMethodChannel?
  private var texture: PlayerTexture?
  private var player: OpaquePointer?
  /// 插件 registrar 与纹理注册表：**必须缓存**，不能每次重新取。
  /// `registrarForPlugin:` 对同名插件只允许调一次，第二次会走
  /// `NSAssertionHandler` → abort（真机日志里是 EXC_CRASH / SIGABRT，
  /// 栈顶 `-[FlutterEngine registrarForPlugin:]`）。
  private var registrar: FlutterPluginRegistrar?
  private var textures: FlutterTextureRegistry?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    configureAudioSession()
    // 先把引擎跑起来，插件注册才有 registrar 可用（否则 registrarForPlugin:
    // 返回 nil，Swift 插件里对不可选参数做类型检查会直接段错误）。
    engine.run()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 把音频会话切到「播放」类别。
  ///
  /// iOS 默认类别是 `ambient`：侧边静音开关拨到静音时整机不出声、锁屏或切到
  /// 后台时音频会被停掉 —— 这正是 iPad 上有画面没声音的原因。`playback` 类别
  /// 让音频走媒体音量、忽略静音开关，配合 Info.plist 的 `UIBackgroundModes:
  /// audio` 才能在锁屏后继续播。
  ///
  /// 反复调用是安全的：`setCategory` 幂等，`setActive` 在已激活时也是空操作。
  @discardableResult
  func configureAudioSession() -> Bool {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .moviePlayback, options: [])
      try session.setActive(true)
      // 留一条证据：没有它，真机上分不清「会话配上了但没声音」和「根本没配上」。
      // 输出走 syslog，`devicectl ... process launch --console` 能直接看到。
      let route = session.currentRoute.outputs
        .map { "\($0.portType.rawValue):\($0.portName)" }
        .joined(separator: ",")
      NSLog("LanPlayer audio session active category=\(session.category.rawValue) "
              + "mode=\(session.mode.rawValue) volume=\(session.outputVolume) "
              + "route=[\(route)]")
      // 启动那一刻的 outputVolume 还没刷新，三秒后再读一次并打出来。这条
      // 日志是给「有画面没声音」准备的：输出走 syslog，
      // `devicectl ... process launch --console` 能直接看到系统媒体音量是
      // 多少 —— 音量被人调到接近零时，从这里一眼就能看出来，不必去猜是
      // 会话没配上、还是解码没出数据。
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        let again = AVAudioSession.sharedInstance()
        let outs = again.currentRoute.outputs
          .map { "\($0.portType.rawValue):\($0.portName)" }
          .joined(separator: ",")
        NSLog("LanPlayer audio session recheck volume=\(again.outputVolume) "
                + "route=[\(outs)] sampleRate=\(again.sampleRate)")
      }
      return true
    } catch {
      // 音频会话配不上时不该拦住播放：画面照常出，只是声音可能受静音开关
      // 影响。所以这里只记日志。
      NSLog("LanPlayer audio session failed: \(error.localizedDescription)")
      return false
    }
  }

  /// 由 SceneDelegate 在 UIWindow 就绪之后调用：注册插件并建立纹理通道。
  func attach(to controller: FlutterViewController) {
    GeneratedPluginRegistrant.register(with: engine)

    // 注意：`registrarForPlugin:` 对同一个插件名只能取一次，第二次会触发
    // NSAssertionHandler 直接 abort（实测是 EXC_CRASH / SIGABRT）。所以这里
    // 取一次存下来，后面所有地方复用。
    let reg = engine.registrar(forPlugin: "lanplayer")
    registrar = reg
    textures = reg?.textures()

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
        guard let registry = self.textures else {
          result(FlutterError(code: "no-registry", message: nil, details: nil))
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
        // 纹理的尺寸由 Flutter 侧布局决定，原生侧无需处理。
        result(nil)
      case "destroyTexture":
        self.removeFrameCallback()
        if let tex = self.texture {
          self.textures?.unregisterTexture(tex.textureId)
        }
        self.texture = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 内核在解码线程回调，这里切回主线程再动 Flutter 的纹理注册表。
  private func installFrameCallback() {
    guard let player else { return }
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    lp_player_install_frame_callback(player, { user in
      guard let user else { return }
      let delegate = Unmanaged<AppDelegate>.fromOpaque(user).takeUnretainedValue()
      DispatchQueue.main.async {
        if let tex = delegate.texture {
          delegate.textures?.textureFrameAvailable(tex.textureId)
        }
      }
    }, ctx)
  }

  private func removeFrameCallback() {
    guard let player else { return }
    lp_player_install_frame_callback(player, nil, nil)
  }
}

/// 最小的 UIScene 适配：创建窗口、把 FlutterViewController 放到根上，
/// 然后把插件注册交给 AppDelegate（引擎已在 didFinishLaunching 里启动）。
@objc class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let win = UIWindow(windowScene: windowScene)
    window = win

    guard let app = UIApplication.shared.delegate as? AppDelegate else { return }
    let controller = FlutterViewController(
      engine: app.engine, nibName: nil, bundle: nil)
    win.rootViewController = controller
    win.makeKeyAndVisible()

    app.attach(to: controller)
  }

  /// 来电、闹钟、其它 app 抢过音频之后，系统的「播放」类别会被取消激活；
  /// 回到前台时再激活一次，否则下次播放会没有声音。
  func sceneDidBecomeActive(_ scene: UIScene) {
    (UIApplication.shared.delegate as? AppDelegate)?.configureAudioSession()
  }
}

/// 把内核给出的 CVPixelBuffer 零拷贝交给 Flutter 纹理：像素缓冲是
/// IOSurface 支持的，直接让引擎读取即可。
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
    // 内核返回的是 +1 引用，所有权转交 Flutter。
    return Unmanaged<CVPixelBuffer>.fromOpaque(buffer)
  }
}
