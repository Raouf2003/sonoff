import 'package:flutter_test/flutter_test.dart';
import 'package:stees_local/devices/device_profile.dart';

void main() {
  test('known ids resolve, unknown and null fall back to sonoff', () {
    expect(DeviceProfile.fromId('sonoff_4ch_pro_r3').displayName, 'Sonoff 4CH Pro R3');
    expect(DeviceProfile.fromId('lilygo_trelay_esp32').displayName, 'LilyGO T-Relay ESP32');
    expect(DeviceProfile.fromId('nope').id, DeviceProfile.defaultId);
    expect(DeviceProfile.fromId(null).id, DeviceProfile.defaultId);
  });

  test('sonoff keeps its template, lilygo ships pre-configured', () {
    expect(DeviceProfile.sonoff4chProR3.tasmotaTemplate, contains('"BASE":23'));
    expect(DeviceProfile.lilygoTRelayEsp32.tasmotaTemplate, isNull);
    expect(DeviceProfile.sonoff4chProR3.channelCount, 4);
    expect(DeviceProfile.lilygoTRelayEsp32.channelCount, 4);
  });
}
