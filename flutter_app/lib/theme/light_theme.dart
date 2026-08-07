import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'stees_colors.dart';

/// Full Material 3 [ColorScheme] for Light Mode, plus the app's brand
/// semantic tokens ([SteesColors]) tuned for a light background.
class AppLightColors {
  static const SteesColors tokens = SteesColors(
    well: Color(0xFFF4FAFB),
    submerged: Color(0xFFFFFFFF),
    surface: Color(0xFFEAF2F4),
    surfaceLight: Color(0xFFDCEAEC),
    stream: Color(0xFF00897B),
    leaf: Color(0xFF1B9E6E),
    sunlight: Color(0xFFB8860B),
    mist: Color(0xFF5B6B73),
    foam: Color(0xFF0F1B20),
    danger: Color(0xFFB3261E),
    border: Color(0x14000000),
    borderActive: Color(0x3300897B),
  );

  static const ColorScheme scheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF00897B),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFF9BEBDF),
    onPrimaryContainer: Color(0xFF00201C),
    secondary: Color(0xFF1B9E6E),
    onSecondary: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF0F1B20),
    surfaceContainerHighest: Color(0xFFEAF2F4),
    onSurfaceVariant: Color(0xFF5B6B73),
    error: Color(0xFFB3261E),
    onError: Color(0xFFFFFFFF),
    outline: Color(0xFF7B8A92),
    outlineVariant: Color(0xFFC6D1D5),
    shadow: Color(0x1F000000),
    scrim: Color(0x52000000),
    inverseSurface: Color(0xFF2A3439),
    onInverseSurface: Color(0xFFEEF5F7),
    inversePrimary: Color(0xFF80CBC4),
    surfaceTint: Color(0xFF00897B),
  );
}

