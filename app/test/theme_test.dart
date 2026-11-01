import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/data/models.dart' show AppThemeMode;
import 'package:lanplayer/main.dart';
import 'package:lanplayer/ui/theme.dart';

/// 深浅色与「外观」设置（评审 4.6、用户 2026-11-01 的要求）。
///
/// 此前 `LanPlayerApp` 的 `themeMode` 固定是 `ThemeMode.system`：用户想要
/// 「一直黑」或「一直白」都没有入口。现在默认黑，可选白或跟随系统，切换
/// 立刻生效。这里钉住三件事：两套主题都真的给出来了、默认是黑、切换真的
/// 换到对应的那套。
void main() {
  group('LanPlayerTheme 的深浅两套', () {
    test('浅色主题的底色是浅的，深色主题的底色是深的', () {
      final light = LanPlayerTheme.light();
      final dark = LanPlayerTheme.dark();

      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);

      // 只看 brightness 不够：把 `_build(Brightness.light)` 里写死的
      // `scaffoldBackgroundColor: surface` 忘了换，brightness 仍然是对的，
      // 界面却还是黑底。
      expect(light.scaffoldBackgroundColor.computeLuminance(), greaterThan(0.5),
          reason: '浅色主题的背景不该是深色');
      expect(dark.scaffoldBackgroundColor.computeLuminance(), lessThan(0.2),
          reason: '深色主题的背景不该是浅色');
    });

    test('两套主题都用打包进来的 MiSans，并保留强调色', () {
      for (final theme in [LanPlayerTheme.light(), LanPlayerTheme.dark()]) {
        expect(
            theme.textTheme.bodyMedium?.fontFamily, LanPlayerTheme.fontFamily,
            reason: '全局字体掉了，中文会落到系统 fallback');
        expect(theme.colorScheme.primary, LanPlayerTheme.accent,
            reason: '强调色在两种亮度下应当是同一个，否则按钮在浅色下会变灰');
      }
    });

    test('错误色按亮度分开：深色用亮红，浅色用暗红', () {
      expect(LanPlayerTheme.dark().colorScheme.error, LanPlayerTheme.danger);
      expect(
          LanPlayerTheme.light().colorScheme.error, LanPlayerTheme.lightDanger);
      // 深色主题那颗亮红放到白底上对比度不够，浅色必须换一档。
      expect(LanPlayerTheme.lightDanger, isNot(LanPlayerTheme.danger));
    });
  });

  testWidgets('默认是黑色主题，不是跟着系统走', (tester) async {
    // 用户 2026-11-01 要求「默认黑色」：系统是浅色时也先给黑底，
    // 这是播放器，暗底看片更舒服，也让首屏观感稳定。
    addTearDown(() => ThemeController.instance.reset());

    await tester.pumpWidget(const LanPlayerApp());
    await tester.pump();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(app.theme?.brightness, Brightness.light, reason: 'theme 是浅色那套');
    expect(app.darkTheme?.brightness, Brightness.dark);

    final theme = Theme.of(tester.element(find.byType(Scaffold).first));
    expect(theme.brightness, Brightness.dark);
  });

  testWidgets('改成浅色后整个应用立刻变亮，改回跟随系统后听系统的', (tester) async {
    addTearDown(() => ThemeController.instance.reset());
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(const LanPlayerApp());
    await tester.pumpAndSettle();

    ThemeController.instance.apply(AppThemeMode.light);
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.light,
    );
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first))
          .scaffoldBackgroundColor
          .computeLuminance(),
      greaterThan(0.5),
    );

    // 跟随系统时既不该钉死浅色，也不该钉死深色。
    ThemeController.instance.apply(AppThemeMode.system);
    await tester.pumpAndSettle();
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system, reason: '交给系统才知道用户选了浅色');
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.light,
    );
  });
}
