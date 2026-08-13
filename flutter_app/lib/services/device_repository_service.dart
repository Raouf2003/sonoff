import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'api_service.dart';
import 'cloud_device_transport.dart';
import 'control_timeline.dart';
import 'device_transport.dart';
import 'local_device_cache.dart';
import 'local_device_discovery.dart';
import 'local_device_transport.dart';
import 'local_ip.dart';

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
/// Relay CONTROL is CLOUD-FIRST (the tap reaches MQTT immediately; the LAN is
/// the fallback when the cloud/backend is genuinely unavailable), while STATUS
/// reads remain LOCAL-FIRST (the device's own HTTP report is the freshest
/// truth). The two transports are never combined for one user action — the
/// first transport that succeeds wins, never both.
///
/// Logical rejections (identity mismatch, unconfirmed command) are NEVER
/// rerouted: an identity violation is a security/ownership matter and an
/// unconfirmed command means the device was already contacted, so a resend
/// would be a duplicate execution.
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
    if (!isValidLocalIp(ip)) {
      _log('rejected invalid candidate IP for $id: $ip');
      return;
    }
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

  /// Relay command, CLOUD-FIRST: a tap reaches the backend/MQTT immediately —
  /// local discovery is never started (nor awaited) before the command. The LAN
  /// is the fallback, used ONLY when the cloud/backend is genuinely unavailable
  /// (see [isAvailabilityFailure]). Every logical rejection — auth/ownership,
  /// validation, command conflicts, coded 409, MAC identity mismatches — is
  /// surfaced to the user and NEVER rerouted to the LAN.
  ///
  /// When [cloudDown] is true the order is inverted: the caller already knows
  /// the cloud is unreachable (e.g. the Socket.IO cloud monitor has confirmed a
  /// disconnect), so the LAN runs FIRST with the cloud as a safety fallback.
  /// [cloudDown] is only ever set from confirmed cloud-unreachability evidence,
  /// so normal cloud control is never delayed.
  ///
  /// The command is never sent through both transports for one tap: the first
  /// transport that succeeds wins.
  ///
  /// [opId] threads the per-tap correlation id into the [ControlTimeline].
  Future<RelayStatusResult> control(
    String deviceId,
    int channel,
    String state, {
    String? opId,
    bool cloudDown = false,
  }) async {
    _tl(opId, deviceId, channel, 'Repository control entered');
    final seq = ++_seq;
    DeviceTransportException? localFailure;

    // LOCAL immediately when the cloud is already known unreachable. The
    // caller does not wait for a cloud timeout before the LAN gets its chance.
    if (cloudDown) {
      try {
        _tl(opId, deviceId, channel, 'Local attempt start');
        final local = await _localControl(deviceId, channel, state, opId: opId)
            .timeout(kLocalBudget);
        _tl(opId, deviceId, channel, 'Local attempt done');
        _lastSource = DeviceTransportSource.local;
        _log('local control success for $deviceId channel $channel');
        return parseRelayStatus(
          local,
          source: DeviceTransportSource.local,
          seq: ++_seq,
        );
      } on Object catch (e) {
        if (e is DeviceTransportException &&
            e.kind == TransportFailureKind.logical) {
          _tl(opId, deviceId, channel, 'Local attempt rejected');
          _log('local control REJECTED for $deviceId (${_describe(e)})');
          rethrow;
        }
        localFailure = e is DeviceTransportException
            ? e
            : DeviceTransportException('Local control failed: $e');
        _tl(opId, deviceId, channel, 'Local attempt failed');
        _log('local control failed for $deviceId (${_describe(localFailure)})');
      }
    }

    // CLOUD first (normal), or the safety fallback after a cloudDown LAN miss.
    try {
      _tl(opId, deviceId, channel, 'Cloud request start');
      final cloud = await _cloud.control(deviceId, channel, state, opId: opId);
      _tl(opId, deviceId, channel, 'Cloud response received');
      _lastSource = DeviceTransportSource.cloud;
      await _seedOneCandidate(deviceId, cloud['lastIp']);
      final result = parseRelayStatus(
        cloud,
        source: DeviceTransportSource.cloud,
        seq: seq,
      );
      _log('cloud control success for $deviceId channel $channel');
      return result;
    } on Object catch (e) {
      // A logical rejection (ownership/validation/conflict, coded 409, MAC
      // identity) must surface to the user — never fall back to the LAN.
      if (e is ApiException && !isAvailabilityFailure(e)) {
        _tl(opId, deviceId, channel, 'Cloud request rejected');
        _log('cloud control REJECTED for $deviceId (${_describe(e)})');
        rethrow;
      }
      if (e is DeviceTransportException &&
          e.kind == TransportFailureKind.logical) {
        _tl(opId, deviceId, channel, 'Cloud request rejected');
        _log('cloud control REJECTED for $deviceId (${_describe(e)})');
        rethrow;
      }
      _tl(opId, deviceId, channel, 'Cloud request failed (availability)');
      _log('cloud control unavailable for $deviceId (${_describe(e)})');
    }

    // LOCAL fallback (cloud/backend genuinely unavailable). Skipped when the
    // LAN already had its chance above (cloudDown) so the cloud is not chased
    // by a second redundant local attempt.
    if (!cloudDown) {
      try {
        final local = await _localControl(deviceId, channel, state, opId: opId)
            .timeout(kLocalBudget);
        _tl(opId, deviceId, channel, 'Local attempt done');
        _lastSource = DeviceTransportSource.local;
        _log('local control success for $deviceId channel $channel');
        return parseRelayStatus(
          local,
          source: DeviceTransportSource.local,
          seq: ++_seq,
        );
      } on Object catch (e) {
        if (e is DeviceTransportException &&
            e.kind == TransportFailureKind.logical) {
          _tl(opId, deviceId, channel, 'Local attempt rejected');
          _log('local control REJECTED for $deviceId (${_describe(e)})');
          rethrow;
        }
        localFailure = e is DeviceTransportException
            ? e
            : DeviceTransportException('Local control failed: $e');
        _tl(opId, deviceId, channel, 'Local attempt failed');
        _log('local control failed for $deviceId (${_describe(localFailure)})');
      }
    }

    // Cloud and LAN both down: one human-readable availability error, keeping
    // the last transport's underlying failure as the cause for diagnostics.
    throw DeviceTransportException(
      'The device could not be reached locally or via the cloud.',
      cause: localFailure,
    );
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
    String state, {
    String? opId,
  }) async {
    final local = await _findLocal(deviceId, urgent: true, opId: opId, channel: channel);
    if (local == null) {
      throw const DeviceTransportException('No local device available.');
    }
    final result = await local.control(deviceId, channel, state, opId: opId);
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
    if (!isValidLocalIp(ip)) {
      _log('rejected invalid candidate IP for $deviceId: $ip');
      return;
    }
    unawaited(_learnIp(deviceId, ip));
  }

  Future<void> _learnIp(String deviceId, String ip) async {
    if (!isValidLocalIp(ip)) {
      _log('rejected invalid candidate IP for $deviceId: $ip');
      return;
    }
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
    String? opId,
    int channel = 0,
  }) {
    final existing = _discoveryInFlight[deviceId];
    if (existing != null) {
      _log('reusing in-flight discovery for $deviceId');
      return existing;
    }
    final future =
        _discoverLocal(deviceId, urgent: urgent, opId: opId, channel: channel)
            .whenComplete(() {
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
    String? opId,
    int channel = 0,
  }) async {
    final warm = _warmCache[deviceId];
    final warmAt = _warmVerifiedAt[deviceId];
    if (warm != null &&
        warmAt != null &&
        DateTime.now().difference(warmAt) < kVerifiedIpTtl) {
      // Defense in depth: never return (or even log "using warm verified
      // endpoint" for) an unusable address, even one cached before validation.
      if (!isUsableHttpHost(warm.address)) {
        _warmCache.remove(deviceId);
        _warmVerifiedAt.remove(deviceId);
        _log(
          'removed invalid cached endpoint (warm) for $deviceId: '
          '${warm.address}',
        );
      } else {
        _tl(opId, deviceId, channel, 'Warm endpoint used');
        _log('using warm verified endpoint for $deviceId');
        return warm;
      }
    }

    _tl(opId, deviceId, channel, 'Cached IP probe start');
    final cached = await _locator.cachedAddress(deviceId);
    if (cached != null && cached.isNotEmpty) {
      // The locator self-heals invalid entries on read, but never trust any
      // locator blindly: an unusable address must not reach a transport.
      if (!isUsableHttpHost(cached)) {
        _tl(opId, deviceId, channel, 'Cached IP probe result: invalid');
        _log('removed invalid cached endpoint for $deviceId: $cached');
        await _locator.discardAddress(deviceId);
      } else {
        final verifiedAt = await _locator.cachedVerifiedAt(deviceId);
        final isVerified = verifiedAt != null;
        final fresh = isVerified &&
            DateTime.now().difference(verifiedAt) < kVerifiedIpTtl;
        if (fresh) {
          _tl(opId, deviceId, channel, 'Cached IP probe result: fresh-verified');
          final transport = _buildLocal(cached, deviceId);
          _warmCache[deviceId] = transport;
          _warmVerifiedAt[deviceId] = verifiedAt;
          _log('using fresh verified cached IP: $cached');
          return transport;
        }
        final transport = _buildLocal(cached, deviceId);
        switch (await transport.checkIdentity()) {
          case LocalIdentityCheck.verified:
            _tl(opId, deviceId, channel, 'Cached IP probe result: verified');
            _warmCache[deviceId] = transport;
            _warmVerifiedAt[deviceId] = DateTime.now();
            await _locator.storeVerifiedAddress(deviceId, cached);
            _log('verified cached IP: $cached');
            return transport;
          case LocalIdentityCheck.mismatch:
            // The box at this address is NOT our device — the IP was repurposed.
            // Drop it so we never probe a stranger's box again.
            await _locator.discardAddress(deviceId);
            _tl(opId, deviceId, channel, 'Cached IP probe result: mismatch');
            _log('cached IP identity mismatch — discarding $cached');
            break;
          case LocalIdentityCheck.unavailable:
            if (isVerified) {
              // A previously-confirmed address that no longer answers (box off /
              // network change): drop it rather than probe it forever.
              await _locator.discardAddress(deviceId);
              _tl(opId, deviceId, channel, 'Cached IP probe result: unreachable-discard');
              _log('verified cached IP unreachable — discarding $cached');
            } else {
              // A cloud-learned hint that is not reachable RIGHT NOW: keep it —
              // the box may be powered off or waking. mDNS still runs below.
              _tl(opId, deviceId, channel, 'Cached IP probe result: unreachable-kept');
              _log('candidate IP unreachable — keeping $cached as a hint');
            }
            break;
        }
      }
    } else {
      _tl(opId, deviceId, channel, 'Cached IP probe result: none');
    }

    final window = urgent ? kTapMdnWindow : kWarmMdnWindow;
    _tl(opId, deviceId, channel, 'mDNS start');
    _log('starting mDNS discovery ($window)');
    final candidates = await _locator.mDnsCandidates(window);
    _tl(opId, deviceId, channel, 'mDNS finished');
    for (final ip in candidates) {
      _log('mDNS candidate: $ip — verifying MAC');
      final transport = _buildLocal(ip, deviceId);
      if (await transport.verifyIdentity()) {
        _log('verified local device: $ip');
        await _locator.storeVerifiedAddress(deviceId, ip);
        _warmCache[deviceId] = transport;
        _warmVerifiedAt[deviceId] = DateTime.now();
        _tl(opId, deviceId, channel, 'mDNS verified');
        return transport;
      }
      _log('mDNS candidate failed identity check — skipped');
    }

    _tl(opId, deviceId, channel, 'Local discovery failed');
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

  /// No-op when [opId] is null (status polls, non-command flows).
  void _tl(String? opId, String deviceId, int channel, String label) {
    if (opId == null) return;
    ControlTimeline.mark(opId, deviceId, channel, label);
  }

  LocalDeviceTransport _buildLocal(String address, String deviceId) {
    return LocalDeviceTransport(
      address: address,
      deviceId: deviceId,
      fetcher: _fetch,
    );
  }
}
