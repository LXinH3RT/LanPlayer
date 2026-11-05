import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import UIKit

/// 平台视图的 view 类型。必须与 Dart 侧
/// `lanplayerVideoSurfaceViewType`（packages/lanplayer_video/lib/src/channel.dart）
/// 逐字相同 —— 两边不一致时 Flutter 会在创建视图时抛
/// "Trying to create a platform view of unknown type"。
let lanplayerVideoSurfaceViewType = "dev.lanplayer/video_surface"

/// 内核帧回调到显示层之间的桥。
///
/// 内核的帧回调只有**一个**槽位（`native/src/core/player.c` 里
/// `p->vout.frame_cb` 是单字段赋值，后装覆盖先装），所以同一时刻只能有一条
/// 取帧路径。iOS 从这条路径改为显示层推帧之后，纹理侧不再注册，两者不会
/// 争抢；但换播放器时必须先摘旧播放器上的回调再装到新的上面，否则新播放器
/// 的 vout 上根本没有回调。
final class VideoFrameBridge {
  private let lock = NSLock()
  private weak var target: VideoDisplayView?
  private var storedPlayer: OpaquePointer?
  /// 回调当前装在哪个播放器上。与 `storedPlayer` 分开记，是因为摘回调必须
  /// 摘在「当初装的那个播放器」上，而不是现在这个。
  private var installedOn: OpaquePointer?

  /// 视频帧的格式描述按分辨率缓存：每帧都重建一次 `CMVideoFormatDescription`
  /// 是纯浪费，而分辨率在播放期间基本不变（换片时会变，所以要校验宽高）。
  private var format: CMVideoFormatDescription?
  private var formatWidth = 0
  private var formatHeight = 0
  /// 内核不对外暴露 PTS，宿主只能自己数；配合
  /// `kCMSampleAttachmentKey_DisplayImmediately` 使用，时间戳实际不参与
  /// 显示调度（见 AVSampleBufferDisplayLayer.h 对 enqueueSampleBuffer: 的说明）。
  private var frameIndex: Int64 = 0
  private var delivered: Int = 0
  private var dropped: Int = 0
  private var loggedOnce = false

  /// 视图挂上来。播放器可能已经就绪（先 attachPlayer 后建视图），也可能还没
  /// （先建视图后 attachPlayer），两条顺序都要能正常工作。
  func attach(_ view: VideoDisplayView) {
    lock.lock()
    target = view
    installLocked()
    lock.unlock()
  }

  /// 视图要销毁了：先摘目标再摘内核回调，避免回调落到已释放的视图上。
  ///
  /// 只有「退掉的正是当前目标」时才摘回调。路由切换时引擎可能先建好新视图
  /// 再销毁旧的：此时 `target` 已经是新视图，若照旧无条件摘回调，新视图就
  /// 再也收不到帧 —— 表现是切一次页面之后画面永久停住，而音频照常。
  func detach(_ view: VideoDisplayView) {
    lock.lock()
    guard target === view else {
      lock.unlock()
      return
    }
    target = nil
    // 视图没了就没人接收帧了，回调留着一来白跑、二来会把内核单槽里的帧
    // 消费掉，症状是「音频继续、画面再也不更新」。
    uninstallLocked()
    lock.unlock()
  }

  /// 播放器就位或换人（对应 Dart 侧的 attachPlayer）。
  ///
  /// 摘旧回调与换指针在同一个临界区内完成。分开做会留下一个窗口：`storedPlayer`
  /// 先换成新的，旧播放器上的回调却还没摘，它一旦再进 [deliver]，取的就是
  /// **新**播放器的帧 —— 帧会串到错误的对象上，并把新播放器单槽里的那帧白白
  /// 消费掉，让真正的投递丢一帧。
  func bind(player: OpaquePointer?) {
    lock.lock()
    // 摘的必须是当初装的那个指针：对新的播放器调 install(nil) 什么也摘不掉。
    uninstallLocked()
    storedPlayer = player
    installLocked()
    lock.unlock()
  }

