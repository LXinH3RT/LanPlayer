import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer_video/lanplayer_video.dart';

/// 视频输出的「谁负责画」这条判定。三种宿主的回答不一样，判错的后果都是黑屏：
///
/// - Android 平台视图为真 → Dart 侧不能建 `Texture`（`textureId` 是 -1），也不能
///   把窗口指针转交给内核 —— 窗口由平台视图自己上交。
/// - Android 以前的纹理路（以及桌面端）`windowPtr != 0` → Dart 必须调
///   `lp_player_set_surface`，否则内核往一个没人看的窗口里画。
/// - Apple / Windows 的 `windowPtr == 0` → 内核直接发布帧，Dart 什么都不做。
///
/// 这三种情况只差一个布尔与一个整数，写反了不会有任何异常，只能靠用例钉住。
void main() {
  test('平台视图：内核不拿窗口，Dart 也不转交', () {
    const tex = VideoTexture(
      textureId: -1,
      windowPtr: 0,
      width: 1920,
      height: 1080,
      platformView: true,
    );
    expect(tex.needsSurface, isFalse);
    // textureId 是 -1：真去建 Texture(textureId: -1) 会拿到一块永远黑的层。
    expect(tex.textureId, lessThan(0));
  });

  test('平台视图即使带着窗口指针也不由 Dart 转交', () {
    const tex = VideoTexture(
      textureId: -1,
      windowPtr: 12345,
      width: 1920,
      height: 1080,
      platformView: true,
    );
    expect(tex.needsSurface, isFalse);
  });

  test('Android 纹理路：窗口指针非 0 时必须转交', () {
    const tex = VideoTexture(
      textureId: 7,
      windowPtr: 4242,
      width: 1920,
      height: 1080,
    );
    expect(tex.platformView, isFalse);
    expect(tex.needsSurface, isTrue);
  });

  test('Apple / Windows：inProcess 哨兵表示内核自己发布帧', () {
    const tex = VideoTexture(
      textureId: 3,
      windowPtr: TextureWindowPtr.inProcess,
      width: 1920,
      height: 1080,
    );
    expect(tex.needsSurface, isFalse);
  });

  test('契约版本随平台视图递增', () {
    // 平台视图把「宿主回什么」改成了一个新键（platformView），旧版本的宿主
    // 不会回它，Dart 会退回纹理路 —— 版本号必须能区分这两套。
    expect(lanplayerVideoBridgeVersion, '2');
  });

  test('平台视图类型名与 Android 宿主注册的字符串一致', () {
    // 两边对不上时引擎找不到工厂，视图建不出来，表现是一块永远黑的区域。
    // Android 侧的字面量在 VideoSurfaceView.kt 的 VIEW_TYPE；
    // tool/check_all.py 逐字比对这两处。
    expect(lanplayerVideoSurfaceViewType, 'dev.lanplayer/video_surface');
  });
}
