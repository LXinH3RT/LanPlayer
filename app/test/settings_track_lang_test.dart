import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/data/stores.dart';
import 'package:lanplayer/ui/settings_screen.dart';

/// 设置页里「首选/次选语言」两档的回归测试。
///
/// 为什么值得单独测：这两格是 DropdownButton，而 DropdownButton 有个很脆的
/// 约定 —— `value` 必须能在 `items` 里找到，否则直接断言崩溃（不是画错，
/// 是整页白屏）。而「次选」这一档的默认值恰好是 `auto`，一不小心就会把它从
/// items 里剔掉。所以这里把三种输入都过一遍：默认值、正常语言、脏数据。
void main() {
  /// 设置页从 SettingsStore 单例读配置，所以要先把它置成期望的状态。
  ///
  /// 设置页现在是左目录右内容，一次只构建一格。语言那四格分在「音频」与
  /// 「字幕」两页里，所以断言前得先翻到对应目录 —— 用 initialTab 指定。
  Future<void> pumpSettings(WidgetTester tester, PlaybackSettings s,
      {SettingsTab tab = SettingsTab.audio}) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SettingsStore.instance.value = s;
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(initialTab: tab)));
    await tester.pumpAndSettle();
  }

  group('两档语言下拉都在', () {
    testWidgets('标题齐全', (tester) async {
      await pumpSettings(tester, PlaybackSettings());
      expect(find.text('首选音轨语言'), findsOneWidget);
      expect(find.text('次选音轨语言'), findsOneWidget);
      // 字幕那两格在「字幕」目录里，不在「音频」目录。
      expect(find.text('首选字幕语言'), findsNothing);
      await pumpSettings(tester, PlaybackSettings(),
          tab: SettingsTab.subtitle);
      expect(find.text('首选字幕语言'), findsOneWidget);
      expect(find.text('次选字幕语言'), findsOneWidget);
    });

    testWidgets('默认值能正常渲染（次选是 auto，不能崩）', (tester) async {
      // 这正是最容易崩的组合：primary=zh、secondary=auto。
      await pumpSettings(tester, PlaybackSettings());
      expect(tester.takeException(), isNull);
      // 音轨首选默认也是中文，就在当前这一页。
      expect(find.text('中文'), findsWidgets, reason: '首选音轨默认中文');
    });
  });

  group('脏配置不会把设置页打崩', () {
    testWidgets('偏好里存了表上没有的语言码', (tester) async {
      await pumpSettings(
        tester,
        PlaybackSettings(
          audioPreference: const TrackPreference(primary: 'klingon'),
        ),
      );
      expect(tester.takeException(), isNull,
          reason: '未知语言码要回落到「自动」，而不是让 DropdownButton 断言');
    });

    testWidgets('偏好是空串', (tester) async {
      await pumpSettings(
        tester,
        PlaybackSettings(
          subtitlePreference: const TrackPreference(primary: ''),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('选完之后会落到配置里', () {
    testWidgets('点开首选音轨语言能选到日语', (tester) async {
      final s = PlaybackSettings();
      await pumpSettings(tester, s);

      // 找到「首选音轨语言」那一格里的下拉。
      final tile = find.ancestor(
        of: find.text('首选音轨语言'),
        matching: find.byType(ListTile),
      );
      final dropdown = find.descendant(
        of: tile,
        matching: find.byType(DropdownButton<String>),
      );
      expect(dropdown, findsOneWidget);

      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      // 展开后会多出一份选项；点最后一个「日语」。
      await tester.tap(find.text('日语').last);
      await tester.pumpAndSettle();

      expect(s.audioPreference.primary, 'ja');
    });
  });
}
