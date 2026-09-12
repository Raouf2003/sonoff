import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../widgets/stees_widgets.dart';
import 'schedule_compiler.dart';
import 'schedule_model.dart';

const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
final _timePattern = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');

class ScheduleFormScreen extends StatefulWidget {
  const ScheduleFormScreen({super.key, this.existing});
  final LocalSchedule? existing;

  @override
  State<ScheduleFormScreen> createState() => _ScheduleFormScreenState();
}

class _ScheduleFormScreenState extends State<ScheduleFormScreen> {
  final _name = TextEditingController();
  final _channels = <int>{1};
  String _recurrence = 'daily';
  final _days = <int>{};
  final List<TextEditingController> _starts = [];
  final List<TextEditingController> _ends = [];
  bool _enabled = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _name.text = e.name;
      _channels.addAll(e.channels);
      _recurrence = e.recurrenceType;
      _days.addAll(e.daysOfWeek);
      for (final r in e.timeRanges) {
        _starts.add(TextEditingController(text: r.start));
        _ends.add(TextEditingController(text: r.end));
      }
      _enabled = e.enabled;
    } else {
      _starts.add(TextEditingController(text: '08:00'));
      _ends.add(TextEditingController(text: '09:00'));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    for (final c in [..._starts, ..._ends]) {
      c.dispose();
    }
    super.dispose();
  }

  void _addRange() {
    setState(() {
      _starts.add(TextEditingController(text: '08:00'));
      _ends.add(TextEditingController(text: '09:00'));
    });
  }

  void _removeRange(int i) {
    setState(() {
      _starts.removeAt(i).dispose();
      _ends.removeAt(i).dispose();
    });
  }

  void _save() {
    final ranges = <TimeRange>[];
    for (var i = 0; i < _starts.length; i++) {
      final start = _starts[i].text.trim();
      final end = _ends[i].text.trim();
      if (!_timePattern.hasMatch(start) || !_timePattern.hasMatch(end)) {
        setState(() => _error = 'Range ${i + 1}: use HH:mm (00:00–23:59).');
        return;
      }
      if (toMinutes(end)! <= toMinutes(start)!) {
        setState(() => _error = 'Range ${i + 1}: end must be after start (same day only).');
        return;
      }
      ranges.add(TimeRange(start: start, end: end));
    }
    if (ranges.isEmpty) {
      setState(() => _error = 'Add at least one time range.');
      return;
    }
    if (_channels.isEmpty) {
      setState(() => _error = 'Select at least one channel.');
      return;
    }
    if (_recurrence == 'custom' && _days.isEmpty) {
      setState(() => _error = 'Custom recurrence needs at least one day.');
      return;
    }
    final schedule = LocalSchedule(
      id: widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: _name.text.trim().isEmpty ? 'Schedule' : _name.text.trim(),
      channels: _channels.toList()..sort(),
      recurrenceType: _recurrence,
      daysOfWeek: _days.toList()..sort(),
      timeRanges: ranges,
      enabled: _enabled,
    );
    Navigator.of(context).pop(schedule);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New schedule' : 'Edit schedule'),
        actions: [IconButton(icon: const Icon(Icons.check), onPressed: _save)],
      ),
      body: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          if (_error != null)
            Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!))),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          const SteesSectionHeader(title: 'Channels'),
          Wrap(
            spacing: 8,
            children: [
              for (var ch = 1; ch <= 4; ch++)
                FilterChip(
                  label: Text('$ch'),
                  selected: _channels.contains(ch),
                  onSelected: (v) => setState(() {
                    v ? _channels.add(ch) : _channels.remove(ch);
                  }),
                ),
            ],
          ),
          const SizedBox(height: 16),
          const SteesSectionHeader(title: 'Recurrence'),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'daily', label: Text('Daily')),
              ButtonSegment(value: 'custom', label: Text('Custom')),
            ],
            selected: {_recurrence},
            onSelectionChanged: (s) => setState(() => _recurrence = s.first),
          ),
          if (_recurrence == 'custom') ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (var d = 0; d < 7; d++)
                  FilterChip(
                    label: Text(_dayLabels[d]),
                    selected: _days.contains(d),
                    onSelected: (v) => setState(() {
                      v ? _days.add(d) : _days.remove(d);
                    }),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Time ranges'),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add'),
                onPressed: _addRange,
              ),
            ],
          ),
          for (var i = 0; i < _starts.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _starts[i],
                      decoration: const InputDecoration(labelText: 'Start', border: OutlineInputBorder()),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('–'),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _ends[i],
                      decoration: const InputDecoration(labelText: 'End', border: OutlineInputBorder()),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _starts.length > 1 ? () => _removeRange(i) : null,
                  ),
                ],
              ),
            ),
          SwitchListTile(
            title: const Text('Enabled'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
        ],
      ),
    );
  }
}
