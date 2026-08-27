import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'api_service.dart';
import 'channel_state_machine.dart';
import 'cloud_device_transport.dart';
import 'control_timeline.dart';
import 'device_transport.dart';
import 'local_device_cache.dart';
import 'local_device_discovery.dart';
import 'local_device_transport.dart';
import 'local_ip.dart';
import 'provisioning_service.dart';

/// How long a single LOCAL attempt (cached-IP probe + possible quick mDNS
/// window + identity verify + command + read-back) may take before the
/// repository gives up and falls back to cloud. Warm taps are sub-second;
/// this is the worst case for a cold LAN so the user never waits 10-20s.
const Duration kLocalBudget = Duration(seconds: 6);

/// Fast timeout for interactive relay control using a CACHED verified IP.
/// This is used for the critical relay button path — if the cached IP
/// doesn't respond within this window, we immediately fall back to cloud.
/// mDNS discovery is NEVER run in this path.
const Duration kLocalControlFastTimeout = Duration(milliseconds: 400);

/// mDNS browse window for a TAP-time discovery (only used when no verified IP
/// is cached). Kept short so a first tap is still snappy.
const Duration kTapMdnWindow = Duration(seconds: 2);

/// mDNS browse window for BACKGROUND warm-up discovery (page load / resume /
/// reconnect / after provisioning).
const Duration kWarmMdnWindow = Duration(seconds: 5);

/// Bound for the authoritative registered-MAC check (`isDeviceRegistered`) at
/// the provisioning boundary. The phone may be on the Tasmota setup AP, which
/// usually has no internet — so the cloud list must fail fast and let the
/// persisted local mirror answer, never blocking provisioning behind the
/// cloud's 15s API timeout.
const Duration kRegisteredCheckLimit = Duration(seconds: 4);

/// A verified IP is trusted without re-probing for this long. After the TTL it
/// is re-verified with `Status 5` before use (cheap, one LAN round trip).
const Duration kVerifiedIpTtl = Duration(minutes: 10);

/// A local device report stays "fresh" (and therefore beats a stale cloud
/// report) for this window after it was read.
const Duration kLocalReportHold = Duration(seconds: 60);

/// How long a freshly-PROBED identity is trusted before the transport
/// re-verifies it with `Status 5`. Discovery always verifies a device before
/// returning an endpoint; this window lets the immediately-following status
/// read / relay command reuse that verification instead of paying a redundant
/// probe — the cold-start LAN latency. Fresh verified CACHE hits and warm-cache
/// reuses are NOT exempt: they re-verify, catching a box that was repurposed
/// since it was cached.
const Duration kLocalProbeTrustWindow = Duration(seconds: 30);

/// How a canonical MAC is known at the provisioning boundary. Distinct states
/// so "no evidence" is never collapsed into "definitely not registered": a
/// network failure is NOT evidence of absence, and the pre-config hard gate may
/// only treat a MAC as a duplicate when [registered] is authoritative.
enum RegistrationState {
  /// Present in a valid registered-device source (live cloud list, or the
  /// persisted account snapshot captured from a successful refresh).
  registered,

  /// A valid source was consulted and the MAC was absent — evidence, not a
  /// guess (e.g. a refreshed account snapshot that does not contain it).
  notRegistered,

  /// No source could establish anything: cloud unreachable and no persisted
  /// account snapshot exists for this account. The backend's pre-claim checks
  /// and POST /api/devices/provision remain the final authority.
  unknown,
}

