import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';
import 'local_device_discovery.dart' show kLocalVerifiedIpPrefix;
import 'local_ip.dart';
import 'provisioning_service.dart' show normalizeMac;
import 'provisioning_service.dart';

/// SharedPreferences key holding the cached, already-provisioned device list.
const String kLocalDevicesKey = 'stees.local.devices';

/// SharedPreferences key holding the ACCOUNT-SCOPED snapshot of the
/// authenticated user's registered canonical MACs, captured from a successful
/// `GET /api/devices` (see [LocalDeviceCache.saveAccountSnapshot]). Unlike the
/// display mirror ([kLocalDevicesKey]), this snapshot deliberately stores ONLY
/// canonical MAC identities, so it can certify a duplicate fully offline at the
/// provisioning boundary — even across Close/reopen, wizard recreation, app
/// restart, and claims made from another client that never populated this
/// phone's display cache.
const String kAccountSnapshotKey = 'stees.account.snapshot';

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
  LocalDeviceCache({
    Future<SharedPreferences> Function()? prefs,
    String? accountScope,
  })  : _prefs = prefs ?? SharedPreferences.getInstance,
        _accountScopeOverride = accountScope;

  final Future<SharedPreferences> Function() _prefs;

  /// Test-only scope override. When null the scope is resolved from the
  /// authenticated session (username) with a `default` fallback; this lets
  /// tests simulate multiple accounts without a live secure-storage channel.
  final String? _accountScopeOverride;

  static const String _defaultScope = 'default';

  /// The scope the persisted account snapshot is stored under: the authenticated
  /// username when available (never shares storage with another user), otherwise
  /// a `default` fallback. Never throws — a secure-storage failure is treated as
  /// the fallback scope, not an error.
  Future<String> resolveAccountScope() async {
    final override = _accountScopeOverride;
    if (override != null) return override;
    try {
      final username = await AuthService().getUsername();
      if (username != null && username.isNotEmpty) return username;
    } catch (_) {}
    return _defaultScope;
  }

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

  /// Persists the account-wide set of registered canonical MAC identities from
  /// a successful `GET /api/devices`. Replaces any previous snapshot for the
  /// current account scope. Only canonical MACs are stored — unparseable or
  /// legacy (non-MAC) IDs are skipped and can never be treated as registered.
  /// Writing an empty list is a valid snapshot (the account held no devices at
  /// refresh time).
  Future<void> saveAccountSnapshot(List<Map<String, dynamic>> devices) async {
    final scope = await resolveAccountScope();
    final macs = <String>{};
    for (final device in devices) {
      final id = device['deviceId'];
      if (id is! String) continue;
      final canonical = normalizeMac(id);
      if (canonical != null) macs.add(canonical);
    }
    final prefs = await _prefs();
    await prefs.setString(
      kAccountSnapshotKey,
      jsonEncode({
        'scope': scope,
        'macs': macs.toList()..sort(),
      }),
    );
  }

  /// The persisted canonical MAC set for the CURRENT account scope. Returns
  /// `null` when no snapshot exists yet (or the stored snapshot belongs to a
  /// different user, or the stored JSON is corrupt) — never guessed or reused
  /// from another account. An empty set means a valid snapshot was refreshed
  /// and the account held no devices at that time.
  Future<Set<String>?> loadAccountSnapshotMacs() async {
    final scope = await resolveAccountScope();
    final prefs = await _prefs();
    final raw = prefs.getString(kAccountSnapshotKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['scope'] != scope) return null;
      final macs = decoded['macs'];
      if (macs is! List) return const <String>{};
      final normalized = <String>{};
      for (final entry in macs) {
        if (entry is! String) continue;
        final canonical = normalizeMac(entry);
        if (canonical != null) normalized.add(canonical);
      }
      return normalized;
    } catch (_) {
      return null;
    }
  }

  /// Adds a newly claimed device's canonical MAC to the persisted account
  /// snapshot (new-device path). Never drops the other MACs already in the set.
  Future<void> upsertAccountSnapshot(String deviceId) async {
    final canonical = normalizeMac(deviceId);
    if (canonical == null) return;
    final current = await loadAccountSnapshotMacs() ?? <String>{};
    final updated = {...current, canonical};
    final scope = await resolveAccountScope();
    final prefs = await _prefs();
    await prefs.setString(
      kAccountSnapshotKey,
      jsonEncode({
        'scope': scope,
        'macs': updated.toList()..sort(),
      }),
    );
  }

  /// Removes a device's canonical MAC from the persisted account snapshot after
  /// a successful delete/unclaim, so a later re-claim is correctly treated as a
  /// new device. The snapshot itself is kept (with the remaining MACs) so
  /// offline knowledge about every other device survives.
  Future<void> removeFromAccountSnapshot(String deviceId) async {
    final canonical = normalizeMac(deviceId);
    if (canonical == null) return;
    final current = await loadAccountSnapshotMacs();
    if (current == null) return;
    final updated = {...current}..remove(canonical);
    final scope = await resolveAccountScope();
    final prefs = await _prefs();
    await prefs.setString(
      kAccountSnapshotKey,
      jsonEncode({
        'scope': scope,
        'macs': updated.toList()..sort(),
      }),
    );
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
      // Only a VALID address is kept: a transient `0.0.0.0` (or any other
      // unusable address) is dropped here, self-healing legacy cached lists.
      if (raw['lastIp'] is String && isValidLocalIp(raw['lastIp'] as String))
        'lastIp': raw['lastIp'] as String,
    };
  }
}