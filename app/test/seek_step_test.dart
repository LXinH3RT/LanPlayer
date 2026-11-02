import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/data/stores.dart';
import 'package:lanplayer/ui/settings_screen.dart';

/// 「快进/快退步长」的读写两头。
///
/// 用户要求这个数字必须是 1..10 的整数。界面上用下拉框只能选 1..10，
/// 但 `settings.json` 是可以手改的，所以 `fromJson` 也必须夹紧 ——
/// 读到 0 会让快进退原地不动，读到 999 一点就跳到片尾。
void main() {
  setUp(() async {
    SettingsStore.instance.value = PlaybackSettings();
  });

  group('快进快退步长', () {
    test('默认是 10 秒，与改动前的行为一致', () {
      expect(PlaybackSettings().seekStepSeconds, 10);
      expect(PlaybackSettings.seekStepMin, 1);
      expect(PlaybackSettings.seekStepMax, 10);
    });

    test('手改过头的配置会被夹回 1..10', () {
      expect(PlaybackSettings.clampSeekStep(0), 1);
      expect(PlaybackSettings.clampSeekStep(-3), 1);
      expect(PlaybackSettings.clampSeekStep(11), 10);
      expect(PlaybackSettings.clampSeekStep(999), 10);
      expect(PlaybackSettings.clampSeekStep(5), 5);
      // 小数也收成整数，不能出现 7.3 秒这种步长。
      expect(PlaybackSettings.clampSeekStep(7.9), 7);
      // 缺字段 / 类型不对，退回默认值。
      expect(PlaybackSettings.clampSeekStep(null), 10);
      expect(PlaybackSettings.clampSeekStep('abc'), 10);
    });

    test('往返 JSON 不丢设置', () {
      final s = PlaybackSettings(seekStepSeconds: 3);
      expect(s.toJson()['seek_step_seconds'], 3);
      expect(PlaybackSettings.fromJson(s.toJson()).seekStepSeconds, 3);
    });

    test('老配置里没有这个字段时按 10 秒算', () {
      final old = <String, dynamic>{
        'hardware_decoding': true,
        'volume': 0.8,
      };
      expect(PlaybackSettings.fromJson(old).seekStepSeconds, 10);
    });

    test('settings.json 里写成越界值时读回也被夹紧', () {
      final bad = <String, dynamic>{'seek_step_seconds': 99};
      expect(PlaybackSettings.fromJson(bad).seekStepSeconds, 10);
      final zero = <String, dynamic>{'seek_step_seconds': 0};
      expect(PlaybackSettings.fromJson(zero).seekStepSeconds, 1);
    });

    test('copy() 把步长一起带过去', () {
      final s = PlaybackSettings(seekStepSeconds: 4);
      expect(s.copy().seekStepSeconds, 4);
    });
  });

  testWidgets('设置页用填数改步长，越界会被夹紧', (tester) async {
    // 设置页现在左目录右内容，一次只构建一格，所以直接点开「播放」。
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
        home: SettingsScreen(initialTab: SettingsTab.playback)));
    await tester.pumpAndSettle();

    final tile = find.text('快进 / 快退步长');
    expect(tile, findsOneWidget);
    // 步长这一格是输入框，不是滑杆，也不是下拉。
    final field = find.descendant(
      of: find.ancestor(of: tile, matching: find.byType(ListTile)),
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget);
    // 这一格里不能有滑杆（倍速/字幕那几格仍是下拉，所以按格查）。
    expect(
      find.descendant(
        of: find.ancestor(of: tile, matching: find.byType(ListTile)),
        matching: find.byType(Slider),
      ),
      findsNothing,
    );
    // 「秒」这个单位在输入框外面（用户 2026-11-01 要求）：写进 suffixText
    // 会跟着输入框边框一起内缩、和整行基线对不齐。这里断言它是一颗独立的
    // Text，且不在 TextField 的装饰里。
    expect(
      find.descendant(
        of: find.ancestor(of: tile, matching: find.byType(ListTile)),
        matching: find.text('秒'),
      ),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(field).decoration?.suffixText, isNull);

    Future<void> enter(String text) async {
      await tester.enterText(field, text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    await enter('3');
    expect(SettingsStore.instance.value.seekStepSeconds, 3);
    expect(tester.widget<TextField>(field).controller?.text, '3');

    // 越界与非法输入：夹到区间内，不允许出现 0 或 99。
    await enter('99');
    expect(SettingsStore.instance.value.seekStepSeconds, 10);
    expect(tester.widget<TextField>(field).controller?.text, '10');

    await enter('0');
    expect(SettingsStore.instance.value.seekStepSeconds, 1);
    expect(tester.widget<TextField>(field).controller?.text, '1');
  });

  testWidgets('设置页的音量增益是下拉，档位 0.1–2.0', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SettingsStore.instance.value = PlaybackSettings(volumeGain: 1.0);
    await tester.pumpWidget(
        const MaterialApp(home: SettingsScreen(initialTab: SettingsTab.audio)));
    await tester.pumpAndSettle();

    final tile = find.text('音量增益');
    final dropdown = find.descendant(
      of: find.ancestor(of: tile, matching: find.byType(ListTile)),
      matching: find.byType(DropdownButton<double>),
    );
    expect(dropdown, findsOneWidget);
    // 1.0 倍是默认档，显示成 1.0x。
    expect(find.text('1.0x'), findsOneWidget);

    Future<void> pick(String label) async {
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await pick('1.6x');
    expect(SettingsStore.instance.value.volumeGain, closeTo(1.6, 1e-9));

    await pick('2.0x');
    expect(SettingsStore.instance.value.volumeGain, closeTo(2.0, 1e-9));
  });
}
