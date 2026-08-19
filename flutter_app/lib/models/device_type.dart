/// Physical kind of a Tasmota device — the single source of truth for how many
/// relays/channels a provisioned device controls. Selecting a type determines
/// the channel count stored on the Device, which every consumer (device
/// control, rules, schedules) reads back as `device['channels']`.
enum DeviceType { oneRelay, fourRelay }

extension DeviceTypeInfo on DeviceType {
  /// Number of relays this device type exposes.
  int get channelCount {
    switch (this) {
      case DeviceType.oneRelay:
        return 1;
      case DeviceType.fourRelay:
        return 4;
    }
  }

  /// 1-based channel indices STEES controls for this device type.
  List<int> get channels => [for (var i = 1; i <= channelCount; i++) i];

  /// Human-friendly label, e.g. "4 Relays".
  String get label {
    switch (this) {
      case DeviceType.oneRelay:
        return '1 Relay';
      case DeviceType.fourRelay:
        return '4 Relays';
    }
  }

  /// Tasmota built-in module number that maps the physical GPIO layout to
  /// exactly [channelCount] relays, written during provisioning so a stock
  /// Tasmota flash (which starts on a single-relay module) actually exposes all
  /// the relays the user asked for. `null` means "leave the factory module
  /// untouched" — a stock Tasmota already exposes one relay, but a "4 Relays"
  /// device must be pinned to the Sonoff 4CH Pro layout (module 23) or Tasmota
  /// would keep presenting a single channel even though the app stores 4.
  ///
  /// Module numbers + `Module`/`Status 0` read-back shapes verified against
  /// Tasmota 15.5.0 on the Sonoff 4CH Pro.
  int? get tasmotaModule {
    switch (this) {
      case DeviceType.oneRelay:
        return null;
      case DeviceType.fourRelay:
        return 23; // Sonoff 4CH Pro: relays on GPIO12/5/4/15, buttons + LED.
    }
  }
}