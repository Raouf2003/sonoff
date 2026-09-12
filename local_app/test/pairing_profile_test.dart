import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stees_local/connection/pairing_store.dart';
import 'package:stees_local/devices/device_profile.dart';
import 'package:stees_local/devices/device_repository.dart';
import 'package:stees_local/devices/device_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
  });

  test('profile round-trips through the pairing store', () async {
    final store = PairingStore();
    expect((await store.deviceProfile()).id, DeviceProfile.defaultId);
    await store.savePairing(
      mac: 'AA',
      name: 'Test',
      profileId: DeviceProfile.lilygoTRelayEsp32.id,
    );
    expect((await store.deviceProfile()).displayName, 'LilyGO T-Relay ESP32');
  });

  test('legacy pairing without a profile defaults to sonoff', () async {
    final store = PairingStore();
    await store.savePairing(mac: 'AA', name: 'Test');
    expect((await store.deviceProfile()).id, 'sonoff_4ch_pro_r3');
  });

  test('lilygo profile never pushes a template', () async {
    var calls = 0;
    Future<String> fetch(String address, String command,
        {String? password, String? deviceId, String? referer}) async {
      calls++;
      return '{}';
    }
    final applied = await applyProfileTemplate(
      LocalDeviceRepository(fetch: fetch),
      'AA',
      DeviceProfile.lilygoTRelayEsp32,
    );
    expect(applied, isFalse);
    expect(calls, 0);
  });
}
