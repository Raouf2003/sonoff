import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'api_service.dart';
import 'cloud_device_transport.dart';
import 'device_transport.dart';
import 'local_device_cache.dart';
import 'local_device_discovery.dart';
import 'local_device_transport.dart';

/// How long a single LOCAL attempt (cached-IP probe + possible quick mDNS
/// window + identity verify + command + read-back) may take before the
/// repository gives up and falls back to cloud. Warm taps are sub-second;
/// this is the worst case for a cold LAN so the user never waits 10-20s.
const Duration kLocalBudget = Duration(seconds: 6);

/// mDNS browse window for a TAP-time discovery (only used when no verified IP
/// is cached). Kept short so a first tap is still snappy.
const Duration kTapMdnWindow = Duration(seconds: 2);

/// mDNS browse window for BACKGROUND warm-up discovery (page load / resume /
/// reconnect / after provisioning).
const Duration kWarmMdnWindow = Duration(seconds: 5);

/// A verified IP is trusted without re-probing for this long. After the TTL it
/// is re-verified with `Status 5` before use (cheap, one LAN round trip).
const Duration kVerifiedIpTtl = Duration(minutes: 10);

/// A local device report stays "fresh" (and therefore beats a stale cloud
/// report) for this window after it was read.
const Duration kLocalReportHold = Duration(seconds: 60);

/// The single service the devices page uses for relay control and status.
///
/// The transport order is LOCAL-FIRST: whenever the phone can reach the device
/// on the LAN the device's own report (HTTP) is the closest source of truth,
/// and the cloud is the fallback/remote transport. The two are never combined
/// for one user action — either the local command confirms, or the cloud
/// command runs; never both.
///
/// Local logical rejections (identity mismatch, unconfirmed command) are NEVER
/// rerouted to the cloud: an identity violation is a security/ownership matter
/// and an unconfirmed command means the device was already contacted, so a
/// cloud resend would be a duplicate execution.
class DeviceRepositoryService {
  DeviceRepositoryService({
    CloudDeviceTransport? cloud,
    DeviceLocator? locator,
    TasmotaCmFetcher? fetch,
    LocalDeviceCache? cache,
  })  : _cloud = cloud ?? CloudDeviceTransport(),
        _locator = locator ?? LocalDeviceDiscovery(),
        _cache = cache ?? LocalDeviceCache(),
        // ignore: prefer_initializing_formals
        _fetch = fetch;

  final CloudDeviceTransport _cloud;
  final DeviceLocator _locator;
  final LocalDeviceCache _cache;
  final TasmotaCmFetcher? _fetch;

  DeviceTransportSource? _lastSource;

  /// Monotonic operation sequence, stamped at request START so a response that
  /// started earlier but lands later can be recognised and rejected.
  int _seq = 0;

  /// Warm in-memory verified endpoints (keyed by deviceId). Populated by
  /// background discovery so relay taps normally use an already-verified IP
  /// without waiting on mDNS.
  final Map<String, LocalDeviceTransport> _warmCache = {};
  final Map<String, DateTime> _warmVerifiedAt = {};

  /// In-flight discovery futures per deviceId: a background status poll and a
  /// relay tap targeting the same device share ONE bounded discovery window.
  final Map<String, Future<LocalDeviceTransport?>> _discoveryInFlight = {};

  /// Transport that produced the most recent successful result. `null` before
  /// the first result or when the last attempt failed everywhere.
  DeviceTransportSource? get lastSource => _lastSource;

  /// Background discovery warm-up for every registered device: cached verified
  /// IP first, then bounded mDNS, each endpoint MAC-verified before caching.
  /// Bounded, single-flight per device, and never blocks the UI.
  Future<void> warmUp(List<Map<String, dynamic>> devices) async {
    for (final d in devices) {
      final id = d['deviceId'];
      if (id is! String || id.isEmpty) continue;
      try {
        await _findLocal(id).timeout(kLocalBudget);
      } on Object catch (e) {
        _log('warm-up failed for $id (${_describe(e)})');
      }
    }
  }

