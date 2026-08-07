import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../services/api_service.dart';
import '../widgets/window_timeline.dart';
import 'schedule_form_screen.dart';

class ScheduleListScreen extends StatefulWidget {
  const ScheduleListScreen({super.key});

  @override
  State<ScheduleListScreen> createState() => _ScheduleListScreenState();
}

class _ScheduleListScreenState extends State<ScheduleListScreen> {
  final _api = ApiService();
  List<Map<String, dynamic>> _devices = [];
  List<Map<String, dynamic>> _schedules = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([_api.getDevices(), _api.getSchedules()]);
      if (mounted) {
        setState(() {
          _devices = results[0].cast<Map<String, dynamic>>();
          _schedules = results[1].cast<Map<String, dynamic>>();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _err('Failed to load schedules');
    }
  }

  Map<String, dynamic> _deviceOf(String deviceId) {
    for (final d in _devices) {
      if (d['deviceId'] == deviceId) return d;
    }
    // Fallback for schedules whose device wasn't claimed/fetched.
    return <String, dynamic>{'deviceId': deviceId, 'name': deviceId, 'channels': 4};
  }

  int _channelsOf(String deviceId) => _deviceOf(deviceId)['channels'] as int? ?? 4;
  String _nameOf(String deviceId) => _deviceOf(deviceId)['name'] as String? ?? deviceId;

  List<Map<String, dynamic>> _schedulesOf(String deviceId) =>
      _schedules.where((s) => s['deviceId'] == deviceId).toList();

  Future<void> _add(String deviceId) async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ScheduleFormScreen(
          deviceId: deviceId,
          deviceName: _nameOf(deviceId),
          maxChannel: _channelsOf(deviceId),
        ),
      ),
    );
    if (created == true) _load();
  }

  Future<void> _edit(Map<String, dynamic> schedule) async {
    final deviceId = schedule['deviceId'] as String;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ScheduleFormScreen(
          deviceId: deviceId,
          deviceName: _nameOf(deviceId),
          maxChannel: _channelsOf(deviceId),
          existing: schedule,
        ),
      ),
    );
    if (changed == true) _load();
  }

  Future<void> _toggle(Map<String, dynamic> schedule) async {
    final id = schedule['_id'] as String;
    final target = !((schedule['enabled'] as bool?) ?? false);
    setState(() => schedule['enabled'] = target);
    try {
      await _api.toggleSchedule(id);
    } catch (e) {
      setState(() => schedule['enabled'] = !target);
      _err('Failed to update schedule');
    }
  }

  Future<void> _delete(Map<String, dynamic> schedule) async {
    final colors = context.steesColors;
    final id = schedule['_id'] as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.submerged,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text('Delete schedule?', style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w600, color: colors.foam)),
        content: Text('"${schedule['name']}" will be removed.', style: GoogleFonts.inter(fontSize: 13, color: colors.mist)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text('Cancel', style: GoogleFonts.inter(fontSize: 13, color: colors.mist))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text('Delete', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: colors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.deleteSchedule(id);
      _load();
    } catch (e) {
      _err('Failed to delete schedule');
    }
  }

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
        title: Text('Schedules', style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: colors.foam)),
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
          child: _loading
              ? Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: colors.stream)))
              : _devices.isEmpty
                  ? const _EmptyDevices()
                  : ListView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      children: [
                        for (final device in _devices)
                          _DeviceSection(
                            device: device,
                            schedules: _schedulesOf(device['deviceId'] as String),
                            canAdd: true,
                            onAdd: () => _add(device['deviceId'] as String),
                            onEdit: _edit,
                            onToggle: _toggle,
                            onDelete: _delete,
                          ),
                      ],
                    ),
        ),
      ),
    );
  }
}

class _DeviceSection extends StatelessWidget {
  final Map<String, dynamic> device;
  final List<Map<String, dynamic>> schedules;
  final bool canAdd;
  final VoidCallback onAdd;
  final void Function(Map<String, dynamic>) onEdit;
  final void Function(Map<String, dynamic>) onToggle;
  final void Function(Map<String, dynamic>) onDelete;

