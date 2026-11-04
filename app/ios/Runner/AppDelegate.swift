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
  private var player: OpaquePointer?
  /// 画面帧的去处。iOS 从 0.1.9 起不再注册外部纹理，改为把每帧塞进
  /// `AVSampleBufferDisplayLayer`（见 VideoPlatformView.swift）。
  ///
  /// 内核的帧回调只有一个槽位（`native/src/core/player.c` 里
  /// `p->vout.frame_cb` 是单字段赋值），所以「纹理取帧」和「显示层推帧」
  /// 这两条路不能同时存在，这里必须二选一。
  let videoBridge = VideoFrameBridge()
  /// 插件 registrar：**必须缓存**，不能每次重新取。
  /// `registrarForPlugin:` 对同名插件只允许调一次，第二次会走
  /// `NSAssertionHandler` → abort（真机日志里是 EXC_CRASH / SIGABRT，
  /// 栈顶 `-[FlutterEngine registrarForPlugin:]`）。
  ///
  /// iOS 侧不再持有 `FlutterTextureRegistry`：画面改由平台视图显示之后，
  /// 这里既没有纹理要注册，也没有 `textureFrameAvailable` 要通知。
  private var registrar: FlutterPluginRegistrar?
  /// 最近一次「播放页要不要横屏」的请求。scene 尚未接好窗口时请求会被系统
  /// 丢掉，靠它在前台之后补发，见 applyPendingOrientation()。
  private var pendingLandscape: Bool?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    configureAudioSession()
    observeAudioSession()
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

  /// 监听音频会话被抢走与归还。
  ///
  /// 只在前台重新激活一次是不够的：来电、闹钟、别的 app 起 Siri 都会把会话
  /// 置为「被中断」，系统在中断期间把它停掉；中断结束后**不会**自己恢复成
  /// 激活状态，必须重设一次 `.playback`。少了这一段，用户接完电话回到 app
  /// 看到的是画面在走、声音没有了 —— 而且只有杀进程重进才能恢复。
  ///
  /// `mediaServicesWereReset` 是另一种情况：音频服务崩溃重启之后，所有会话
  /// 对象作废，同样要重新配置一遍。
  func observeAudioSession() {
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(handleInterruption(_:)),
      name: AVAudioSession.interruptionNotification, object: nil)
    center.addObserver(
      self, selector: #selector(handleMediaServicesReset(_:)),
      name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
  }

  @objc private func handleInterruption(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else {
      return
    }
    guard type == .ended else {
      // 中断开始：系统自己会停音频，这里不主动暂停播放。播放状态归 Dart 侧
      // 管（切后台暂停在 player_screen 的 lifecycle 回调查里做），在这边再
      // 暂停一次会把「来电挂断后接着播」变成「得手动按播放」。
      return
    }
    var options = AVAudioSession.InterruptionOptions()
    if let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
      options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
    }
    // 只有系统说「可以继续」时才抢回来；否则用户可能正在接电话。
    if options.contains(.shouldResume) {
      configureAudioSession()
    }
  }

  @objc private func handleMediaServicesReset(_ note: Notification) {
    _ = note
    configureAudioSession()
  }

  /// 由 SceneDelegate 在 UIWindow 就绪之后调用：注册插件并建立纹理通道。
  func attach(to controller: FlutterViewController) {
    GeneratedPluginRegistrant.register(with: engine)

    // 注意：`registrarForPlugin:` 对同一个插件名只能取一次，第二次会触发
    // NSAssertionHandler 直接 abort（实测是 EXC_CRASH / SIGABRT）。所以这里
    // 取一次存下来，后面所有地方复用。
    let reg = engine.registrar(forPlugin: "lanplayer")
    registrar = reg
    // 画面走平台视图：把视图工厂挂到 registrar 上，Dart 侧按同样的类型名创建。
    // 类型名的字面量定义在 VideoPlatformView.swift 里，与 Dart 的
    // `lanplayerVideoSurfaceViewType` 逐字相同。
    reg?.register(
      VideoPlatformViewFactory(bridge: videoBridge),
      withId: lanplayerVideoSurfaceViewType)

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
        // 名字还叫 createTexture（Dart 侧与另外三个宿主共用一套方法名），
        // 但 iOS 不再注册外部纹理：`textureId: -1` + `platformView: true`
        // 让 Dart 侧走平台视图那条路，画面由 AVSampleBufferDisplayLayer 显示。
        //
        // 为什么放弃纹理：引擎只要看到有活跃的外部纹理就每个 vsync 重绘整棵
        // layer tree（flutter/flutter#188616、#192181），120 Hz 屏放 30 fps
        // 内容时四次合成里三次在重绘同一张图 —— 这就是「音频正常、画面卡顿」
        // 的根，与解码快慢无关。
        result(["textureId": -1, "window": 0, "platformView": true])
      case "attachPlayer":
        let args = call.arguments as? [String: Any]
        if let raw = args?["player"] as? Int {
          self.player = OpaquePointer(bitPattern: raw)
          self.videoBridge.bind(player: self.player)
        }
        result(nil)
      case "destroyTexture":
        // 先把播放器从显示层那条路上摘下来，再让 Dart 释放它：回调里会读
        // 裸指针，晚一步就是 use-after-free。
        self.videoBridge.unbind()
        self.player = nil
        result(nil)
      case "lockLandscape":
        self.requestOrientation(landscape: (call.arguments as? Bool) ?? false)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 把当前窗口转成横屏（`landscape == true`）或还回竖屏。
  ///
  /// 为什么不用 `SystemChrome.setPreferredOrientations`：在 iPad 上那条路
  /// 不生效。Flutter 文档写得很清楚 —— "This setting will only be respected
  /// on iPad if multitasking is disabled"；而 iPadOS 26 起窗口一律由系统按
  /// 可调整大小窗口分配，`UIRequiresFullScreen` 也被忽略了（实测加上它之后
  /// `devicectl device info displays` 仍报 `Main display orientation:
  /// portrait`）。想在 iPad 上真正把窗口转横，只能自己发几何请求。
  ///
  /// iOS 16 起用 `requestGeometryUpdate`：系统接受后会把 scene 的尺寸一起
  /// 调整，FlutterViewController 随窗口重排，画面自然铺满。
  /// iOS 15 及以下没有这个 API，退回到 `attemptRotationToDeviceOrientation`，
  /// 配合 Dart 侧已经下发的 `setPreferredOrientations` 生效。
  ///
  /// 两个方向都请求 `.landscape`（左右都允许）：把机身从一侧翻到另一侧时，
  /// 系统自己按设备朝向在左右之间切换，这才是「跟着陀螺仪转」。
  private func requestOrientation(landscape: Bool, attempt: Int = 0) {
    // 记下这次请求：scene 还没接好窗口时请求会被系统直接丢掉，得等到
    // `sceneDidBecomeActive` 再补发一次，见 applyPendingOrientation()。
    pendingLandscape = landscape
    guard let scene = activeWindowScene() else {
      NSLog("LanPlayer orientation: no window scene to ask (landscape=\(landscape))")
      return
    }
    // 先更新「这个窗口支持哪些方向」，否则系统会因为不支持目标方向而拒绝
    // 几何请求。iOS 16 起这个方法才存在。
    if #available(iOS 16.0, *) {
      // scene 还没 attach 时 requestGeometryUpdate 会被静默丢弃（连失败回调
      // 都不会调）。播放页是在引擎启动后第一帧就打开的，那一刻 scene 往往
      // 还在连接中，所以这里要等它进入 foregroundActive 再发。
      guard scene.activationState == .foregroundActive else {
        if attempt < 24 {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.requestOrientation(landscape: landscape, attempt: attempt + 1)
          }
        } else {
          NSLog("LanPlayer orientation: scene never became active "
                  + "(state=\(scene.activationState.rawValue)); request dropped")
        }
        return
      }
      let prefs = UIWindowScene.GeometryPreferences.iOS(
        interfaceOrientations: landscape ? .landscape : .portrait)
      let root = scene.keyWindow?.rootViewController
      let vcMask = root?.supportedInterfaceOrientations.rawValue ?? 0
      let win = scene.keyWindow
      let bounds = win?.bounds ?? .zero
      // iPadOS 26 起窗口由系统分配：只在「scene 居中、与屏幕同尺寸、未被遮挡」
      // 三项都成立时才允许锁定界面方向（见 UIViewController.h 的
      // prefersInterfaceOrientationLocked）。所以日志里要把屏幕尺寸与窗口实际
      // frame 一起打出来，才能分清「系统拒绝方向」和「窗口不是全屏」；
      // `requestGeometryUpdate` 的成功不回调，只有失败才回调，前后两次尺寸对比
      // 是唯一能证明请求生效的证据。
      //
      // 方向锁状态本身（`UIWindowScene.Geometry.isInterfaceOrientationLocked`）
      // 读不到：它随 iPadOS 26 的 SDK 一起出现，而 CI 与多数开发机的 iOS SDK
      // 还停在 18.x；`#available` 只挡运行期，挡不住编译期对这个成员的解析，
      // 会直接把整个 iOS 构建打红。这里只留尺寸证据。
      let screen = scene.screen.bounds
      NSLog("LanPlayer orientation: requesting geometry (landscape=\(landscape), "
              + "attempt=\(attempt), scene=\(scene.activationState.rawValue), "
              + "interfaceOrientation=\(scene.interfaceOrientation.rawValue), "
              + "vcMask=\(vcMask), windows=\(scene.windows.count), "
              + "screen=\(Int(screen.width))x\(Int(screen.height)), "
              + "frame=\(Int(bounds.width))x\(Int(bounds.height)))")
      // 关键顺序：先让 FlutterViewController 放开对目标方向的支持，再请求几何。
      // 反过来的话系统看到「当前窗口只支持竖屏」，直接把这个请求丢掉。
      root?.setNeedsUpdateOfSupportedInterfaceOrientations()
      scene.requestGeometryUpdate(prefs) { error in
        // 请求被拒绝时留下证据：真机上分不清「没转」和「请求没发出去」。
        NSLog("LanPlayer orientation: geometry request failed: "
                + "\(error.localizedDescription)")
      }
      // 请求已经交给系统，别让下次前台再补发一遍。
      pendingLandscape = nil
      // 记一行结果：`requestGeometryUpdate` 成功时没有任何回调，只靠前后尺寸
      // 对比才能证明请求真的生效。隔三秒读，避开动画的中间态（半秒时窗口往往
      // 还在过渡，读到的是旧尺寸）。
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
        guard let s = self?.activeWindowScene() else { return }
        let b = s.keyWindow?.bounds ?? .zero
        NSLog("LanPlayer orientation: after request (landscape=\(landscape), "
                + "interfaceOrientation=\(s.interfaceOrientation.rawValue), "
                + "frame=\(Int(b.width))x\(Int(b.height)))")
      }
    } else {
      UIDevice.current.setValue(
        landscape ? UIInterfaceOrientation.landscapeRight.rawValue
                  : UIInterfaceOrientation.portrait.rawValue,
        forKey: "orientation")
      UIViewController.attemptRotationToDeviceOrientation()
    }
  }

  /// 取当前前台窗口所在的 scene。
  ///
  /// 多 scene 是关闭的（Info.plist 里 `UIApplicationSupportsMultipleScenes`
  /// 为 false），所以这里只会有一个窗口 scene；它可能还没进入
  /// `.foregroundActive`（启动瞬间就是），调用方要自己判断。
  private func activeWindowScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
  }

  /// 前台之后补发一次被丢掉的横屏请求。
  ///
  /// 播放页可能在 scene 进入 `.foregroundActive` 之前就打开（引擎起来得比
  /// 窗口快），那一刻 `requestGeometryUpdate` 会被系统静默丢弃 —— 实测连
  /// 失败回调都不触发，日志里只有一行 requesting geometry 就没了。
  func applyPendingOrientation() {
    guard let want = pendingLandscape else { return }
    requestOrientation(landscape: want)
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
    let app = UIApplication.shared.delegate as? AppDelegate
    app?.configureAudioSession()
    // 启动瞬间 scene 还没接好，那次横屏请求会被系统丢掉，这里补发。
    app?.applyPendingOrientation()
  }
}