  /// The registered device list, cloud-first with a local cache fallback
  /// (unchanged: the list itself remains cloud-authorised; Local Mode never
  /// invents devices). Also seeds the local discovery candidate list from each
  /// device's last-known LAN IP so a later offline session can find the device
  /// WITHOUT mDNS — identity is still verified with `Status 5` before use.
  Future<List<Map<String, dynamic>>> getDevices() async {
    try {
      final devices = await _cloud.getDevices();
      try {
        await _cache.replaceAll(devices);
      } on Object catch (e) {
        _log('cache refresh failed after cloud list fetch (${_describe(e)})');
      }
      await _seedCandidates(devices);
      _lastSource = DeviceTransportSource.cloud;
      _log('device list from cloud (${devices.length}) — cache refreshed');
      return devices;
    } on Object catch (e) {
      if (!isAvailabilityFailure(e)) rethrow;
      _log(
        'cloud unavailable for device list (${_describe(e)}) — '
        'serving local cache',
      );
      final cached = await _cache.cachedDevices();
      if (cached.isEmpty) {
        _log('cache empty — surfacing original cloud error');
        rethrow;
      }
      await _seedCandidates(cached);
      _lastSource = DeviceTransportSource.local;
      return cached;
    }
  }

  /// Best-effort, non-authoritative: persists each device's cloud-learned LAN
  /// IP as an UNVERIFIED discovery candidate. Never trusted until `Status 5`
  /// confirms the MAC, so it is safe to seed from the (untrusted) cloud. Any
  /// failure is swallowed — a seed is an optimization, never a blocker.
  Future<void> _seedCandidates(List<Map<String, dynamic>> devices) async {
    await Future.wait([
      for (final d in devices)
        _seedOneCandidate(d['deviceId'], d['lastIp']),
    ]);
  }

  Future<void> _seedOneCandidate(Object? id, Object? ip) async {
    if (id is! String || id.isEmpty || ip is! String || ip.isEmpty) return;
    if (InternetAddress.tryParse(ip) == null) return;
    try {
      await _locator
          .storeCandidateAddress(id, ip)
          .timeout(const Duration(seconds: 2));
      _log('seeded candidate IP for $id: $ip');
    } on Object catch (e) {
      _log('candidate seed failed for $id (${_describe(e)})');
    }
  }

  /// Status, LOCAL-FIRST: a live LAN read (the freshest possible report) wins
  /// whenever the device is reachable. When the LAN cannot be reached the
  /// cloud's status is used. A cloud report that says ONLINE is only accepted
  /// if it is fresh; a stale cloud answer never overwrites a fresh LAN read.
  Future<RelayStatusResult> getStatus(String deviceId) async {
    final seq = ++_seq;
    // LOCAL first.
    try {
      final local = await _localStatus(deviceId).timeout(kLocalBudget);
      _lastSource = DeviceTransportSource.local;
      _log('local status success for $deviceId');
      return parseRelayStatus(
        local,
        source: DeviceTransportSource.local,
        seq: seq,
      );
    } on Object catch (e) {
      if (e is DeviceTransportException &&
          e.kind == TransportFailureKind.logical) {
        rethrow; // identity violation — never fall back to the cloud for it.
      }
      _log('local status failed for $deviceId (${_describe(e)})');
    }

    // CLOUD fallback.
    try {
      final cloud = await _cloud.getStatus(deviceId);
      _lastSource = DeviceTransportSource.cloud;
      await _seedOneCandidate(deviceId, cloud['lastIp']);
      final result = parseRelayStatus(
        cloud,
        source: DeviceTransportSource.cloud,
        seq: ++_seq,
      );
      // The cloud answered and reports the device ONLINE: trust its (fresh)
      // reports. If it reports OFFLINE, the device may still be on the LAN —
      // probe local once more and prefer the live LAN report when it verifies.
      if (result.online) return result;
      try {
        final local = await _localStatus(deviceId).timeout(kLocalBudget);
        _lastSource = DeviceTransportSource.local;
        return parseRelayStatus(
          local,
          source: DeviceTransportSource.local,
          seq: ++_seq,
        );
      } on Object {
        // The LAN could not be reached either: the cloud's (offline) answer is
        // still valid truth, so keep it instead of turning a valid response
        // into an error.
        _log('cloud said offline and the LAN re-probe failed — keeping cloud truth');
        return result;
      }
    } on Object catch (e) {
      _log('cloud status failed for $deviceId (${_describe(e)})');
      rethrow;
    }
  }

