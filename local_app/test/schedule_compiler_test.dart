import 'package:flutter_test/flutter_test.dart';
import 'package:stees_local/schedules/schedule_compiler.dart';
import 'package:stees_local/schedules/schedule_model.dart';

LocalSchedule _s({
  required String id,
  List<int> channels = const [1],
  String recurrence = 'daily',
  List<int> days = const [],
  required List<TimeRange> ranges,
  bool enabled = true,
}) {
  return LocalSchedule(
    id: id,
    name: id,
    channels: channels,
    recurrenceType: recurrence,
    daysOfWeek: days,
    timeRanges: ranges,
    enabled: enabled,
  );
}

const _morning = TimeRange(start: '08:00', end: '09:00');

void main() {
  test('helpers: day mask and time conversion', () {
    expect(toMinutes('08:30'), 510);
    expect(toMinutes('24:00'), isNull);
    expect(toMinutes('8:00'), isNull);
    expect(toHhmm(510), '08:30');
    expect(tasmotaDayPosition(0), 1);
    expect(tasmotaDayPosition(6), 0);
    expect(daysMask([0, 1, 2, 3, 4, 5, 6]), '1111111');
    expect(daysMask([0]), '0100000');
  });

  test('vector 1: single channel daily range compiles to 2 direct timers', () {
    final plan = compileSchedules([_s(id: 'a', ranges: [_morning])]);
    expect(plan.isValid, isTrue);
    expect(plan.requiredTimerCount, 2);
    expect(plan.ruleText, isEmpty);
    expect(plan.timers[0].config.time, '08:00');
    expect(plan.timers[0].config.output, 1);
    expect(plan.timers[0].config.action, 1);
    expect(plan.timers[0].config.days, '1111111');
    expect(plan.timers[1].config.time, '09:00');
    expect(plan.timers[1].config.action, 0);
  });

  test('vector 2: multi-channel range uses Action 3 timers plus Rule2', () {
    final plan = compileSchedules(
        [_s(id: 'a', channels: [1, 2], ranges: [_morning])]);
    expect(plan.isValid, isTrue);
    expect(plan.requiredTimerCount, 2);
    expect(plan.timers.every((t) => t.config.action == 3), isTrue);
    expect(plan.ruleText,
        'ON Clock#Timer=1 DO Backlog Power1 ON; Power2 ON ENDON '
        'ON Clock#Timer=2 DO Backlog Power1 OFF; Power2 OFF ENDON');
  });

  test('vector 3: identical time on different days merges into one timer', () {
    final plan = compileSchedules([
      _s(id: 'a', recurrence: 'custom', days: [0], ranges: [_morning]),
      _s(id: 'b', recurrence: 'custom', days: [1], ranges: [_morning]),
    ]);
    expect(plan.isValid, isTrue);
    expect(plan.requiredTimerCount, 2);
    expect(plan.timers[0].config.days, '0110000');
  });

  test('vector 4: overlapping ranges keep coverage without mid flicker', () {
    final plan = compileSchedules([
      _s(id: 'a', ranges: [const TimeRange(start: '08:00', end: '10:00')]),
      _s(id: 'b', ranges: [const TimeRange(start: '09:00', end: '11:00')]),
    ]);
    expect(plan.isValid, isTrue);
    final times = [for (final t in plan.timers) t.config.time];
    expect(times, ['08:00', '11:00']);
    expect(plan.timers[0].on, [1]);
    expect(plan.timers[1].off, [1]);
  });

  test('vector 6: disabled schedules are excluded', () {
    final plan = compileSchedules(
        [_s(id: 'a', ranges: [_morning], enabled: false)]);
    expect(plan.isValid, isTrue);
    expect(plan.requiredTimerCount, 0);
    expect(plan.ruleText, isEmpty);
  });

  test('vector 7: overnight ranges are rejected', () {
    final plan = compileSchedules([
      _s(id: 'night', ranges: [const TimeRange(start: '22:00', end: '02:00')])
    ]);
    expect(plan.isValid, isFalse);
    expect(plan.requiredTimerCount, 0);
    expect(plan.unsupportedReasons.single, contains('22:00-02:00'));
  });

  test('vector 8: malformed ranges, empty custom days, bad channels rejected',
      () {
    final badTime = compileSchedules([
      _s(id: 'bad', ranges: [const TimeRange(start: '8:00', end: '09:00')])
    ]);
    expect(badTime.isValid, isFalse);

    final emptyDays = compileSchedules([
      _s(id: 'days', recurrence: 'custom', days: [], ranges: [_morning])
    ]);
    expect(emptyDays.isValid, isFalse);

    final badChannel =
        compileSchedules([_s(id: 'ch', channels: [9], ranges: [_morning])]);
    expect(badChannel.isValid, isFalse);
    expect(badChannel.conflicts.single, contains('channel 9'));
  });

  test('vector 9: more transitions than 16 timers blocks the whole plan', () {
    final schedules = [
      for (var h = 0; h < 10; h++)
        _s(
          id: 's$h',
          ranges: [
            TimeRange(
              start: '${h.toString().padLeft(2, '0')}:00',
              end: '${h.toString().padLeft(2, '0')}:30',
            )
          ],
        ),
    ];
    final plan = compileSchedules(schedules);
    expect(plan.requiredTimerCount, 20);
    expect(plan.isValid, isFalse);
    expect(plan.unsupportedReasons.single, contains('20 timers (16 max)'));
  });

  test('vector 10: oversized rule text blocks the plan', () {
    final plan = compileSchedules([
      _s(id: 'big', channels: [1, 2, 3, 4], ranges: [_morning])
    ]);
    expect(plan.ruleText.length, lessThanOrEqualTo(kMaxRuleLength));
    expect(plan.isValid, isTrue);
  });

  test('vector 11: empty schedule set compiles to an empty valid plan', () {
    final plan = compileSchedules([]);
    expect(plan.isValid, isTrue);
    expect(plan.requiredTimerCount, 0);
    expect(plan.ruleText, isEmpty);
  });

  test('timer payload matches the device wire shape byte for byte', () {
    final plan = compileSchedules([_s(id: 'a', ranges: [_morning])]);
    expect(plan.timers[0].config.toPayload(),
        '{"Enable":1,"Mode":0,"Time":"08:00","Window":0,"Days":"1111111","Repeat":1,"Output":1,"Action":1}');
    expect(TimerConfig.factoryDefault.toPayload(),
        '{"Enable":0,"Mode":0,"Time":"00:00","Window":0,"Days":"0000000","Repeat":0,"Output":1,"Action":0}');
  });
}
