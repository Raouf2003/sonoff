import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';

// ──────────────────────────────────────────────────────────────
// SteesCard
// ──────────────────────────────────────────────────────────────

class SteesCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final bool active;
  final VoidCallback? onTap;
  final Color? borderColor;

  const SteesCard({
    super.key,
    required this.child,
    this.padding,
    this.active = false,
    this.onTap,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final border = borderColor ??
        (active ? AppColors.borderActive : AppColors.border);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: padding ?? const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: border, width: 1),
          boxShadow: active ? AppShadows.glow : AppShadows.card,
        ),
        child: child,
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// SteesEmpty
// ──────────────────────────────────────────────────────────────

class SteesEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  const SteesEmpty({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.stream.withValues(alpha: 0.06),
                border: Border.all(color: AppColors.stream.withValues(alpha: 0.12)),
              ),
              child: Icon(icon, size: 32, color: AppColors.stream.withValues(alpha: 0.4)),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              title,
              style: GoogleFonts.sora(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.foam,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                height: 1.5,
                color: AppColors.mist.withValues(alpha: 0.7),
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.xxl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// SteesLoading
// ──────────────────────────────────────────────────────────────

class SteesLoading extends StatelessWidget {
  const SteesLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: AppColors.stream,
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// SteesSectionHeader
// ──────────────────────────────────────────────────────────────

class SteesSectionHeader extends StatelessWidget {
  final String title;
  final int? count;
  final Widget? trailing;

  const SteesSectionHeader({
    super.key,
    required this.title,
    this.count,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
      child: Row(
        children: [
          Text(
            title,
            style: GoogleFonts.sora(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.8,
              color: AppColors.mist,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                '$count',
                style: GoogleFonts.inter(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.mist,
                ),
              ),
            ),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// SteesActiveTag
// ──────────────────────────────────────────────────────────────

class SteesActiveTag extends StatelessWidget {
  final bool active;
  const SteesActiveTag({super.key, required this.active});

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.leaf : AppColors.mist;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 5, height: 5, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          const SizedBox(width: 4),
          Text(
            active ? 'Active' : 'Off',
            style: GoogleFonts.sora(fontSize: 10, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// SteesAvatar (circle icon)
// ──────────────────────────────────────────────────────────────

class SteesAvatar extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const SteesAvatar({
    super.key,
    required this.icon,
    required this.color,
    this.size = 36,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.12),
      ),
      child: Icon(icon, size: size * 0.5, color: color),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// SteesInfoRow
// ──────────────────────────────────────────────────────────────

class SteesInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget? value;

  const SteesInfoRow({
    super.key,
    required this.icon,
    required this.label,
    this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 13, color: AppColors.mist.withValues(alpha: 0.7)),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: AppColors.mist.withValues(alpha: 0.8),
            ),
          ),
        ),
        ?value,
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────
// SteesFAB
// ──────────────────────────────────────────────────────────────

class SteesFAB extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const SteesFAB({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      onPressed: onPressed,
      backgroundColor: AppColors.stream,
      foregroundColor: AppColors.well,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      icon: Icon(icon, size: 20),
      label: Text(
        label,
        style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    );
  }
}
