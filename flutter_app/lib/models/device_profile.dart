const String kSonoffProfileId = 'sonoff_4ch_pro_r3';
const String kLilygoProfileId = 'lilygo_trelay_esp32';

class HardwareProfile {
  const HardwareProfile({
    required this.id,
    required this.displayName,
    required this.channelCount,
    this.tasmotaModule,
  });

  final String id;
  final String displayName;
  final int channelCount;
  final int? tasmotaModule;

  static const HardwareProfile sonoff4chProR3 = HardwareProfile(
    id: kSonoffProfileId,
    displayName: 'Sonoff 4CH Pro R3',
    channelCount: 4,
    tasmotaModule: 23,
  );

  static const HardwareProfile lilygoTRelayEsp32 = HardwareProfile(
    id: kLilygoProfileId,
    displayName: 'LilyGO T-Relay ESP32',
    channelCount: 4,
    tasmotaModule: null,
  );

  static const List<HardwareProfile> values = [sonoff4chProR3, lilygoTRelayEsp32];

  static HardwareProfile fromId(String? id) {
    for (final profile in values) {
      if (profile.id == id) return profile;
    }
    return sonoff4chProR3;
  }
}
