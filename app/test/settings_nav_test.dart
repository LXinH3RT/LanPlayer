import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart' show PlaybackSettings;
import 'package:lanplayer/data/stores.dart';
import 'package:lanplayer/ui/settings_screen.dart';
import 'package:lanplayer/ui/theme.dart';

/// 设置页的分栏结构：左边目录、右边内容。
///
/// 用户要求「左侧为目录导航栏，右侧为所选目录对应的设置」，并且「目录标题
/// 和正文采用统一的字体字号」。这两条都不是纯视觉偏好：分栏之后一次只构建
/// 一格，能省掉手机上一路滚到「关于」的七八屏；字号统一是为了让目录项看
/// 起来和它右边的标题是同一层级的东西，而不是一小撮灰色的分类标签。
void main() {
  Future<void> pump(WidgetTester tester, {Size size = const Size(1200, 2400)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SettingsStore.instance.value = PlaybackSettings();
    await tester.pumpWidget(MaterialApp(
      theme: LanPlayerTheme.dark(),
      home: const SettingsScreen(),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('宽屏左侧是竖排目录，右侧只放当前一格', (tester) async {
    await pump(tester);

    // 每一格目录都在。
    for (final tab in SettingsTab.values) {
      expect(find.byKey(tab.tabKey), findsOneWidget,
          reason: '目录里缺 ${tab.label}');
    }

    // 默认停在「解码」，右边只有解码那两行，没有别格的内容。
    expect(find.text('硬件解码'), findsOneWidget);
    expect(find.text('默认音量'), findsNothing, reason: '一次只该构建一格');
    expect(find.text('版本'), findsNothing);

    // 点「关于」→ 右边换成关于，解码那两行消失。
    await tester.tap(find.byKey(SettingsTab.about.tabKey));
    await tester.pumpAndSettle();
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('硬件解码'), findsNothing);
  });

  testWidgets('窄屏把目录改成顶部横条，不是把目录丢掉', (tester) async {
    await pump(tester, size: const Size(420, 900));

    // 窄屏放不下 220 的侧栏，但每一格目录仍然可点。
    for (final tab in SettingsTab.values) {
      expect(find.byKey(tab.tabKey), findsOneWidget);
    }
    await tester.tap(find.byKey(SettingsTab.picture.tabKey));
    await tester.pumpAndSettle();
    expect(find.text('适应屏幕'), findsOneWidget);
  });

  testWidgets('目录标题与正文标题用同一套字体字号', (tester) async {
    await pump(tester);

    // 正文标题那条 ListTile 不写 style，所以它渲染出来用的是 Material
    // 给 ListTile 标题的那一项（titleMedium）。目录项要和它一致。
    TextStyle styleOf(Finder f) => tester.widget<Text>(f).style!;

    final tab = styleOf(find.descendant(
      of: find.byKey(SettingsTab.decode.tabKey),
      matching: find.byType(Text),
    ));
    // ListTile 标题没写 style 时由 ListTileTheme / titleMedium 决定。
    final ctx = tester.element(find.byType(SettingsScreen));
    final row = Theme.of(ctx).textTheme.titleMedium!;

    expect(tab.fontSize, row.fontSize,
        reason: '目录项的字号必须和正文标题一致，不能自成一套');
    expect(tab.fontFamily, row.fontFamily);

    // 选中与否只靠颜色和字重区分，不改字号 —— 字号一变，扫视时会觉得
    // 那是两种层级的东西。
    await tester.tap(find.byKey(SettingsTab.about.tabKey));
    await tester.pumpAndSettle();
    final selected = styleOf(find.descendant(
      of: find.byKey(SettingsTab.about.tabKey),
      matching: find.byType(Text),
    ));
    final unselected = styleOf(find.descendant(
      of: find.byKey(SettingsTab.decode.tabKey),
      matching: find.byType(Text),
    ));
    expect(selected.fontSize, unselected.fontSize);
    expect(selected.fontFamily, unselected.fontFamily);
    expect(selected.fontWeight, isNot(unselected.fontWeight),
        reason: '选中的那一项要靠字重区分出来');
  });

  testWidgets('界面字体仍然是 MiSans', (tester) async {
    await pump(tester);
    final ctx = tester.element(find.byType(SettingsScreen));
    expect(Theme.of(ctx).textTheme.bodyLarge?.fontFamily,
        LanPlayerTheme.fontFamily);
  });
}
