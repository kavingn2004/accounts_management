import 'package:flutter/material.dart';

/// Blue & white (and dark) Material 3 theme with a soft, card-based look.
class AppTheme {
  static const Color primary = Color(0xFF1565C0); // strong blue
  static const Color primaryDark = Color(0xFF0D47A1);
  static const Color accent = Color(0xFF42A5F5); // light blue

  // Per-module accent palette (multi-colour highlights).
  static const Color cIncome = Color(0xFF2E7D32);
  static const Color cExpense = Color(0xFFE53935);
  static const Color cSavings = Color(0xFF00897B);
  static const Color cInvest = Color(0xFF6A1B9A);
  static const Color cDebtor = Color(0xFF1565C0);
  static const Color cCreditor = Color(0xFFC2185B);
  static const Color cBills = Color(0xFFEF6C00);
  static const Color cAlerts = Color(0xFF3949AB);
  static const Color cLoan = Color(0xFF6D4C41); // brown

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final isDark = b == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(seedColor: primary, brightness: b);

    final cardColor = isDark ? const Color(0xFF1E1F26) : Colors.white;
    final scaffoldColor = isDark ? const Color(0xFF131419) : Colors.white;
    final borderColor =
        isDark ? const Color(0xFF2C2D36) : const Color(0xFFE3E9F2);

    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffoldColor,
      // Keep the brand-blue app bar in both modes.
      appBarTheme: const AppBarTheme(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: borderColor),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Colors.white,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          minimumSize: const Size.fromHeight(48),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cardColor,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primary, width: 1.5),
        ),
      ),
      listTileTheme: const ListTileThemeData(iconColor: primary),
    );
  }
}
