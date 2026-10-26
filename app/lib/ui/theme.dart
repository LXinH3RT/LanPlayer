import 'package:flutter/material.dart';

/// Dark, cinema-first theme: the UI disappears while a video plays.
class LanPlayerTheme {
  static const Color accent = Color(0xFF4FC3F7);
  static const Color surface = Color(0xFF12161C);
  static const Color surfaceAlt = Color(0xFF1B222B);
  static const Color danger = Color(0xFFFF6E6E);

  /// 打包进来的界面字体（见 pubspec.yaml 的 fonts 段）。
  static const String fontFamily = 'MiSans';

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    ).copyWith(
      surface: surface,
      primary: accent,
      error: danger,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: surface,
      visualDensity: VisualDensity.standard,
      // 全局字体：MiSans（见 pubspec.yaml 的 fonts 段）。
      //
      // 之前没设 fontFamily，Windows 上中文只能落到系统的 fallback 字体，
      // 而 Material 的各处 TextStyle 又常常只写 fontSize/fontWeight，于是
      // 同一个界面里「音轨」「关闭」这类中文与数字、拉丁字母来自两套字，
      // 笔画粗细和字面大小都不一致，看起来像字体坏了。
      fontFamily: fontFamily,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: surfaceAlt,
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
