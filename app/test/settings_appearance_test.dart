import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart';
import 'package:lanplayer/data/stores.dart';
import 'package:lanplayer/ui/settings_screen.dart';
import 'package:lanplayer/ui/theme.dart';

/// 设置页在 2026-11-01 的四处结构调整。
///
/// 四条都不是纯视觉偏好：
/// - 「外观」给了主题一个持久化的出口，之前只有跟随系统，想一直黑没有入口；
/// - 字号和延迟改成下拉，是因为这是两组离散档位，滑杆拖出的 1.37 既不
///   可复述也不可比对；
/// - 「进度」「连播」「默认倍速」合并成「播放」，因为它们回答的是同一个
///   问题「这片子怎么放」，分在三处就得点三次目录；
/// - 「秒」搬到输入框外，是因为 suffixText 会跟着输入框边框内缩，和整行
///   基线对不齐。
void main() {
  Future<void> pump(
    WidgetTester tester,
    SettingsTab tab, {
    Size size = const Size(1200, 2600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => ThemeController.instance.reset());
    await tester.pumpWidget(MaterialApp(
      theme: LanPlayerTheme.dark(),
      home: SettingsScreen(initialTab: tab),
    ));
    await tester.pumpAndSettle();
  }

  group('外观', () {
    testWidgets('三个选项都在，默认选中黑色', (tester) async {
      SettingsStore.instance.value = PlaybackSettings();
      await pump(tester, SettingsTab.appearance);

      expect(find.text('黑色'), findsOneWidget);
      expect(find.text('白色'), findsOneWidget);
      expect(find.text('跟随系统'), findsOneWidget);

      // 默认黑色：选中态在「黑色」那一行，其余两行没有选中。
      final dark = tester.widget<RadioListTile<AppThemeMode>>(
        find.byKey(const ValueKey('settings-theme-dark')),
      );
      expect(dark.groupValue, AppThemeMode.dark);
      expect(dark.value, AppThemeMode.dark);
    });

    testWidgets('点「白色」立刻生效并落盘', (tester) async {
      SettingsStore.instance.value = PlaybackSettings();
      await pump(tester, SettingsTab.appearance);
      expect(ThemeController.instance.value, AppThemeMode.dark);

      await tester.tap(find.byKey(const ValueKey('settings-theme-light')));
      await tester.pumpAndSettle();

      expect(ThemeController.instance.value, AppThemeMode.light);
      expect(SettingsStore.instance.value.themeMode, AppThemeMode.light);

      // 外观页不是纯视觉开关：整棵树的主题要跟着变。
      await tester.tap(find.byKey(const ValueKey('settings-theme-system')));
      await tester.pumpAndSettle();
      expect(ThemeController.instance.value, AppThemeMode.system);
      expect(SettingsStore.instance.value.themeMode, AppThemeMode.system);
    });

    test('三档到 ThemeMode 的映射与设置项一一对应', () {
      expect(ThemeController.toThemeMode(AppThemeMode.dark), ThemeMode.dark);
      expect(ThemeController.toThemeMode(AppThemeMode.light), ThemeMode.light);
      expect(
          ThemeController.toThemeMode(AppThemeMode.system), ThemeMode.system);
      // 顺序就是界面上从上到下的顺序：跟随系统、黑色、白色之外的第三项
      // 不在这里断言，避免把枚举顺序变成契约。
      expect(AppThemeMode.values.length, 3);
    });
  });

  group('字幕页的两个下拉', () {
    testWidgets('字号和延迟都是下拉，不是滑杆', (tester) async {
      SettingsStore.instance.value = PlaybackSettings();
      await pump(tester, SettingsTab.subtitle);

      final scale = find.byKey(const ValueKey('settings-subtitle-scale'));
      final delay = find.byKey(const ValueKey('settings-subtitle-delay'));
      expect(scale, findsOneWidget);
      expect(delay, findsOneWidget);

      // key 就挂在 DropdownButton 自己身上，所以按类型断言它本身，
      // 而不是找它的后代。
      expect(tester.widget<DropdownButton<double>>(scale),
          isA<DropdownButton<double>>());
      expect(tester.widget<DropdownButton<int>>(delay),
          isA<DropdownButton<int>>());
      // 这一格里不能再有滑杆。
      final row = find.ancestor(of: scale, matching: find.byType(ListTile));
      expect(find.descendant(of: row, matching: find.byType(Slider)),
          findsNothing);
    });

    testWidgets('下拉里列出的是模型的档位表，不是随手写的范围', (tester) async {
      SettingsStore.instance.value = PlaybackSettings();
      await pump(tester, SettingsTab.subtitle);

      await tester.tap(find.byKey(const ValueKey('settings-subtitle-scale')));
      await tester.pumpAndSettle();
      for (final s in PlaybackSettings.subtitleScaleSteps) {
        final label = '${(s * 100).round()}%';
        expect(find.text(label), findsWidgets, reason: '缺少 $label 这一档');
      }
      await tester.tap(find.text('150%').last);
      await tester.pumpAndSettle();
      expect(SettingsStore.instance.value.subtitleScale, 1.5);

      await tester.tap(find.byKey(const ValueKey('settings-subtitle-delay')));
      await tester.pumpAndSettle();
      expect(find.text('0.0 s'), findsWidgets);
      await tester.tap(find.text('0.5 s').last);
      await tester.pumpAndSettle();
      expect(SettingsStore.instance.value.subtitleDelayMs, 500);
    });

    testWidgets('老配置里的连续值不会让下拉框崩掉', (tester) async {
      // 滑杆时代存下来的 1.37 / -350 不在档位表里，直接喂给
      // DropdownButton 会抛断言；页面必须靠 clamp 吸附。
      SettingsStore.instance.value =
          PlaybackSettings.fromJson(<String, dynamic>{
        'subtitle_scale': 1.37,
        'subtitle_delay_ms': -350,
      });
      await pump(tester, SettingsTab.subtitle);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('settings-subtitle-scale')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('settings-subtitle-delay')),
          findsOneWidget);
    });
  });

  group('合并出来的「播放」页', () {
    testWidgets('步长、默认倍速、连播三件事在一格里', (tester) async {
      SettingsStore.instance.value = PlaybackSettings();
      await pump(tester, SettingsTab.playback);

      // 原来分在「进度」（步长）、「连播」（两个开关）、「音频」（倍速）。
      expect(find.text('快进 / 快退步长'), findsOneWidget);
      expect(find.text('默认倍速'), findsOneWidget);
      expect(find.text('当前目录自动连播'), findsOneWidget);
      expect(find.text('记忆上次播放位置'), findsOneWidget);
    });

    testWidgets('「进度」与「连播」不再是独立目录', (tester) async {
      // 枚举里已经没有这两项；留着会让同一件事有两个入口。
      expect(SettingsTab.values.contains(SettingsTab.playback), isTrue);
      final names = SettingsTab.values.map((t) => t.name).toList();
      expect(names.contains('progress'), isFalse);
      expect(names.contains('autoplay'), isFalse);
      expect(names.contains('appearance'), isTrue);
    });

    testWidgets('「秒」在输入框外面，输入框里没有后缀', (tester) async {
      SettingsStore.instance.value = PlaybackSettings();
      await pump(tester, SettingsTab.playback);

      final row = find.ancestor(
        of: find.text('快进 / 快退步长'),
        matching: find.byType(ListTile),
      );
      final field = find.descendant(of: row, matching: find.byType(TextField));
      expect(field, findsOneWidget);
      expect(tester.widget<TextField>(field).decoration?.suffixText, isNull);
      expect(
          find.descendant(of: row, matching: find.text('秒')), findsOneWidget);
    });

    testWidgets('「默认倍速」已经从音频页搬走', (tester) async {
      SettingsStore.instance.value = PlaybackSettings();
      await pump(tester, SettingsTab.audio);

      // 音频页只剩音量与两条语言。
      expect(find.text('默认倍速'), findsNothing);
      expect(find.text('音量增益'), findsOneWidget);
      expect(find.text('首选音轨语言'), findsOneWidget);
    });
  });
}
