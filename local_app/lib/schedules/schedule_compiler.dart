import 'dart:convert';
import 'schedule_model.dart';

const int kMaxTimers = 16;
const int kMaxRuleLength = 511;
const int kSteesRuleIndex = 2;
const List<int> kAllDays = [0, 1, 2, 3, 4, 5, 6];

int? toMinutes(String? hhmm) {
  if (hhmm == null) return null;
  final m = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(hhmm);
  if (m == null) return null;
  return int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
}

String toHhmm(int minutes) {
  final p = (int n) => n.toString().padLeft(2, '0');
  return '${p(minutes ~/ 60)}:${p(minutes % 60)}';
}

int tasmotaDayPosition(int steesDay) => (steesDay + 1) % 7;

String daysMask(List<int> steesDays) {
  final chars = List.filled(7, '0');
  for (final day in steesDays) {
    chars[tasmotaDayPosition(day)] = '1';
  }
  return chars.join();
}

Set<int>? expandDays(LocalSchedule schedule) {
  if (schedule.recurrenceType == 'daily') return Set.of(kAllDays);
  if (schedule.recurrenceType != 'custom') return null;
  final days = <int>{};
  for (final d in schedule.daysOfWeek) {
    if (d >= 0 && d <= 6) days.add(d);
  }
  return days;
}

class TimerConfig {
  const TimerConfig({
    required this.enable,
    required this.mode,
    required this.time,
    required this.window,
    required this.days,
    required this.repeat,
    required this.output,
    required this.action,
  });

  final int enable;
  final int mode;
  final String time;
  final int window;
  final String days;
  final int repeat;
  final int output;
  final int action;

  static const TimerConfig factoryDefault = TimerConfig(
    enable: 0,
    mode: 0,
    time: '00:00',
    window: 0,
    days: '0000000',
    repeat: 0,
    output: 1,
    action: 0,
  );

  bool get isDefault =>
      enable == 0 &&
      mode == 0 &&
      time == '00:00' &&
      window == 0 &&
      days == '0000000' &&
      repeat == 0 &&
      action == 0;

  String toPayload() => jsonEncode({
        'Enable': enable,
        'Mode': mode,
        'Time': time,
        'Window': window,
        'Days': days,
        'Repeat': repeat,
        'Output': output,
        'Action': action,
      });

