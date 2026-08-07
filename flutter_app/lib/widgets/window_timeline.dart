import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';

/// A compact 24-hour timeline strip. Each ON window ([0,1) ranges in minutes)
/// is drawn as a bright bar against the night track, with hour tick marks
/// beneath. Used live in the form and as a preview on schedule list cards.
class WindowTimeline extends StatelessWidget {
  final List<({int start, int end})> windows;
  final bool compact;
  const WindowTimeline({super.key, required this.windows, this.compact = false});

  static const _totalMin = 1440;

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final trackHeight = compact ? 12.0 : 22.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return SizedBox(
          height: compact ? 28 : 48,
          width: width,
          child: Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: trackHeight,
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: colors.well.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: colors.border),
                  ),
                  child: Stack(
                    children: [
                      for (var i = 1; i < 24; i++)
                        Positioned(
                          left: width * i / 24 - 0.25,
                          top: 0,
                          bottom: 0,
                          child: Container(width: 0.5, color: colors.border),
                        ),
                    ],
                  ),
                ),
              ),
              for (final w in windows) _drawWindow(context, width, trackHeight, w, colors),
              Positioned(
                left: 0,
                right: 0,
                top: trackHeight + 5,
                child: Row(
                  children: [
                    for (var i = 0; i <= 24; i += 6) ...[
                      if (i > 0) const Spacer(),
                      Text(
                        i == 24 ? '24' : '$i',
                        style: GoogleFonts.inter(
                          fontSize: compact ? 9 : 11,
                          color: colors.mist.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _drawWindow(BuildContext context, double width, double trackHeight, ({int start, int end}) w, SteesColors colors) {
    final left = width * w.start / _totalMin;
    final wid = width * (w.end - w.start) / _totalMin;
    return Positioned(
      left: left.clamp(0.0, width),
      top: 1,
      bottom: 1,
      width: wid.clamp(0.0, width - left),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [colors.stream, colors.leaf],
          ),
          borderRadius: BorderRadius.circular(4),
          boxShadow: [BoxShadow(color: colors.stream.withValues(alpha: 0.4), blurRadius: 3)],
        ),
      ),
    );
  }
}