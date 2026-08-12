import 'dart:async';
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

  /// Persists a verified IP. The repository only calls this AFTER the Tasmota
  /// reported a matching canonical MAC — the cache never bypasses verification.
  Future<void> storeVerifiedAddress(String deviceId, String ip);

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

  @override
  Future<String?> cachedAddress(String deviceId) async {
    final prefs = await _prefs();
    return prefs.getString(_key(deviceId));
  }

  @override
  Future<void> storeVerifiedAddress(String deviceId, String ip) async {
    final prefs = await _prefs();
    await prefs.setString(_key(deviceId), ip);
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
    await Future<void>.delayed(timeout);
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