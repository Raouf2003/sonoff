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
  const ScheduleFormScreen({
    super.key,
    required this.deviceId,
    required this.deviceName,
    this.maxChannel = 4,
    this.existing,
  });

  @override
  State<ScheduleFormScreen> createState() => _ScheduleFormScreenState();
}

class _ScheduleFormScreenState extends State<ScheduleFormScreen> {
  final _nameCtl = TextEditingController();
  final _api = ApiService();

  final Set<int> _channels = <int>{1};
  String _recurrenceType = 'daily';
  final Set<int> _daysOfWeek = <int>{};
  final List<TimeOfDay> _rangeStarts = <TimeOfDay>[TimeOfDay.now()];
  final List<TimeOfDay> _rangeEnds = <TimeOfDay>[TimeOfDay(hour: 23, minute: 59)];
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) _prefill(existing);
  }

  void _prefill(Map<String, dynamic> schedule) {
    _nameCtl.text = (schedule['name'] as String?) ?? '';

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
    _nameCtl.dispose();
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

  Future<void> _save() async {
    final name = _nameCtl.text.trim();
    if (name.isEmpty) { _err('Enter a schedule name'); return; }
    if (_channels.isEmpty) { _err('Select at least one channel'); return; }
    if (_recurrenceType == 'custom' && _daysOfWeek.isEmpty) {
      _err('Pick at least one day for custom recurrence');
      return;
    }
    if (!_validateRanges()) return;

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
      if (_isEdit) {
        await _api.updateSchedule(
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
      } else {
        await _api.createSchedule(
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
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _err(e.toString().replaceFirst('Exception: ', ''));
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
                  eyebrow: 'NAME',
                  child: TextField(
                    controller: _nameCtl,
                    style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
                    textInputAction: TextInputAction.next,
                    decoration: _inputDec('Schedule name', 'e.g. Morning irrigation', Icons.label_outline, colors),
                  ),
                ),
                const SizedBox(height: 14),
                _SectionCard(
                  eyebrow: 'CHANNELS',
                  description: 'Which outlets this schedule drives.',
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (var i = 1; i <= widget.maxChannel; i++)
                        _ChannelChip(
                          label: 'CH$i',
                          selected: _channels.contains(i),
                          color: colors.stream,
                          onTap: () => setState(() {
                            if (!_channels.remove(i)) _channels.add(i);
                          }),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _SectionCard(
                  eyebrow: 'REPEATS',
                  description: 'When the week this schedule runs.',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'daily', label: Text('Daily', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                          ButtonSegment(value: 'custom', label: Text('Custom days', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                        ],
                        selected: {_recurrenceType},
                        style: SegmentedButton.styleFrom(
                          backgroundColor: colors.well,
                          selectedBackgroundColor: colors.stream,
                          selectedForegroundColor: colors.well,
                          foregroundColor: colors.mist,
                          side: BorderSide(color: colors.border),
                        ),
                        onSelectionChanged: (s) => setState(() => _recurrenceType = s.first),
                      ),
                      if (_recurrenceType == 'custom') ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (var i = 0; i < 7; i++)
                              _ChannelChip(
                                label: _dayLabels[i],
                                selected: _daysOfWeek.contains(i),
                                color: colors.sunlight,
                                onTap: () => setState(() {
                                  if (!_daysOfWeek.remove(i)) _daysOfWeek.add(i);
                                }),
                              ),
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
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _rangeStarts.length >= 6
                            ? null
                            : () => setState(() {
                                _rangeStarts.add(TimeOfDay(hour: 6, minute: 0));
                                _rangeEnds.add(TimeOfDay(hour: 12, minute: 0));
                              }),
                        icon: const Icon(Icons.add, size: 16),
                        label: Text('Add another window', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600)),
                        style: TextButton.styleFrom(foregroundColor: colors.stream),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity, height: 52,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
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
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: _timeButton(
              label: 'Starts',
              time: _rangeStarts[index],
              onTap: () => _pickTime(isStart: true, index: index),
              colors: colors,
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 6),
            height: 18,
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

  Widget _timeButton({required String label, required TimeOfDay time, required VoidCallback onTap, required SteesColors colors}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.stream.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: GoogleFonts.inter(fontSize: 10, color: colors.mist)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(_hhmm(time), overflow: TextOverflow.ellipsis,
                style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700, color: colors.foam)),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDec(String hint, String helper, IconData icon, SteesColors colors) {
    return InputDecoration(
      hintText: hint,
      helperText: helper,
      helperStyle: GoogleFonts.inter(fontSize: 11, color: colors.mist.withValues(alpha: 0.75)),
      hintStyle: GoogleFonts.inter(fontSize: 14, color: colors.mist.withValues(alpha: 0.6)),
      prefixIcon: Icon(icon, size: 18, color: colors.mist),
      filled: true,
      fillColor: colors.well,
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: colors.stream, width: 1.5),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: colors.stream.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.stream.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.stream.withValues(alpha: 0.15),
            ),
            child: Icon(Icons.schedule, size: 20, color: colors.stream),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(deviceName, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: colors.foam)),
                const SizedBox(height: 2),
                Text(deviceId, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(fontSize: 11, color: colors.mist)),
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
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.submerged,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 20, height: 2, decoration: BoxDecoration(color: colors.stream, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 8),
              Text(eyebrow, style: GoogleFonts.sora(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.8, color: colors.stream)),
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

class _ChannelChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  const _ChannelChip({required this.label, required this.selected, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? color : colors.well,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? color : colors.border,
            width: selected ? 1 : 1,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? colors.well : colors.foam),
        ),
      ),
    );
  }
}
