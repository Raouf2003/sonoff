import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
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
  bool _loadError = false;

  // Deferred-sync visual flow, shared by every CRUD action: cards/chips
  // linger while the device-side sync catches up. The backend cannot tell
  // clients when the sweep physically finalizes (rows leave GET at soft-
  // delete), so liveness is polled from the existing /api/status endpoint and
  // drives an online/offline state machine per watched action.
  //   kind=create/delete -> full-card dim treatment (nothing/something is
  //                         materially appearing/vanishing on the device)
  //   kind=edit/toggle   -> non-blocking corner chip (old config stays valid
  //                         until the new sync lands)
  final List<_SyncWatch> _syncWatches = [];
  Timer? _removalTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _removalTimer?.cancel();
    super.dispose();
  }

  void _upsertWatch(_SyncWatch watch) {
    _syncWatches.removeWhere((w) => w.scheduleId == watch.scheduleId);
    _syncWatches.add(watch);
    _startSyncSweeper();
  }

  void _clearWatch(String? scheduleId) {
    if (scheduleId == null) return;
    final before = _syncWatches.length;
    _syncWatches.removeWhere((w) => w.scheduleId == scheduleId);
    if (_syncWatches.length != before && mounted) setState(() {});
  }

  /// Lazily started ticker: one /api/status poll per affected device per tick
  /// (LWT-authoritative, via ApiService.getStatus) advances every watch:
  ///   ONLINE   -> short 12 s grace (delete-time sync + sweep finalize), then
  ///               the watch settles (chip clears / dim card finalizes).
  ///   OFFLINE  -> latched: dim card / chip persists indefinitely with the
  ///               reconnect label until an online transition starts the grace.
  /// Poll failures leave watches untouched; a blind 90 s fallback bounds the
  /// worst case so a broken API can never pin UI forever.
  static const _onlineGrace = Duration(seconds: 12);
  static const _blindFallback = Duration(seconds: 90);
  bool _presencePollBusy = false;

  void _startSyncSweeper() {
    _removalTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      _sweepSyncWatches();
    });
  }

  Future<void> _sweepSyncWatches() async {
    if (!mounted || _syncWatches.isEmpty || _presencePollBusy) return;
    _presencePollBusy = true;
    final now = DateTime.now();
    var changed = false;
    try {
      final deviceIds = _syncWatches
          .map((w) => w.schedule['deviceId'] as String?)
          .whereType<String>()
          .toSet();
      final onlineByDevice = <String, bool>{};
      for (final deviceId in deviceIds) {
        try {
          final status = await _api.getStatus(deviceId);
          onlineByDevice[deviceId] = status['online'] == true;
        } catch (_) {
          onlineByDevice[deviceId] = false; // unknown: treated as no-transition
        }
      }
      if (!mounted) return;
      final settled = <_SyncWatch>[];
      for (final w in _syncWatches) {
        final deviceId = w.schedule['deviceId'] as String?;
        final online = deviceId != null ? onlineByDevice[deviceId] : false;
        if (online == false) {
          // Went (or stayed) offline: latch the indefinite waiting state.
          if (w.phase != 'offline' || w.dismissAt != null) changed = true;
          w.phase = 'offline';
          w.dismissAt = null;
          continue;
        }
        if (online == null) {
          // Status unknown (poll failed): keep current state, but never let a
          // watch stick forever on a broken API.
          if (now.difference(w.startedAt) > _blindFallback &&
              w.startedAt.add(_blindFallback).isBefore(now)) {
            settled.add(w);
            changed = true;
          }
          continue;
        }
        // Device is online: first observation opens the grace window.
        w.dismissAt ??= now.add(_onlineGrace);
        if (now.isAfter(w.dismissAt!)) {
          settled.add(w);
          changed = true;
        }
      }
      for (final s in settled) {
        _syncWatches.remove(s);
      }
      if (_syncWatches.isEmpty) {
        _removalTimer?.cancel();
        _removalTimer = null;
      }
      if (changed || settled.isNotEmpty) setState(() {});
    } finally {
      _presencePollBusy = false;
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
        ),
      ),
    );
    await _load();
    _watchFromResult(result, 'create');
  }

  Future<void> _edit(Map<String, dynamic> schedule) async {
    final deviceId = schedule['deviceId'] as String;
    final result = await Navigator.of(context).push<Object?>(
      MaterialPageRoute(
        builder: (_) => ScheduleFormScreen(
          deviceId: deviceId,
          deviceName: _nameOf(deviceId),
          maxChannel: _channelsOf(deviceId),
          existing: schedule,
        ),
      ),
    );
    await _load();
    _watchFromResult(result, 'edit');
  }

  // The form pops the saved schedule payload (or legacy `true`). A payload
  // means a real device sync was triggered server-side: open a watch so the
  // card reflects convergence (dim for create, chip for edit).
  void _watchFromResult(Object? result, String kind) {
    if (!mounted) return;
    if (result is Map && result['_id'] != null) {
      final schedule = Map<String, dynamic>.from(result);
      _upsertWatch(_SyncWatch(
        kind: kind,
        scheduleId: schedule['_id'] as String?,
        schedule: schedule,
      ));
    } else if (result == true) {
      // Legacy/unknown payload: nothing to key on — plain reload only.
    }
  }

  Future<void> _toggle(Map<String, dynamic> schedule) async {
    final id = schedule['_id'] as String;
    final target = !((schedule['enabled'] as bool?) ?? false);
    setState(() => schedule['enabled'] = target);
    try {
      await _api.toggleSchedule(id);
      // Old enabled-state stays valid on the device until the new sync lands:
      // non-blocking "Updating…" chip driven by the shared presence watcher.
      _upsertWatch(_SyncWatch(
        kind: 'toggle',
        scheduleId: id,
        schedule: Map<String, dynamic>.from(schedule),
      ));
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => schedule['enabled'] = !target);
      _clearWatch(id);
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
    // "Pending then confirmed" flow: the card moves out of the live list into
    // a dimmed watch immediately (no network wait), and stays visible while
    // the device-side removal catches up.
    final previousIndex = _schedules.indexOf(schedule);
    final watch = _SyncWatch(
      kind: 'delete',
      scheduleId: schedule['_id'] as String?,
      schedule: schedule,
    );
    setState(() {
      if (previousIndex >= 0) _schedules.removeAt(previousIndex);
      _syncWatches.add(watch);
    });
    _startSyncSweeper();
    try {
      final res = await _api.deleteSchedule(id);
      if (!mounted) return;
      if (res['deferred'] == true) {
        // Device offline / removal not yet confirmed on hardware: latch the
        // offline phase (indefinite dimmed card + reconnect label). The
        // presence sweeper settles it once /api/status reports online again.
        setState(() => watch.phase = 'offline');
      } else {
        // Degraded/immediate path (native sync off): already gone server-side.
        _clearWatch(watch.scheduleId);
      }
    } catch (e) {
      // Hard failure: restore the card to its original slot, normal look.
      _clearWatch(watch.scheduleId);
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

  void _showError(String msg) {
    if (!mounted) return;
    final colors = context.steesColors;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        backgroundColor: colors.danger,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
        margin: const EdgeInsets.all(AppSpacing.lg),
        duration: const Duration(seconds: 3),
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
        itemCount: _devices.length,
        itemBuilder: (_, i) {
          final deviceId = _devices[i]['deviceId'] as String;
          return _DeviceSection(
            device: _devices[i],
            schedules: _schedulesOf(deviceId),
            watches: _syncWatches
                .where((w) => w.schedule['deviceId'] == deviceId)
                .toList(),
            onAdd: () => _add(deviceId),
            onEdit: _edit,
            onToggle: _toggle,
            onDelete: _delete,
          );
        },
      ),
    );
  }
}

