import 'package:flutter_test/flutter_test.dart';
import 'package:stees_local/transport/clock_sync.dart';
import 'package:stees_local/transport/device_transport.dart';

class _CmFake {
  _CmFake(this.handler);
  Future<String> Function(String address, String command) handler;
  final List<String> called = [];

  Future<String> call(String address, String command,
      {String? password, String? deviceId, String? referer}) async {
    called.add(command);
    return handler(address, command);
  }
}

String _iso(DateTime t) {
  String p(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${p(t.month)}-${p(t.day)}T${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
}

void main() {
  test('parseDeviceTime reads ISO wall time and Epoch', () {
    final sync = ClockSync(fetch: _CmFake((_, __) async => '').call);
    expect(sync.parseDeviceTime('{"Time":"2026-09-07T19:00:00"}'),
        DateTime(2026, 9, 7, 19, 0, 0));
    final epoch = DateTime(2026, 9, 7, 19, 0, 0).millisecondsSinceEpoch ~/ 1000;
    expect(
        sync.parseDeviceTime('{"Time":"2026-09-07T19:00:00","Epoch":$epoch}'),
        DateTime.fromMillisecondsSinceEpoch(epoch * 1000));
    expect(sync.parseDeviceTime('not json'), isNull);
    expect(sync.parseDeviceTime(''), isNull);
  });

  test('classify: ok within 120s, needsSync beyond, invalid when ancient', () {
    final sync = ClockSync(fetch: _CmFake((_, __) async => '').call);
    final now = DateTime.now();
    expect(sync.classify(now, now), ClockHealth.ok);
    expect(sync.classify(now.subtract(const Duration(seconds: 119)), now),
        ClockHealth.ok);
    expect(sync.classify(now.subtract(const Duration(seconds: 121)), now),
        ClockHealth.needsSync);
    expect(sync.classify(DateTime(1970, 1, 1), now), ClockHealth.invalid);
    expect(sync.classify(null, now), ClockHealth.invalid);
  });

  test('ensureSynced leaves a healthy clock untouched', () async {
    final cm = _CmFake((_, command) async {
      if (command == 'Time') return '{"Time":"${_iso(DateTime.now())}"}';
      throw const DeviceTransportException('unexpected write');
    });
    final sync = ClockSync(fetch: cm.call);
    final clock = await sync.ensureSynced('192.168.4.1');
    expect(clock.health, ClockHealth.ok);
    expect(cm.called, ['Time']);
  });

  test('ensureSynced pushes timezone then epoch when drifted', () async {
    var pushed = false;
    final cm = _CmFake((_, command) async {
      if (command == 'Time') {
        return pushed
            ? '{"Time":"${_iso(DateTime.now())}"}'
            : '{"Time":"2020-01-01T00:00:00"}';
      }
      if (command.startsWith('Timezone')) return '{"Timezone":"+1"}';
      if (command.startsWith('Time%20')) {
        pushed = true;
        return '{"Time":"${_iso(DateTime.now())}"}';
      }
      throw DeviceTransportException('unexpected $command');
    });
    final sync = ClockSync(fetch: cm.call);
    final clock = await sync.ensureSynced('192.168.4.1');
    expect(clock.health, ClockHealth.ok);
    expect(cm.called.any((c) => c.startsWith('Timezone')), isTrue);
    expect(cm.called.any((c) => c.startsWith('Time%20')), isTrue);
  });

  test('unreachable device reads as invalid', () async {
    final cm = _CmFake((_, __) async {
      throw const DeviceTransportException('down');
    });
    final sync = ClockSync(fetch: cm.call);
    expect((await sync.readClock('192.168.4.1')).health, ClockHealth.invalid);
  });
}
