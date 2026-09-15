import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';
import '../services/api_service.dart';
import '../widgets/stees_widgets.dart';
import '../widgets/weather_advisory_chip.dart';
import '../widgets/window_timeline.dart';
import 'schedule_form_screen.dart';

/// Page-level offline notice. Shown at the top of the schedules page while
/// any listed device reports offline; schedules converge automatically once
/// the device reconnects (backend retry sweep), so no per-card sync state is
/// tracked here.
const kOfflineBannerText =
    'Device offline — schedules will sync automatically once it reconnects.';

class SchedulesPage extends StatefulWidget {
  const SchedulesPage({super.key, this.api});

  /// Injectable transport (widget tests). Defaults to a live [ApiService].
  final ApiService? api;

  @override
  State<SchedulesPage> createState() => SchedulesPageState();
}

class SchedulesPageState extends State<SchedulesPage> {
  late final ApiService _api;
  List<Map<String, dynamic>> _devices = [];
  List<Map<String, dynamic>> _schedules = [];
  bool _loading = true;
  bool _loadError = false;

  // Single page-level presence flag driving the offline banner. Sourced from
  // GET /api/status on a fixed interval plus after every load/CRUD round
  // trip — one sweep for the whole page, never per card. Reflects the latest
  // reported state directly: no grace period, no fallback timers.
  bool _deviceOffline = false;
  Timer? _presenceTimer;
  Timer? _weatherTimer;
  bool _presenceBusy = false;
  final Map<String, Map<String, dynamic>> _weatherBySchedule = {};

