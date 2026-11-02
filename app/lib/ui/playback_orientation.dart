import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

import 'video_texture.dart';

/// 手机与平板：竖着拿的时候横屏片子只能缩成中间一条，字幕和底栏也挤在一起。
///
/// 判定放在这里而不是散在界面代码里，是因为「哪些宿主需要锁方向」这件事只有
/// 一张答案：桌面端的窗口由用户自己拉，锁方向没有意义，`setPreferredOrientations`
/// 在那边本来也是空操作。
bool get isMobileHost => Platform.isAndroid || Platform.isIOS;

/// 进入播放页时是否要锁横屏。
///
/// 两个条件缺一不可：宿主是手机 / 平板，并且用户没有在设置里关掉这一项。
bool shouldLockLandscape({required bool mobile, required bool preference}) =>
    mobile && preference;

/// 是否要靠宿主原生通道去锁横屏。
///
/// 两个移动平台都要走，理由不同：
///
/// - Android：`setPreferredOrientations` 那套只保证「窗口是横的」，不保证
///   「跟着机身翻」。用户在控制中心关掉自动旋转之后，FULL_USER 会把播放页钉
///   在当时那个横向上，把机身转到另一侧也不会动。`SCREEN_ORIENTATION_SENSOR_
///   LANDSCAPE` 不看那个开关，只看加速度计与陀螺仪。
/// - iOS / iPadOS：`setPreferredOrientations` 在 iPad 上根本不生效（Flutter
///   文档写明「只有关掉多任务才生效」，而 iPadOS 26 起窗口由系统分配，
///   `UIRequiresFullScreen` 也已失效），必须由宿主自己向 window scene 发
///   `requestGeometryUpdate`。
///
/// 桌面端不发：那边窗口由用户自己拉，锁方向没有意义。
bool shouldAskHostForLandscape({
  required bool mobile,
  required bool preference,
}) =>
    shouldLockLandscape(mobile: mobile, preference: preference);

/// 播放页要锁的方向；null 表示这次不动方向。
///
/// 只锁左右横屏，不带 `portraitDown`：手机上把机器倒过来看片是极少数，
/// 而两个方向都在表里，正反横着拿都能自动贴合。
List<DeviceOrientation>? lockedOrientations({
  required bool mobile,
  required bool preference,
}) =>
    shouldLockLandscape(mobile: mobile, preference: preference)
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : null;

/// 真正把锁横屏的请求发给宿主。
///
/// 两条路都要走，谁也不是另一条的超集：
///
/// 1. `SystemChrome.setPreferredOrientations` 负责「窗口本身变成横的」。
///    Android 上这一步会成功，只是方向档是 FULL_USER；iPad 上这一步会被
///    系统忽略。
/// 2. 宿主原生通道补上各自那一半 —— Android 换成 SENSOR_LANDSCAPE 档，
///    iOS 发 `requestGeometryUpdate`。谁先谁后无关紧要，两者幂等。
Future<void> enterPlaybackOrientation({
  required bool mobile,
  required bool preference,
}) async {
  final want = lockedOrientations(mobile: mobile, preference: preference);
  if (want == null) return;
  await SystemChrome.setPreferredOrientations(want);
  if (shouldAskHostForLandscape(mobile: mobile, preference: preference)) {
    // 宿主那条路在 iPad 上不会回包（`requestGeometryUpdate` 成功时没有回调），
    // 真机上「没转」和「没发出去」只能靠这行日志分开，所以留着。
    debugPrint('LanPlayer orientation: asking host for landscape');
    await VideoTextureBridge.lockLandscape(true);
  }
}

/// 退出播放页时把方向交还给系统。
///
/// 交回全部四向而不是写死「竖屏」：应用清单本来就同时声明了竖屏与横屏，
/// 用户在列表页横着拿手机时也该能横过来 —— 之前就是这么工作的，这里只是
/// 把播放页临时借走的方向还回去。
Future<void> leavePlaybackOrientation({
  required bool mobile,
  required bool preference,
}) async {
  if (!shouldLockLandscape(mobile: mobile, preference: preference)) return;
  if (shouldAskHostForLandscape(mobile: mobile, preference: preference)) {
    await VideoTextureBridge.lockLandscape(false);
  }
  await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
}

/// 纹理该按多大创建。
///
/// 锁横屏时窗口一定宽大于高，而 `_bootstrap()` 跑在旋转真正落地之前 ——
/// 那一刻 `MediaQuery` 报的还是竖屏尺寸。照着竖屏尺寸建纹理，硬解会一直往
/// 一个竖着的缓冲区里渲染，等到画面真的横过来，Flutter 只能把一张竖纹理塞进
/// 横着的窗口，四周留下大片黑边。所以锁横屏时改按物理屏幕的长 / 短边算，
/// 方向一落定就正好对上。
({int width, int height}) surfaceSizeFor({
  required double logicalWidth,
  required double logicalHeight,
  required double devicePixelRatio,
  required bool landscape,
}) {
  final a = (logicalWidth * devicePixelRatio).round();
  final b = (logicalHeight * devicePixelRatio).round();
  final longSide = a > b ? a : b;
  final shortSide = a > b ? b : a;
  if (!landscape) {
    return (width: a.clamp(320, 3840), height: b.clamp(240, 2160));
  }
  return (width: longSide.clamp(320, 3840), height: shortSide.clamp(240, 2160));
}
