import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/device_profile.dart';
import '../theme/app_theme.dart';

class HardwareProfilePicker extends StatelessWidget {
  final HardwareProfile value;
  final ValueChanged<HardwareProfile> onChanged;

  const HardwareProfilePicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final profile in HardwareProfile.values) ...[
          Expanded(
            child: _Option(
              icon: Icons.memory_outlined,
              label: profile.displayName,
              hint: profile.tasmotaModule == null ? 'Keeps its template' : null,
              selected: profile.id == value.id,
              onTap: () => onChanged(profile),
            ),
          ),
          if (profile != HardwareProfile.values.last)
            const SizedBox(width: AppSpacing.md),
        ],
      ],
    );
  }
}

class _Option extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? hint;
  final bool selected;
  final VoidCallback onTap;

  const _Option({
    required this.icon,
    required this.label,
    this.hint,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg, horizontal: AppSpacing.sm),
        decoration: BoxDecoration(
          color: selected ? colors.stream.withValues(alpha: 0.14) : colors.well,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
            color: selected ? colors.stream : colors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: selected ? colors.stream : colors.mist),
            const SizedBox(height: AppSpacing.sm),
            Text(
              label,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: selected ? colors.stream : colors.mist,
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 2),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(fontSize: 11, color: colors.mist),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
