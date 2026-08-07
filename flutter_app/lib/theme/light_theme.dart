import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'stees_colors.dart';

/// Full Material 3 [ColorScheme] for Light Mode, plus the app's brand
/// semantic tokens ([SteesColors]) tuned for a light background.
class AppLightColors {
  static const SteesColors tokens = SteesColors(
    well: Color(0xFFF3F5F7),
    submerged: Color(0xFFFFFFFF),
    surface: Color(0xFFE9EEF2),
    surfaceLight: Color(0xFFDBE3EA),
    stream: Color(0xFF0F766E),
    leaf: Color(0xFF15803D),
    sunlight: Color(0xFFB45309),
    mist: Color(0xFF475569),
    foam: Color(0xFF0F172A),
    danger: Color(0xFFDC2626),
    border: Color(0x16000000),
    borderActive: Color(0x380F766E),
  );

  static const ColorScheme scheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF0F766E),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFCCE8E4),
    onPrimaryContainer: Color(0xFF042F2B),
    secondary: Color(0xFF47636F),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFD6E4EA),
    onSecondaryContainer: Color(0xFF142630),
    tertiary: Color(0xFF5C6B7A),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFE0E7EE),
    onTertiaryContainer: Color(0xFF24303B),
    error: Color(0xFFDC2626),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFED7D7),
    onErrorContainer: Color(0xFF450A0A),
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF0F172A),
    surfaceContainerHighest: Color(0xFFE9EEF2),
    surfaceContainerHigh: Color(0xFFEFF3F6),
    surfaceContainer: Color(0xFFF3F6F9),
    surfaceContainerLow: Color(0xFFF8FAFC),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    onSurfaceVariant: Color(0xFF475569),
    outline: Color(0xFFB6C2CC),
    outlineVariant: Color(0xFFD7E0E8),
    shadow: Color(0x1A000000),
    scrim: Color(0x52000000),
    inverseSurface: Color(0xFF1F2A35),
    onInverseSurface: Color(0xFFE9EEF2),
    inversePrimary: Color(0xFF6BD3C9),
    surfaceTint: Color(0xFF0F766E),
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
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
      ),
      iconTheme: IconThemeData(color: colors.mist),

    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.submerged,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      indicatorColor: colors.stream.withValues(alpha: 0.12),
      indicatorShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>((states) {
        final active = states.contains(WidgetState.selected);
        return textTheme.labelMedium?.copyWith(
          color: active ? colors.stream : colors.mist,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith<IconThemeData?>((states) {
        final active = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 24,
          color: active ? colors.stream : colors.mist,
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