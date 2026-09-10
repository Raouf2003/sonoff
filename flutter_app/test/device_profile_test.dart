import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home_app/models/device_profile.dart';

void main() {
  test('sonoff keeps module 23, lilygo leaves the module untouched', () {
    expect(HardwareProfile.sonoff4chProR3.tasmotaModule, 23);
    expect(HardwareProfile.lilygoTRelayEsp32.tasmotaModule, isNull);
    expect(HardwareProfile.sonoff4chProR3.channelCount, 4);
    expect(HardwareProfile.lilygoTRelayEsp32.channelCount, 4);
  });

  test('fromId falls back to sonoff for unknown and null', () {
    expect(HardwareProfile.fromId('lilygo_trelay_esp32'),
        HardwareProfile.lilygoTRelayEsp32);
    expect(HardwareProfile.fromId('nope'), HardwareProfile.sonoff4chProR3);
    expect(HardwareProfile.fromId(null), HardwareProfile.sonoff4chProR3);
  });
}
