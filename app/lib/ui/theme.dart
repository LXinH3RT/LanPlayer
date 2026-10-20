import 'package:flutter/material.dart';

/// Dark, cinema-first theme: the UI disappears while a video plays.
class LanPlayerTheme {
  static const Color accent = Color(0xFF4FC3F7);
  static const Color surface = Color(0xFF12161C);
  static const Color surfaceAlt = Color(0xFF1B222B);
  static const Color danger = Color(0xFFFF6E6E);

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
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
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