/// The single service the devices page uses for relay control and status.
///
/// Relay CONTROL is routed by NETWORK (same WiFi → local-only, else cloud-only,
/// decided once per tap from the page's live reachability state). Each tap
/// dispatches to ONE primary transport; on an AVAILABILITY failure alone the
/// bounded single-fallback safety net retries the OTHER transport exactly once
/// before surfacing an error. STATUS reads remain LOCAL-FIRST (the device's own
/// HTTP report is the freshest truth), falling back to the cloud only when the
/// LAN cannot reach the device. The two transports are never combined for one
/// user action beyond that single retry — the first transport that succeeds
/// wins, never both.
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

  /// When discovery last PROBED (not merely reused a cache) and verified a
  /// device's identity, keyed by deviceId. Lets the transport skip its own
  /// duplicate `Status 5` on operations that immediately follow that probe.
  final Map<String, DateTime> _identityTrustedAt = {};

  /// Last reason the claim-time local HTTP setup failed (for the wizard's
  /// terminal diagnostic). `null` before the first setup attempt or after a
  /// success.
  String? _lastSetupError;

  /// Latest `enableLocalHttpApi` failure reason to surface on the wizard's
  /// diagnostic screen. `null` when setup never ran or last succeeded.
  String? get lastLocalSetupError => _lastSetupError;

  /// Transport that produced the most recent successful result. `null` before
  /// the first result or when the last attempt failed everywhere.
  DeviceTransportSource? get lastSource => _lastSource;

  /// Whether a verified local endpoint is cached and still fresh for the given
  /// device. This indicates the device can be controlled locally without mDNS.
  bool hasVerifiedLocalIp(String deviceId) {
    final transport = _warmCache[deviceId];
    final verifiedAt = _warmVerifiedAt[deviceId];
    if (transport == null || verifiedAt == null) return false;
    if (!isUsableHttpHost(transport.address)) return false;
    return DateTime.now().difference(verifiedAt) < kVerifiedIpTtl;
  }

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

  /// BLOCKING local HTTP API enable + verify, the claim wizard's hard gate:
  /// run immediately after a successful cloud claim for a FRESH device so local
  /// `/cm` control works out of the box, and only returns `true` once the
  /// enable is positively confirmed AND `StatusNET.HTTP_API` reports `1` AND a
  /// real (referer-less) relay command round-trips. The caller fails
  /// provisioning when this returns `false`.
  ///
  /// [lastIp] is the LAN IP the CLAIM RESPONSE carried, learned by the backend
  /// from MQTT telemetry. When present, the setup uses it as a DIRECT bootstrap
  /// candidate (enable-first, referer'd — no discovery, no referer-less probe
  /// before the enable). The persisted cached IP is tried the same way, then
  /// the normal discovery ladder (only usable once SO128 is already ON).
  ///
  /// On success the device was enabled on the LAN (SetOption128 1, idempotent,
  /// positively confirmed), its identity verified (`Status 5` MAC), a read-only
  /// state verified, and the IP persisted as verified through the existing
  /// locator mechanism so the devices page (a separate repository instance)
  /// uses it locally on the next tap.
  Future<bool> enableLocalHttpApi(String deviceId, {String? lastIp}) async {
    _lastSetupError = null;
    _logSetup('setup started');

    String? cached;
    DateTime? cachedVerifiedAt;
    try {
      cached = await _locator.cachedAddress(deviceId);
      cachedVerifiedAt = await _locator.cachedVerifiedAt(deviceId);
    } on Object catch (e) {
      _logSetup('cache read failed: ${_describe(e)}');
    }
    _logSetup(
      'candidates: backend lastIp=$lastIp'
      '${cached != null ? ', cached IP=$cached' : ''}'
      '${cachedVerifiedAt != null ? ', cached verifiedAt=${cachedVerifiedAt.toIso8601String()}' : ''}',
    );

    // DIRECT bootstrap (preferred): the claim response's lastIp. While SO128
    // is OFF Tasmota answers a referer-less `/cm` (including `Status 5`) with
    // the referer-denial warning, so normal discovery can never verify the
    // device pre-SO128. This path therefore sends the referer'd `SetOption128
    // 1` FIRST (accepted exactly like the built-in console), then verifies
    // identity/state, then persists. NO referer-less request runs before the
    // enable.
    if (lastIp != null && lastIp.isNotEmpty) {
      if (!isValidLocalIp(lastIp)) {
        _lastSetupError = 'The backend-reported LAN IP $lastIp was invalid.';
        _logSetup('backend lastIp rejected (invalid): $lastIp');
      } else {
        _logSetup('backend lastIp accepted');
        try {
          await _seedOneCandidate(deviceId, lastIp);
        } on Object catch (e) {
          _logSetup('candidate seed failed: ${_describe(e)}');
        }
        _logSetup('selected IP: $lastIp');
        final transport = LocalDeviceTransport(
          address: lastIp,
          deviceId: deviceId,
          fetcher: _fetch,
          bootstrap: true,
        );
        if (await _directBootstrap(transport, deviceId)) return true;
        // The direct bootstrap failed for a concrete reason; record it so the
        // wizard's diagnostic is precise even if a later ladder step finally
        // succeeds (the string is just the most recent failure).
        _logSetup('direct lastIp bootstrap failed');
      }
    }

    // DIRECT bootstrap on the persisted cached IP (verified or candidate) —
    // same enable-first sequence, no referer-less probe before the enable.
    if (cached != null && isValidLocalIp(cached)) {
      _logSetup('selected IP: $cached (cached)');
      final transport = LocalDeviceTransport(
        address: cached,
        deviceId: deviceId,
        fetcher: _fetch,
        bootstrap: true,
      );
      if (await _directBootstrap(transport, deviceId)) return true;
    }

    // LAST RESORT: the normal discovery ladder (warm cache / verified cache /
    // mDNS). Its referer-less identity probe only works once SO128 is already
    // ON, so this covers the idempotent re-run on an enabled device.
    LocalDeviceTransport? local;
    try {
      // `urgent` keeps the mDNS window short (2s) so the candidate probe + a
      // possible mDNS sweep stay inside kLocalBudget.
      local = await _findLocal(deviceId, urgent: true).timeout(kLocalBudget);
    } on Object catch (e) {
      _lastSetupError =
          'Local discovery failed (${_describe(e)}). Make sure this phone is '
          'on the same Wi-Fi as the device.';
      _logSetup('discovery lookup failed: ${_describe(e)}');
      return false;
    }
    if (local != null) {
      _logSetup('selected IP: ${local.address} (discovered)');
      return _directBootstrap(local, deviceId);
    }

    _lastSetupError ??=
        'No local HTTP endpoint was reachable for the device. Make sure this '
        'phone is on the same Wi-Fi as the device, then try again.';
    _logSetup('failed: no reachable LAN endpoint');
    return false;
  }

  /// The direct claim-time bootstrap sequence for a KNOWN candidate IP:
  /// referer'd `SetOption128 1` FIRST (no identity discovery, no referer-less
  /// request), then the definitive `StatusNET.HTTP_API` enable-proof, then a
  /// real referer-less read-back and persistence. Any failure returns `false`
  /// and records a precise reason for the wizard's diagnostic.
  Future<bool> _directBootstrap(LocalDeviceTransport transport, String deviceId) async {
    _logSetup('before enableHttpApi');
    try {
      await transport.enableHttpApi();
      _logSetup('enableHttpApi result: SetOption128 accepted');
    } on Object catch (e) {
      _lastSetupError =
          'The device rejected or did not confirm the SetOption128 enable '
          '(${_describe(e)}).';
      _logSetup('enableHttpApi result: ${_describe(e)}');
      return false;
    }
    // Definitive proof the enable actually took: the device must now report
    // `StatusNET.HTTP_API == 1` (referer'd probe, MAC-verified).
    _logSetup('before HTTP_API verification');
    if (!await transport.verifyHttpApiEnabled()) {
      _lastSetupError =
          'The device did not confirm its HTTP API is enabled '
          '(StatusNET.HTTP_API != 1). Restart the wizard or check the device '
          'console.';
      _logSetup('HTTP_API verification failed');
      return false;
    }
    _logSetup('after HTTP_API verification: HTTP_API=1');
    _identityTrustedAt[deviceId] = DateTime.now();
    return _verifyAndPersist(transport, deviceId);
  }

  /// Read-only state verification + persistence of the now-verified IP. The
  /// final read deliberately runs on a NORMAL (non-bootstrap, referer-less)
  /// transport — the exact transport the app uses for every relay tap — proving
  /// a real command round-trips once SO128 is ON. The warm cache stores that
  /// same normal transport so the subsequent relay/status path stays referer-less.
  Future<bool> _verifyAndPersist(LocalDeviceTransport transport, String deviceId) async {
    try {
      final normal = LocalDeviceTransport(
        address: transport.address,
        deviceId: deviceId,
        fetcher: _fetch,
      );
      final status = await normal.getStatus(
        deviceId,
        identityVerified: _canSkipIdentityVerify(deviceId),
      );
      _logSetup('final verification result: OK (referer-less State read)');
      await _locator
          .storeVerifiedAddress(deviceId, transport.address)
          .timeout(const Duration(seconds: 2));
      _warmCache[deviceId] = normal;
      _warmVerifiedAt[deviceId] = DateTime.now();
      _lastSource = DeviceTransportSource.local;
      _maybeLearnIp(deviceId, transport.address, status);
      _logSetup('persisted verified IP: ${transport.address}');
      return true;
    } on Object catch (e) {
      _lastSetupError =
          'The final referer-less state check failed (${_describe(e)}).';
      _logSetup('final verification failed: ${_describe(e)}');
      return false;
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
      // A successful cloud list fetch also refreshes the PERSISTED account
      // snapshot (canonical MACs) so offline duplicate detection always knows
      // the full registered set — including devices claimed from another client.
      try {
        await _cache.saveAccountSnapshot(devices);
      } on Object catch (e) {
        _log('account snapshot refresh failed after cloud list fetch '
            '(${_describe(e)})');
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

  /// Fast, best-effort read of the persisted local device list (the last
  /// cloud-authorised list). Used at cold start so the devices page can render
  /// the known card structure immediately instead of blocking behind the cloud
  /// list timeout; the cloud list remains the authoritative source and replaces
  /// this render when it arrives. Display metadata only — never throws.
  Future<List<Map<String, dynamic>>> cachedDevices() async {
    try {
      return await _cache.cachedDevices();
    } on Object catch (e) {
      _log('cached device list unavailable (${_describe(e)})');
      return const [];
    }
  }

  /// True when the registration knowledge is authoritative that [canonicalMac]
  /// is registered (see [registrationState] for the full three-state semantics).
  /// `false` covers both "evidence of absence" and "unknown" — both proceed at
  /// the boundary, where the backend pre-claim check and POST /api/devices/provision
  /// remain the final authority.
  Future<bool> isDeviceRegistered(String canonicalMac) async {
    return await registrationState(canonicalMac) == RegistrationState.registered;
  }

  /// HARD provisioning invariant, consulted at the authoritative provisioning
  /// boundary immediately before the first Tasmota configuration command.
  ///
  /// Three-state registration knowledge for [canonicalMac]:
  ///
  ///  * [RegistrationState.registered] — the MAC is present in a valid source:
  ///    the cloud-authorised list (bounded), the PERSISTED account snapshot
  ///    ([LocalDeviceCache.saveAccountSnapshot], taken from a successful
  ///    `GET /api/devices`), or the persisted display mirror ([kLocalDevicesKey]).
  ///    A MAC in ANY of these is registered, so the rule survives closing the
  ///    wizard, reopening Add Device, recreating the widget, and offline /
  ///    setup-AP conditions.
  ///  * [RegistrationState.notRegistered] — a valid source was consulted and
  ///    the MAC was absent (e.g. a persisted account snapshot that was refreshed
  ///    online and that does not contain it). This is evidence, not a guess.
  ///  * [RegistrationState.unknown] — no source could establish anything:
  ///    cloud unreachable, no persisted account snapshot for this account. A
  ///    network failure is NOT evidence of absence; the backend pre-claim check
  ///    and POST /api/devices/provision remain the final authority.
  ///
  /// The cloud list is tried first (bounded by [kRegisteredCheckLimit]); a
  /// successful fetch refreshes BOTH the persisted account snapshot and the
  /// display mirror, so offline knowledge is never lost and only grows fresher.
  /// An unreachable cloud falls back to the persisted snapshot — a failed
  /// request must never erase already-known information.
  Future<RegistrationState> registrationState(String canonicalMac) async {
    try {
      final devices =
          await _cloud.getDevices().timeout(kRegisteredCheckLimit);
      final found = ClaimDeviceSnapshot.fromDevices(devices).containsMac(
        canonicalMac,
      );
      // Persist the fresh authoritative knowledge before answering so an
      // immediately-following offline boundary still certifies it.
      try {
        await _cache.saveAccountSnapshot(devices);
      } on Object catch (e) {
        _log('account snapshot refresh failed (${_describe(e)})');
      }
      try {
        await _cache.replaceAll(devices);
      } on Object catch (e) {
        _log('display mirror refresh failed (${_describe(e)})');
      }
      return found
          ? RegistrationState.registered
          : RegistrationState.notRegistered;
    } on Object catch (e) {
      _log('registered-MAC cloud check unavailable (${_describe(e)})');
    }

    // Cloud unreachable (phone on the offline Tasmota AP): consult the
    // PERSISTED account snapshot captured before entering the AP. Presence is
    // registered; a valid snapshot that lacks the MAC is evidence of absence.
    try {
      final snapshotMacs = await _cache.loadAccountSnapshotMacs();
      if (snapshotMacs != null) {
        return snapshotMacs.contains(canonicalMac)
            ? RegistrationState.registered
            : RegistrationState.notRegistered;
      }
    } on Object catch (e) {
      _log('registered-MAC account snapshot unavailable (${_describe(e)})');
    }

    // No account snapshot yet: fall back to the persisted display mirror
    // (legacy/back-compat). Presence certifies; otherwise the state is UNKNOWN —
    // never a confident "not registered".
    try {
      final cached = await _cache.cachedDevices();
      final found =
          ClaimDeviceSnapshot.fromDevices(cached).containsMac(canonicalMac);
      return found ? RegistrationState.registered : RegistrationState.unknown;
    } on Object catch (e) {
      _log('registered-MAC mirror check unavailable (${_describe(e)})');
    }
    return RegistrationState.unknown;
  }

  /// Refreshes the PERSISTED account device snapshot (canonical MACs) plus the
  /// display mirror from a bounded cloud list fetch. Called at the Add Device
  /// entry while the phone is still on its normal network — BEFORE the wizard
  /// enters the offline Tasmota AP. Any failure is swallowed: the last valid
  /// persisted snapshot must never be erased by a failed request.
  Future<void> refreshAccountSnapshot() async {
    try {
      final devices = await _cloud.getDevices().timeout(kRegisteredCheckLimit);
      await _cache.saveAccountSnapshot(devices);
      try {
        await _cache.replaceAll(devices);
      } on Object catch (e) {
        _log('display mirror refresh failed after account refresh '
            '(${_describe(e)})');
      }
      await _seedCandidates(devices);
    } on Object catch (e) {
      _log('account snapshot refresh unavailable (${_describe(e)})');
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
  ///
  /// When [cloudDown] is true the status read is LOCAL-ONLY: the caller already
  /// knows the cloud is unreachable (Socket.IO / health monitor confirmed it),
  /// so a local miss rethrows immediately instead of blocking on a doomed cloud
  /// attempt that could sit on the 15s API timeout — the known-endpoint ladder
  /// (warm memory → persisted verified IP → candidate/verify → mDNS) runs first
  /// and unchanged, and the poll / repeated-failure threshold reconciles a
  /// total local miss. Mirrors the [control] `cloudDown` convention.
  Future<RelayStatusResult> getStatus(
    String deviceId, {
    bool cloudDown = false,
  }) async {
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
      if (cloudDown) {
        // Cloud is confirmed unreachable: never spend the API timeout on it.
        rethrow;
      }
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

  /// Relay command, dispatched to ONE primary transport per tap — chosen once
  /// by the view's [routingPolicy] from the live reachability state:
  ///
  /// - [ControlRoute.localOnly] → the command runs over the LAN (cached/warm
  ///   verified IP only, no mDNS, no cloud round-trip).
  /// - [ControlRoute.cloudOnly] → the command runs through the backend/MQTT and
  ///   the LAN is not attempted first.
  ///
  /// On an AVAILABILITY failure of the primary transport (connection failure,
  /// timeout, backend 5xx, device-offline 409) the bounded safety net retries
  /// the OPPOSITE transport exactly once — this covers a stale same-WiFi
  /// verdict during a network transition, when the routing choice was made a
  /// moment before the network actually changed. Every LOGICAL rejection —
  /// auth/ownership, validation, command conflicts, coded 409, MAC identity
  /// mismatches — is surfaced to the user and NEVER rerouted to the other
  /// transport.
  ///
  /// [opId] threads the per-tap correlation id into the [ControlTimeline].
  Future<RelayStatusResult> control(
    String deviceId,
    int channel,
    String state, {
    String? opId,
    ControlRoute route = ControlRoute.cloudOnly,
    bool? sameWifiAtTap,
  }) async {
    _tl(opId, deviceId, channel, 'Repository control entered');
    final seq = ++_seq;

    final attempts = <ControlRoute>[route, route.opposite];
    Object? firstError;
    for (var i = 0; i < attempts.length; i++) {
      final attempt = attempts[i];
      try {
        if (attempt == ControlRoute.localOnly) {
          _tl(opId, deviceId, channel, 'Local attempt start');
          final local = await _localControlFast(deviceId, channel, state, opId: opId)
              .timeout(kLocalBudget);
          _tl(opId, deviceId, channel, 'Local attempt done');
          _lastSource = DeviceTransportSource.local;
          _log('local control success for $deviceId channel $channel');
          return parseRelayStatus(
            local,
            source: DeviceTransportSource.local,
            seq: ++_seq,
          );
        } else {
          _tl(opId, deviceId, channel, 'Cloud request start');
          final cloud = await _cloud.control(deviceId, channel, state, opId: opId);
          _tl(opId, deviceId, channel, 'Cloud response received');
          if (cloud['status'] == 'pending') {
            _tl(opId, deviceId, channel, 'Cloud 202 pending — awaiting Socket.IO RESULT');
            _lastSource = DeviceTransportSource.cloud;
            await _seedOneCandidate(deviceId, cloud['lastIp']);
            _log('cloud 202 pending for $deviceId channel $channel op=$opId');
            final expected = cloud['expected'] as String? ?? state;
            return parseRelayStatus(
              {
                'online': true,
                'channels': {
                  '$channel': {'state': expected, 'updatedAt': null}
                },
              },
              source: DeviceTransportSource.cloud,
              seq: seq,
            );
          }
          _lastSource = DeviceTransportSource.cloud;
          await _seedOneCandidate(deviceId, cloud['lastIp']);
          _log('cloud control success for $deviceId channel $channel');
          return parseRelayStatus(
            cloud,
            source: DeviceTransportSource.cloud,
            seq: seq,
          );
        }
      } on Object catch (e) {
        if (_isLogicalRejection(e)) {
          _tl(opId, deviceId, channel, '$attempt attempt rejected');
          _log('$attempt control REJECTED for $deviceId (${_describe(e)})');
          rethrow;
        }
        if (i == 0) {
          // Scoped fallback: when the cloud was the primary and sameWifi was
          // false at tap time (genuinely off-WiFi), don't pay the full 6s
          // discovery. Do only a fast warm-cache probe (400ms) as a stale-
          // verdict sanity check — if the device is actually reachable (warm
          // cache still valid due to hysteresis lag) the fast probe succeeds;
          // otherwise surface the cloud error immediately without full discovery.
          if (attempt == ControlRoute.cloudOnly && sameWifiAtTap == false) {
            firstError = e;
            _tl(opId, deviceId, channel,
                '$attempt attempt failed — fast warm-probe fallback (sameWifi==false)');
            _log('$attempt control failed for $deviceId (${_describe(e)}); '
                'trying fast warm-cache probe');
            try {
              // Fast warm-cache probe: 800ms = 2×kLocalControlFastTimeout (400ms for
              // identity check + 400ms for control) — no mDNS, no 6s budget.
              final local = await _localControlFast(deviceId, channel, state, opId: opId)
                  .timeout(const Duration(milliseconds: 800));
              _tl(opId, deviceId, channel, 'Fast fallback succeeded');
              _lastSource = DeviceTransportSource.local;
              _log('fast fallback success for $deviceId channel $channel');
              return parseRelayStatus(
                local,
                source: DeviceTransportSource.local,
                seq: ++_seq,
              );
            } on Object catch (fastError) {
              if (_isLogicalRejection(fastError)) {
                _tl(opId, deviceId, channel, 'Fast fallback rejected');
                _log('fast fallback REJECTED for $deviceId (${_describe(fastError)})');
                rethrow;
              }
              _log('fast fallback failed for $deviceId (${_describe(fastError)}); '
                  'surfacing cloud error without full discovery');
              // ignore: unnecessary_non_null_assertion
              Error.throwWithStackTrace(firstError!, StackTrace.current);
            }
          }
          // Availability failure: the primary path is unusable RIGHT NOW, which
          // is exactly when a stale routing verdict during a network transition
          // bites. Retry the opposite transport exactly once.
          firstError = e;
          _tl(opId, deviceId, channel,
              '$attempt attempt failed — single fallback to ${attempts[1]}');
          _log('$attempt control failed for $deviceId (${_describe(e)}); '
              'trying the ${attempts[1]} transport');
          continue;
        }
        // The single fallback also failed with availability: the device is
        // genuinely unreachable on BOTH transports. Surface the combined error
        // with the first (primary) failure preserved as the cause.
        _tl(opId, deviceId, channel, 'Both transports unavailable');
        _log('$attempt control failed for $deviceId (${_describe(e)}); '
            'both transports exhausted');
        throw DeviceTransportException(
          'The device could not be reached locally or online.',
          cause: firstError,
        );
      }
    }
    throw StateError('unreachable');
  }

  /// True for a rejection that must surface as-is and NEVER be rerouted to the
  /// other transport: a logical `DeviceTransportException` (identity/ownership)
  /// or a classified backend rejection (`ApiException` that is not an
  /// availability failure — 4xx, coded 409, etc.).
  bool _isLogicalRejection(Object e) {
    if (e is DeviceTransportException) {
      return e.kind == TransportFailureKind.logical;
    }
    if (e is ApiException) {
      return !isAvailabilityFailure(e);
    }
    return false;
  }

  /// Fast same-WiFi detection for tap routing. Returns true when the device is
  /// reachable on the phone's network: a recently-confirmed warm endpoint needs
  /// no probe (instant); otherwise the persisted verified IP is probed with a
  /// bounded fast identity check (`Status 5`, [kLocalControlFastTimeout]). The
  /// successful probe also warms the cache, so the immediately-following
  /// [ControlRoute.localOnly] control hits the warm endpoint with no second
  /// probe. Anything ambiguous — no cached IP, probe timeout, unreachable,
  /// identity mismatch — returns false, the caller's safe cloud default.
  Future<bool> isDeviceOnSameNetwork(String deviceId) async {
    final now = DateTime.now();
    final warm = _warmCache[deviceId];
    final warmAt = _warmVerifiedAt[deviceId];
    if (warm != null &&
        warmAt != null &&
        now.difference(warmAt) < kLocalReportHold) {
      return true;
    }
    try {
      final cached = await _locator.cachedAddress(deviceId);
      if (cached == null || cached.isEmpty || !isUsableHttpHost(cached)) {
        return false;
      }
      final transport = _buildLocal(cached, deviceId);
      final check = await transport.checkIdentity().timeout(kLocalControlFastTimeout);
      if (check == LocalIdentityCheck.verified) {
        _warmCache[deviceId] = transport;
        _warmVerifiedAt[deviceId] = now;
        _identityTrustedAt[deviceId] = now;
        await _locator.storeVerifiedAddress(deviceId, cached);
        return true;
      }
      if (check == LocalIdentityCheck.mismatch) {
        await _locator.discardAddress(deviceId);
      }
    } catch (_) {
      // Probe failed or timed out: not confirmably on the same network.
    }
    return false;
  }

  /// True when discovery PROBED and verified this device's identity recently,
  /// so the transport may skip its own redundant `Status 5`. Never true for a
  /// fresh verified-cache / warm-cache reuse (those keep re-verifying to catch
  /// a repurposed box), so the same signal that makes a cold LAN fast never
  /// weakens the identity check for an already-cached endpoint.
  bool _canSkipIdentityVerify(String deviceId) {
    final at = _identityTrustedAt[deviceId];
    return at != null && DateTime.now().difference(at) < kLocalProbeTrustWindow;
  }

  Future<Map<String, dynamic>> _localStatus(String deviceId) async {
    final local = await _findLocal(deviceId, urgent: true);
    if (local == null) {
      throw const DeviceTransportException('No local device available.');
    }
    try {
      final result = await local.getStatus(
        deviceId,
        identityVerified: _canSkipIdentityVerify(deviceId),
      );
      _maybeLearnIp(deviceId, local.address, result);
      return result;
    } on DeviceTransportException catch (e) {
      if (e.kind != TransportFailureKind.logical) rethrow;
      // The endpoint's identity changed under us (repurposed IP): the box at
      // this address is NOT our device. Drop it and re-discover so mDNS can
      // find the real device; the foreign box is never read. One bounded retry,
      // then the original identity violation is surfaced unchanged.
      _log(
        'local endpoint identity violation for $deviceId — '
        'discarding and re-discovering',
      );
      await _invalidateEndpoint(deviceId);
      final rediscovered = await _findLocal(deviceId, urgent: true);
      if (rediscovered == null) rethrow;
      final result = await rediscovered.getStatus(
        deviceId,
        identityVerified: _canSkipIdentityVerify(deviceId),
      );
      _maybeLearnIp(deviceId, rediscovered.address, result);
      return result;
    }
  }

  /// Fast local control attempt using ONLY cached/warm IPs.
  /// Never runs mDNS discovery. Used for the [ControlRoute.localOnly] tap path
  /// so the command reaches an already-known, identity-verified endpoint with
  /// no discovery window.
  Future<Map<String, dynamic>> _localControlFast(
    String deviceId,
    int channel,
    String state, {
    String? opId,
  }) async {
    _tl(opId, deviceId, channel, 'Cached local IP attempt start');

    // Try warm in-memory endpoint first (already verified)
    final warm = _warmCache[deviceId];
    final warmAt = _warmVerifiedAt[deviceId];
    if (warm != null &&
        warmAt != null &&
        DateTime.now().difference(warmAt) < kVerifiedIpTtl) {
      if (!isUsableHttpHost(warm.address)) {
        _warmCache.remove(deviceId);
        _warmVerifiedAt.remove(deviceId);
      } else {
        _tl(opId, deviceId, channel, 'Warm endpoint used');
        _log('using warm verified endpoint for $deviceId (fast)');
        return _executeLocalControl(warm, deviceId, channel, state, opId: opId);
      }
    }

    // Try persisted cached IP (must verify identity first)
    _tl(opId, deviceId, channel, 'Cached IP probe start');
    final cached = await _locator.cachedAddress(deviceId);
    if (cached != null && cached.isNotEmpty && isUsableHttpHost(cached)) {
      final transport = _buildLocal(cached, deviceId);
      // Fast identity check with short timeout
      try {
        final check = await transport.checkIdentity().timeout(kLocalControlFastTimeout);
        if (check == LocalIdentityCheck.verified) {
          _tl(opId, deviceId, channel, 'Cached IP probe result: verified');
          _warmCache[deviceId] = transport;
          _warmVerifiedAt[deviceId] = DateTime.now();
          await _locator.storeVerifiedAddress(deviceId, cached);
          _identityTrustedAt[deviceId] = DateTime.now();
          _log('verified cached IP: $cached (fast)');
          return _executeLocalControl(transport, deviceId, channel, state, opId: opId);
        }
        if (check == LocalIdentityCheck.mismatch) {
          await _locator.discardAddress(deviceId);
          _log('cached IP identity mismatch — discarding $cached');
          // Logical rejection (identity mismatch) must surface immediately
          throw const DeviceTransportException(
            'The local device identity could not be verified.',
            kind: TransportFailureKind.logical,
          );
        }
      } on TimeoutException {
        _tl(opId, deviceId, channel, 'Cached IP probe timeout');
        _log('cached IP probe timeout — skipping to cloud');
      }
    } else {
      _tl(opId, deviceId, channel, 'Cached IP probe result: none');
    }

    // No usable cached IP — fail fast so cloud can take over
    _tl(opId, deviceId, channel, 'Cached local IP attempt fast timeout');
    throw const DeviceTransportException(
      'No cached local endpoint available for fast control.',
      kind: TransportFailureKind.availability,
    );
  }

  /// Execute the actual local control command with fast timeout.
  Future<Map<String, dynamic>> _executeLocalControl(
    LocalDeviceTransport transport,
    String deviceId,
    int channel,
    String state, {
    String? opId,
  }) async {
    final result = await transport
        .control(
          deviceId,
          channel,
          state,
          opId: opId,
          identityVerified: true, // already verified in caller
        )
        .timeout(kLocalControlFastTimeout);
    _maybeLearnIp(deviceId, transport.address, result);
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
      _identityTrustedAt[deviceId] = DateTime.now();
      _log('learned device IP from local report: $ip');
    } on Object catch (e) {
      _log('IP learn failed for $deviceId (${_describe(e)})');
    }
  }

  /// Drops every trace of a repurposed/invalid local endpoint so the next
  /// discovery can never hand out the foreign box at the old address again:
  /// the warm in-memory endpoint, the probe-trust window, the persisted
  /// verified-IP cache, and any in-flight discovery are all cleared.
  /// Best-effort; never blocks discovery.
  Future<void> _invalidateEndpoint(String deviceId) async {
    _warmCache.remove(deviceId);
    _warmVerifiedAt.remove(deviceId);
    _identityTrustedAt.remove(deviceId);
    _discoveryInFlight.remove(deviceId);
    try {
      await _locator
          .discardAddress(deviceId)
          .timeout(const Duration(seconds: 2));
      _log('invalidated endpoint for $deviceId');
    } on Object catch (e) {
      _log('endpoint invalidation failed for $deviceId (${_describe(e)})');
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
    late final Future<LocalDeviceTransport?> future;
    final discovery = _discoverLocal(
      deviceId,
      urgent: urgent,
      opId: opId,
      channel: channel,
    );
    future = discovery.whenComplete(() {
      // Only clear the entry we created: a concurrent identity invalidation
      // may have already dropped it or replaced it with a fresh discovery.
      if (identical(_discoveryInFlight[deviceId], future)) {
        _discoveryInFlight.remove(deviceId);
      }
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
            _identityTrustedAt[deviceId] = DateTime.now();
            _log('verified cached IP: $cached');
            return transport;
          case LocalIdentityCheck.mismatch:
            // The box at this address is NOT our device — the IP was repurposed.
            // Drop it so we never probe a stranger's box again.
            await _locator.discardAddress(deviceId);
            _tl(opId, deviceId, channel, 'Cached IP probe result: mismatch');
            _log('cached IP identity mismatch — discarding $cached');
            break;
          case LocalIdentityCheck.refererGated:
            // The box IS reachable but SetOption128 is OFF, so the referer-less
            // probe could not confirm the MAC. Out-of-scope old devices are
            // never repaired: keep the address as a hint only (like unavailable)
            // and let the claim-time setup handle pre-SO128 boxes.
            _tl(opId, deviceId, channel, 'Cached IP probe result: gated');
            _log('cached IP referer-gated (SetOption128 OFF) — kept as hint');
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
      switch (await transport.checkIdentity()) {
        case LocalIdentityCheck.verified:
          _log('verified local device: $ip');
          await _locator.storeVerifiedAddress(deviceId, ip);
          _warmCache[deviceId] = transport;
          _warmVerifiedAt[deviceId] = DateTime.now();
          _identityTrustedAt[deviceId] = DateTime.now();
          _tl(opId, deviceId, channel, 'mDNS verified');
          return transport;
        case LocalIdentityCheck.mismatch:
          _log('mDNS candidate failed identity check — skipped');
          break;
        case LocalIdentityCheck.unavailable:
          _log('mDNS candidate unreachable — skipped');
          break;
        case LocalIdentityCheck.refererGated:
          // Pre-SO128 box: reachable but referer-less probes are denied. Not a
          // "mismatch", but old devices are out of scope — no repair, no
          // bootstrap outside the claim flow.
          _log('mDNS candidate referer-gated (SetOption128 OFF) — kept as hint');
          break;
      }
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

  /// Dedicated trace for the claim-time AUTO SetOption128 bootstrap, so a
  /// post-claim LAN miss is distinguishable from background warm-up logs.
  void _logSetup(String message) {
    debugPrint('[local-setup] $message');
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
