import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanplayer/main.dart';
import 'package:lanplayer/ui/theme.dart';

/// 深浅色跟随系统（评审 4.6）。
///
/// 在此之前 `LanPlayerApp` 只给了 `theme:`，等于把界面钉死在深色：系统设成
/// 浅色的用户看到的仍是深色底，而 README 承诺「深浅色跟随系统」。这里钉住
/// 三件事：两套主题都真的给出来了、`themeMode` 交给系统、浅色主题的底色是
/// 浅的（不是把深色底换个名字）。
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

  testWidgets('应用把 themeMode 交给系统，深色系统下取到深色主题', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(const LanPlayerApp());
    await tester.pump();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system, reason: '交给系统才知道用户选了浅色');
    expect(app.theme?.brightness, Brightness.light, reason: 'theme 是浅色那套');
    expect(app.darkTheme?.brightness, Brightness.dark);

    final theme = Theme.of(tester.element(find.byType(Scaffold).first));
    expect(theme.brightness, Brightness.dark, reason: '深色系统应当用 darkTheme');
  });

  testWidgets('浅色系统下取到浅色主题', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(const LanPlayerApp());
    await tester.pump();

    final theme = Theme.of(tester.element(find.byType(Scaffold).first));
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor.computeLuminance(), greaterThan(0.5));
  });
}