  /// 播放器即将释放（对应 Dart 侧的 destroyTexture）：必须先摘回调，
  /// 否则内核会在已释放的桥对象上回调。
  ///
  /// 摘回调与清 `storedPlayer` 必须在**同一个临界区**内完成。分成两步会留下
  /// 一个窗口：内核解码线程可能已经取到回调函数指针、正要进 [deliver]，此
  /// 时 `storedPlayer` 仍非空，它就继续调 `lp_player_copy_pixel_buffer`；而
  /// Dart 侧 `destroyTexture` 一返回就 `dispose()` 掉播放器，这一取就是
  /// use-after-free。合成一步之后，凡是拿过锁的 `deliver` 必然已经跑完取帧，
  /// 没进锁的则一定看到 nil 而直接返回。
  ///
  /// 原来的 `PlayerTexture.detach()` 靠的就是这条不变量（见
  /// app/lib/ui/player_screen.dart 的 `_releaseTextureThenPlayer` 注释）。
  func unbind() {
    lock.lock()
    uninstallLocked()
    storedPlayer = nil
    lock.unlock()
  }

  /// 装上内核帧回调（若还没装）。**调用方必须持锁**。
  ///
  /// 状态变更与内核调用放在同一临界区内，是为了让「已经装了」这件事与
  /// `installedOn` 永远一致：分开做的话，`unbind` 可能正好插在
  /// 「置好 `installedOn`」与「真正调 install」之间，它摘一次、随后 install
  /// 又把回调装回去，留下一个谁也不会再摘的残留。
  ///
  /// 锁序安全：内核在 `lp_render_publish_pixel_buffer` 里只持 `vout.mutex`
  /// 把 `frame_cb` 拷出来，**出锁之后**才调用它
  /// （native/src/platform/apple/apple_texture.c:118-124），所以 [deliver]
  /// 进来时不持 `vout.mutex`。这里「先本锁、后 vout.mutex」不会与它成环。
  private func installLocked() {
    guard installedOn == nil, let player = storedPlayer, target != nil else {
      return
    }
    installedOn = player
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    lp_player_install_frame_callback(player, { user in
      guard let user else { return }
      let bridge = Unmanaged<VideoFrameBridge>.fromOpaque(user).takeUnretainedValue()
      bridge.deliver()
    }, ctx)
  }

  /// 摘掉内核帧回调（若装着）。**调用方必须持锁**。
  private func uninstallLocked() {
    guard let player = installedOn else { return }
    installedOn = nil
    lp_player_install_frame_callback(player, nil, nil)
  }

  /// 内核在解码线程调用这里。整段不碰主线程：iOS 17 起
  /// `AVSampleBufferVideoRenderer.enqueue` 允许后台线程直接入队；
  /// iOS 15/16 只能回主线程，那是系统接口本身的限制。
  ///
  /// 取帧走 `lp_player_copy_pixel_buffer`（+1 引用），和纹理路径是同一口井：
  /// 两条路径不能同时取，这一点由 iOS 侧不再注册纹理来保证。
  private func deliver() {
    lock.lock()
    guard let player = storedPlayer, let view = target else {
      lock.unlock()
      return
    }
    guard let raw = lp_player_copy_pixel_buffer(player) else {
      dropped += 1
      lock.unlock()
      return
    }
    let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(raw).takeRetainedValue()
    let sample = makeSampleBuffer(pixelBuffer)
    if sample != nil {
      delivered += 1
    } else {
      dropped += 1
    }
    lock.unlock()
    guard let sample else { return }
    enqueue(sample, to: view)
  }

