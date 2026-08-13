import 'dart:async';
import 'dart:convert';
import 'package:bonsoir/bonsoir.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key prefix for the verified-IP cache. Public so the
/// [LocalDeviceCache] can also clear a removed device's IP locator.
const String kLocalVerifiedIpPrefix = 'stees.local.ip.';

/// Abstraction consumed by [DeviceRepositoryService] so the discovery ladder
/// (cache + mDNS) can be faked in unit tests without platform channels.
abstract class DeviceLocator {
  /// The IP cached for [deviceId] after a previous identity verification, or
  /// null when the device was never seen locally (or its cache was discarded).
  Future<String?> cachedAddress(String deviceId);

  /// When the cached IP was verified, or null when unknown/legacy. Used to skip
  /// re-verification of a still-fresh verified IP and avoid needless probes.
  Future<DateTime?> cachedVerifiedAt(String deviceId);

  /// Persists a verified IP. The repository only calls this AFTER the Tasmota
  /// reported a matching canonical MAC — the cache never bypasses verification.
  Future<void> storeVerifiedAddress(String deviceId, String ip);

  /// Persists an UNVERIFIED IP hint (e.g. the last IP the cloud backend learned
  /// from MQTT telemetry). Stored without a `verifiedAt`, so discovery still
  /// runs `Status 5` before trusting it. Skipped when the address is already
  /// known so an existing verified entry is never downgraded. A candidate that
  /// fails verification is kept (the box may be off) unless identity mismatch
  /// proves the address was repurposed.
  Future<void> storeCandidateAddress(String deviceId, String ip);

  /// Removes a cached IP (stale / repurposed / MAC mismatch).
  Future<void> discardAddress(String deviceId);

  /// Raw mDNS candidates (IPs advertising `_tasmota._tcp`), bounded by
  /// [timeout]. Candidates are NOT trusted independently — the repository must
  /// still verify each one's identity. Returns an empty list when nothing was
  /// found or the platform has no mDNS support.
  Future<List<String>> mDnsCandidates(Duration timeout);

  /// True when any candidates were service-resolved with addresses at all —
  /// lets the repository skip the verify loop when mDNS is unavailable.
}

/// Discovery ladder, fully user-invisible:
///
///   1. known verified IP cache (SharedPreferences)
///   2. mDNS `_tasmota._tcp` discovery (bonsoir)
///   3. nothing → local unavailable
///
/// There is NO manual IP entry, NO subnet scan and NO port scan. An IP is
/// purely a temporary locator; identity is always the canonical MAC, verified
/// with `Status 5` by the caller before any command or cache write.
class LocalDeviceDiscovery implements DeviceLocator {
  LocalDeviceDiscovery({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefs;

  String _key(String deviceId) => '$kLocalVerifiedIpPrefix$deviceId';

  // The cache value is either a JSON envelope {ip, verifiedAt} written by this
  // version, or a legacy bare IP string from before — both must resolve.
  @override
  Future<String?> cachedAddress(String deviceId) async {
    final prefs = await _prefs();
    final raw = prefs.getString(_key(deviceId));
    if (raw == null || raw.isEmpty) return null;
    final decoded = _decodeEntry(raw);
    return decoded?.ip ?? (raw.contains('{') ? null : raw);
  }

  @override
  Future<DateTime?> cachedVerifiedAt(String deviceId) async {
    final prefs = await _prefs();
    final raw = prefs.getString(_key(deviceId));
    if (raw == null || raw.isEmpty) return null;
    return _decodeEntry(raw)?.verifiedAt;
  }

  @override
  Future<void> storeVerifiedAddress(String deviceId, String ip) async {
    final prefs = await _prefs();
    await prefs.setString(
      _key(deviceId),
      '{"ip":${_json(ip)},"verifiedAt":${_json(DateTime.now().toIso8601String())}}',
    );
  }

  @override
  Future<void> storeCandidateAddress(String deviceId, String ip) async {
    if (ip.isEmpty) return;
    final prefs = await _prefs();
    final key = _key(deviceId);
    final raw = prefs.getString(key);
    if (raw != null && raw.isNotEmpty) {
      final existing = _decodeEntry(raw)?.ip ?? (raw.contains('{') ? null : raw);
      if (existing == ip) return; // already known (verified or candidate)
    }
    // verifiedAt:null marks this as a CLOUD-LEARNED HINT, never trusted until
    // `Status 5` confirms the MAC.
    await prefs.setString(key, '{"ip":${_json(ip)},"verifiedAt":null}');
  }

  @override
  Future<void> discardAddress(String deviceId) async {
    final prefs = await _prefs();
    await prefs.remove(_key(deviceId));
  }

  @override
  Future<List<String>> mDnsCandidates(Duration timeout) {
    return _browseTasmota(timeout);
  }
}

class _CachedEntry {
  final String ip;
  final DateTime? verifiedAt;
  const _CachedEntry(this.ip, {this.verifiedAt});
}

_CachedEntry? _decodeEntry(String raw) {
  if (!raw.contains('{')) return null;
  try {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final ip = map['ip'];
    if (ip is! String || ip.isEmpty) return null;
    final v = map['verifiedAt'];
    final verifiedAt = v is String ? DateTime.tryParse(v) : null;
    return _CachedEntry(ip, verifiedAt: verifiedAt);
  } catch (_) {
    return null;
  }
}

String _json(String value) {
  // Minimal JSON string escaping for the envelope; IPs/ISO timestamps are
  // safe in practice.
  return '"${value.replaceAll('"', '\\"')}"';
}

/// Bounded mDNS browse for Tasmota services (`_tasmota._tcp`). Collects
/// resolved host addresses until [timeout] elapses, then stops. Returns an
/// empty list on any platform failure so the caller never hangs.
Future<List<String>> _browseTasmota(Duration timeout) async {
  final addresses = <String>{};
  final discovery = BonsoirDiscovery(type: '_tasmota._tcp');
  final sub = discovery.eventStream?.listen((event) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent():
      case BonsoirDiscoveryServiceUpdatedEvent():
        // v7 broadcasts services before resolving them; ask for addresses.
        event.service?.resolve(discovery.serviceResolver);
      case BonsoirDiscoveryServiceResolvedEvent():
        addresses.addAll(event.service.hostAddresses);
      default:
        break;
    }
  });
  try {
    await discovery.initialize();
    await discovery.start();
    // The browse window bounds how long we LOOK for services; the extra grace
    // lets service RESOLUTIONS (which bonsoir delivers asynchronously after a
    // Found event) land before we stop, so a device found just before the
    // deadline still yields its IPs.
    await Future<void>.delayed(timeout + const Duration(milliseconds: 600));
    await discovery.stop();
    return addresses.toList();
  } catch (_) {
    return const [];
  } finally {
    await sub?.cancel();
    try {
      await discovery.stop();
    } catch (_) {}
  }
}