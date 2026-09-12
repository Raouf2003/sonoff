import 'package:flutter/material.dart';
import '../devices/device_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/stees_widgets.dart';
import 'schedule_compiler.dart';
import 'schedule_form_screen.dart';
import 'schedule_model.dart';
import 'schedule_store.dart';
import 'schedule_transport.dart';

const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

class ScheduleListScreen extends StatefulWidget {
  const ScheduleListScreen({
    super.key,
    required this.deviceId,
    this.password,
    ScheduleStore? store,
    ScheduleTransport? transport,
  })  : _store = store,
        _transport = transport;

  final String deviceId;
  final String? password;
  final ScheduleStore? _store;
  final ScheduleTransport? _transport;

  @override
  State<ScheduleListScreen> createState() => _ScheduleListScreenState();
}

class _ScheduleListScreenState extends State<ScheduleListScreen> {
  late final ScheduleStore _store;
  late final ScheduleTransport _transport;
  List<LocalSchedule> _schedules = [];
  bool _loading = true;
  bool _pushing = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _store = widget._store ?? ScheduleStore();
    _transport = widget._transport ?? ScheduleTransport();
    _reload();
  }

  Future<void> _reload() async {
    final schedules = await _store.load();
    if (mounted) {
      setState(() {
        _schedules = schedules;
        _loading = false;
      });
    }
  }

  String _summary(LocalSchedule s) {
    final days = s.recurrenceType == 'daily'
        ? 'Daily'
        : s.daysOfWeek.map((d) => _dayLabels[d]).join(',');
    final ranges = s.timeRanges.map((r) => '${r.start}–${r.end}').join(', ');
    return 'CH ${s.channels.join(',')} · $days · $ranges${s.enabled ? '' : ' · OFF'}';
  }

  Future<void> _push() async {
    setState(() {
      _pushing = true;
      _notice = null;
    });
    try {
      final plan = compileSchedules(_schedules);
      if (!plan.isValid) {
        setState(() => _notice = 'Cannot apply:\n${plan.unsupportedReasons.join('\n')}');
        return;
      }
      if (plan.conflicts.isNotEmpty) {
        setState(() => _notice = 'Warnings:\n${plan.conflicts.join('\n')}');
      }
      final slots = await _store.managedSlots();
      final ruleManaged = await _store.ruleManaged();
      await _transport.applyPlan(
        kApAddress,
        plan,
        password: widget.password,
        managedSlots: slots,
        ruleManaged: ruleManaged,
      );
      final used = {for (final t in plan.timers) t.index};
      await _store.markSynced(used, plan.wantsRule);
      if (mounted) {
        setState(() => _notice = 'Applied ${plan.requiredTimerCount} timers${plan.wantsRule ? ' + Rule2' : ''} and verified.');
      }
    } on ScheduleSyncException catch (e) {
      if (mounted) setState(() => _notice = 'Failed: $e');
    } catch (e) {
      if (mounted) setState(() => _notice = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _pushing = false);
    }
  }

  Future<void> _edit(LocalSchedule? existing) async {
    final result = await Navigator.of(context).push<LocalSchedule>(
      MaterialPageRoute(builder: (_) => ScheduleFormScreen(existing: existing)),
    );
    if (result == null) return;
    final next = List<LocalSchedule>.from(_schedules);
    final index = next.indexWhere((s) => s.id == result.id);
    if (index >= 0) {
      next[index] = result;
    } else {
      next.add(result);
    }
    await _store.save(next);
    _reload();
  }

  Future<void> _remove(LocalSchedule schedule) async {
    final next = List<LocalSchedule>.from(_schedules)
      ..removeWhere((s) => s.id == schedule.id);
    await _store.save(next);
    _reload();
  }

  Future<void> _toggleEnabled(LocalSchedule schedule, bool value) async {
    final next = _schedules
        .map((s) => s.id == schedule.id
            ? LocalSchedule(
                id: s.id,
                name: s.name,
                channels: s.channels,
                recurrenceType: s.recurrenceType,
                daysOfWeek: s.daysOfWeek,
                timeRanges: s.timeRanges,
                enabled: value,
              )
            : s)
        .toList();
    await _store.save(next);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Schedules')),
      floatingActionButton: SteesFAB(
        icon: Icons.add,
        label: 'Add',
        onPressed: () => _edit(null),
      ),
      body: _loading
          ? const SteesLoading()
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                if (_notice != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: SteesCard(child: Text(_notice!)),
                  ),
                SteesCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Device timers',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: context.steesColors.foam)),
                            Text('${_schedules.where((s) => s.enabled).length} active schedules',
                                style: TextStyle(
                                    fontSize: 12, color: context.steesColors.mist)),
                          ],
                        ),
                      ),
                      ElevatedButton.icon(
                        icon: _pushing
                            ? const SizedBox(
                                width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.upload, size: 18),
                        label: const Text('Push'),
                        onPressed: _pushing ? null : _push,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                const SteesSectionHeader(title: 'Schedules', count: null),
                if (_schedules.isEmpty)
                  SteesEmpty(
                    icon: Icons.schedule_outlined,
                    title: 'No schedules yet',
                    subtitle: 'Add windows of time when relays should turn on automatically.',
                    action: ElevatedButton(
                      onPressed: () => _edit(null),
                      child: const Text('Add schedule'),
                    ),
                  ),
                for (final s in _schedules)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: SteesCard(
                      active: s.enabled,
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(s.name,
                                    style: const TextStyle(fontWeight: FontWeight.w600)),
                                Text(_summary(s),
                                    style: TextStyle(
                                        fontSize: 12, color: context.steesColors.mist)),
                              ],
                            ),
                          ),
                          SteesActiveTag(active: s.enabled),
                          Switch(value: s.enabled, onChanged: (v) => _toggleEnabled(s, v)),
                          IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _edit(s)),
                          IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _remove(s)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
