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
}