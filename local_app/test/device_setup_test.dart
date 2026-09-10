import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stees_local/devices/device_profile.dart';
import 'package:stees_local/devices/device_repository.dart';
import 'package:stees_local/devices/device_setup.dart';
import 'package:stees_local/transport/device_transport.dart';

const _deviceId = '34987AC30304';
const _macBody = '{"StatusNET":{"Mac":"34:98:7A:C3:03:04"}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('applies the 4CHPROR3 template then restarts', () async {
    final called = <String>[];
    Future<String> fetch(String address, String command,
        {String? password, String? deviceId, String? referer}) async {
      called.add(command);
      if (command == 'Status%205') return _macBody;
      if (command == 'State') return '{"POWER":"ON"}';
      return '{}';
    }

    final repo = LocalDeviceRepository(fetch: fetch);
    await applyFourChannelTemplate(repo, _deviceId);
    final templateCmd = called.firstWhere((c) => c.startsWith('Template%20'));
    expect(Uri.decodeComponent(templateCmd.substring('Template%20'.length)),
        DeviceProfile.sonoff4chProR3.tasmotaTemplate);
    expect(called.any((c) => c == 'Module%200'), isTrue);
    expect(called.any((c) => c == 'Restart%201'), isTrue);
    expect(called.indexOf('Restart%201') > called.indexOf('Module%200'), isTrue);
  });

  test('refuses template write on foreign identity', () async {
    Future<String> fetch(String address, String command,
        {String? password, String? deviceId, String? referer}) async {
      if (command == 'Status%205') {
        return '{"StatusNET":{"Mac":"AA:BB:CC:DD:EE:FF"}}';
      }
      return '{}';
    }
    final repo = LocalDeviceRepository(fetch: fetch);
    await expectLater(
      applyFourChannelTemplate(repo, _deviceId),
      throwsA(isA<DeviceTransportException>().having(
          (e) => e.kind, 'kind', TransportFailureKind.logical)),
    );
  });
}
