import 'package:flutter/material.dart';

/// Semantic color tokens shared across the whole app.
///
/// A [ThemeExtension] so every token adapts per light/dark theme. Widgets
/// resolve them through [BuildContext.steesColors] (see app_theme.dart) and
/// never read hardcoded `Color(...)` values themselves.
class SteesColors extends ThemeExtension<SteesColors> {
  /// Deep background / backdrop color.
  final Color well;

  /// Card / elevated surface background.
  final Color submerged;

  /// Secondary surface (slightly different tone than [submerged]).
  final Color surface;

  /// Elevated / highlighted surface (e.g. selected pills).
  final Color surfaceLight;

  /// Primary brand / accent color (teal).
  final Color stream;

  /// Secondary brand / "active / success" color (green).
  final Color leaf;

  /// Tertiary / highlight color (amber, warnings).
  final Color sunlight;

  /// Muted / secondary text color.
  final Color mist;

  /// Primary text color on branded surfaces.
  final Color foam;

  /// Error / destructive color.
  final Color danger;

  /// Default hairline border color.
  final Color border;

  /// Active / selected border accent.
  final Color borderActive;

  const SteesColors({
    required this.well,
    required this.submerged,
    required this.surface,
    required this.surfaceLight,
    required this.stream,
    required this.leaf,
    required this.sunlight,
    required this.mist,
    required this.foam,
    required this.danger,
    required this.border,
    required this.borderActive,
  });

  @override
  SteesColors copyWith({
    Color? well,
    Color? submerged,
    Color? surface,
    Color? surfaceLight,
    Color? stream,
    Color? leaf,
    Color? sunlight,
    Color? mist,
    Color? foam,
    Color? danger,
    Color? border,
    Color? borderActive,
  }) {
    return SteesColors(
      well: well ?? this.well,
      submerged: submerged ?? this.submerged,
      surface: surface ?? this.surface,
      surfaceLight: surfaceLight ?? this.surfaceLight,
      stream: stream ?? this.stream,
      leaf: leaf ?? this.leaf,
      sunlight: sunlight ?? this.sunlight,
      mist: mist ?? this.mist,
      foam: foam ?? this.foam,
      danger: danger ?? this.danger,
      border: border ?? this.border,
      borderActive: borderActive ?? this.borderActive,
    );
  }

  @override
  SteesColors lerp(ThemeExtension<SteesColors>? other, double t) {
    if (other is! SteesColors) return this;
    return SteesColors(
      well: Color.lerp(well, other.well, t)!,
      submerged: Color.lerp(submerged, other.submerged, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceLight: Color.lerp(surfaceLight, other.surfaceLight, t)!,
      stream: Color.lerp(stream, other.stream, t)!,
      leaf: Color.lerp(leaf, other.leaf, t)!,
      sunlight: Color.lerp(sunlight, other.sunlight, t)!,
      mist: Color.lerp(mist, other.mist, t)!,
      foam: Color.lerp(foam, other.foam, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderActive: Color.lerp(borderActive, other.borderActive, t)!,
    );
  }
}