  /// Relay command, LOCAL-FIRST. The command is NEVER sent through both
  /// transports: a local confirmation (device reported the requested state via
  /// HTTP read-back) wins; otherwise the cloud runs the command once.
  ///
  /// A local logical failure (identity mismatch / unconfirmed command) is
  /// rethrown, never rerouted to the cloud.
  Future<RelayStatusResult> control(
    String deviceId,
    int channel,
    String state,
  ) async {
    final seq = ++_seq;
    DeviceTransportException? localFailure;
    // LOCAL first.
    try {
      final local = await _localControl(deviceId, channel, state)
          .timeout(kLocalBudget);
      _lastSource = DeviceTransportSource.local;
      _log('local control success for $deviceId channel $channel');
      return parseRelayStatus(
        local,
        source: DeviceTransportSource.local,
        seq: seq,
      );
    } on Object catch (e) {
      if (e is DeviceTransportException &&
          e.kind == TransportFailureKind.logical) {
        _log('local control REJECTED for $deviceId (${_describe(e)})');
        rethrow;
      }
      localFailure = e is DeviceTransportException
          ? e
          : DeviceTransportException('Local control failed: $e');
      _log('local control failed for $deviceId (${_describe(localFailure)})');
    }

    // CLOUD fallback.
    try {
      final cloud = await _cloud.control(deviceId, channel, state);
      _lastSource = DeviceTransportSource.cloud;
      await _seedOneCandidate(deviceId, cloud['lastIp']);
      final result = parseRelayStatus(
        cloud,
        source: DeviceTransportSource.cloud,
        seq: ++_seq,
      );
      _log('cloud control success for $deviceId channel $channel');
      return result;
    } on Object catch (e) {
      if (e is ApiException && !isAvailabilityFailure(e)) rethrow;
      if (e is DeviceTransportException &&
          e.kind == TransportFailureKind.logical) {
        rethrow;
      }
      _log('cloud control failed for $deviceId (${_describe(e)})');
      // Local already failed (any success would have returned above), so both
      // transports are down: wrap the local failure so the UI gets one
      // human-readable availability error.
      throw DeviceTransportException(
        'The device could not be reached locally or via the cloud.',
        cause: localFailure,
      );
    }
  }

  Future<Map<String, dynamic>> _localStatus(String deviceId) async {
    final local = await _findLocal(deviceId, urgent: true);
    if (local == null) {
      throw const DeviceTransportException('No local device available.');
    }
    final result = await local.getStatus(deviceId);
    _maybeLearnIp(deviceId, local.address, result);
    return result;
  }

  Future<Map<String, dynamic>> _localControl(
    String deviceId,
    int channel,
    String state,
  ) async {
    final local = await _findLocal(deviceId, urgent: true);
    if (local == null) {
      throw const DeviceTransportException('No local device available.');
    }
    final result = await local.control(deviceId, channel, state);
    _maybeLearnIp(deviceId, local.address, result);
    return result;
  }

  /// The device's own report often carries its current LAN IP (`State` →
  /// `IPAddress`). When it differs from the endpoint we used, the DHCP lease
  /// probably changed: refresh the discovery cache so the next attempt goes
  /// straight to the current address. Best-effort and never blocking.
  void _maybeLearnIp(
    String deviceId,
    String currentAddress,
    Map<String, dynamic> result,
  ) {
    final ip = result['ipAddress'];
    if (ip is! String || ip.isEmpty || ip == currentAddress) return;
    if (InternetAddress.tryParse(ip) == null) return;
    unawaited(_learnIp(deviceId, ip));
  }

  Future<void> _learnIp(String deviceId, String ip) async {
    try {
      await _locator
          .storeVerifiedAddress(deviceId, ip)
          .timeout(const Duration(seconds: 2));
      _warmCache[deviceId] = _buildLocal(ip, deviceId);
      _warmVerifiedAt[deviceId] = DateTime.now();
      _log('learned device IP from local report: $ip');
    } on Object catch (e) {
      _log('IP learn failed for $deviceId (${_describe(e)})');
    }
  }

  /// Single-flight discovery per deviceId: concurrent callers (a status poll
  /// and a relay tap, or two status refreshes) await the SAME bounded
  /// discovery instead of each opening their own mDNS browser.
  Future<LocalDeviceTransport?> _findLocal(
    String deviceId, {
    bool urgent = false,
  }) {
    final existing = _discoveryInFlight[deviceId];
    if (existing != null) {
      _log('reusing in-flight discovery for $deviceId');
      return existing;
    }
    final future = _discoverLocal(deviceId, urgent: urgent).whenComplete(() {
      _discoveryInFlight.remove(deviceId);
    });
    _discoveryInFlight[deviceId] = future;
    return future;
  }