  static const _presenceInterval = Duration(seconds: 15);

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? ApiService();
    _load();
    _presenceTimer =
        Timer.periodic(_presenceInterval, (_) => _pollPresence());
    _weatherTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (mounted) _loadWeather();
    });
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    _weatherTimer?.cancel();
    super.dispose();
  }

  void refreshWeather() => _loadWeather();

  /// One status sweep for the whole page: the banner is on while any listed
  /// device reports offline. A failed poll leaves the previous state
  /// untouched — it is "unknown", not evidence of offline.
  Future<void> _pollPresence() async {
    if (!mounted || _presenceBusy || _devices.isEmpty) return;
    _presenceBusy = true;
    try {
      var anyOffline = false;
      for (final d in _devices) {
        final deviceId = d['deviceId'] as String?;
        if (deviceId == null) continue;
        late final Map<String, dynamic> status;
        try {
          status = await _api.getStatus(deviceId);
        } catch (_) {
          return;
        }
        if (status['online'] != true) {
          anyOffline = true;
          break;
        }
      }
      if (!mounted) return;
      if (anyOffline != _deviceOffline) {
        setState(() => _deviceOffline = anyOffline);
      }
    } finally {
      _presenceBusy = false;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = false;
    });
    try {
      final results = await Future.wait([_api.getDevices(), _api.getSchedules()]);
      if (mounted) {
        setState(() {
          _devices = results[0].cast<Map<String, dynamic>>();
          _schedules = results[1].cast<Map<String, dynamic>>();
          _loading = false;
        });
        _loadWeather();
        await _pollPresence();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          // Only surface the error screen when nothing is loaded yet; a failed
          // refresh against existing data keeps showing the list.
          _loadError = _devices.isEmpty;
        });
      }
    }
  }

  Future<void> _loadWeather() async {
    final locDevices = _devices
        .where((d) => d['deviceId'] != null && d['lat'] != null && d['lon'] != null)
        .toList();
    if (locDevices.isEmpty) {
      if (mounted && _weatherBySchedule.isNotEmpty) {
        setState(() => _weatherBySchedule.clear());
      }
      return;
    }
    final results = await Future.wait(
      locDevices.map((d) async {
        try {
          final res = await _api.getWeatherToday(d['deviceId'] as String);
          return res['advisories'] as List<dynamic>? ?? [];
        } catch (_) {
          return <dynamic>[];
        }
      }),
    );
    final next = <String, Map<String, dynamic>>{};
    for (final list in results) {
      for (final a in list) {
        if (a is Map<String, dynamic> && a['scheduleId'] != null) {
          next[a['scheduleId'] as String] = a;
        }
      }
    }
    if (mounted) {
      setState(() {
        _weatherBySchedule
          ..clear()
          ..addAll(next);
      });
    }
  }

  Map<String, dynamic>? _weatherFor(String? scheduleId) =>
      scheduleId == null ? null : _weatherBySchedule[scheduleId];

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
    final result = await Navigator.of(context).push<Object?>(
      MaterialPageRoute(
        builder: (_) => ScheduleFormScreen(
          deviceId: deviceId,
          deviceName: _nameOf(deviceId),
          maxChannel: _channelsOf(deviceId),
          siblings: _schedulesOf(deviceId),
        ),
      ),
    );
    await _load();
    _confirmSaved(result);
  }

  Future<void> _edit(Map<String, dynamic> schedule) async {
    final deviceId = schedule['deviceId'] as String;
    final id = schedule['_id'] as String?;
    final result = await Navigator.of(context).push<Object?>(
      MaterialPageRoute(
        builder: (_) => ScheduleFormScreen(
          deviceId: deviceId,
          deviceName: _nameOf(deviceId),
          maxChannel: _channelsOf(deviceId),
          existing: schedule,
          // Exclude the schedule under edit so it can't conflict with itself.
          siblings:
              _schedulesOf(deviceId).where((s) => s['_id'] != id).toList(),
        ),
      ),
    );
    await _load();
    _confirmSaved(result);
  }

  // The form pops the saved schedule payload (or legacy `true`) on success.
  // This is immediate feedback that the API call succeeded — independent of
  // device online status, which the top banner already covers.
  void _confirmSaved(Object? result) {
    if (!mounted) return;
    if ((result is Map && result['_id'] != null) || result == true) {
      _showInfo('Schedule saved');
    }
  }

  Future<void> _toggle(Map<String, dynamic> schedule) async {
    final id = schedule['_id'] as String;
    final target = !((schedule['enabled'] as bool?) ?? false);
    setState(() => schedule['enabled'] = target);
    try {
      await _api.toggleSchedule(id);
      if (!mounted) return;
      _showInfo('Schedule saved');
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => schedule['enabled'] = !target);
      _showError(e is ApiException ? e.message : 'Could not update the schedule');
    }
  }

  Future<void> _delete(Map<String, dynamic> schedule) async {
    final colors = context.steesColors;
    final id = schedule['_id'] as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
        title: Text('Delete schedule?', style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w600, color: colors.foam)),
        content: Text('"${schedule['name']}" will be removed.', style: GoogleFonts.inter(fontSize: 13, color: colors.mist)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text('Cancel', style: GoogleFonts.inter(fontSize: 13, color: colors.mist))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text('Delete', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: colors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    // Optimistic removal for a snappy list; restored below on hard failure.
    final previousIndex = _schedules.indexOf(schedule);
    setState(() {
      if (previousIndex >= 0) _schedules.removeAt(previousIndex);
    });
    try {
      await _api.deleteSchedule(id);
      if (!mounted) return;
      _showInfo('Schedule deleted');
      await _load();
    } catch (e) {
      // Hard failure: restore the card to its original slot, normal look.
      if (!mounted) return;
      setState(() {
        if (previousIndex >= 0 && previousIndex <= _schedules.length) {
          _schedules.insert(previousIndex, schedule);
        } else {
          _schedules.add(schedule);
        }
      });
      _showError(e is ApiException ? e.message : 'Could not delete the schedule');
    }
  }

  void _showInfo(String msg) => _showToast(msg, isError: false);

  void _showError(String msg) => _showToast(msg, isError: true);

  /// Toast matching the page's card/banner language: tinted fill with an
  /// accent border and a leading icon instead of the default solid blocks.
  /// Success uses `leaf`, errors use `danger`.
  void _showToast(String msg, {required bool isError}) {
    if (!mounted) return;
    final colors = context.steesColors;
    final accent = isError ? colors.danger : colors.leaf;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                isError ? Icons.error_outline : Icons.check_circle_outline,
                size: 18,
                color: accent,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  msg,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: colors.foam,
                  ),
                ),
              ),
            ],
          ),
          backgroundColor: accent.withValues(alpha: 0.16),
          elevation: 0,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.xl),
            side: BorderSide(color: accent.withValues(alpha: 0.45)),
          ),
          margin: const EdgeInsets.all(AppSpacing.lg),
          duration: Duration(seconds: isError ? 3 : 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    if (_loading) return const SteesLoading();
    if (_loadError) {
      return SteesError(
        title: 'Could not load schedules',
        subtitle: 'Check your connection and try again.',
        onRetry: _load,
      );
    }
    if (_devices.isEmpty) {
      return const SteesEmpty(
        icon: Icons.devices_other,
        title: 'No devices yet',
        subtitle: 'Claim a device to start scheduling.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: colors.stream,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.xxxl),
        itemCount: _devices.length + 1,
        itemBuilder: (_, i) {
          if (i == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildPageTitle(context.steesColors),
                if (_deviceOffline) _buildOfflineBanner(context.steesColors),
              ],
            );
          }
          final deviceId = _devices[i - 1]['deviceId'] as String;
          return _DeviceSection(
            device: _devices[i - 1],
            schedules: _schedulesOf(deviceId),
            weatherFor: _weatherFor,
            onAdd: () => _add(deviceId),
            onEdit: _edit,
            onToggle: _toggle,
            onDelete: _delete,
          );
        },
      ),
    );
  }

  Widget _buildPageTitle(SteesColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xs,
        AppSpacing.sm,
        AppSpacing.xs,
        AppSpacing.md,
      ),
      child: Text(
        'SCHEDULES',
        style: GoogleFonts.sora(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.8,
          color: colors.mist,
        ),
      ),
    );
  }

  /// The single page-level offline notice. Visible while any listed device
  /// reports offline; hidden again as soon as status reports online.
  Widget _buildOfflineBanner(SteesColors colors) {
    return Container(
      key: const ValueKey('offlineBanner'),
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.xs,
        0,
        AppSpacing.xs,
        AppSpacing.md,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.sunlight.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colors.sunlight.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 14, color: colors.sunlight),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              kOfflineBannerText,
              style: GoogleFonts.inter(fontSize: 12, color: colors.foam),
            ),
          ),
        ],
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
  final Map<String, dynamic>? Function(String? scheduleId)? weatherFor;

  const _DeviceSection({
    required this.device,
    required this.schedules,
    required this.onAdd,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
    this.weatherFor,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final channels = device['channels'] as int? ?? 4;
    // Open group: no enclosing box. A quiet header introduces the device and
    // the schedule tiles stand on their own — no card-in-card nesting.
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    color: colors.stream.withValues(alpha: 0.10),
                    border: Border.all(color: colors.borderActive),
                  ),
                  child: Icon(Icons.water_drop, size: 17, color: colors.stream),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device['name'] as String? ?? 'Device',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.sora(fontSize: 16, fontWeight: FontWeight.w700, color: colors.foam),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        schedules.isEmpty
                            ? 'CH1–CH$channels'
                            : 'CH1–CH$channels  ·  ${schedules.length} ${schedules.length == 1 ? 'schedule' : 'schedules'}',
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.6,
                          color: colors.mist.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add, size: 15),
                  label: Text('Add', style: GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w600)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colors.foam,
                    side: BorderSide(color: colors.border),
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 8),
                    minimumSize: const Size(0, 36),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (schedules.isEmpty)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onAdd,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: colors.border),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.schedule_outlined, size: 14, color: colors.mist.withValues(alpha: 0.5)),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      'No schedules for this device',
                      style: GoogleFonts.inter(fontSize: 12.5, color: colors.mist.withValues(alpha: 0.6)),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Icon(Icons.add, size: 14, color: colors.stream.withValues(alpha: 0.7)),
                  ],
                ),
              ),
            )
          else
            Column(
              children: [
                for (final (i, schedule) in schedules.indexed) ...[
                  _ScheduleTile(
                    schedule: schedule,
                    onEdit: () => onEdit(schedule),
                    onToggle: () => onToggle(schedule),
                    onDelete: () => onDelete(schedule),
                    advisory: weatherFor?.call(schedule['_id'] as String?),
                  ),
                  if (i < schedules.length - 1)
                    const SizedBox(height: AppSpacing.sm),
                ],
              ],
            ),
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
  final Map<String, dynamic>? advisory;

  const _ScheduleTile({
    required this.schedule,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
    this.advisory,
  });

  @override
  State<_ScheduleTile> createState() => _ScheduleTileState();
}

