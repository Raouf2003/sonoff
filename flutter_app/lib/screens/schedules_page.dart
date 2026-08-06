import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../services/api_service.dart';
import '../widgets/stees_widgets.dart';
import '../widgets/window_timeline.dart';
import 'schedule_form_screen.dart';

class SchedulesPage extends StatefulWidget {
  const SchedulesPage({super.key});

  @override
  State<SchedulesPage> createState() => _SchedulesPageState();
}

class _SchedulesPageState extends State<SchedulesPage> {
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
    }
  }

  Map<String, dynamic> _deviceOf(String deviceId) {
    for (final d in _devices) {
      if (d['deviceId'] == deviceId) return d;
    }
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
    }
  }

  Future<void> _delete(Map<String, dynamic> schedule) async {
    final id = schedule['_id'] as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
        title: Text('Delete schedule?', style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.foam)),
        content: Text('"${schedule['name']}" will be removed.', style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text('Cancel', style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text('Delete', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.deleteSchedule(id);
      _load();
    } catch (e) {
      // ignore
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SteesLoading();
    if (_devices.isEmpty) {
      return const SteesEmpty(
        icon: Icons.devices_other,
        title: 'No devices yet',
        subtitle: 'Claim a device to start scheduling.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: AppColors.stream,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.xxxl),
        itemCount: _devices.length,
        itemBuilder: (_, i) => _DeviceSection(
          device: _devices[i],
          schedules: _schedulesOf(_devices[i]['deviceId'] as String),
          onAdd: () => _add(_devices[i]['deviceId'] as String),
          onEdit: _edit,
          onToggle: _toggle,
          onDelete: _delete,
        ),
      ),
    );
  }
}

class _DeviceSection extends StatelessWidget {
  final Map<String, dynamic> device;
  final List<Map<String, dynamic>> schedules;
  final VoidCallback onAdd;
  final void Function(Map<String, dynamic>) onEdit;
  final void Function(Map<String, dynamic>) onToggle;
  final void Function(Map<String, dynamic>) onDelete;

  const _DeviceSection({
    required this.device,
    required this.schedules,
    required this.onAdd,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final channels = device['channels'] as int? ?? 4;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SteesAvatar(icon: Icons.water_drop, color: AppColors.stream),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device['name'] as String? ?? 'Device',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.foam),
                    ),
                    Text(
                      'CH1–CH$channels',
                      style: GoogleFonts.inter(fontSize: 11, color: AppColors.mist.withValues(alpha: 0.7)),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add, size: 16),
                label: Text('Add', style: GoogleFonts.sora(fontSize: 12, fontWeight: FontWeight.w700)),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.stream,
                  foregroundColor: AppColors.well,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (schedules.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(
                'No schedules for this device',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(fontSize: 13, color: AppColors.mist.withValues(alpha: 0.6)),
              ),
            )
          else
            for (final (i, schedule) in schedules.indexed) ...[
              _ScheduleTile(
                schedule: schedule,
                onEdit: () => onEdit(schedule),
                onToggle: () => onToggle(schedule),
                onDelete: () => onDelete(schedule),
              ),
              if (i < schedules.length - 1) const SizedBox(height: AppSpacing.sm),
            ],
        ],
      ),
    );
  }
}

class _ScheduleTile extends StatefulWidget {
  final Map<String, dynamic> schedule;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const _ScheduleTile({
    required this.schedule,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  State<_ScheduleTile> createState() => _ScheduleTileState();
}

class _ScheduleTileState extends State<_ScheduleTile> {
  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.schedule;
    final enabled = (s['enabled'] as bool?) ?? false;
    final channels = (s['channels'] as List<dynamic>? ?? []).map((c) => 'CH$c').join(', ');
    final windows = _scheduleWindows(s);

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) { setState(() => _pressed = false); widget.onEdit(); },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: SteesCard(
          active: enabled,
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SteesAvatar(icon: Icons.schedule, color: AppColors.stream),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s['name'] as String? ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.foam),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Channels: $channels',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(fontSize: 11, color: AppColors.mist),
                        ),
                      ],
                    ),
                  ),
                  SteesActiveTag(active: enabled),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              WindowTimeline(windows: windows, compact: true),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Icon(Icons.event_repeat, size: 12, color: AppColors.sunlight),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      _recurrenceSummary(s),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(fontSize: 11, color: AppColors.mist.withValues(alpha: 0.9)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text('Enabled', style: GoogleFonts.inter(fontSize: 12, color: AppColors.mist)),
                  const SizedBox(width: AppSpacing.sm),
                  Switch(
                    value: enabled,
                    onChanged: (_) => widget.onToggle(),
                    activeTrackColor: AppColors.leaf,
                    activeThumbColor: AppColors.well,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  IconButton(
                    onPressed: widget.onEdit,
                    icon: const Icon(Icons.edit_outlined, size: 18, color: AppColors.stream),
                    tooltip: 'Edit',
                  ),
                  IconButton(
                    onPressed: widget.onDelete,
                    icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.danger),
                    tooltip: 'Delete',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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

  List<({int start, int end})> _scheduleWindows(Map<String, dynamic> schedule) {
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
}