_SyncWatch? _watchById(List<_SyncWatch> watches, String? id) {
  if (id == null) return null;
  for (final w in watches) {
    if (w.scheduleId == id) return w;
  }
  return null;
}

class _DeviceSection extends StatelessWidget {
  final Map<String, dynamic> device;
  final List<Map<String, dynamic>> schedules;
  final List<_SyncWatch> watches;
  final VoidCallback onAdd;
  final void Function(Map<String, dynamic>) onEdit;
  final void Function(Map<String, dynamic>) onToggle;
  final void Function(Map<String, dynamic>) onDelete;

  const _DeviceSection({
    required this.device,
    required this.schedules,
    required this.watches,
    required this.onAdd,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  /// Chip treatment for edit/toggle: the old schedule config remains valid on
  /// the device until the new sync lands, so the card stays FULLY normal and
  /// interactive — only a small corner chip communicates convergence.
  Widget _chipOverlay(BuildContext context, _ScheduleTile tile, _SyncWatch watch) {
    final colors = context.steesColors;
    final offline = watch.phase == 'offline';
    return Stack(
      children: [
        tile,
        Positioned(
          top: 6,
          right: 6,
          child: Tooltip(
            message: _syncWatchLabel(watch) ?? '',
            preferBelow: false,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: (offline ? colors.mist : colors.sunlight).withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: (offline ? colors.mist : colors.sunlight).withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_syncWatchIcon(watch), size: 10, color: offline ? colors.mist : colors.sunlight),
                  const SizedBox(width: 4),
                  Text(
                    offline ? 'DEVICE OFFLINE' : 'UPDATING\u2026',
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                      color: offline ? colors.mist : colors.sunlight,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

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
                        'CH1\u2013CH$channels',
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
          if (schedules.isEmpty && watches.isEmpty)
            Container(
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
                ],
              ),
            )
          else
            Column(
              children: [
                for (final (i, schedule) in schedules.indexed) ...[
                  Builder(builder: (ctx) {
                    final watch = _watchById(watches, schedule['_id'] as String?);
                    if (watch == null) {
                      return _ScheduleTile(
                        schedule: schedule,
                        onEdit: () => onEdit(schedule),
                        onToggle: () => onToggle(schedule),
                        onDelete: () => onDelete(schedule),
                      );
                    }
                    if (watch.isDim) {
                      // create: nothing existed before — full dim card.
                      return _buildDimmedWatchCard(ctx, watch);
                    }
                    // edit/toggle: old config stays valid — normal
                    // interactive card + corner chip only.
                    return _chipOverlay(
                      ctx,
                      _ScheduleTile(
                        schedule: schedule,
                        onEdit: () => onEdit(schedule),
                        onToggle: () => onToggle(schedule),
                        onDelete: () => onDelete(schedule),
                      ),
                      watch,
                    );
                  }),
                  if (i < schedules.length - 1 || watches.any((w) => w.kind == 'delete'))
                    const SizedBox(height: AppSpacing.sm),
                ],
                for (final (i, w) in watches.where((w) => w.kind == 'delete').indexed) ...[
                  _buildDimmedWatchCard(context, w),
                  if (i < watches.length - 1) const SizedBox(height: AppSpacing.sm),
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
    final colors = context.steesColors;
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
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      s['name'] as String? ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.sora(fontSize: 14.5, fontWeight: FontWeight.w600, color: colors.foam),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  SteesActiveTag(active: enabled),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                '$channels  \u00b7  ${_recurrenceSummary(s)}',
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

/// A CRUD action awaiting device-side convergence. The backend hides
/// soft-deleted rows immediately and cannot report sweep finalization, so
/// liveness is polled (/api/status) and drives phase 'active' -> 'offline'
/// with a bounded grace before the watch settles.
class _SyncWatch {
  /// create | edit | toggle | delete — picks the visual treatment + wording.
  final String kind;
  final String? scheduleId;
  final Map<String, dynamic> schedule;
  final DateTime startedAt = DateTime.now();
  String phase = 'active'; // 'active' | 'offline'
  DateTime? dismissAt;

  _SyncWatch({required this.kind, required this.scheduleId, required this.schedule});

  bool get isDim => kind == 'create' || kind == 'delete';
}

/// Status-line / chip wording per kind and phase. Null return = no label yet.
String? _syncWatchLabel(_SyncWatch w) {
  if (w.phase == 'offline') {
    switch (w.kind) {
      case 'create':
        return 'Device offline \u2014 will finish syncing once it reconnects.';
      case 'delete':
        return 'Device offline \u2014 will finish removing once it reconnects.';
      default:
        return 'Device offline \u2014 will update once it reconnects.';
    }
  }
  switch (w.kind) {
    case 'delete':
      return 'Removing\u2026';
    case 'create':
      return 'Syncing to device\u2026';
    default:
      return 'Updating\u2026';
  }
}

IconData _syncWatchIcon(_SyncWatch w) {
  if (w.phase == 'offline') return Icons.cloud_off_outlined;
  switch (w.kind) {
    case 'create':
      return Icons.sync_outlined;
    default:
      return Icons.hourglass_top;
  }
}

/// Dimmed full-card treatment for create/delete: nothing/something is
/// materially appearing or vanishing on the device, so the card reads as
/// not-yet-real until the sync lands.
Widget _buildDimmedWatchCard(
  BuildContext context,
  _SyncWatch watch,
) {
  final colors = context.steesColors;
  final label = _syncWatchLabel(watch);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      IgnorePointer(
        child: Opacity(
          opacity: 0.45,
          child: _ScheduleTile(
            schedule: watch.schedule,
            onEdit: () {},
            onToggle: () {},
            onDelete: () {},
          ),
        ),
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          Icon(_syncWatchIcon(watch), size: 12, color: colors.mist.withValues(alpha: 0.8)),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              label ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: colors.mist.withValues(alpha: 0.85),
              ),
            ),
          ),
        ],
      ),
    ],
  );
}
