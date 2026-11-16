/// The app's visual language: Persian, right-to-left, warm.
///
/// ## Why the palette is what it is
///
/// The default Material purple reads as a generic template. This app is about
/// food and money, and the colour carries meaning:
///
///   * A warm **amber** primary — appetite, warmth, meals.
///   * A deep **teal** secondary — money and calm, distinct from the food
///     colour so a balance never looks like a meal.
///   * Semantic colours: green for held, red for released, orange for a slot
///     closing.
///
/// Contrast was checked for WCAG AA on both light and dark schemes. In dark
/// mode, semantic tones are shifted to high-contrast pastel variants (> 5:1
/// contrast ratio on dark surfaces).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The app's colour scheme.
class AppColors {
  const AppColors._();

  /// Primary: a warm amber, for actions and headers.
  static const Color primary = Color(0xFFB45309);

  /// Primary container, for chips and selected states.
  static const Color primaryContainer = Color(0xFFFEF3C7);

  /// Secondary: a deep teal, for money and information.
  static const Color secondary = Color(0xFF0F766E);

  static const Color secondaryContainer = Color(0xFFCCFBF1);

  /// A meal the student holds (light mode).
  static const Color held = Color(0xFF15803D);

  /// A meal that was released or given up (light mode).
  static const Color released = Color(0xFFB91C1C);

  /// Something closing or expiring (light mode).
  static const Color closing = Color(0xFFEA580C);

  /// A meal the student holds (dark mode, high contrast).
  static const Color heldDark = Color(0xFF4ADE80);

  /// A meal that was released or given up (dark mode, high contrast).
  static const Color releasedDark = Color(0xFFF87171);

  /// Something closing or expiring (dark mode, high contrast).
  static const Color closingDark = Color(0xFFFB923C);

  /// Returns the theme-appropriate held meal colour.
  static Color heldOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? heldDark : held;

  /// Returns the theme-appropriate released meal colour.
  static Color releasedOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? releasedDark : released;

  /// Returns the theme-appropriate closing slot colour.
  static Color closingOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? closingDark : closing;
}

/// Custom semantic theme extension for meals and deadlines.
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({
    required this.held,
    required this.released,
    required this.closing,
  });

  final Color held;
  final Color released;
  final Color closing;

  static const light = AppSemanticColors(
    held: AppColors.held,
    released: AppColors.released,
    closing: AppColors.closing,
  );

  static const dark = AppSemanticColors(
    held: AppColors.heldDark,
    released: AppColors.releasedDark,
    closing: AppColors.closingDark,
  );

  @override
  ThemeExtension<AppSemanticColors> copyWith({
    Color? held,
    Color? released,
    Color? closing,
  }) {
    return AppSemanticColors(
      held: held ?? this.held,
      released: released ?? this.released,
      closing: closing ?? this.closing,
    );
  }

  @override
  ThemeExtension<AppSemanticColors> lerp(
    covariant ThemeExtension<AppSemanticColors>? other,
    double t,
  ) {
    if (other is! AppSemanticColors) return this;
    return AppSemanticColors(
      held: Color.lerp(held, other.held, t)!,
      released: Color.lerp(released, other.released, t)!,
      closing: Color.lerp(closing, other.closing, t)!,
    );
  }
}

/// Text and background colours for the light scheme.
const Color _lightSurface = Color(0xFFFDFCFA);
const Color _lightBackground = Color(0xFFF7F4EF);

/// Builds the app's light theme.
ThemeData buildLightTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.light,
      ).copyWith(
        primary: AppColors.primary,
        primaryContainer: AppColors.primaryContainer,
        secondary: AppColors.secondary,
        secondaryContainer: AppColors.secondaryContainer,
        surface: _lightSurface,
      );

  return _base(scheme).copyWith(
    scaffoldBackgroundColor: _lightBackground,
    extensions: const [AppSemanticColors.light],
  );
}

/// Builds the app's dark theme conforming to Material 3 standards.
ThemeData buildDarkTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.dark,
      ).copyWith(
        primary: const Color(0xFFF59E0B),
        onPrimary: const Color(0xFF451A03),
        primaryContainer: const Color(0xFF78350F),
        onPrimaryContainer: const Color(0xFFFEF3C7),
        secondary: const Color(0xFF2DD4BF),
        onSecondary: const Color(0xFF003732),
        secondaryContainer: const Color(0xFF134E4A),
        onSecondaryContainer: const Color(0xFFCCFBF1),
        surface: const Color(0xFF141316),
        onSurface: const Color(0xFFEDE9F0),
        onSurfaceVariant: const Color(0xFFCAC4CE),
        surfaceContainerLowest: const Color(0xFF0F0E11),
        surfaceContainerLow: const Color(0xFF19181C),
        surfaceContainer: const Color(0xFF1F1E22),
        surfaceContainerHigh: const Color(0xFF29282D),
        surfaceContainerHighest: const Color(0xFF343338),
        outline: const Color(0xFF948F99),
        outlineVariant: const Color(0xFF49454E),
        error: const Color(0xFFF87171),
        onError: const Color(0xFF450A0A),
        errorContainer: const Color(0xFF7F1D1D),
        onErrorContainer: const Color(0xFFFEE2E2),
      );

  return _base(scheme).copyWith(
    scaffoldBackgroundColor: scheme.surface,
    extensions: const [AppSemanticColors.dark],
  );
}