  private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    if format == nil || width != formatWidth || height != formatHeight {
      var created: CMVideoFormatDescription?
      let status = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
        formatDescriptionOut: &created)
      guard status == noErr, let created else {
        NSLog("LanPlayer display layer: format description failed (\(status))")
        return nil
      }
      format = created
      formatWidth = width
      formatHeight = height
    }
    guard let format else { return nil }
    frameIndex += 1
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMTime(value: frameIndex, timescale: 30),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
      formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
    guard status == noErr, let sample else {
      NSLog("LanPlayer display layer: sample buffer failed (\(status))")
      return nil
    }
    // 这行是「立刻显示」的开关。不设的话 layer 会按 presentationTimeStamp
    // 排队，而内核给的时间戳只是宿主自增计数，与真实播放时钟没有对齐关系。
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sample, createIfNecessary: true) as? [CFMutableDictionary],
      let first = attachments.first {
      CFDictionarySetValue(
        first,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
  }

  private func enqueue(_ sample: CMSampleBuffer, to view: VideoDisplayView) {
    logOnceIfNeeded()
    if #available(iOS 17.0, *) {
      view.displayLayer.sampleBufferRenderer.enqueue(sample)
    } else {
      // iOS 15/16 上 enqueueSampleBuffer: 只能在主线程调用（该方法本身是
      // NS_SWIFT_UI_ACTOR）。这条分支不进 SwiftUI 主线程检查的视野，
      // 因为工程是 Swift 5 语言模式。
      DispatchQueue.main.async {
        view.displayLayer.enqueue(sample)
      }
    }
  }

  /// 播放开始后打一行，作为「显示层这条路真的通了」的证据：
  /// 没有它，真机上分不清「画面黑」是解码没出帧还是显示层没接上。
  private func logOnceIfNeeded() {
    lock.lock()
    let first = !loggedOnce
    loggedOnce = true
    lock.unlock()
    guard first else { return }
    NSLog("LanPlayer display layer: first frame enqueued")
  }
}

/// 承载 `AVSampleBufferDisplayLayer` 的视图。
///
/// 之所以用 `layerClass` 而不是给普通 view 加子 layer：
/// `AVSampleBufferDisplayLayer` 会自己按 `videoGravity` 调整内容矩形，作为
/// backing layer 时随视图尺寸变化自动跟随，不用手写 `layoutSubviews` 里的
/// frame 同步。
final class VideoDisplayView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

  var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = true
    backgroundColor = .black
    // Dart 侧 VideoSurface 已经按缩放模式算好了黑边矩形（见
    // app/lib/ui/widgets/video_surface.dart 的 fittedSize），送进来的 frame
    // 就是最终展示区域，所以这里让画面填满视图即可；改用 resizeAspect 会在
    // 「比例刚刚好」的情况下也留一圈亚像素黑边。
    displayLayer.videoGravity = .resize
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }
}

final class VideoPlatformView: NSObject, FlutterPlatformView {
  private let displayView: VideoDisplayView
  private let bridge: VideoFrameBridge

  init(frame: CGRect, bridge: VideoFrameBridge) {
    self.bridge = bridge
    self.displayView = VideoDisplayView(frame: frame)
    super.init()
    bridge.attach(displayView)
  }

  func view() -> UIView { displayView }

  /// 平台视图被移除时由引擎调用。此时必须把内核回调摘掉：视图一旦释放，
  /// 回调里的 target 就是悬空的 weak，虽然 weak 会置 nil，但每帧仍会白跑
  /// 一趟取帧（并把内核单槽里的帧消费掉，让音频继续、画面永远不更新）。
  deinit {
    bridge.detach(displayView)
  }
}

final class VideoPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  private let bridge: VideoFrameBridge

  init(bridge: VideoFrameBridge) {
    self.bridge = bridge
    super.init()
  }

  // 协议里的 createArgsCodec 没有标 _Nullable，导入 Swift 后是非可选的；
  // 写成可选返回值会报 `different optionality than required by protocol`。
  func createArgsCodec() -> (any FlutterMessageCodec & NSObjectProtocol) {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    _ = viewId
    _ = args
    return VideoPlatformView(frame: frame, bridge: bridge)
  }
}
