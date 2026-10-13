import 'package:flutter/material.dart';

/// Auto Frame's visual language: deep black canvas, warm gold accent,
/// photographic restraint.
class AfColors {
  AfColors._();

  static const black = Color(0xFF050505);
  static const surface = Color(0xFF121212);
  static const surfaceHigh = Color(0xFF1C1C1E);
  static const outline = Color(0x33FFFFFF);
  static const gold = Color(0xFFFFB627);
  static const goldDim = Color(0x55FFB627);
  static const text = Color(0xFFF2F2F2);
  static const textDim = Color(0x99F2F2F2);
  static const good = Color(0xFF5BE38C);
  static const warn = Color(0xFFFF6B5B);
  static const record = Color(0xFFFF3B30);

  /// Score colour: red -> gold -> green.
  static Color forScore(double score) {
    if (score >= 75) return good;
    if (score >= 50) return gold;
    return warn;
  }
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AfColors.gold,
    brightness: Brightness.dark,
    surface: AfColors.surface,
  ).copyWith(primary: AfColors.gold, onPrimary: Colors.black);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AfColors.black,
    appBarTheme: const AppBarTheme(
      backgroundColor: AfColors.black,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
        color: AfColors.text,
      ),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 2,
      activeTrackColor: AfColors.gold,
      inactiveTrackColor: AfColors.outline,
      thumbColor: Colors.white,
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AfColors.surface,
      showDragHandle: true,
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AfColors.surfaceHigh,
      contentTextStyle: TextStyle(color: AfColors.text),
    ),
    textTheme: const TextTheme(
      labelSmall: TextStyle(letterSpacing: 1.1, fontWeight: FontWeight.w600),
    ),
  );
}