/// The parts of the theme shared by both schemes.
ThemeData _base(ColorScheme scheme) {
  final isDark = scheme.brightness == Brightness.dark;

  return ThemeData(
    useMaterial3: true,
    brightness: scheme.brightness,
    colorScheme: scheme,
    fontFamily: 'Vazirmatn',
    // Persian needs a little more line height than the Latin default, and the
    // descenders in Arabic script are deep.
    textTheme: _persianTextTheme(scheme),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 2,
      centerTitle: false,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: scheme.brightness,
        systemNavigationBarColor: scheme.surface,
        systemNavigationBarIconBrightness: isDark
            ? Brightness.light
            : Brightness.dark,
      ),
      titleTextStyle: TextStyle(
        fontFamily: 'Vazirmatn',
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: isDark ? scheme.surfaceContainer : scheme.surface,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: isDark ? 0.35 : 0.6),
        ),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: isDark ? scheme.surfaceContainerLow : scheme.surface,
      modalBackgroundColor: isDark
          ? scheme.surfaceContainerLow
          : scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? scheme.surfaceContainerLow : scheme.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.5),
      space: 1,
      thickness: 1,
    ),
    switchTheme: SwitchThemeData(
      // The disabled state must read as disabled. Without this, a switch that
      // the master switch has disabled still renders as a solid, "on" amber
      // block - which reads as active and misleads.
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return scheme.onSurface.withValues(alpha: 0.38);
        }
        if (states.contains(WidgetState.selected)) return scheme.onPrimary;
        return scheme.outline;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return scheme.onSurface.withValues(alpha: 0.12);
        }
        if (states.contains(WidgetState.selected)) {
          return scheme.primary.withValues(alpha: 0.5);
        }
        return scheme.surfaceContainerHighest;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? scheme.onSurface.withValues(alpha: 0.12)
            : scheme.outline,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      elevation: 2,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: 'Vazirmatn',
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? scheme.onSurface
              : scheme.onSurfaceVariant,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide(color: scheme.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
      closeIconColor: isDark ? scheme.onSurface : Colors.white,
      backgroundColor: isDark ? scheme.surfaceContainerHighest : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      contentTextStyle: TextStyle(
        fontFamily: 'Vazirmatn',
        color: isDark ? scheme.onSurface : null,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: isDark ? scheme.surfaceContainerHigh : scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: TextStyle(
        fontFamily: 'Vazirmatn',
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      contentTextStyle: TextStyle(
        fontFamily: 'Vazirmatn',
        fontSize: 14,
        height: 1.7,
        color: scheme.onSurfaceVariant,
      ),
    ),
  );
}

/// The text theme, with Persian-appropriate line heights.
TextTheme _persianTextTheme(ColorScheme scheme) {
  final base = ThemeData(brightness: scheme.brightness).textTheme;
  TextStyle style(TextStyle? s, {double? height, Color? color}) =>
      (s ?? const TextStyle()).copyWith(
        fontFamily: 'Vazirmatn',
        height: height ?? 1.6,
        color: color ?? scheme.onSurface,
      );

  return TextTheme(
    displaySmall: style(base.displaySmall, height: 1.4),
    headlineMedium: style(base.headlineMedium, height: 1.4),
    headlineSmall: style(base.headlineSmall, height: 1.4),
    titleLarge: style(base.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
    titleMedium: style(base.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
    titleSmall: style(base.titleSmall?.copyWith(fontWeight: FontWeight.w500)),
    bodyLarge: style(base.bodyLarge),
    bodyMedium: style(base.bodyMedium),
    bodySmall: style(
      base.bodySmall,
      height: 1.5,
      color: scheme.onSurfaceVariant,
    ),
    labelLarge: style(base.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
    labelMedium: style(base.labelMedium, color: scheme.onSurfaceVariant),
    labelSmall: style(base.labelSmall, color: scheme.onSurfaceVariant),
  );
}
