import 'package:flutter/material.dart';

/// Design tokens for the Accounflow redesign — "paper, one accent, serif for
/// statements". Ivory ground, clay interaction, borders instead of shadows.
///
/// Every colour here was contrast-checked against the surface it sits on;
/// see UI_REDESIGN.md §2. Two traps are encoded in the token names:
///
///  * [AppColors.accent] fails AA as *text* on light (4.16:1). Use it only for
///    fills — FAB, focus ring, selection tint. For clay text use [accentText].
///  * White on [accent] is only 4.23:1, so filled buttons use [buttonFill]
///    (#B85536, 4.78:1 with white) rather than the accent itself.
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.accent,
    required this.accentText,
    required this.buttonFill,
    required this.onButtonFill,
    required this.onAccent,
    required this.positive,
    required this.negative,
    required this.chipAlpha,
  });

  final Color bg;
  final Color surface;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;

  /// Fills only — never text. See the class doc.
  final Color accent;

  /// Clay used as text (links, TextButton labels).
  final Color accentText;

  /// Filled-button background; darker than [accent] so its label passes AA.
  final Color buttonFill;
  final Color onButtonFill;

  /// Glyph colour on top of an [accent] fill (the FAB).
  final Color onAccent;

  final Color positive;
  final Color negative;

  /// Opacity for module-tinted icon chips — lighter ground needs less.
  final double chipAlpha;

  static const light = AppColors(
    bg: Color(0xFFF5F1EB),
    surface: Color(0xFFFFFDFA),
    border: Color(0xFFE4DDD2),
    textPrimary: Color(0xFF1F1E1C),
    textSecondary: Color(0xFF6B655C),
    accent: Color(0xFFC15F3C),
    accentText: Color(0xFFA44B2C),
    buttonFill: Color(0xFFB85536),
    onButtonFill: Color(0xFFFFFDFA),
    onAccent: Color(0xFFFFFDFA),
    positive: Color(0xFF2F6B4F),
    negative: Color(0xFF8C2F26),
    chipAlpha: 0.12,
  );

  static const dark = AppColors(
    bg: Color(0xFF1A1917),
    surface: Color(0xFF232120),
    border: Color(0xFF35322E),
    textPrimary: Color(0xFFEDE9E3),
    textSecondary: Color(0xFFA39C92),
    // On the warm dark ground clay clears AA at 5.14:1, so one token serves
    // fill, text, and button alike.
    accent: Color(0xFFD97757),
    accentText: Color(0xFFD97757),
    buttonFill: Color(0xFFD97757),
    onButtonFill: Color(0xFF1F1E1C),
    onAccent: Color(0xFF1F1E1C),
    positive: Color(0xFF7FB08A),
    negative: Color(0xFFE08A7D),
    chipAlpha: 0.16,
  );

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return t < 0.5 ? this : other;
  }
}

/// Per-module accent. Category colour survives the redesign only at icon-chip
/// size — the value itself is always [AppColors.textPrimary]. Direction of
/// money (positive/negative) is what keeps real colour.
enum ModuleTone {
  income(Color(0xFF2F6B4F), Color(0xFF7FB08A)),
  expense(Color(0xFF8C2F26), Color(0xFFE08A7D)),
  savings(Color(0xFF2C6E6B), Color(0xFF6FB3AF)),
  invest(Color(0xFF5B4B8A), Color(0xFFA99BD4)),
  debtor(Color(0xFF3A5F8A), Color(0xFF8FB3DE)),
  creditor(Color(0xFF8A3A5F), Color(0xFFDE8FB3)),
  bills(Color(0xFF8A5A22), Color(0xFFD9A867)),
  loan(Color(0xFF6B4F3A), Color(0xFFBFA08A)),
  alerts(Color(0xFF4A4A7A), Color(0xFF9A9AD4));

  const ModuleTone(this.light, this.dark);

  final Color light;
  final Color dark;

  Color of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// Tinted background for the 32px icon chip this tone appears in.
  Color chip(BuildContext context) =>
      of(context).withValues(alpha: context.colors.chipAlpha);
}

extension AppColorsX on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
  TextTheme get text => Theme.of(this).textTheme;
}

/// Money and any figure that lines up in a column. Without tabular figures
/// amount columns visibly misalign row to row.
const List<FontFeature> tabular = [FontFeature.tabularFigures()];

class AppTheme {
  AppTheme._();

  static const String sans = 'Inter';
  static const String serif = 'SourceSerif4';

  /// Radii — smaller than stock Material, which reads more editorial.
  static const double rCard = 12;
  static const double rControl = 10;
  static const double rChip = 8;
  static const double rFab = 16;

  static const double rowHeight = 64;
  static const double screenPad = 20;

  static ThemeData get light => _build(AppColors.light, Brightness.light);
  static ThemeData get dark => _build(AppColors.dark, Brightness.dark);

  /// Serif display face — screen titles and headline figures only.
  static TextStyle display(
    double size, {
    required double height,
    Color? color,
    double letterSpacing = 0,
    bool numeric = false,
  }) =>
      TextStyle(
        fontFamily: serif,
        fontSize: size,
        height: height / size,
        fontWeight: FontWeight.w600,
        letterSpacing: letterSpacing,
        color: color,
        fontFeatures: numeric ? tabular : null,
      );

