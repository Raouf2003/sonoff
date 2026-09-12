import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stees_local/devices/device_repository.dart';
import 'package:stees_local/transport/device_transport.dart';

const _deviceId = '34987AC30304';
const _macBody = '{"StatusNET":{"Mac":"34:98:7A:C3:03:04"}}';
const _otherMacBody = '{"StatusNET":{"Mac":"AA:BB:CC:DD:EE:FF"}}';

class _CmFake {
  _CmFake(this.responses);
  final Map<String, String> responses;
  final List<String> called = [];
  Object? error;

  Future<String> call(String address, String command,
      {String? password, String? deviceId, String? referer}) async {
    called.add('$address|$command');
    final err = error;
    if (err != null) throw err;
    final body = responses[command];
    if (body == null) throw const DeviceTransportException('HTTP 404');
    return body;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('status resolves the AP, verifies identity and persists the endpoint',
      () async {
    final cm = _CmFake({
      'Status%205': _macBody,
      'State': '{"POWER1":"ON","POWER4":"OFF"}',
    });
    final repo = LocalDeviceRepository(fetch: cm.call);
    final result = await repo.getStatus(_deviceId);
    expect(result.online, isTrue);
    expect(result.source, DeviceTransportSource.local);
    expect(result.channels[1]!.state, 'ON');
    expect(result.channels[4]!.state, 'OFF');
    expect(cm.called, ['192.168.4.1|Status%205', '192.168.4.1|State']);
    final again = LocalDeviceRepository(fetch: cm.call);
    await again.getStatus(_deviceId);
    expect(cm.called.where((c) => c.endsWith('|Status%205')).length, 2,
        reason: 'second repo reuses persisted endpoint, still verifies');
  });

  test('control confirms via read-back and maps UNCONFIRMED', () async {
    final cm = _CmFake({
      'Status%205': _macBody,
      'Power2%20ON': '{"POWER2":"ON"}',
      'State': '{"POWER2":"OFF"}',
    });
    final repo = LocalDeviceRepository(fetch: cm.call);
    await expectLater(
      repo.control(_deviceId, 2, 'ON'),
      throwsA(isA<DeviceTransportException>()
          .having((e) => e.code, 'code', 'UNCONFIRMED')),
    );
  });

  test('foreign MAC on the AP surfaces a logical error, never a command',
      () async {
    final cm = _CmFake({'Status%205': _otherMacBody});
    final repo = LocalDeviceRepository(fetch: cm.call);
    await expectLater(
      repo.control(_deviceId, 1, 'ON'),
      throwsA(isA<DeviceTransportException>().having(
          (e) => e.kind, 'kind', TransportFailureKind.logical)),
    );
    expect(cm.called.any((c) => c.contains('Power')), isFalse);
  });

  test('unreachable AP surfaces availability', () async {
    final cm = _CmFake({});
    final repo = LocalDeviceRepository(fetch: cm.call);
    await expectLater(
      repo.getStatus(_deviceId),
      throwsA(isA<DeviceTransportException>().having(
          (e) => e.kind, 'kind', TransportFailureKind.availability)),
    );
  });

  test('DHCP-learned IP from a State report is adopted', () async {
    final cm = _CmFake({
      'Status%205': _macBody,
      'State': '{"POWER1":"ON","IPAddress":"192.168.4.2"}',
    });
    final repo = LocalDeviceRepository(fetch: cm.call);
    await repo.getStatus(_deviceId);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('stees_local.endpoint.$_deviceId'),
        '192.168.4.2');
  });

  test('enableHttpApi bootstraps SO128 and verifies HTTP_API', () async {
    final cm = _CmFake({
      'SetOption128%201': '{"SetOption128":"1"}',
      'Status%205':
          '{"StatusNET":{"Mac":"34:98:7A:C3:03:04","HTTP_API":1}}',
    });
    final repo = LocalDeviceRepository(fetch: cm.call);
    await repo.enableHttpApi(_deviceId);
    expect(cm.called.first, '192.168.4.1|SetOption128%201');
  });
}
