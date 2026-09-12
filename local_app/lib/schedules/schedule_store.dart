import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'schedule_model.dart';

const String _kSchedules = 'stees_local.schedules';
const String _kManagedSlots = 'stees_local.managed_slots';
const String _kRuleManaged = 'stees_local.rule_managed';
const String _kDirty = 'stees_local.schedules_dirty';
const String _kLastSync = 'stees_local.schedules_synced_at';

class ScheduleStore {
  ScheduleStore({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefs;

  Future<List<LocalSchedule>> load() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_kSchedules);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final e in decoded)
          if (e is Map<String, dynamic>)
            LocalSchedule.fromJson(e)
          else if (e is Map)
            LocalSchedule.fromJson(e.cast<String, dynamic>())
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<LocalSchedule> schedules, {bool dirty = true}) async {
    final prefs = await _prefs();
    await prefs.setString(
      _kSchedules,
      jsonEncode([for (final s in schedules) s.toJson()]),
    );
    await prefs.setBool(_kDirty, dirty);
  }

  Future<bool> isDirty() async =>
      (await _prefs()).getBool(_kDirty) ?? false;

  Future<Set<int>> managedSlots() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kManagedSlots);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return {for (final e in decoded) (e as num).toInt()};
    } catch (_) {}
    return {};
  }

  Future<bool> ruleManaged() async =>
      (await _prefs()).getBool(_kRuleManaged) ?? false;

  Future<void> markSynced(Set<int> slots, bool rule) async {
    final prefs = await _prefs();
    await prefs.setString(_kManagedSlots, jsonEncode(slots.toList()));
    await prefs.setBool(_kRuleManaged, rule);
    await prefs.setBool(_kDirty, false);
    await prefs.setString(_kLastSync, DateTime.now().toIso8601String());
  }

  Future<DateTime?> lastSyncedAt() async {
    final raw = (await _prefs()).getString(_kLastSync);
    return raw == null ? null : DateTime.tryParse(raw);
  }
}
