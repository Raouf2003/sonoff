import 'dart:convert';
import '../transport/device_transport.dart';
import 'local_device_transport.dart';

enum ClockHealth { ok, needsSync, invalid }

class DeviceClock {
  const DeviceClock({required this.health, this.deviceTime, this.drift});
  final ClockHealth health;
  final DateTime? deviceTime;
  final Duration? drift;
}

class ClockSync {
  ClockSync({TasmotaCmFetcher? fetch}) : _fetch = fetch ?? defaultTasmotaCmFetcher;

  final TasmotaCmFetcher _fetch;

  static const Duration driftThreshold = Duration(seconds: 120);
  static const String algeriaTimezone = 'Timezone%20%2B1';
  static final DateTime _minValidTime = DateTime(2020, 1, 1);

  DateTime? parseDeviceTime(String body) {
    try {
      final decoded = jsonDecode(body.trim());
      if (decoded is Map) {
        final epoch = decoded['Epoch'];
        if (epoch is int && epoch > 0) {
          return DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
        }
        if (epoch is String) {
          final n = int.tryParse(epoch);
          if (n != null && n > 0) {
            return DateTime.fromMillisecondsSinceEpoch(n * 1000);
          }
        }
        final time = decoded['Time'];
        if (time is String) return DateTime.tryParse(time);
      }
    } catch (_) {}
    return null;
  }

  ClockHealth classify(DateTime? deviceTime, DateTime now) {
    if (deviceTime == null || deviceTime.isBefore(_minValidTime)) {
      return ClockHealth.invalid;
    }
    final drift = deviceTime.difference(now).abs();
    return drift <= driftThreshold ? ClockHealth.ok : ClockHealth.needsSync;
  }

  Future<DeviceClock> readClock(String address, {String? password}) async {
    final now = DateTime.now();
    try {
      final body = await _fetch(address, 'Time', password: password);
      final deviceTime = parseDeviceTime(body);
      final health = classify(deviceTime, now);
      final drift = deviceTime == null ? null : deviceTime.difference(now);
      return DeviceClock(health: health, deviceTime: deviceTime, drift: drift);
    } on DeviceTransportException {
      return const DeviceClock(health: ClockHealth.invalid);
    }
  }

  Future<DeviceClock> pushPhoneTime(String address, {String? password}) async {
    await _fetch(address, algeriaTimezone, password: password);
    final epoch = (DateTime.now().toUtc().millisecondsSinceEpoch / 1000).round();
    await _fetch(address, 'Time%20$epoch', password: password);
    final check = await readClock(address, password: password);
    if (check.health != ClockHealth.ok) {
      throw const DeviceTransportException(
        'The device clock could not be synchronized. Schedules stay paused.',
        kind: TransportFailureKind.logical,
      );
    }
    return check;
  }

  Future<DeviceClock> ensureSynced(String address, {String? password}) async {
    final current = await readClock(address, password: password);
    if (current.health == ClockHealth.ok) return current;
    return pushPhoneTime(address, password: password);
  }
}
