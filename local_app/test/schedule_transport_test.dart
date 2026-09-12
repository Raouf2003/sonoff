import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:stees_local/schedules/schedule_compiler.dart';
import 'package:stees_local/schedules/schedule_model.dart';
import 'package:stees_local/schedules/schedule_transport.dart';

const _defaultTimer = {
  'Enable': 0,
  'Mode': 0,
  'Time': '00:00',
  'Window': 0,
  'Days': '0000000',
  'Repeat': 0,
  'Output': 1,
  'Action': 0,
};

class _FakeTasmota {
  _FakeTasmota() {
    for (var i = 1; i <= 16; i++) {
      timers[i] = Map<String, dynamic>.from(_defaultTimer);
    }
  }
  final Map<int, Map<String, dynamic>> timers = {};
  String rule2 = '';
  bool rule2On = false;
  final List<String> written = [];

  Future<String> call(String address, String command,
      {String? password, String? deviceId, String? referer}) async {
    final space = command.indexOf('%20');
    final head = space < 0 ? command : command.substring(0, space);
    final arg = space < 0 ? '' : Uri.decodeComponent(command.substring(space + 3));
    if (head == 'Timers') return '{"Timers":"ON"}';
    if (head == 'Rule2') {
      if (arg.isEmpty) {
        return '{"Rule2":{"State":"${rule2On ? 'ON' : 'OFF'}","Rules":"$rule2"}}';
      }
      written.add('Rule2');
      if (arg == '0') {
        rule2 = '';
        rule2On = false;
      } else if (arg == '1') {
        rule2On = true;
      } else {
        rule2 = arg;
      }
      return '{"Rule2":{"State":"${rule2On ? 'ON' : 'OFF'}","Rules":"$rule2"}}';
    }
    final m = RegExp(r'^Timer(\d+)$').firstMatch(head);
    if (m != null) {
      final i = int.parse(m.group(1)!);
      if (arg.isEmpty) return jsonEncode({'Timer$i': timers[i]});
      written.add('Timer$i');
      timers[i] = (jsonDecode(arg) as Map).cast<String, dynamic>();
      return jsonEncode({'Timer$i': timers[i]});
    }
    throw StateError('unexpected $command');
  }

  int nonDefaultCount() =>
      timers.values.where((t) => t['Enable'] == 1).length;
}

LocalSchedule _s(String id, String start, String end,
    {List<int> channels = const [1]}) {
  return LocalSchedule(
    id: id,
    name: id,
    channels: channels,
    recurrenceType: 'daily',
    timeRanges: [TimeRange(start: start, end: end)],
  );
}

void main() {
  test('full sync writes timers plus Rule2 then verifies', () async {
    final device = _FakeTasmota();
    final transport = ScheduleTransport(fetch: device.call);
    final plan = compileSchedules(
        [_s('a', '08:00', '09:00', channels: [1, 2])]);
    expect(plan.isValid, isTrue);
    await transport.applyPlan('192.168.4.1', plan);
    expect(device.nonDefaultCount(), 2);
    expect(device.rule2, contains('Clock#Timer=1'));
    expect(device.rule2On, isTrue);
  });

  test('second identical sync writes nothing', () async {
    final device = _FakeTasmota();
    final transport = ScheduleTransport(fetch: device.call);
    final plan = compileSchedules([_s('a', '08:00', '09:00')]);
    await transport.applyPlan('192.168.4.1', plan,
        managedSlots: const {}, ruleManaged: false);
    device.written.clear();
    await transport.applyPlan('192.168.4.1', plan,
        managedSlots: const {1, 2}, ruleManaged: true);
    expect(device.written, isEmpty);
  });

  test('foreign timer aborts before any write', () async {
    final device = _FakeTasmota();
    device.timers[5] = {
      ..._defaultTimer,
      'Enable': 1,
      'Time': '06:00',
      'Days': '1111111',
      'Repeat': 1,
      'Output': 3,
      'Action': 1,
    };
    final transport = ScheduleTransport(fetch: device.call);
    final plan = compileSchedules([_s('a', '08:00', '09:00')]);
    await expectLater(
      transport.applyPlan('192.168.4.1', plan),
      throwsA(isA<ScheduleSyncException>().having(
          (e) => e.message, 'message', contains('Timer5'))),
    );
    expect(device.written, isEmpty);
  });

  test('foreign Rule2 aborts before any write', () async {
    final device = _FakeTasmota();
    device.rule2 = 'ON Switch1#State DO Power1 2 ENDON';
    device.rule2On = true;
    final transport = ScheduleTransport(fetch: device.call);
    final plan = compileSchedules([_s('a', '08:00', '09:00')]);
    await expectLater(
      transport.applyPlan('192.168.4.1', plan,
          managedSlots: const {1, 2}),
      throwsA(isA<ScheduleSyncException>().having(
          (e) => e.message, 'message', contains('Rule2'))),
    );
    expect(device.written, isEmpty);
  });

  test('invalid plan never touches the device', () async {
    final device = _FakeTasmota();
    final transport = ScheduleTransport(fetch: device.call);
    final plan = compileSchedules([
      _s('night', '22:00', '02:00'),
    ]);
    expect(plan.isValid, isFalse);
    await expectLater(
      transport.applyPlan('192.168.4.1', plan),
      throwsA(isA<ScheduleSyncException>()),
    );
    expect(device.written, isEmpty);
    expect(device.nonDefaultCount(), 0);
  });

  test('shrinking plan clears owned slots back to default', () async {
    final device = _FakeTasmota();
    final transport = ScheduleTransport(fetch: device.call);
    final big = compileSchedules([_s('a', '08:00', '09:00')]);
    await transport.applyPlan('192.168.4.1', big);
    device.written.clear();
    final small = compileSchedules([]);
    await transport.applyPlan('192.168.4.1', small,
        managedSlots: const {1, 2}, ruleManaged: false);
    expect(device.nonDefaultCount(), 0);
  });
}
