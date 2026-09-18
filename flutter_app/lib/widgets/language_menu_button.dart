import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../l10n/gen/app_localizations.dart';
import '../l10n/locale_controller.dart';
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';

/// Compact language selector reused anywhere a full header is unavailable
/// (login / signup screens, secondary AppBars).
///
/// Drives the app-wide [LocaleController] — the single source of truth — so
/// switching rebuilds the whole app in place without losing navigation or
/// form state.
class LanguageMenuButton extends StatelessWidget {
  final LocaleController controller;
  final bool compact;

  const LanguageMenuButton({
    super.key,
    required this.controller,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final current = controller.locale.languageCode;
        return PopupMenuButton<String>(
          icon: compact
              ? const Icon(Icons.language_outlined, size: 20)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.language_outlined, size: 20),
                    const SizedBox(width: 2),
                    Text(
                      current.toUpperCase(),
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: colors.mist,
                      ),
                    ),
                  ],
                ),
          tooltip: l10n.actionLanguage,
          color: colors.submerged,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            side: BorderSide(color: colors.border),
          ),
          onSelected: (value) => controller.setLocale(Locale(value)),
          itemBuilder: (_) => [
            _item(colors, 'en', l10n.languageEnglish, current),
            _item(colors, 'ar', l10n.languageArabic, current),
            _item(colors, 'fr', l10n.languageFrench, current),
          ],
        );
      },
    );
  }

  PopupMenuItem<String> _item(
    SteesColors colors,
    String value,
    String label,
    String current,
  ) {
    final selected = value == current;
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? colors.stream : colors.foam,
              ),
            ),
          ),
          if (selected)
            Icon(Icons.check_rounded, size: 16, color: colors.stream),
        ],
      ),
    );
  }
}
