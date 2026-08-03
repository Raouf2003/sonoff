import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../services/api_service.dart';

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
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _rangeStarts[index] : _rangeEnds[index],
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: AppColors.stream,
            surface: AppColors.submerged,
            onSurface: AppColors.foam,
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(m, style: const TextStyle(fontSize: 13)),
        backgroundColor: Colors.redAccent.shade200,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Schedule' : 'Add Schedule', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.foam)),
        backgroundColor: AppColors.well,
        iconTheme: const IconThemeData(color: AppColors.mist),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [AppColors.well, Color(0xFF0F2332), AppColors.well],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  decoration: BoxDecoration(
                    color: AppColors.stream.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.stream.withValues(alpha: 0.25)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('DEVICE', style: GoogleFonts.sora(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 2.2, color: AppColors.stream)),
                      const SizedBox(height: 6),
                      Text(widget.deviceName, style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.foam)),
                      const SizedBox(height: 2),
                      Text('ID: ${widget.deviceId}', style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist)),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppColors.submerged,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Schedule details', style: GoogleFonts.sora(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.foam)),
                      const SizedBox(height: 4),
                      Text(
                        'Turns the selected channels ON during each time range, OFF at other times.',
                        style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist.withValues(alpha: 0.7)),
                      ),
                      const SizedBox(height: 18),
                      TextField(
                        controller: _nameCtl,
                        style: GoogleFonts.inter(fontSize: 14, color: AppColors.foam),
                        textInputAction: TextInputAction.next,
                        decoration: _inputDec('Schedule name', 'e.g. Morning irrigation', Icons.label_outline),
                      ),
                      const SizedBox(height: 16),
                      _label('CHANNELS'),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (var i = 1; i <= widget.maxChannel; i++)
                            FilterChip(
                              label: Text('CH$i', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: _channels.contains(i) ? AppColors.well : AppColors.foam)),
                              selected: _channels.contains(i),
                              selectedColor: AppColors.stream,
                              checkmarkColor: AppColors.well,
                              backgroundColor: AppColors.well,
                              side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              onSelected: (sel) => setState(() {
                                if (sel) {
                                  _channels.add(i);
                                } else {
                                  _channels.remove(i);
                                }
                              }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      _label('REPEATS'),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'daily', label: Text('Daily', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                          ButtonSegment(value: 'custom', label: Text('Custom days', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                        ],
                        selected: {_recurrenceType},
                        style: SegmentedButton.styleFrom(
                          backgroundColor: AppColors.well,
                          selectedBackgroundColor: AppColors.stream,
                          selectedForegroundColor: AppColors.well,
                          foregroundColor: AppColors.mist,
                          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
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
                              ChoiceChip(
                                label: Text(_dayLabels[i], style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: _daysOfWeek.contains(i) ? AppColors.well : AppColors.foam)),
                                selected: _daysOfWeek.contains(i),
                                selectedColor: AppColors.sunlight,
                                backgroundColor: AppColors.well,
                                checkmarkColor: AppColors.well,
                                side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                onSelected: (sel) => setState(() {
                                  if (sel) {
                                    _daysOfWeek.add(i);
                                  } else {
                                    _daysOfWeek.remove(i);
                                  }
                                }),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Text('TIME RANGES', style: GoogleFonts.sora(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.6, color: AppColors.mist)),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _rangeStarts.length >= 6
                                ? null
                                : () => setState(() {
                                    _rangeStarts.add(TimeOfDay(hour: 6, minute: 0));
                                    _rangeEnds.add(TimeOfDay(hour: 12, minute: 0));
                                  }),
                            icon: const Icon(Icons.add, size: 16),
                            label: Text('Add range', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600)),
                            style: TextButton.styleFrom(foregroundColor: AppColors.stream),
                          ),
                        ],
                      ),
                      for (var i = 0; i < _rangeStarts.length; i++) ...[
                        _buildRangeRow(i),
                        if (i < _rangeStarts.length - 1) const SizedBox(height: 10),
                      ],
                      const SizedBox(height: 22),
                      SizedBox(
                        width: double.infinity, height: 50,
                        child: FilledButton(
                          onPressed: _saving ? null : _save,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.stream,
                            foregroundColor: AppColors.well,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          child: _saving
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.well))
                              : Text(_isEdit ? 'Save Changes' : 'Create Schedule', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRangeRow(int index) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.well,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _timeButton(
              label: 'Start',
              time: _rangeStarts[index],
              onTap: () => _pickTime(isStart: true, index: index),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.arrow_forward, size: 16, color: AppColors.mist),
          ),
          Expanded(
            child: _timeButton(
              label: 'End',
              time: _rangeEnds[index],
              onTap: () => _pickTime(isStart: false, index: index),
            ),
          ),
          if (_rangeStarts.length > 1)
            IconButton(
              onPressed: () => setState(() {
                _rangeStarts.removeAt(index);
                _rangeEnds.removeAt(index);
              }),
              icon: const Icon(Icons.close, size: 16, color: Color(0xFFFF7A7A)),
              tooltip: 'Remove range',
            ),
        ],
      ),
    );
  }

  Widget _timeButton({required String label, required TimeOfDay time, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.stream.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: GoogleFonts.inter(fontSize: 10, color: AppColors.mist)),
            const SizedBox(height: 2),
            Text(_hhmm(time), style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.foam)),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: GoogleFonts.sora(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.6, color: AppColors.mist)),
    );
  }

  InputDecoration _inputDec(String hint, String helper, IconData icon) {
    return InputDecoration(
      hintText: hint,
      helperText: helper,
      helperStyle: GoogleFonts.inter(fontSize: 11, color: AppColors.mist.withValues(alpha: 0.5)),
      hintStyle: GoogleFonts.inter(fontSize: 14, color: AppColors.mist.withValues(alpha: 0.6)),
      prefixIcon: Icon(icon, size: 18, color: AppColors.mist),
      filled: true,
      fillColor: AppColors.well,
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.stream, width: 1.5),
      ),
    );
  }
}
