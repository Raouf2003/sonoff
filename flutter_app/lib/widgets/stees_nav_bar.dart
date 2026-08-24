import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

/// One destination in the [SteesNavBar].
class SteesNavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const SteesNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}

/// Custom bottom navigation styled as an industrial control-cabinet bus bar.
///
/// A docked fascia with a hairline top seam; channels are separated by
/// inset engraved grooves. The selected channel reads as energized: a
/// backlit wash spills down from its segment while a short accent tick
/// slides along the top edge to meet it.
class SteesNavBar extends StatelessWidget {
  final List<SteesNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  const SteesNavBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final slideDuration =
        reduceMotion ? Duration.zero : const Duration(milliseconds: 280);
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segmentWidth = constraints.maxWidth / items.length;
          return Container(
            height: 68,
            decoration: BoxDecoration(
              color: colors.submerged,
              border: Border(top: BorderSide(color: colors.border)),
            ),
            child: Stack(
              children: [
                // Backlit wash: light spilling down from the energized
                // segment, fading out before mid-bar.
                AnimatedPositioned(
                  duration: slideDuration,
                  curve: Curves.easeOutCubic,
                  left: currentIndex * segmentWidth,
                  width: segmentWidth,
                  top: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0, 0.55],
                        colors: [
                          colors.stream.withValues(alpha: 0.08),
                          colors.stream.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
                // Energized tick riding the top seam. A touch of overshoot
                // sells the mechanical settle without feeling bouncy.
                AnimatedPositioned(
                  duration: slideDuration,
                  curve:
                      reduceMotion ? Curves.linear : Curves.easeOutBack,
                  left: currentIndex * segmentWidth + segmentWidth * 0.34,
                  width: segmentWidth * 0.32,
                  top: 0,
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: colors.stream,
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(3),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < items.length; i++)
                      Expanded(
                        child: _SteesNavChannel(
                          item: items[i],
                          selected: i == currentIndex,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            onTap(i);
                          },
                          reduceMotion: reduceMotion,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SteesNavChannel extends StatelessWidget {
  final SteesNavItem item;
  final bool selected;
  final VoidCallback onTap;
  final bool reduceMotion;

  const _SteesNavChannel({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.reduceMotion,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final accent = selected ? colors.stream : colors.mist;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          splashColor: colors.stream.withValues(alpha: 0.06),
          highlightColor: colors.stream.withValues(alpha: 0.04),
          child: SizedBox.expand(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedSwitcher(
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  // Fade plus a small scale settle: the incoming glyph lands
                  // like a key being pressed into the fascia.
                  transitionBuilder: (child, anim) {
                    final scale = Tween<double>(begin: 0.92, end: 1).animate(
                      CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                    );
                    return FadeTransition(
                      opacity: anim,
                      child: ScaleTransition(scale: scale, child: child),
                    );
                  },
                  child: Icon(
                    selected ? item.activeIcon : item.icon,
                    key: ValueKey(selected),
                    size: 22,
                    color: accent,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                AnimatedDefaultTextStyle(
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 10,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    letterSpacing: 0.3,
                    color: selected ? colors.foam : colors.mist,
                  ),
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