  static ThemeData _build(AppColors c, Brightness brightness) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: c.buttonFill,
      onPrimary: c.onButtonFill,
      secondary: c.accent,
      onSecondary: c.onAccent,
      error: c.negative,
      onError: c.surface,
      surface: c.surface,
      onSurface: c.textPrimary,
      surfaceContainerHighest: c.bg,
      outline: c.border,
      outlineVariant: c.border,
    );

    final text = TextTheme(
      // Serif — statements.
      displayLarge: display(32, height: 38, letterSpacing: -0.32, numeric: true),
      displayMedium:
          display(30, height: 36, letterSpacing: -0.3, numeric: true),
      displaySmall: display(26, height: 32, numeric: true),
      headlineMedium: display(24, height: 30, letterSpacing: -0.24),
      headlineSmall: display(22, height: 28),
      titleLarge: display(20, height: 26),

      // Sans — everything you scan or compare.
      titleMedium: const TextStyle(
        fontFamily: sans,
        fontSize: 16,
        height: 22 / 16,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: const TextStyle(
        fontFamily: sans,
        fontSize: 15,
        height: 20 / 15,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: const TextStyle(
        fontFamily: sans,
        fontSize: 15,
        height: 22 / 15,
      ),
      bodyMedium: const TextStyle(
        fontFamily: sans,
        fontSize: 14,
        height: 20 / 14,
      ),
      bodySmall: const TextStyle(
        fontFamily: sans,
        fontSize: 13,
        height: 20 / 13,
      ),
      labelLarge: const TextStyle(
        fontFamily: sans,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      labelMedium: const TextStyle(
        fontFamily: sans,
        fontSize: 12,
        height: 16 / 12,
        fontWeight: FontWeight.w500,
      ),
      labelSmall: const TextStyle(
        fontFamily: sans,
        fontSize: 11,
        height: 15 / 11,
        fontWeight: FontWeight.w500,
      ),
    ).apply(
      bodyColor: c.textPrimary,
      displayColor: c.textPrimary,
    );

    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(rControl),
      borderSide: BorderSide(color: c.border),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      extensions: [c],
      scaffoldBackgroundColor: c.bg,
      canvasColor: c.bg,
      dividerColor: c.border,
      fontFamily: sans,
      textTheme: text,

      // Transparent over the page — the blue bar is gone in both modes.
      appBarTheme: AppBarTheme(
        backgroundColor: c.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 56,
        centerTitle: false,
        titleTextStyle: text.headlineMedium,
        iconTheme: IconThemeData(color: c.textPrimary, size: 20),
        actionsIconTheme: IconThemeData(color: c.textSecondary, size: 20),
      ),

      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rCard),
          side: BorderSide(color: c.border),
        ),
        clipBehavior: Clip.antiAlias,
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rFab),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.buttonFill,
          foregroundColor: c.onButtonFill,
          disabledBackgroundColor: c.border,
          disabledForegroundColor: c.textSecondary,
          minimumSize: const Size.fromHeight(48),
          textStyle: text.labelLarge,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rControl),
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          minimumSize: const Size.fromHeight(48),
          textStyle: text.labelLarge,
          side: BorderSide(color: c.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rControl),
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.accentText,
          textStyle: const TextStyle(
            fontFamily: sans,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surface,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rControl),
          borderSide: BorderSide(color: c.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rControl),
          borderSide: BorderSide(color: c.negative, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rControl),
          borderSide: BorderSide(color: c.negative, width: 1.5),
        ),
        labelStyle: text.labelMedium?.copyWith(color: c.textSecondary),
        floatingLabelStyle: text.labelMedium?.copyWith(color: c.textSecondary),
        hintStyle: text.bodyMedium?.copyWith(color: c.textSecondary),
        errorStyle: text.labelMedium?.copyWith(color: c.negative),
        prefixIconColor: c.textSecondary,
        suffixIconColor: c.textSecondary,
      ),

      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        selectedColor: c.accent.withValues(alpha: c.chipAlpha),
        side: BorderSide(color: c.border),
        labelStyle: text.labelMedium!.copyWith(color: c.textSecondary),
        secondaryLabelStyle:
            text.labelMedium!.copyWith(color: c.textPrimary),
        showCheckmark: false,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rChip),
        ),
      ),

      dividerTheme: DividerThemeData(
        color: c.border,
        thickness: 1,
        space: 1,
      ),

      listTileTheme: ListTileThemeData(
        iconColor: c.textSecondary,
        textColor: c.textPrimary,
        titleTextStyle: text.titleMedium,
        subtitleTextStyle: text.bodyMedium?.copyWith(color: c.textSecondary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rControl),
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalBarrierColor: brightness == Brightness.dark
            ? const Color(0xFF12100D).withValues(alpha: 0.5)
            : const Color(0xFF1F1E1C).withValues(alpha: 0.32),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(rCard)),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: text.headlineSmall,
        contentTextStyle: text.bodyMedium?.copyWith(color: c.textSecondary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rCard),
          side: BorderSide(color: c.border),
        ),
      ),

      drawerTheme: DrawerThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.textPrimary,
        contentTextStyle: text.bodyMedium?.copyWith(color: c.bg),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rControl),
        ),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accent,
        linearTrackColor: c.border,
        circularTrackColor: c.border,
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.onButtonFill : c.surface,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.buttonFill : c.border,
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),

      iconTheme: IconThemeData(color: c.textSecondary, size: 20),
    );
  }
}
