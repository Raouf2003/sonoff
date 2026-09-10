import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stees_local/app/home_screen.dart';
import 'package:stees_local/devices/device_repository.dart';
import 'package:stees_local/transport/clock_sync.dart';

const _deviceId = '34987AC30304';
const _macBody = '{"StatusNET":{"Mac":"34:98:7A:C3:03:04"}}';

class _FakeDevice {
  var power1 = 'OFF';

  Future<String> call(String address, String command,
      {String? password, String? deviceId, String? referer}) async {
    if (command == 'Status%205') return _macBody;
    if (command == 'State') return '{"POWER1":"$power1"}';
    if (command == 'Time') return '{"Time":"2026-01-01T00:00:00"}';
    throw StateError('unexpected $command');
  }
}

void main() {
  testWidgets('physical change appears without manual refresh', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    final device = _FakeDevice();
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          deviceId: _deviceId,
          deviceName: 'Test',
          repository: LocalDeviceRepository(fetch: device.call),
          clock: ClockSync(fetch: device.call),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    Switch s() => tester.widget<Switch>(find.byType(Switch).first);
    expect(s().value, isFalse);

    device.power1 = 'ON';
    await tester.pump(const Duration(seconds: 2));
    expect(s().value, isTrue);
  });
}
