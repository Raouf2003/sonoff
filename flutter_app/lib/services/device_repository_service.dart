import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'api_service.dart';
import 'cloud_device_transport.dart';
import 'device_transport.dart';
import 'local_device_discovery.dart';
import 'local_device_transport.dart';

/// How long the cloud→local lookup is allowed to take in total (cached-IP
/// probe + mDNS window + per-candidate MAC checks). A relay tap on a degraded
/// network never blocks past this before surfacing the cloud's error.
const Duration kLocalFallbackBudget = Duration(seconds: 10);

/// mDNS browse window for a single lookup. Bounded by contract — discovery
/// never runs indefinitely.
const Duration kLocalMDnsWindow = Duration(seconds: 5);

/// The single service the devices page uses for relay control and status.
///
/// Cloud is ALWAYS preferred. Local Mode is a transparent fallback for the SAME
/// already-provisioned devices, triggered only when the cloud failure is an
/// availability failure:
///
///   * no network / connection failure / timeout / backend 5xx  → try local
///   * 400 / 401 / 403 / 404 / ownership / validation / conflicts → NEVER
///
/// The UI never learns which transport ran; it only reads [lastSource] for the
/// optional, subtle connection indicator.
class DeviceRepositoryService {
  DeviceRepositoryService({
    CloudDeviceTransport? cloud,
    DeviceLocator? locator,
    TasmotaCmFetcher? fetch,
  })  : _cloud = cloud ?? CloudDeviceTransport(),
        _locator = locator ?? LocalDeviceDiscovery(),
        // ignore: prefer_initializing_formals
        _fetch = fetch;

  final CloudDeviceTransport _cloud;
  final DeviceLocator _locator;
  final TasmotaCmFetcher? _fetch;

  DeviceTransportSource? _lastSource;

  /// Transport that produced the most recent successful result. `null` before
  /// the first result or when the last attempt failed everywhere.
  DeviceTransportSource? get lastSource => _lastSource;

  Future<Map<String, dynamic>> getStatus(String deviceId) async {
    Map<String, dynamic> result;
    try {
      result = await _cloud.getStatus(deviceId);
    } on Object catch (e) {
      if (!isAvailabilityFailure(e)) rethrow;
      _log(
        'cloud unavailable for $deviceId (${_describe(e)}), '
        'starting local fallback',
      );
      return _fallback(() => _localStatus(deviceId), originalError: e);
    }
    // The cloud answered. When it reports the device online we are done; when
    // it reports the device OFFLINE at the cloud, the device may still be on
    // the LAN (the same outage often hides it from MQTT). Probe local and
    // prefer the live LAN status when it verifies — never paper over cloud
    // truth with a guessed answer.
    if (result['online'] != true) {
      return _probeLocalStatus(deviceId, cloudResult: result);
    }
    _lastSource = DeviceTransportSource.cloud;
    return result;
  }

  /// Cloud is healthy but says the device is offline. Try the LAN; keep the
  /// cloud's (offline) answer untouched when the LAN cannot find the device.
  Future<Map<String, dynamic>> _probeLocalStatus(
    String deviceId, {
    required Map<String, dynamic> cloudResult,
  }) async {
    _lastSource = DeviceTransportSource.cloud;
    try {
      final local = await _localStatus(deviceId).timeout(kLocalFallbackBudget);
      _log('local status success for $deviceId — using LAN state');
      _lastSource = DeviceTransportSource.local;
      return local;
    } on Object {
      _log('local status failed for $deviceId — keeping cloud truth (offline)');
      _lastSource = DeviceTransportSource.cloud;
      return cloudResult;
    }
  }

  Future<Map<String, dynamic>> control(
    String deviceId,
    int channel,
    String state,
  ) async {
    try {
      final result = await _cloud.control(deviceId, channel, state);
      _lastSource = DeviceTransportSource.cloud;
      return result;
    } on Object catch (e) {
      if (!isAvailabilityFailure(e)) rethrow;
      _log(
        'cloud unavailable for $deviceId (${_describe(e)}), '
        'starting local fallback',
      );
      return _fallback(
        () => _localControl(deviceId, channel, state),
        originalError: e,
      );
    }
  }

  /// Attempts the local path. Preserves the ORIGINAL cloud availability error
  /// when the device is not reachable on the LAN either, so the UI shows the
  /// same offline message it always did — it never pretends success.
  Future<Map<String, dynamic>> _fallback(
    Future<Map<String, dynamic>> Function() run, {
    required Object originalError,
  }) async {
    Map<String, dynamic>? result;
    try {
      result = await run().timeout(kLocalFallbackBudget);
    } on Object {
      result = null;
    }
    if (result != null) {
      _lastSource = DeviceTransportSource.local;
      return result;
    }
    throw originalError;
  }

  Future<Map<String, dynamic>> _localStatus(String deviceId) async {
    final local = await _findLocal(deviceId);
    if (local == null) {
      throw const DeviceTransportException('No local device available.');
    }
    return local.getStatus(deviceId);
  }

  Future<Map<String, dynamic>> _localControl(
    String deviceId,
    int channel,
    String state,
  ) async {
    final local = await _findLocal(deviceId);
    if (local == null) {
      throw const DeviceTransportException('No local device available.');
    }
    return local.control(deviceId, channel, state);
  }

  /// Discovery ladder for a single device: verified-IP cache first, then mDNS.
  /// Every candidate is identity-verified via `Status 5` (`normalizeMac ==
  /// deviceId`) before it is used or cached; a stale/repurposed cached IP is
  /// discarded and re-discovered.
  Future<LocalDeviceTransport?> _findLocal(String deviceId) async {
    _log('starting discovery for $deviceId');

    final cached = await _locator.cachedAddress(deviceId);
    if (cached != null && cached.isNotEmpty) {
      _log('trying cached IP: $cached');
      final transport = _buildLocal(cached, deviceId);
      if (await transport.verifyIdentity()) {
        _log('verified cached IP: $cached');
        return transport;
      }
      // Stale / unreachable / repurposed: never use it, forget it.
      _log('cached IP failed — discarding stale entry');
      await _locator.discardAddress(deviceId);
    }

    _log('starting mDNS discovery');
    final candidates = await _locator.mDnsCandidates(kLocalMDnsWindow);
    for (final ip in candidates) {
      _log('mDNS candidate: $ip — verifying MAC');
      final transport = _buildLocal(ip, deviceId);
      if (await transport.verifyIdentity()) {
        _log('verified local device: $ip');
        await _locator.storeVerifiedAddress(deviceId, ip);
        return transport;
      }
      // A foreign Tasmota (or a non-Tasmota responder) is ignored.
      _log('mDNS candidate failed identity check — skipped');
    }

    _log('local discovery failed');
    return null;
  }

  /// Short, non-sensitive description of a failure for the debug trace. Never
  /// includes messages/bodies that could carry credentials.
  String _describe(Object error) {
    if (error is ApiException) {
      return 'ApiException(status=${error.statusCode}, code=${error.code})';
    }
    if (error is DeviceTransportException) {
      return 'DeviceTransportException(kind=${error.kind})';
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