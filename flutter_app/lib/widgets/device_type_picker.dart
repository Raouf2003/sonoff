import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/device_type.dart';
import '../theme/app_theme.dart';

/// Shared selector for the physical device type (relay count). Uses the
/// [DeviceType] enum directly so the number of relays/channels is defined in
/// exactly one place and passed through provisioning unchanged.
class DeviceTypePicker extends StatelessWidget {
  final DeviceType value;
  final ValueChanged<DeviceType> onChanged;

  const DeviceTypePicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final type in DeviceType.values) ...[
          Expanded(
            child: _Option(
              icon: type == DeviceType.oneRelay
                  ? Icons.power_settings_new
                  : Icons.grid_view,
              label: type.label,
              selected: type == value,
              onTap: () => onChanged(type),
            ),
          ),
          if (type != DeviceType.values.last) const SizedBox(width: AppSpacing.md),
        ],
      ],
    );
  }
}

class _Option extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Option({
    required this.icon,
    required this.label,
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
          ],
        ),
      ),
    );
  }
}