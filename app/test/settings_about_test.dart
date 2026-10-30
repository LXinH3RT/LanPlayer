import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/build_info.dart';
import 'package:lanplayer/ui/settings_screen.dart';
import 'package:lanplayer/ui/theme.dart';

/// 「设置 → 关于」里的版本号与界面字体。
///
/// 版本号的唯一来源是 `app/pubspec.yaml`，Flutter 不会把它带进 Dart，所以
/// 构建脚本用 `--dart-define=LANPLAYER_VERSION=` 注进来。这里锁三件事：
/// 没注入时落回 dev；注入后在「关于」里能看到这一行；界面字体走 MiSans。
void main() {
  /// 设置页现在是左目录右内容，一次只构建一格，所以先点「关于」再断言。
  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: LanPlayerTheme.dark(),
      home: const SettingsScreen(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SettingsTab.about.tabKey));
    await tester.pumpAndSettle();
  }

  test('没注入 define 时版本落回 dev', () {
    // String.fromEnvironment 在测试里没有 define，走默认值。
    expect(kAppVersion, 'dev');
  });

  testWidgets('设置 → 关于 里有版本这一行，值是注入的那个字符串', (tester) async {
    await pumpSettings(tester);

    expect(find.text('版本'), findsOneWidget);

    // 版本号是那一行的 subtitle，值来自编译期 define。
    final tile = find.ancestor(
      of: find.text('版本'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: tile, matching: find.text(kAppVersion)),
      findsOneWidget,
    );
  });

  testWidgets('界面默认字体是 MiSans', (tester) async {
    await pumpSettings(tester);

    final context = tester.element(find.byType(SettingsScreen));
    final theme = Theme.of(context);
    expect(theme.textTheme.bodyMedium?.fontFamily, LanPlayerTheme.fontFamily);
    expect(theme.textTheme.titleMedium?.fontFamily, LanPlayerTheme.fontFamily);
    // 设置页自己的标题也要跟着走，否则只剩正文是 MiSans。
    expect(theme.appBarTheme.titleTextStyle?.fontFamily,
        LanPlayerTheme.fontFamily);
  });
}
