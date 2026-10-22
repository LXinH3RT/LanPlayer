import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/ui/widgets/volume_sheet.dart';

/// 播放页音量面板的回归测试。
///
/// 用户报的是「音量按钮只能静音，不能调音量大小」：以前那一格是个
/// IconButton，`onPressed` 里只有 `toggleMute()`。现在点开的是
/// [VolumeSheet]：滑杆（0–200%）+ 静音开关 + 六个常用档位。
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

  group('滑杆能真正调节音量', () {
    testWidgets('滑杆存在，且量程是 0–200%', (tester) async {
      await pumpSheet(tester);
      final slider = tester.widget<Slider>(find.byKey(const Key('volume-slider')));
      expect(slider.max, VolumeSheet.maxVolume);
      expect(slider.max, 2.0, reason: '内核支持 0–2 增益，不能只到 1.0');
      expect(slider.divisions, 40);
      expect(slider.value, 1.0);
    });

    testWidgets('向左拖滑杆会把音量调小（这是用户要的能力）', (tester) async {
      final rec = await pumpSheet(tester, volume: 1.0);
      final slider = find.byKey(const Key('volume-slider'));
      final rect = tester.getRect(slider);

      // 从当前位置（100% = 滑杆中点）拖到左侧约 25% 处。
      await tester.dragFrom(
        rect.center,
        Offset(-rect.width * 0.25, 0),
      );
      await tester.pumpAndSettle();

      expect(rec.vols, isNotEmpty, reason: '拖动必须产生 onVolumeChanged');
      expect(rec.vols.last, lessThan(1.0), reason: '音量应当变小');
      expect(rec.vols.last, greaterThanOrEqualTo(0.0));
    });

    testWidgets('向右拖滑杆能把音量提到 100% 以上', (tester) async {
      final rec = await pumpSheet(tester, volume: 1.0);
      final slider = find.byKey(const Key('volume-slider'));
      final rect = tester.getRect(slider);

      await tester.dragFrom(rect.center, Offset(rect.width * 0.3, 0));
      await tester.pumpAndSettle();

      expect(rec.vols, isNotEmpty);
      expect(rec.vols.last, greaterThan(1.0), reason: '应当能超过 100%');
      expect(rec.vols.last, lessThanOrEqualTo(2.0));
    });
  });

  group('档位按钮', () {
    testWidgets('六个档位都在，点 50% 会回调 0.5', (tester) async {
      final rec = await pumpSheet(tester);
      for (final p in VolumeSheet.presets) {
        expect(find.byKey(Key('volume-preset-${(p * 100).round()}')),
            findsOneWidget);
      }
      await tester.tap(find.byKey(const Key('volume-preset-50')));
      await tester.pumpAndSettle();
      expect(rec.vols.last, 0.5);
    });

    testWidgets('点 200% 会回调 2.0（增强档）', (tester) async {
      final rec = await pumpSheet(tester);
      await tester.tap(find.byKey(const Key('volume-preset-200')));
      await tester.pumpAndSettle();
      expect(rec.vols.last, 2.0);
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

      expect(rec.vols.last, 0.25);
      expect(rec.mutes, isNotEmpty, reason: '应当回调一次取消静音');
      expect(rec.mutes.last, isFalse);
    });
  });
}