class _ScheduleTileState extends State<_ScheduleTile> {
  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final s = widget.schedule;
    final enabled = (s['enabled'] as bool?) ?? false;
    final channels = (s['channels'] as List<dynamic>? ?? []).map((c) => 'CH$c').join(', ');
    final windows = _scheduleWindows(s);
    final ranges = s['timeRanges'] as List<dynamic>? ?? const [];
    final heroRange = ranges.isNotEmpty ? _rangeText(ranges.first) : '--:--';
    final extraRanges = ranges.length > 1 ? '+${ranges.length - 1}' : null;

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
              // Time-first: the window IS the card's face, in the data face.
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Text(
                      heroRange,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 23,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                        color: enabled ? colors.stream : colors.mist.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
                  if (extraRanges != null) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: colors.surfaceLight.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Text(
                        extraRanges,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: colors.mist,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: AppSpacing.sm),
                  SteesActiveTag(active: enabled),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _metaLine(s, channels),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.4,
                  color: colors.mist.withValues(alpha: 0.75),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              WindowTimeline(windows: windows, compact: true),
              if (widget.advisory != null) ...[
                const SizedBox(height: AppSpacing.sm),
                WeatherAdvisoryChip(advisory: widget.advisory!),
              ],
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Text('Enabled', style: GoogleFonts.inter(fontSize: 12, color: colors.mist)),
                  const SizedBox(width: AppSpacing.sm),
                  Switch(
                    value: enabled,
                    onChanged: (_) => widget.onToggle(),
                    activeTrackColor: colors.leaf,
                    activeThumbColor: colors.well,
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: widget.onEdit,
                    icon: Icon(Icons.edit_outlined, size: 18, color: colors.stream),
                    tooltip: 'Edit',
                  ),
                  IconButton(
                    onPressed: widget.onDelete,
                    icon: Icon(Icons.delete_outline, size: 18, color: colors.danger),
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

  static String _rangeText(dynamic r) {
    if (r is! Map) return '--:--';
    final start = r['start'] as String? ?? '--:--';
    final end = r['end'] as String? ?? '--:--';
    return '$start–$end';
  }

  /// Meta readout under the hero time: name (when present), channels,
  /// recurrence — so same-hour programs stay distinguishable.
  String _metaLine(Map<String, dynamic> s, String channels) {
    final parts = <String>[
      if ((s['name'] as String? ?? '').isNotEmpty) s['name'] as String,
      channels,
      _recurrenceSummary(s),
    ];
    return parts.join('  ·  ');
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