  const _DeviceSection({
    required this.device,
    required this.schedules,
    required this.canAdd,
    required this.onAdd,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final channels = device['channels'] as int? ?? 4;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device['name'] as String? ?? 'Device', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.sora(fontSize: 20, fontWeight: FontWeight.w700, color: colors.foam)),
                    const SizedBox(height: 2),
                    Text('ID: ${device['deviceId']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(fontSize: 12, color: colors.mist)),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 40,
                child: FilledButton.icon(
                  onPressed: canAdd ? onAdd : null,
                  icon: const Icon(Icons.add, size: 17),
                  label: Text('Add', style: GoogleFonts.sora(fontSize: 13, fontWeight: FontWeight.w700)),
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.stream,
                    foregroundColor: colors.well,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text('CH1–CH$channels', style: GoogleFonts.inter(fontSize: 11, color: colors.mist.withValues(alpha: 0.7))),
          const SizedBox(height: 12),
          if (schedules.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              decoration: BoxDecoration(
                color: colors.submerged.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: colors.border),
              ),
              child: Text('No schedules for this device', style: GoogleFonts.inter(fontSize: 13, color: colors.mist)),
            )
          else
            for (final (i, schedule) in schedules.indexed) ...[
              _ScheduleTile(
                schedule: schedule,
                canEdit: true,
                onEdit: () => onEdit(schedule),
                onToggle: () => onToggle(schedule),
                onDelete: () => onDelete(schedule),
              ),
              if (i < schedules.length - 1) const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }
}

class _ScheduleTile extends StatelessWidget {
  final Map<String, dynamic> schedule;
  final bool canEdit;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const _ScheduleTile({
    required this.schedule,
    required this.canEdit,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final enabled = (schedule['enabled'] as bool?) ?? false;
    final channels = (schedule['channels'] as List<dynamic>? ?? [])
        .map((c) => 'CH$c')
        .join(', ');
    final windows = _scheduleWindows(schedule);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: colors.submerged,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: enabled ? colors.leaf.withValues(alpha: 0.3) : colors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: canEdit ? onEdit : null,
            borderRadius: BorderRadius.circular(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(schedule['name'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: colors.foam)),
                    ),
                    _ActiveTag(enabled: enabled),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.tune, size: 12, color: colors.mist.withValues(alpha: 0.8)),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text('Channels: $channels', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(fontSize: 12, color: colors.mist)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                WindowTimeline(windows: windows, compact: true),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.event_repeat, size: 12, color: colors.sunlight),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(_recurrenceSummary(schedule), maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(fontSize: 11, color: colors.mist.withValues(alpha: 0.9))),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text('Enabled', style: GoogleFonts.inter(fontSize: 12, color: colors.mist)),
              const SizedBox(width: 8),
              Switch(
                value: enabled,
                onChanged: (_) => onToggle(),
                activeTrackColor: colors.leaf,
                activeThumbColor: colors.well,
              ),
              const SizedBox(width: 6),
              IconButton(
                onPressed: canEdit ? onEdit : null,
                icon: Icon(Icons.edit_outlined, size: 19, color: colors.stream),
                tooltip: 'Edit',
              ),
              IconButton(
                onPressed: onDelete,
                icon: Icon(Icons.delete_outline, size: 19, color: colors.danger),
                tooltip: 'Delete',
              ),
            ],
          ),
        ],
      ),
    );
  }

  static List<({int start, int end})> _scheduleWindows(Map<String, dynamic> schedule) {
    final ranges = (schedule['timeRanges'] as List<dynamic>? ?? []);
    return [
      for (final r in ranges)
        (
          start: _minOf(r['start'] as String?),
          end: _minOf(r['end'] as String?),
        ),
    ];
  }

  static int _minOf(String? hhmm) {
    if (hhmm == null) return 0;
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm);
    if (m == null) return 0;
    return int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
  }

  String _recurrenceSummary(Map<String, dynamic> schedule) {
    final recurrence = schedule['recurrence'] as Map<String, dynamic>? ?? {};
    if (recurrence['type'] == 'custom') {
      final days = (recurrence['daysOfWeek'] as List<dynamic>? ?? [])
          .map((d) => _dayLabels[(d as int?) ?? 0])
          .join(', ');
      return 'Custom: $days';
    }
    return 'Every day';
  }
}

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices();

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.devices_other, size: 48, color: colors.mist.withValues(alpha: 0.3)),
          const SizedBox(height: 12),
          Text('No devices yet', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600, color: colors.mist)),
          const SizedBox(height: 4),
          Text('Claim a device to start scheduling', style: GoogleFonts.inter(fontSize: 12, color: colors.mist.withValues(alpha: 0.6))),
        ],
      ),
    );
  }
}

class _ActiveTag extends StatelessWidget {
  final bool enabled;
  const _ActiveTag({required this.enabled});

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final color = enabled ? colors.leaf : colors.mist;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          const SizedBox(width: 5),
          Text(enabled ? 'Active' : 'Off',
            style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}