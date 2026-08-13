import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'local_device_discovery.dart' show kLocalVerifiedIpPrefix;

/// SharedPreferences key holding the cached, already-provisioned device list.
const String kLocalDevicesKey = 'stees.local.devices';

/// Local mirror of the user's registered devices — ONLY display metadata
/// (`deviceId`, `name`, `type`, `channels`). It is written exclusively by
/// cloud-verified flows:
///
///   * after a successful GET /api/devices [replaceAll]
///   * after a successful POST /api/devices/provision [upsert]
///   * removed after a successful unclaim/delete [remove] (device + IP locator)
///
/// It never contains credentials, JWTs or passwords, and Local Mode uses it ONLY
/// as the list of already-authorized devices to show/control when the cloud is
/// unavailable — it can never add, claim or unclaim a device by itself.
class LocalDeviceCache {
  LocalDeviceCache({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefs;

  /// The cached devices, normalized to display metadata only. Returns an empty
  /// list (never throws) when nothing is cached or the stored JSON is corrupt.
  Future<List<Map<String, dynamic>>> cachedDevices() async {
    final prefs = await _prefs();
    final raw = prefs.getString(kLocalDevicesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(_normalize)
          .whereType<Map<String, dynamic>>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Replaces the whole mirror after a successful cloud device list fetch.
  Future<void> replaceAll(List<Map<String, dynamic>> devices) async {
    final prefs = await _prefs();
    final normalized = devices
        .map(_normalize)
        .whereType<Map<String, dynamic>>()
        .toList();
    await prefs.setString(kLocalDevicesKey, jsonEncode(normalized));
  }

  /// Inserts or replaces a single device after a successful cloud provision.
  Future<void> upsert(Map<String, dynamic> device) async {
    final deviceId = device['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) return;
    final normalized = _normalize(device);
    if (normalized == null) return;
    final current = await cachedDevices();
    await replaceAll([
      for (final d in current)
        if (d['deviceId'] != deviceId) d,
      normalized,
    ]);
  }

  /// Removes a device from the mirror after a successful cloud unclaim/delete,
  /// and clears its verified-IP locator so it can never be targeted locally.
  Future<void> remove(String deviceId) async {
    if (deviceId.isEmpty) return;
    final current = await cachedDevices();
    await replaceAll([
      for (final d in current)
        if (d['deviceId'] != deviceId) d,
    ]);
    final prefs = await _prefs();
    await prefs.remove('$kLocalVerifiedIpPrefix$deviceId');
  }

  /// Keeps only the non-sensitive display fields the devices page reads back.
  /// Invalid entries (no usable deviceId) are dropped.
  Map<String, dynamic>? _normalize(Map<String, dynamic> raw) {
    final deviceId = raw['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) return null;
    return <String, dynamic>{
      'deviceId': deviceId,
      if (raw['name'] is String && (raw['name'] as String).isNotEmpty)
        'name': raw['name'] as String
      else
        'name': deviceId,
      if (raw['type'] is String && (raw['type'] as String).isNotEmpty)
        'type': raw['type'] as String
      else
        'type': 'sonoff-4ch',
      'channels': raw['channels'] is num
          ? (raw['channels'] as num).toInt()
          : 4,
      // Last known LAN IP (learned by the backend via MQTT telemetry). Kept so
      // an offline load can still seed the local discovery candidate list.
      if (raw['lastIp'] is String && (raw['lastIp'] as String).isNotEmpty)
        'lastIp': raw['lastIp'] as String,
    };
  }
}