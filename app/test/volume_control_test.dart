import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/ui/widgets/volume_sheet.dart';

/// 播放页音量面板的回归测试。
///
/// 用户先后报过两次：
/// 1. 「音量按钮只能静音，不能调音量大小」：以前那一格是个 IconButton，
///    `onPressed` 里只有 `toggleMute()`。现在有 [VolumeSheet]。
/// 2. 「音量条显示最大值为 100，实际最大值为 200」：滑杆显示 0–100，
///    内部增益 0–2.0，两者差一个 2 倍系数。
///
/// 这里直接驱动**真实组件**（不是复刻一份），所以断言不会和实现漂移。
void main() {
  /// 把面板套进一个能测试的宿主里，并记录回调。
  Future<({List<double> vols, List<bool> mutes})> pumpSheet(
    WidgetTester tester, {
    double volume = 1.0,
    bool muted = false,
  }) async {
    final vols = <double>[];
    final mutes = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VolumeSheet(
          volume: volume,
          muted: muted,
          onVolumeChanged: vols.add,
          onMutedChanged: mutes.add,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return (vols: vols, mutes: mutes);
  }

  group('显示值与增益的换算', () {
    test('100 显示值就是内核的满增益 2.0', () {
      expect(VolumeSheet.displayMax, 100);
      expect(VolumeSheet.maxVolume, 2.0);
      expect(VolumeSheet.volumeOf(100), 2.0);
      expect(VolumeSheet.volumeOf(0), 0.0);
      expect(VolumeSheet.volumeOf(50), 1.0);
    });

    test('增益换算回显示值，且被夹在 0–100', () {
      expect(VolumeSheet.displayOf(2.0), 100);
      expect(VolumeSheet.displayOf(1.0), 50);
      expect(VolumeSheet.displayOf(0.0), 0);
      expect(VolumeSheet.displayOf(5.0), 100, reason: '越界要夹住');
      expect(VolumeSheet.displayOf(-1.0), 0);
    });
  });

  group('滑杆能真正调节音量', () {
    testWidgets('滑杆量程是 0–100，默认音量 1.0 显示成 50', (tester) async {
      await pumpSheet(tester);
      final slider =
          tester.widget<Slider>(find.byKey(const Key('volume-slider')));
      expect(slider.max, 100.0, reason: '用户要求音量条显示最大值为 100');
      expect(slider.divisions, 40);
      expect(slider.value, 50.0, reason: '1.0 增益对应显示 50');
      expect(find.text('50'), findsWidgets);
    });

    testWidgets('把它拖到最右端会回调内核满增益 2.0', (tester) async {
      final rec = await pumpSheet(tester, volume: 1.0);
      final slider = find.byKey(const Key('volume-slider'));
      final rect = tester.getRect(slider);

      await tester.dragFrom(rect.center, Offset(rect.width, 0));
      await tester.pumpAndSettle();

      expect(rec.vols, isNotEmpty);
      expect(rec.vols.last, closeTo(VolumeSheet.maxVolume, 0.001),
          reason: '显示 100 必须等于内核的 2.0，而不是 1.0');
    });

    testWidgets('向左拖滑杆会把音量调小（这是用户要的能力）', (tester) async {
      final rec = await pumpSheet(tester, volume: 1.0);
      final slider = find.byKey(const Key('volume-slider'));
      final rect = tester.getRect(slider);

      await tester.dragFrom(rect.center, Offset(-rect.width * 0.25, 0));
      await tester.pumpAndSettle();

      expect(rec.vols, isNotEmpty, reason: '拖动必须产生 onVolumeChanged');
      expect(rec.vols.last, lessThan(1.0), reason: '音量应当变小');
      expect(rec.vols.last, greaterThanOrEqualTo(0.0));
    });
  });

  group('档位按钮', () {
    testWidgets('六个档位按显示值给出，点 100 会回调 2.0', (tester) async {
      final rec = await pumpSheet(tester);
      for (final p in VolumeSheet.presets) {
        expect(find.byKey(Key('volume-preset-$p')), findsOneWidget);
      }
      expect(VolumeSheet.presets.last, 100, reason: '最高档就是显示的 100');
      await tester.tap(find.byKey(const Key('volume-preset-100')));
      await tester.pumpAndSettle();
      expect(rec.vols.last, 2.0);
    });

    testWidgets('点 25 会回调 0.5（显示值减半即增益减半）', (tester) async {
      final rec = await pumpSheet(tester);
      await tester.tap(find.byKey(const Key('volume-preset-25')));
      await tester.pumpAndSettle();
      expect(rec.vols.last, 0.5);
    });
  });

  group('静音', () {
    testWidgets('静音开关能切过去并回调 true', (tester) async {
      final rec = await pumpSheet(tester, muted: false);
      await tester.tap(find.byKey(const Key('volume-mute-switch')));
      await tester.pumpAndSettle();
      expect(rec.mutes, isNotEmpty);
      expect(rec.mutes.last, isTrue);
    });

    testWidgets('静音时标题提示已静音', (tester) async {
      await pumpSheet(tester, muted: true);
      expect(find.text('音量（已静音）'), findsOneWidget);
    });

    testWidgets('静音状态下调音量会自动取消静音', (tester) async {
      // 否则用户会以为滑杆坏了：动了却没声音。
      final rec = await pumpSheet(tester, volume: 1.0, muted: true);
      await tester.tap(find.byKey(const Key('volume-preset-25')));
      await tester.pumpAndSettle();

      expect(rec.vols.last, 0.5);
      expect(rec.mutes, isNotEmpty, reason: '应当回调一次取消静音');
      expect(rec.mutes.last, isFalse);
    });
  });

  /// 滚轮调音量（用户 2026-10-27 要求「鼠标滚轮控制音量」）。
  ///
  /// 用户的场景是鼠标停在画面上直接滚，不点任何按钮。这里测的是换算本身：
  /// 真机上滚轮事件走 `Listener.onPointerSignal`，widget test 里造
  /// `PointerScrollEvent` 也能验，但先把「一格到底走多少」钉死更关键 ——
  /// 滚一格跨 5 个显示刻度，从 0 到 100 正好 20 格。
  group('滚轮调音量', () {
    test('往上滚变大、往下滚变小', () {
      expect(VolumeSheet.wheelVolume(1.0, -60), greaterThan(1.0));
      expect(VolumeSheet.wheelVolume(1.0, 60), lessThan(1.0));
    });

    test('一格（Windows 报 60）走 5 个显示刻度', () {
      // 1.0 增益 = 显示 50。这条钉住的是实测值：滚三格走过 9 个刻度时说明
      // 每格只有 3，正是把一格当成 100 造成的。
      expect(VolumeSheet.displayOf(VolumeSheet.wheelVolume(1.0, -60)), 55);
      expect(VolumeSheet.displayOf(VolumeSheet.wheelVolume(1.0, 60)), 45);
    });

    test('滚到头就停住，不会超量程', () {
      expect(VolumeSheet.wheelVolume(2.0, -60), 2.0);
      expect(VolumeSheet.wheelVolume(0.0, 60), 0.0);
      // 触控板一次给很大的 delta 也要夹住。
      expect(VolumeSheet.wheelVolume(1.0, -100000), 2.0);
      expect(VolumeSheet.wheelVolume(1.0, 100000), 0.0);
    });

    test('触控板的小 delta 按比例折算，不是按次加减一格', () {
      // 只有 1/3 格 => 显示值约动 2；1/15 格 => 不到 1 个刻度，四舍五入不动。
      expect(VolumeSheet.displayOf(VolumeSheet.wheelVolume(1.0, -20)), 52);
      expect(VolumeSheet.displayOf(VolumeSheet.wheelVolume(1.0, -4)), 50);
    });
  });
}