  /// Discovery ladder for a single device: warm in-memory endpoint, then the
  /// persisted verified-IP cache, then mDNS. Every accepted endpoint is
  /// identity-verified (`Status 5`, `normalizeMac == deviceId`) before it is
  /// used or cached; a stale/repurposed cached IP is discarded and re-found.
  Future<LocalDeviceTransport?> _discoverLocal(
    String deviceId, {
    bool urgent = false,
  }) async {
    final warm = _warmCache[deviceId];
    final warmAt = _warmVerifiedAt[deviceId];
    if (warm != null &&
        warmAt != null &&
        DateTime.now().difference(warmAt) < kVerifiedIpTtl) {
      _log('using warm verified endpoint for $deviceId');
      return warm;
    }

    final cached = await _locator.cachedAddress(deviceId);
    if (cached != null && cached.isNotEmpty) {
      final verifiedAt = await _locator.cachedVerifiedAt(deviceId);
      final isVerified = verifiedAt != null;
      final fresh = isVerified &&
          DateTime.now().difference(verifiedAt) < kVerifiedIpTtl;
      if (fresh) {
        final transport = _buildLocal(cached, deviceId);
        _warmCache[deviceId] = transport;
        _warmVerifiedAt[deviceId] = verifiedAt;
        _log('using fresh verified cached IP: $cached');
        return transport;
      }
      final transport = _buildLocal(cached, deviceId);
      switch (await transport.checkIdentity()) {
        case LocalIdentityCheck.verified:
          _warmCache[deviceId] = transport;
          _warmVerifiedAt[deviceId] = DateTime.now();
          await _locator.storeVerifiedAddress(deviceId, cached);
          _log('verified cached IP: $cached');
          return transport;
        case LocalIdentityCheck.mismatch:
          // The box at this address is NOT our device — the IP was repurposed.
          // Drop it so we never probe a stranger's box again.
          await _locator.discardAddress(deviceId);
          _log('cached IP identity mismatch — discarding $cached');
          break;
        case LocalIdentityCheck.unavailable:
          if (isVerified) {
            // A previously-confirmed address that no longer answers (box off /
            // network change): drop it rather than probe it forever.
            await _locator.discardAddress(deviceId);
            _log('verified cached IP unreachable — discarding $cached');
          } else {
            // A cloud-learned hint that is not reachable RIGHT NOW: keep it —
            // the box may be powered off or waking. mDNS still runs below.
            _log('candidate IP unreachable — keeping $cached as a hint');
          }
          break;
      }
    }

    final window = urgent ? kTapMdnWindow : kWarmMdnWindow;
    _log('starting mDNS discovery ($window)');
    final candidates = await _locator.mDnsCandidates(window);
    for (final ip in candidates) {
      _log('mDNS candidate: $ip — verifying MAC');
      final transport = _buildLocal(ip, deviceId);
      if (await transport.verifyIdentity()) {
        _log('verified local device: $ip');
        await _locator.storeVerifiedAddress(deviceId, ip);
        _warmCache[deviceId] = transport;
        _warmVerifiedAt[deviceId] = DateTime.now();
        return transport;
      }
      _log('mDNS candidate failed identity check — skipped');
    }

    _log('local discovery failed');
    return null;
  }

  /// Short, non-sensitive description of a failure for the debug trace. Never
  /// includes messages/bodies that could carry credentials. For local
  /// transport failures the original error's runtimeType is surfaced via the
  /// preserved `cause`, so logcat shows e.g. a SocketException instead of only
  /// the generic availability wrapper.
  String _describe(Object error) {
    if (error is ApiException) {
      return 'ApiException(status=${error.statusCode}, code=${error.code})';
    }
    if (error is DeviceTransportException) {
      final cause = error.cause;
      final message = error.message.isNotEmpty ? '"${error.message}"' : '-';
      return 'DeviceTransportException(kind=${error.kind}, code=${error.code}, '
          'message=$message'
          '${cause != null ? ', cause=${cause.runtimeType}' : ''})';
    }
    return error.runtimeType.toString();
  }

  void _log(String message) {
    debugPrint('[LOCAL] $message');
  }

  LocalDeviceTransport _buildLocal(String address, String deviceId) {
    return LocalDeviceTransport(
      address: address,
      deviceId: deviceId,
      fetcher: _fetch,
    );
  }
}
