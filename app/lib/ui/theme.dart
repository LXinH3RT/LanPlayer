import 'package:flutter/material.dart';

/// 深色为主、跟随系统切换的界面主题。
///
/// 深色是主场景：播放时界面要消失，只剩画面。但桌面与移动端都可能有用户把
/// 系统设成浅色，README 也承诺「深浅色跟随系统」，所以两套都要给。这里不改
/// 任何业务色（强调色、危险色在两种亮度下用的是同一组语义），只是把底色与
/// 前景色按亮度换一套。
class LanPlayerTheme {
  static const Color accent = Color(0xFF4FC3F7);

  /// 深色底色。播放页、启动页这些固定场景也会直接引用。
  static const Color surface = Color(0xFF12161C);
  static const Color surfaceAlt = Color(0xFF1B222B);

  /// 浅色底色。
  ///
  /// 不用纯白：Material 3 的浅色表面本身带一点灰度，纯白上叠卡片会看不出
  /// 层次；`surfaceAlt` 才是卡片用的纯白。
  static const Color lightSurface = Color(0xFFF5F7FA);
  static const Color lightSurfaceAlt = Color(0xFFFFFFFF);

  static const Color danger = Color(0xFFFF6E6E);
  static const Color lightDanger = Color(0xFFC62828);

  /// 打包进来的界面字体（见 pubspec.yaml 的 fonts 段）。
  static const String fontFamily = 'MiSans';

  /// 深色主题。播放页、启动页的固定黑底不受这套配色影响。
  static ThemeData dark() => _build(Brightness.dark);

  /// 浅色主题。
  static ThemeData light() => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final base = isDark ? surface : lightSurface;
    final card = isDark ? surfaceAlt : lightSurfaceAlt;

    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    ).copyWith(
      surface: base,
      primary: accent,
      error: isDark ? danger : lightDanger,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: base,
      visualDensity: VisualDensity.standard,
      // 全局字体：MiSans（见 pubspec.yaml 的 fonts 段）。
      //
      // 之前没设 fontFamily，Windows 上中文只能落到系统的 fallback 字体，
      // 而 Material 的各处 TextStyle 又常常只写 fontSize/fontWeight，于是
      // 同一个界面里「音轨」「关闭」这类中文与数字、拉丁字母来自两套字，
      // 笔画粗细和字面大小都不一致，看起来像字体坏了。
      fontFamily: fontFamily,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          // 不写 color 的话浅色主题下标题会取到 M3 的 onSurface 默认值，
          // 深色主题下也一致，所以这里显式跟随主题而不是写死白色。
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 3,
        overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
      ),
      snackBarTheme:
          const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}