/// The full Material 3 [ThemeData] for Light Mode.
ThemeData buildLightTheme() {
  final scheme = AppLightColors.scheme;
  final colors = AppLightColors.tokens;
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: Brightness.light,
  );
  final textTheme = GoogleFonts.interTextTheme(base.textTheme);

  return base.copyWith(
    scaffoldBackgroundColor: colors.well,
    colorScheme: scheme,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.well,
      foregroundColor: colors.foam,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: colors.foam,
        fontFamily: 'Sora',
        fontWeight: FontWeight.w600,
      ),
      iconTheme: IconThemeData(color: colors.mist),

    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      indicatorColor: colors.stream.withValues(alpha: 0.12),
      labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>((states) {
        final active = states.contains(WidgetState.selected);
        return textTheme.labelMedium?.copyWith(
          color: active ? colors.stream : colors.mist.withValues(alpha: 0.7),
          fontWeight: active ? FontWeight.w600 : FontWeight.w500,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith<IconThemeData?>((states) {
        final active = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 24,
          color: active ? colors.stream : colors.mist.withValues(alpha: 0.7),
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: colors.well,
      indicatorColor: colors.stream.withValues(alpha: 0.12),
      selectedIconTheme: IconThemeData(color: colors.stream),
      selectedLabelTextStyle: textTheme.labelSmall?.copyWith(
        color: colors.stream,
        fontWeight: FontWeight.w600,
      ),
      unselectedIconTheme: IconThemeData(
        color: colors.mist.withValues(alpha: 0.7),
      ),
      unselectedLabelTextStyle: textTheme.labelSmall?.copyWith(
        color: colors.mist.withValues(alpha: 0.7),
      ),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: colors.submerged,
      surfaceTintColor: Colors.transparent,

    ),
    cardTheme: CardThemeData(
      color: colors.submerged,
      surfaceTintColor: Colors.transparent,
      elevation: 0,

    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.submerged,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: textTheme.titleMedium?.copyWith(
        color: colors.foam,
        fontFamily: 'Sora',
        fontWeight: FontWeight.w600,
      ),
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: colors.mist),
      shadowColor: Colors.transparent,

    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.submerged,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: colors.submerged,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      shadowColor: Colors.transparent,

    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(colors.submerged),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(
          BorderSide(color: colors.border),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),

      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.submerged,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: textTheme.bodyMedium?.copyWith(color: colors.foam),

    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: colors.stream,
        foregroundColor: colors.well,
        elevation: 0,

      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: colors.stream,
        foregroundColor: colors.well,

      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.foam,
        side: BorderSide(color: colors.stream.withValues(alpha: 0.5)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),

      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: colors.stream),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: colors.stream,
      foregroundColor: colors.well,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),

      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.submerged,
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      hintStyle: textTheme.bodyMedium?.copyWith(
        color: colors.mist.withValues(alpha: 0.6),

      ),
      prefixIconColor: colors.mist,
      suffixIconColor: colors.mist,
      labelStyle: textTheme.bodySmall?.copyWith(color: colors.mist),
      helperStyle: textTheme.bodySmall?.copyWith(
        color: colors.mist.withValues(alpha: 0.5),

      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,

      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: colors.border),

      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: colors.stream, width: 1.5),

      ),

    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: colors.stream,
      selectionColor: colors.stream.withValues(alpha: 0.25),
      selectionHandleColor: colors.stream,

    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return colors.well;
        return colors.mist.withValues(alpha: 0.5);

      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? colors.leaf
            : colors.surfaceLight;

      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? colors.leaf
            : colors.mist.withValues(alpha: 0.4);

      }),

    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? colors.stream
            : Colors.transparent;

      }),
      checkColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? colors.well
            : colors.mist,

      ),
      side: BorderSide(color: colors.mist.withValues(alpha: 0.5)),

    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? colors.stream
            : colors.mist;

      }),

    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: colors.stream,
      inactiveTrackColor: colors.surfaceLight,
      thumbColor: colors.stream,
      overlayColor: colors.stream.withValues(alpha: 0.12),
      activeTickMarkColor: colors.well,

    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colors.stream,
      linearTrackColor: colors.surfaceLight,
      circularTrackColor: colors.surfaceLight,

    ),
    dividerTheme: DividerThemeData(
      color: colors.border,
      thickness: 1,

    ),
    iconTheme: IconThemeData(color: colors.mist),
    listTileTheme: ListTileThemeData(
      iconColor: colors.mist,
      textColor: colors.foam,
      subtitleTextStyle: textTheme.bodySmall?.copyWith(color: colors.mist),

    ),
    chipTheme: ChipThemeData(
      backgroundColor: colors.surface,
      selectedColor: colors.stream.withValues(alpha: 0.15),
      labelStyle: textTheme.labelMedium?.copyWith(color: colors.foam),
      secondaryLabelStyle: textTheme.labelMedium?.copyWith(color: colors.foam),
      side: BorderSide(color: colors.border),
      brightness: Brightness.light,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),

    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: colors.foam,

        borderRadius: BorderRadius.circular(8),

      ),
      textStyle: textTheme.bodySmall?.copyWith(color: colors.well),
      waitDuration: const Duration(milliseconds: 400),

    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: colors.danger,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: colors.well,
        fontSize: 13,

      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 6,

    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: colors.well,
        selectedBackgroundColor: colors.stream,
        selectedForegroundColor: colors.well,
        foregroundColor: colors.mist,
        side: BorderSide(color: colors.border),

      ),
    ),
    dataTableTheme: DataTableThemeData(
      headingTextStyle: textTheme.labelLarge?.copyWith(
        color: colors.stream,
        fontWeight: FontWeight.w600,

      ),
      dataTextStyle: textTheme.bodyMedium?.copyWith(color: colors.foam),
      headingRowColor: WidgetStatePropertyAll(colors.surface),
      dataRowColor: WidgetStatePropertyAll(colors.submerged),
      dividerThickness: 1,

    ),
    dividerColor: colors.border,
    extensions: [colors],

  );
}