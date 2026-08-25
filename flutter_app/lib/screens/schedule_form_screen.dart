import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';
import '../services/api_service.dart';
import '../widgets/window_timeline.dart';

class ScheduleFormScreen extends StatefulWidget {
  final String deviceId;
  final String deviceName;
  final int maxChannel;
  final Map<String, dynamic>? existing;

  /// Other schedules already saved for this device (the caller excludes the
  /// one being edited). Used purely client-side to block overlapping windows
  /// on the same channel + day before a save reaches the backend.
  final List<Map<String, dynamic>> siblings;
  const ScheduleFormScreen({
    super.key,
    required this.deviceId,
    required this.deviceName,
    this.maxChannel = 4,
    this.existing,
    this.siblings = const [],
  });

  @override
  State<ScheduleFormScreen> createState() => _ScheduleFormScreenState();
}

class _ScheduleFormScreenState extends State<ScheduleFormScreen> {
  final _api = ApiService();

  final Set<int> _channels = <int>{1};
  String _recurrenceType = 'daily';
  final Set<int> _daysOfWeek = <int>{};
  final List<TimeOfDay> _rangeStarts = <TimeOfDay>[TimeOfDay.now()];
  final List<TimeOfDay> _rangeEnds = <TimeOfDay>[TimeOfDay(hour: 23, minute: 59)];
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _dayShortLabels = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) _prefill(existing);
  }

  void _prefill(Map<String, dynamic> schedule) {
    final channels = (schedule['channels'] as List<dynamic>?) ?? [];
    _channels.clear();
    for (final c in channels) {
      final v = c as int?;
      if (v != null && v >= 1 && v <= widget.maxChannel) _channels.add(v);
    }

    final recurrence = schedule['recurrence'] as Map<String, dynamic>? ?? {};
    _recurrenceType = (recurrence['type'] as String?) == 'custom' ? 'custom' : 'daily';
    final days = (recurrence['daysOfWeek'] as List<dynamic>?) ?? [];
    _daysOfWeek.clear();
    for (final d in days) {
      final v = d as int?;
      if (v != null && v >= 0 && v <= 6) _daysOfWeek.add(v);
    }

    final ranges = (schedule['timeRanges'] as List<dynamic>?) ?? [];
    _rangeStarts.clear();
    _rangeEnds.clear();
    if (ranges.isEmpty) {
      _rangeStarts.add(TimeOfDay.now());
      _rangeEnds.add(const TimeOfDay(hour: 23, minute: 59));
    } else {
      for (final r in ranges) {
        _rangeStarts.add(_parseHhmm(r['start'] as String?));
        _rangeEnds.add(_parseHhmm(r['end'] as String?));
      }
    }
  }

  TimeOfDay _parseHhmm(String? hhmm) {
    if (hhmm == null) return TimeOfDay.now();
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm);
    if (m == null) return TimeOfDay.now();
    return TimeOfDay(
      hour: int.parse(m.group(1)!).clamp(0, 23),
      minute: int.parse(m.group(2)!).clamp(0, 59),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _pickTime({required bool isStart, required int index}) async {
    final colors = context.steesColors;
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _rangeStarts[index] : _rangeEnds[index],
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: ColorScheme.dark(
            primary: colors.stream,
            surface: colors.submerged,
            onSurface: colors.foam,
          ),
        ),
        child: child!,
      ),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _rangeStarts[index] = picked;
      } else {
        _rangeEnds[index] = picked;
      }
    });
  }

  bool _validateRanges() {
    for (var i = 0; i < _rangeStarts.length; i++) {
      final s = _rangeStarts[i];
      final e = _rangeEnds[i];
      final sMin = s.hour * 60 + s.minute;
      final eMin = e.hour * 60 + e.minute;
      if (eMin <= sMin) {
        _err('Range ${i + 1}: end must be after start (no overnight)');
        return false;
      }
    }
    return true;
  }

  // ──────────────────────────────────────────────────────────
  // Overlap validation (client-side, same channel + day + time)
  // ──────────────────────────────────────────────────────────

  static int _minutesOf(String? hhmm) {
    if (hhmm == null) return 0;
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm);
    if (m == null) return 0;
    return int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
  }

  static String _minutesText(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

  /// The form's windows as minute pairs (only valid ones; invalid ranges are
  /// reported separately by [_validateRanges] on save).
  List<({int start, int end})> get _formRanges => [
        for (var i = 0; i < _rangeStarts.length; i++)
          (
            start: _rangeStarts[i].hour * 60 + _rangeStarts[i].minute,
            end: _rangeEnds[i].hour * 60 + _rangeEnds[i].minute,
          ),
      ];

  /// Days this schedule applies to: custom selection, or all seven.
  Set<int> get _formDays => _recurrenceType == 'custom'
      ? Set<int>.of(_daysOfWeek)
      : const {0, 1, 2, 3, 4, 5, 6};

  /// Null when the form is saveable, otherwise a human-readable conflict
  /// report naming the channel(s), the conflicting window(s), the day(s) and
  /// the existing schedule. Rule: same channel + same day + overlapping time.
  String? _conflictMessage() {
    final formDays = _formDays;
    final formRanges = _formRanges;
    if (_channels.isEmpty || formDays.isEmpty || formRanges.isEmpty) {
      return null;
    }
    final conflicts = <String>[];
    for (final sibling in widget.siblings) {
      // Never compare a schedule against itself while editing.
      if (_isEdit &&
          widget.existing?['_id'] != null &&
          sibling['_id'] == widget.existing!['_id']) {
        continue;
      }
      final sibChannels = (sibling['channels'] as List<dynamic>? ?? [])
          .whereType<int>()
          .toSet();
      final channelHit = sibChannels.intersection(_channels);
      if (channelHit.isEmpty) continue;

      final recurrence = sibling['recurrence'] as Map<String, dynamic>? ?? {};
      final sibDays = (recurrence['type'] as String?) == 'custom'
          ? (recurrence['daysOfWeek'] as List<dynamic>? ?? [])
              .whereType<int>()
              .toSet()
          : const {0, 1, 2, 3, 4, 5, 6};
      final dayHit = sibDays.intersection(formDays);
      if (dayHit.isEmpty) continue;

      final sibRanges = [
        for (final r in (sibling['timeRanges'] as List<dynamic>? ?? []))
          if (r is Map)
            (
              start: _minutesOf(r['start'] as String?),
              end: _minutesOf(r['end'] as String?),
            ),
      ];
      final hitRanges = <String>{};
      for (final f in formRanges) {
        if (f.end <= f.start) continue;
        for (final s in sibRanges) {
          if (s.end <= s.start) continue;
          if (f.start < s.end && s.start < f.end) {
            hitRanges.add(
                '${_minutesText(s.start)}\u2013${_minutesText(s.end)}');
          }
        }
      }
      if (hitRanges.isEmpty) continue;

      final chans = (channelHit.toList()..sort()).map((c) => 'CH$c').join(', ');
      final dayText = dayHit.length == 7
          ? 'every day'
          : (dayHit.toList()..sort()).map((d) => _dayLabels[d]).join(', ');
      final name = (sibling['name'] as String? ?? '').trim();
      conflicts.add(
        'Schedule conflict: $chans is already scheduled '
        '${hitRanges.join(', ')} on $dayText'
        '${name.isEmpty ? '' : ' ("$name")'}.',
      );
      if (conflicts.length >= 3) break;
    }
    if (conflicts.isEmpty) return null;
    return conflicts.join('\n');
  }

  Future<void> _save() async {
    if (_channels.isEmpty) { _err('Select at least one channel'); return; }
    if (_recurrenceType == 'custom' && _daysOfWeek.isEmpty) {
      _err('Pick at least one day for custom recurrence');
      return;
    }
    if (!_validateRanges()) return;
    // Defense in depth: the Save button is already disabled on conflict.
    final conflict = _conflictMessage();
    if (conflict != null) {
      _err(conflict.split('\n').first);
      return;
    }

    // The name field was removed from the UI: the backend contract still
    // requires one, so it is derived from the first window (create) or kept
    // from the existing row (edit).
    final autoName =
        '${_hhmm(_rangeStarts.first)}\u2013${_hhmm(_rangeEnds.first)}';
    final name = _isEdit
        ? ((widget.existing!['name'] as String?)?.isNotEmpty ?? false)
            ? widget.existing!['name'] as String
            : autoName
        : autoName;

    final channels = _channels.toList()..sort();
    final timeRanges = <Map<String, String>>[
      for (var i = 0; i < _rangeStarts.length; i++)
        {
          'start': _hhmm(_rangeStarts[i]),
          'end': _hhmm(_rangeEnds[i]),
        },
    ];

    setState(() => _saving = true);
    try {
      Map<String, dynamic>? saved;
      if (_isEdit) {
        final res = await _api.updateSchedule(
          widget.existing!['_id'] as String,
          {
            'name': name,
            'deviceId': widget.deviceId,
            'channels': channels,
            'recurrence': {
              'type': _recurrenceType,
              'daysOfWeek': _recurrenceType == 'custom'
                  ? (_daysOfWeek.toList()..sort())
                  : const <int>[],
            },
            'timeRanges': timeRanges,
          },
        );
        saved = (res['schedule'] as Map<String, dynamic>?) ?? res;
      } else {
        final res = await _api.createSchedule(
          name: name,
          deviceId: widget.deviceId,
          channels: channels,
          recurrence: {
            'type': _recurrenceType,
            'daysOfWeek': _recurrenceType == 'custom'
                ? (_daysOfWeek.toList()..sort())
                : const <int>[],
          },
          timeRanges: timeRanges,
        );
        saved = (res['schedule'] as Map<String, dynamic>?) ?? res;
      }
      // Pop with the saved payload so the caller can key a device-sync watch
      // on it; legacy `true` remains the fallback contract.
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      _err(e is ApiException ? e.message : 'Could not save the schedule');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _hhmm(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void _err(String m) {
    if (!mounted) return;
    final colors = context.steesColors;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(m, style: const TextStyle(fontSize: 13)),
        backgroundColor: colors.danger,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Schedule' : 'New Schedule', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: colors.foam)),
        backgroundColor: colors.well,
        iconTheme: IconThemeData(color: colors.mist),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [colors.well, Theme.of(context).colorScheme.surfaceContainerHighest, colors.well],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DeviceBanner(deviceName: widget.deviceName, deviceId: widget.deviceId),
                const SizedBox(height: 18),
                _SectionCard(
                  eyebrow: 'CHANNELS',
                  description: 'Which outlets this schedule drives.',
                  child: LayoutBuilder(
                    builder: (ctx, box) {
                      final count = widget.maxChannel;
                      // Up to four outlets share one row; beyond that the
                      // tiles fall back to a fixed-width grid flow.
                      final tileWidth = count > 0 && count <= 4
                          ? (box.maxWidth - (count - 1) * 8) / count
                          : 64.0;
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 1; i <= count; i++)
                            SizedBox(
                              width: tileWidth,
                              child: _ChannelTile(
                                label: 'CH$i',
                                selected: _channels.contains(i),
                                onTap: () => setState(() {
                                  if (!_channels.remove(i)) _channels.add(i);
                                }),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 14),
                _SectionCard(
                  eyebrow: 'REPEATS',
                  description: 'When in the week this schedule runs.',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _ModeChip(
                              label: 'Daily',
                              icon: Icons.event_repeat,
                              selected: _recurrenceType == 'daily',
                              onTap: () => setState(() => _recurrenceType = 'daily'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _ModeChip(
                              label: 'Custom days',
                              icon: Icons.date_range,
                              selected: _recurrenceType == 'custom',
                              onTap: () => setState(() => _recurrenceType = 'custom'),
                            ),
                          ),
                        ],
                      ),
                      if (_recurrenceType == 'custom') ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            for (var i = 0; i < 7; i++) ...[
                              if (i > 0) const SizedBox(width: 6),
                              Expanded(
                                child: _DayTile(
                                  label: _dayShortLabels[i],
                                  selected: _daysOfWeek.contains(i),
                                  onTap: () => setState(() {
                                    if (!_daysOfWeek.remove(i)) _daysOfWeek.add(i);
                                  }),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _SectionCard(
                  eyebrow: 'WINDOWS',
                  description: 'Channels are ON inside each window, OFF otherwise.',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      WindowTimeline(windows: _timelineWindows()),
                      const SizedBox(height: 14),
                      for (var i = 0; i < _rangeStarts.length; i++) ...[
                        _buildRangeRow(i, colors),
                        if (i < _rangeStarts.length - 1) const SizedBox(height: 10),
                      ],
                      const SizedBox(height: 10),
                      // Full-width ghost tile instead of a text button.
                      InkWell(
                        onTap: _rangeStarts.length >= 6
                            ? null
                            : () => setState(() {
                                _rangeStarts.add(TimeOfDay(hour: 6, minute: 0));
                                _rangeEnds.add(TimeOfDay(hour: 12, minute: 0));
                              }),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        child: Container(
                          width: double.infinity,
                          height: 44,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            border: Border.all(color: colors.border),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.add, size: 14, color: colors.stream.withValues(alpha: 0.7)),
                              const SizedBox(width: 6),
                              Text(
                                'Add window',
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: colors.mist,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                // Inline overlap error: names the channel, the clashing
                // window, the day and the existing schedule. Save stays
                // disabled while this is visible.
                if (_conflictMessage() != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: colors.danger.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: colors.danger.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline, size: 18, color: colors.danger),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _conflictMessage()!,
                            style: GoogleFonts.inter(
                              fontSize: 12.5,
                              height: 1.45,
                              color: colors.danger,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                SizedBox(
                  width: double.infinity, height: 52,
                  child: FilledButton.icon(
                    onPressed: (_saving || _conflictMessage() != null) ? null : _save,
                    icon: _saving
                        ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: colors.well))
                        : Icon(_isEdit ? Icons.save_outlined : Icons.add, size: 18),
                    label: Text(_isEdit ? 'Save Changes' : 'Create Schedule', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.stream,
                      foregroundColor: colors.well,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<({int start, int end})> _timelineWindows() {
    return [
      for (var i = 0; i < _rangeStarts.length; i++)
        (
          start: _rangeStarts[i].hour * 60 + _rangeStarts[i].minute,
          end: _rangeEnds[i].hour * 60 + _rangeEnds[i].minute,
        ),
    ];
  }

  Widget _buildRangeRow(int index, SteesColors colors) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              'W${index + 1}',
              textAlign: TextAlign.center,
              style: GoogleFonts.jetBrainsMono(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: colors.mist.withValues(alpha: 0.6),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _timeButton(
              label: 'Starts',
              time: _rangeStarts[index],
              onTap: () => _pickTime(isStart: true, index: index),
              colors: colors,
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            height: 30,
            width: 1,
            color: colors.border,
          ),
          Expanded(
            child: _timeButton(
              label: 'Ends',
              time: _rangeEnds[index],
              onTap: () => _pickTime(isStart: false, index: index),
              colors: colors,
            ),
          ),
          if (_rangeStarts.length > 1)
            IconButton(
              onPressed: () => setState(() {
                _rangeStarts.removeAt(index);
                _rangeEnds.removeAt(index);
              }),
              icon: Icon(Icons.close, size: 16, color: colors.danger),
              tooltip: 'Remove window',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.all(4),
            ),
        ],
      ),
    );
  }

  /// Stacked time readout: label over a mono value, the same voice as the
  /// time-first schedule cards.
  Widget _timeButton({required String label, required TimeOfDay time, required VoidCallback onTap, required SteesColors colors}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 8),
        decoration: BoxDecoration(
          color: colors.submerged,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          children: [
            Text(label, style: GoogleFonts.inter(fontSize: 9, color: colors.mist)),
            const SizedBox(height: 3),
            Text(_hhmm(time), overflow: TextOverflow.ellipsis,
              style: GoogleFonts.jetBrainsMono(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: colors.foam,
              )),
          ],
        ),
      ),
    );
  }
}

class _DeviceBanner extends StatelessWidget {
  final String deviceName;
  final String deviceId;
  const _DeviceBanner({required this.deviceName, required this.deviceId});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final scheme = Theme.of(context).colorScheme;
    // Same recipe as the Devices hero panel: bordered panel, soft neutral
    // shadow, rounded-square badge, mono id readout.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colors.submerged,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: colors.border),
        boxShadow: [AppShadows.softShadow(scheme.shadow)],
      ),
      child: Row(
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              color: colors.well,
              border: Border.all(color: colors.border),
            ),
            child: Icon(Icons.schedule, size: 20, color: colors.stream),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(deviceName, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700, color: colors.foam)),
                const SizedBox(height: 3),
                Text(deviceId.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.6,
                    color: colors.mist.withValues(alpha: 0.55),
                  )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String eyebrow;
  final String? description;
  final Widget child;
  const _SectionCard({required this.eyebrow, required this.child, this.description});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: colors.submerged,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 20, height: 2, decoration: BoxDecoration(color: colors.stream, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 8),
              Text(eyebrow, style: GoogleFonts.jetBrainsMono(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 1.6, color: colors.stream)),
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: Text(description!, style: GoogleFonts.inter(fontSize: 11, color: colors.mist.withValues(alpha: 0.7))),
            ),
          ],
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

/// Channel selector tile: border-first module, mono label, tinted when
/// selected.
class _ChannelTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ChannelTile({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? colors.stream.withValues(alpha: 0.12) : colors.submerged,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected ? colors.borderActive : colors.border,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.jetBrainsMono(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? colors.stream : colors.mist,
          ),
        ),
      ),
    );
  }
}

/// Recurrence mode selector: border-first chip with icon + label.
class _ModeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _ModeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 44,
        decoration: BoxDecoration(
          color: selected ? colors.stream.withValues(alpha: 0.12) : colors.submerged,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected ? colors.borderActive : colors.border,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: selected ? colors.stream : colors.mist),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? colors.stream : colors.mist,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Day selector tile: compact two-letter mono cell in a DIP-switch style row.
class _DayTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _DayTile({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? colors.sunlight.withValues(alpha: 0.14) : colors.submerged,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: selected ? colors.sunlight.withValues(alpha: 0.6) : colors.border,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.jetBrainsMono(
            fontSize: 10.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? colors.sunlight : colors.mist,
          ),
        ),
      ),
    );
  }
}
