import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/ui/playback_orientation.dart';

/// 手机进播放页锁横屏这件事，逻辑全在 `playback_orientation.dart` 里的纯函数，
/// 这样不必真的转一台设备就能钉住：哪几种宿主会锁、锁成哪两个方向、退出时
/// 还回什么、纹理按多大尺寸建。
void main() {
  group('什么时候锁横屏', () {
    test('手机和平板开着开关时锁', () {
      expect(shouldLockLandscape(mobile: true, preference: true), isTrue);
    });

    test('用户把开关关掉就不锁', () {
      expect(shouldLockLandscape(mobile: true, preference: false), isFalse);
    });

    test('桌面端永远不锁，哪怕开关是开的', () {
      // 桌面的窗口由用户自己拉，锁方向在那边也没有意义。
      expect(shouldLockLandscape(mobile: false, preference: true), isFalse);
      expect(shouldLockLandscape(mobile: false, preference: false), isFalse);
    });
  });

  group('要宿主原生帮忙锁横屏', () {
    test('两个移动平台都发，桌面端不发', () {
      // Android 要那一档 SENSOR_LANDSCAPE；iPad 要 requestGeometryUpdate。
      // 两个平台的理由不同，但结论一样：都要打这条通道。
      expect(
        shouldAskHostForLandscape(mobile: true, preference: true),
        isTrue,
      );
    });

    test('开关关掉或桌面端时不发', () {
      expect(
        shouldAskHostForLandscape(mobile: true, preference: false),
        isFalse,
      );
      expect(
        shouldAskHostForLandscape(mobile: false, preference: true),
        isFalse,
      );
    });
  });

  group('锁哪两个方向', () {
    test('只锁左右横屏，不含两个竖屏', () {
      final want = lockedOrientations(mobile: true, preference: true);
      expect(want, isNotNull);
      expect(want, contains(DeviceOrientation.landscapeLeft));
      expect(want, contains(DeviceOrientation.landscapeRight));
      expect(want, isNot(contains(DeviceOrientation.portraitUp)));
      expect(want, isNot(contains(DeviceOrientation.portraitDown)));
      expect(want!.length, 2);
    });

    test('不锁的时候返回 null，调用方据此跳过平台通道', () {
      expect(lockedOrientations(mobile: true, preference: false), isNull);
      expect(lockedOrientations(mobile: false, preference: true), isNull);
    });
  });

  group('纹理尺寸', () {
    test('不锁横屏时按当前窗口方向建纹理', () {
      // 竖屏手机：宽 400、高 800，2 倍屏。
      final s = surfaceSizeFor(
        logicalWidth: 400,
        logicalHeight: 800,
        devicePixelRatio: 2,
        landscape: false,
      );
      expect(s.width, 800);
      expect(s.height, 1600);
    });

    test('锁横屏时改按长 / 短边分配，方向落定后正好对上', () {
      // 同一个竖屏窗口，但这次一定会转成横的：纹理必须是 1600x800，
      // 不能是 800x1600 —— 后者会让硬解一直往竖着的缓冲区里画。
      final s = surfaceSizeFor(
        logicalWidth: 400,
        logicalHeight: 800,
        devicePixelRatio: 2,
        landscape: true,
      );
      expect(s.width, 1600);
      expect(s.height, 800);
      expect(s.width > s.height, isTrue);
    });

    test('本来就横着拿的时候，两种口径给的是同一个尺寸', () {
      final portraitBasis = surfaceSizeFor(
        logicalWidth: 800,
        logicalHeight: 400,
        devicePixelRatio: 2,
        landscape: true,
      );
      final alreadyLandscape = surfaceSizeFor(
        logicalWidth: 800,
        logicalHeight: 400,
        devicePixelRatio: 2,
        landscape: false,
      );
      expect(portraitBasis.width, alreadyLandscape.width);
      expect(portraitBasis.height, alreadyLandscape.height);
      expect(portraitBasis.width, 1600);
      expect(portraitBasis.height, 800);
    });

    test('夹紧到内核收的区间，不让 0 或离谱的值漏下去', () {
      // 内核 lp_player_set_surface 对尺寸不做校验，0 会让 EGL 的 viewport
      // 变成空矩形，画面直接消失。
      final tiny = surfaceSizeFor(
        logicalWidth: 1,
        logicalHeight: 1,
        devicePixelRatio: 1,
        landscape: true,
      );
      expect(tiny.width, greaterThanOrEqualTo(320));
      expect(tiny.height, greaterThanOrEqualTo(240));

      final huge = surfaceSizeFor(
        logicalWidth: 4000,
        logicalHeight: 9000,
        devicePixelRatio: 3,
        landscape: true,
      );
      expect(huge.width, lessThanOrEqualTo(3840));
      expect(huge.height, lessThanOrEqualTo(2160));
    });
  });
}
