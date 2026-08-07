import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'stees_colors.dart';

/// Full Material 3 [ColorScheme] for Dark Mode, plus the app's brand semantic
/// tokens tuned for a dark background.
class AppDarkColors {
  static const SteesColors tokens = SteesColors(
    well: Color(0xFF0B1922),
    submerged: Color(0xFF1A2D3D),
    surface: Color(0xFF152535),
    surfaceLight: Color(0xFF1E3347),
    stream: Color(0xFF2DD4BF),
    leaf: Color(0xFF34D399),
    sunlight: Color(0xFFFBBF24),
    mist: Color(0xFF94A3B8),
    foam: Color(0xFFF1F5F9),
    danger: Color(0xFFFF7A7A),
    border: Color(0x14FFFFFF),
    borderActive: Color(0x402DD4BF),
  );

  static const ColorScheme scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF2DD4BF),
    onPrimary: Color(0xFF003731),
    primaryContainer: Color(0xFF00525B),
    onPrimaryContainer: Color(0xFF9BEBDF),
    secondary: Color(0xFF34D399),
    onSecondary: Color(0xFF0B3622),
    surface: Color(0xFF152535),
    onSurface: Color(0xFFF1F5F9),
    surfaceContainerHighest: Color(0xFF1E3347),
    onSurfaceVariant: Color(0xFF94A3B8),
    error: Color(0xFFFF7A7A),
    onError: Color(0xFF3B0A0A),
    outline: Color(0xFF6B7B83),
    outlineVariant: Color(0xFF2A3A47),
    shadow: Color(0xFF000000),
    scrim: Color(0x99000000),
    inverseSurface: Color(0xFFEEF5F7),
    onInverseSurface: Color(0xFF1B252B),
    inversePrimary: Color(0xFF00897B),
    surfaceTint: Color(0xFF2DD4BF),
  );
}

/// The full Material 3 [ThemeData] for Dark Mode.
ThemeData buildDarkTheme() {
  final scheme = AppDarkColors.scheme;
  final colors = AppDarkColors.tokens;
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: Brightness.dark,
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
      backgroundColor: colors.submerged,
      surfaceTintColor: Colors.transparent,
      height: 68,
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
        side: WidgetStatePropertyAll(BorderSide(color: colors.border)),
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
        side: BorderSide(color: colors.stream.withValues(alpha: 0.35)),
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
      fillColor: colors.well,
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
      brightness: Brightness.dark,
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
        color: Colors.white,
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