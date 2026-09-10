import 'package:flutter/material.dart';
import 'light_theme.dart';
import 'dark_theme.dart';
import 'stees_colors.dart';

/// Public theme entry point. Holds the flock of concrete theme builders plus
/// the app-wide semantic token accessor used by every widget.
class AppTheme {
  const AppTheme._();

  static ThemeData light() => buildLightTheme();
  static ThemeData dark() => buildDarkTheme();
}

/// Layout constants (unchanged from the previous `theme.dart`).
class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
}

class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}

class AppShadows {
  static BoxShadow cardShadow(Color shadowColor) =>
      BoxShadow(color: shadowColor, blurRadius: 16, offset: const Offset(0, 4));
  static BoxShadow softShadow(Color shadowColor) =>
      BoxShadow(color: shadowColor.withValues(alpha: 0.10), blurRadius: 18, offset: const Offset(0, 6));
  static BoxShadow glow(Color glowColor) =>
      BoxShadow(color: glowColor.withValues(alpha: 0.14), blurRadius: 14, offset: Offset.zero);
}

/// Convenience accessor so widgets write `context.steesColors.stream` instead
/// of reaching into `Theme.of(context).extension<SteesColors>()`.
extension SteesColorsX on BuildContext {
  SteesColors get steesColors =>
      Theme.of(this).extension<SteesColors>() ?? AppDarkColors.tokens;

  SteesColors get appColors => steesColors;
}