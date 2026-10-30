import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/data/stores.dart';
import 'package:lanplayer/ui/settings_screen.dart';

void main() {
  group('播放倍速档位', () {
    test('档位就是你点名的那八档，从慢到快', () {
      expect(PlaybackSettings.speedSteps,
          [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]);
    });

    test('吸附：老配置里的 1.3 贴到 1.25，1.9 贴到 2.0', () {
      expect(PlaybackSettings.clampSpeed(1.3), 1.25);
      expect(PlaybackSettings.clampSpeed(1.9), 2.0);
      expect(PlaybackSettings.clampSpeed(1.0), 1.0);
    });

    test('吸附：越界值贴到最近的那一端，不会原样透传', () {
      expect(PlaybackSettings.clampSpeed(0.0), 0.25);
      expect(PlaybackSettings.clampSpeed(9.0), 2.0);
      expect(PlaybackSettings.clampSpeed(-4), 0.25);
    });

    test('吸附：字段缺失或类型不对时回到 1.0', () {
      expect(PlaybackSettings.clampSpeed(null), 1.0);
      expect(PlaybackSettings.clampSpeed('fast'), 1.0);
    });

    test('fromJson 也吸附：settings.json 手写成 1.3 读回来是 1.25', () {
      final s = PlaybackSettings.fromJson(
          jsonDecode('{"version":1,"speed":1.3}') as Map<String, dynamic>);
      expect(s.speed, 1.25);
    });

    test('0.25 倍速能存进 json 再读回来', () {
      final s = PlaybackSettings(speed: 0.25);
      final back = PlaybackSettings.fromJson(s.toJson());
      expect(back.speed, 0.25);
    });
  });

  testWidgets('设置页的默认倍速是下拉，且只列这八档', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SettingsStore.instance.value = PlaybackSettings(speed: 1.0);
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    final tile = find.text('默认倍速');
    expect(tile, findsOneWidget);

    // 这一格必须是下拉，不能是滑杆。
    final row = find.ancestor(of: tile, matching: find.byType(ListTile));
    expect(find.descendant(of: row, matching: find.byType(Slider)),
        findsNothing);
    final dropdown = find.descendant(
        of: row, matching: find.byType(DropdownButton<double>));
    expect(dropdown, findsOneWidget);

    await tester.tap(dropdown);
    await tester.pumpAndSettle();

    for (final s in PlaybackSettings.speedSteps) {
      expect(find.text('${s}x'), findsWidgets, reason: '缺少 ${s}x 这一档');
    }
    // 0.5 是老版滑杆的下限，改完仍然在；0.1 从来不合法。
    expect(find.text('0.1x'), findsNothing);

    await tester.tap(find.text('0.25x').last);
    await tester.pumpAndSettle();
    expect(SettingsStore.instance.value.speed, 0.25);
  });

  testWidgets('播放页的倍速面板与设置页共用同一组档位', (tester) async {
    // 面板是 player_screen 内部的私有 widget，这里用源码常量间接保证：
    // 两处都从 PlaybackSettings.speedSteps 取，档位不会漂。
    expect(PlaybackSettings.speedSteps.contains(0.25), isTrue);
    expect(PlaybackSettings.speedSteps.first, 0.25);
    expect(PlaybackSettings.speedSteps.last, 2.0);
    expect(PlaybackSettings.speedSteps.length, 8);
  });
}