  static TimerConfig? fromDevice(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    String time(Object? v) =>
        v is String && RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(v) ? v : '00:00';
    String days(Object? v) =>
        v is String && RegExp(r'^[01]{7}$').hasMatch(v) ? v : '0000000';
    return TimerConfig(
      enable: asInt(raw['Enable']) == 1 ? 1 : 0,
      mode: asInt(raw['Mode']) == 1 ? 1 : 0,
      time: time(raw['Time']),
      window: asInt(raw['Window']),
      days: days(raw['Days']),
      repeat: asInt(raw['Repeat']),
      output: asInt(raw['Output']),
      action: asInt(raw['Action']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TimerConfig &&
      enable == other.enable &&
      mode == other.mode &&
      time == other.time &&
      window == other.window &&
      days == other.days &&
      repeat == other.repeat &&
      output == other.output &&
      action == other.action;

  @override
  int get hashCode => Object.hash(enable, mode, time, window, days, repeat, output, action);
}

class PlannedTimer {
  const PlannedTimer({required this.index, required this.config, required this.on, required this.off});
  final int index;
  final TimerConfig config;
  final List<int> on;
  final List<int> off;
}

class CompiledPlan {
  const CompiledPlan({
    required this.timers,
    required this.ruleText,
    required this.requiredTimerCount,
    required this.conflicts,
    required this.unsupportedReasons,
  });
  final List<PlannedTimer> timers;
  final String ruleText;
  final int requiredTimerCount;
  final List<String> conflicts;
  final List<String> unsupportedReasons;

  bool get isValid => unsupportedReasons.isEmpty;
  bool get wantsRule => ruleText.isNotEmpty;
}

class _Interval {
  _Interval(this.day, this.start, this.end, this.channels, this.scheduleId);
  final int day;
  final int start;
  final int end;
  final Set<int> channels;
  final String scheduleId;
}

class _Transition {
  _Transition(this.time, this.on, this.off);
  final int time;
  final List<int> on;
  final List<int> off;
}

List<_Transition> _statesForDay(int day, List<_Interval> intervals) {
  final times = <int>{};
  for (final iv in intervals) {
    times.add(iv.start);
    times.add(iv.end);
  }
  final sorted = times.toList()..sort();
  Set<int> coverageAt(int t) {
    final on = <int>{};
    for (final iv in intervals) {
      if (iv.start <= t && t < iv.end) on.addAll(iv.channels);
    }
    return on;
  }

  final transitions = <_Transition>[];
  var previous = <int>{};
  for (final t in sorted) {
    final next = coverageAt(t);
    final on = next.where((c) => !previous.contains(c)).toList()..sort();
    final off = previous.where((c) => !next.contains(c)).toList()..sort();
    if (on.isNotEmpty || off.isNotEmpty) {
      transitions.add(_Transition(t, on, off));
    }
    previous = next;
  }
  return transitions;
}

CompiledPlan compileSchedules(List<LocalSchedule> schedules, {int deviceMaxChannels = 4}) {
  final conflicts = <String>[];
  final unsupportedReasons = <String>[];

  final enabled = schedules.where((s) => s.enabled).toList()
    ..sort((a, b) {
      final ka = '${a.id}|${a.name}';
      final kb = '${b.id}|${b.name}';
      return ka.compareTo(kb);
    });

  final intervals = <_Interval>[];
  for (final schedule in enabled) {
    final label = schedule.name.isEmpty ? schedule.id : schedule.name;
    final days = expandDays(schedule);
    if (days == null || days.isEmpty) {
      unsupportedReasons.add('Schedule $label has an unsupported or empty recurrence');
      continue;
    }
    final channels = <int>{};
    for (final c in schedule.channels) {
      if (c >= 1 && c <= deviceMaxChannels) {
        channels.add(c);
      } else {
        conflicts.add('Schedule $label targets channel $c which is outside the device (1..$deviceMaxChannels)');
      }
    }
    if (channels.isEmpty) {
      unsupportedReasons.add('Schedule $label has no valid channels after validation');
      continue;
    }
    for (final range in schedule.timeRanges) {
      final start = toMinutes(range.start);
      final end = toMinutes(range.end);
      if (start == null || end == null || end <= start) {
        unsupportedReasons.add('Schedule $label has an invalid time range ${range.start}-${range.end}');
        continue;
      }
      for (final day in days) {
        intervals.add(_Interval(day, start, end, channels, schedule.id));
      }
    }
  }

  final eventsByKey = <String, _MergedEvent>{};
  for (final day in kAllDays) {
    final dayIntervals = intervals.where((iv) => iv.day == day).toList();
    if (dayIntervals.isEmpty) continue;
    for (final tr in _statesForDay(day, dayIntervals)) {
      final key = '${tr.time}|${tr.on.join(',')}|${tr.off.join(',')}';
      final event = eventsByKey.putIfAbsent(
        key,
        () => _MergedEvent(tr.time, tr.on, tr.off),
      );
      event.days.add(day);
    }
  }

  final events = eventsByKey.values.toList()
    ..sort((a, b) {
      final c = a.time.compareTo(b.time);
      if (c != 0) return c;
      final d = a.on.join(',').compareTo(b.on.join(','));
      return d != 0 ? d : a.off.join(',').compareTo(b.off.join(','));
    });

  final timers = <PlannedTimer>[];
  final ruleClauses = <String>[];
  for (var i = 0; i < events.length; i++) {
    final event = events[i];
    final index = i + 1;
    final mask = daysMask(event.days.toList()..sort());
    final direct = event.on.length + event.off.length == 1;
    late final TimerConfig config;
    if (direct) {
      final channel = event.on.isNotEmpty ? event.on.first : event.off.first;
      config = TimerConfig(
        enable: 1,
        mode: 0,
        time: toHhmm(event.time),
        window: 0,
        days: mask,
        repeat: 1,
        output: channel,
        action: event.on.isNotEmpty ? 1 : 0,
      );
    } else {
      config = TimerConfig(
        enable: 1,
        mode: 0,
        time: toHhmm(event.time),
        window: 0,
        days: mask,
        repeat: 1,
        output: 1,
        action: 3,
      );
      final commands = [
        for (final c in event.on) 'Power$c ON',
        for (final c in event.off) 'Power$c OFF',
      ];
      final body = commands.length == 1 ? commands.first : 'Backlog ${commands.join('; ')}';
      ruleClauses.add('ON Clock#Timer=$index DO $body ENDON');
    }
    timers.add(PlannedTimer(index: index, config: config, on: event.on, off: event.off));
  }

  final ruleText = ruleClauses.join(' ');
  if (ruleText.isNotEmpty && ruleText.length > kMaxRuleLength) {
    unsupportedReasons.add('Rule2 requires ${ruleText.length} chars ($kMaxRuleLength max)');
  }
  if (timers.length > kMaxTimers) {
    unsupportedReasons.add('Requires ${timers.length} timers ($kMaxTimers max)');
  }

  return CompiledPlan(
    timers: timers,
    ruleText: ruleText,
    requiredTimerCount: timers.length,
    conflicts: conflicts,
    unsupportedReasons: unsupportedReasons,
  );
}

class _MergedEvent {
  _MergedEvent(this.time, this.on, this.off);
  final int time;
  final List<int> on;
  final List<int> off;
  final Set<int> days = {};
}
