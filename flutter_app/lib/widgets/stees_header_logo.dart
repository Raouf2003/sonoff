import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Top-left header logo badge for the STEES App Bar.
///
/// - Fixed 48x48 container so the original `assets/logo.png` is never
///   stretched or clipped (`BoxFit.contain`).
/// - Transparent background so it blends with the header (same header color),
///   soft 12px rounding, no circle outline / gradient / shadow.
/// - Logo image itself is untouched (no color filter / tint).
class SteesHeaderLogo extends StatelessWidget {
  final double size;
  const SteesHeaderLogo({super.key, this.size = 48});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Image.asset(
            'assets/logo.png',
            fit: BoxFit.contain,
            semanticLabel: 'STEES logo',
          ),
        ),
      ),
    );
  }
}

/// Hero logo for login / signup / splash.
///
/// - Clean image only: no background, no shadow, no glow.
///   Transparent PNG blends with the page, logo pixels untouched.
class SteesAuthLogo extends StatelessWidget {
  final double size;
  const SteesAuthLogo({super.key, this.size = 96});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        'assets/logo.png',
        fit: BoxFit.contain,
        semanticLabel: 'STEES logo',
      ),
    );
  }
}
