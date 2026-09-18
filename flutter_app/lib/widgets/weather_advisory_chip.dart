import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../l10n/gen/app_localizations.dart';
import '../theme/app_theme.dart';

class WeatherAdvisoryChip extends StatelessWidget {
  final Map<String, dynamic> advisory;
  const WeatherAdvisoryChip({super.key, required this.advisory});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final l10n = AppLocalizations.of(context)!;
    final isOverlap = advisory['type'] != 'adjacent';
    final rainStart = advisory['rainStart'] ?? '--:--';
    final rainEnd = advisory['rainEnd'] ?? '--:--';
    final mm = advisory['precipitationMm'];
    final prob = advisory['probability'];
    final color = isOverlap ? colors.stream : colors.sunlight;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(isOverlap ? '🌧' : '🌦', style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              l10n.wRainChip(
                rainStart.toString(),
                rainEnd.toString(),
                '${mm ?? '?'}',
                '${prob ?? '?'}',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
