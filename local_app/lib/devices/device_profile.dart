class DeviceProfile {
  const DeviceProfile({
    required this.id,
    required this.displayName,
    required this.channelCount,
    this.tasmotaTemplate,
  });

  final String id;
  final String displayName;
  final int channelCount;
  final String? tasmotaTemplate;

  static const DeviceProfile sonoff4chProR3 = DeviceProfile(
    id: 'sonoff_4ch_pro_r3',
    displayName: 'Sonoff 4CH Pro R3',
    channelCount: 4,
    tasmotaTemplate:
        '{"NAME":"Sonoff 4CHPROR3","GPIO":[17,255,255,255,23,22,18,19,21,56,20,24,0],"FLAG":0,"BASE":23}',
  );

  static const DeviceProfile lilygoTRelayEsp32 = DeviceProfile(
    id: 'lilygo_trelay_esp32',
    displayName: 'LilyGO T-Relay ESP32',
    channelCount: 4,
    tasmotaTemplate: null,
  );

  static const List<DeviceProfile> values = [sonoff4chProR3, lilygoTRelayEsp32];

  static const String defaultId = 'sonoff_4ch_pro_r3';

  static DeviceProfile fromId(String? id) {
    for (final profile in values) {
      if (profile.id == id) return profile;
    }
    return sonoff4chProR3;
  }
}
