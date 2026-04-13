import 'package:flutter/material.dart';

// Shared design tokens and app-level ThemeData builders.
class AuricTheme {
  // ─── Brand Colors ──────────────────────────────────────
  static const Color brandBlue = Color(0xFF3B82F6);
  static const Color brandBlueLight = Color(0xFF60A5FA);
  static const Color brandBlueDark = Color(0xFF1D4ED8);

  // ─── Dark Theme Colors ─────────────────────────────────
  static const Color darkBg = Color(0xFF0A0A0A);
  static const Color darkSurface = Color(0xFF111111);
  static const Color darkCard = Color(0xFF1A1A1A);
  static const Color darkBorder = Color(0xFF2A2A2A);
  static const Color darkText = Color(0xFFFFFFFF);
  static const Color darkSubtext = Color(0xFF9CA3AF);
  static const Color darkMuted = Color(0xFF4B5563);

  // ─── Light Theme Colors ────────────────────────────────
  static const Color lightBg = Color(0xFF99CCFF);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightCard = Color(0xFFF3F4F6);
  static const Color lightBorder = Color(0xFFE5E7EB);
  static const Color lightText = Color(0xFF111827);
  static const Color lightSubtext = Color(0xFF6B7280);

  // ─── Gradients ─────────────────────────────────────────
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [brandBlueLight, brandBlueDark],
  );

  static const LinearGradient darkBgGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF0A0A0A), Color(0xFF0D1117)],
  );

  // ─── Dark ThemeData ────────────────────────────────────
  static ThemeData dark() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBg,
      colorScheme: const ColorScheme.dark(
        primary: brandBlue,
        secondary: brandBlueLight,
        surface: darkSurface,
        onSurface: darkText,
      ),
      textTheme: _textTheme(darkText, darkSubtext),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          color: darkText,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        iconTheme: IconThemeData(color: darkSubtext),
      ),
    );
  }

  // ─── Light ThemeData ───────────────────────────────────
  static ThemeData light() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: lightBg,
      colorScheme: const ColorScheme.light(
        primary: brandBlue,
        secondary: brandBlueLight,
        surface: lightSurface,
        onSurface: lightText,
      ),
      textTheme: _textTheme(lightText, lightSubtext),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          color: lightText,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        iconTheme: IconThemeData(color: lightSubtext),
      ),
    );
  }

  static TextTheme _textTheme(Color primary, Color secondary) {
    return TextTheme(
      displayLarge: TextStyle(
        color: primary, fontSize: 48, fontWeight: FontWeight.w800, letterSpacing: -2),
      displayMedium: TextStyle(
        color: primary, fontSize: 36, fontWeight: FontWeight.w700, letterSpacing: -1),
      headlineLarge: TextStyle(
        color: primary, fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.5),
      headlineMedium: TextStyle(
        color: primary, fontSize: 22, fontWeight: FontWeight.w600),
      titleLarge: TextStyle(
        color: primary, fontSize: 18, fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(color: primary, fontSize: 16),
      bodyMedium: TextStyle(color: secondary, fontSize: 14),
      labelSmall: TextStyle(
        color: secondary, fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.w600),
    );
  }

  // ─── Glass Card Decoration ─────────────────────────────
  static BoxDecoration glassCard({bool isDark = true, double opacity = 0.05}) {
    return BoxDecoration(
      color: (isDark ? Colors.white : Colors.black).withOpacity(opacity),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(
        color: (isDark ? Colors.white : Colors.black).withOpacity(opacity * 0.8),
      ),
      boxShadow: isDark
          ? []
          : [BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 20,
              offset: const Offset(0, 4),
            )],
    );
  }
}
