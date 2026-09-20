import 'package:flutter/material.dart';

// 极客风主题: 等宽字体 + 终端绿/青绿主色, 自动/白天/黑夜共用一套风格
ThemeData geekTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final seed = dark ? const Color(0xFF2BFFB0) : const Color(0xFF00997A);
  final bg = dark ? const Color(0xFF0A0E12) : const Color(0xFFF4F6F8);
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b).copyWith(
    surface: dark ? const Color(0xFF11171E) : Colors.white,
    onSurface: dark ? const Color(0xFFC7D2DC) : const Color(0xFF0F1B24),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    fontFamily: 'monospace',
    scaffoldBackgroundColor: bg,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outline.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(8),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    dividerTheme: DividerThemeData(color: scheme.outline.withValues(alpha: 0.2)),
    chipTheme: ChipThemeData.fromDefaults(
      brightness: b,
      secondaryColor: scheme.primary,
      labelStyle: TextStyle(color: scheme.onSurface),
    ),
  );
}
