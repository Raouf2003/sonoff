import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import '../transport/device_transport.dart';
import '../transport/local_device_transport.dart';
import '../transport/local_ip.dart';

const String kApAddress = '192.168.4.1';
const Duration kStatusBudget = Duration(seconds: 5);
const Duration kControlBudget = Duration(seconds: 5);
const Duration kVerifiedEndpointTtl = Duration(minutes: 10);
const Duration kIdentityTrustWindow = Duration(seconds: 30);
const String _endpointPrefix = 'stees_local.endpoint.';

class LocalDeviceRepository {
  LocalDeviceRepository({
    TasmotaCmFetcher? fetch,
    Future<SharedPreferences> Function()? prefs,
  })  : _fetch = fetch,
        _prefs = prefs ?? SharedPreferences.getInstance;

  final TasmotaCmFetcher? _fetch;
  final Future<SharedPreferences> Function() _prefs;

  int _seq = 0;
  final Map<String, String> _warmEndpoints = {};
  final Map<String, DateTime> _warmVerifiedAt = {};
  final Map<String, DateTime> _identityTrustedAt = {};
  final Map<String, Future<String>> _resolveInFlight = {};
  final List<String> _diagnostics = [];

  List<String> get diagnostics => List.unmodifiable(_diagnostics);

  void _log(String message) {
    final line = '${DateTime.now().toIso8601String()} $message';
    _diagnostics.add(line);
    if (_diagnostics.length > 100) _diagnostics.removeAt(0);
    debugPrint('[LOCAL][REPO] $message');
  }

  bool _canSkipVerify(String deviceId) {
    final at = _identityTrustedAt[deviceId];
    return at != null && DateTime.now().difference(at) < kIdentityTrustWindow;
  }

  LocalDeviceTransport _build(String endpoint, String deviceId, String? password, {bool bootstrap = false}) {
    return LocalDeviceTransport(
      address: endpoint,
      deviceId: deviceId,
      password: password,
      fetcher: _fetch,
      bootstrap: bootstrap,
    );
  }

  Future<String?> _cachedEndpoint(String deviceId) async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString('$_endpointPrefix$deviceId');
      if (raw == null || raw.isEmpty || !isValidLocalIp(raw)) return null;
      return raw;
    } catch (_) {
      return null;
    }
  }

  Future<void> _storeEndpoint(String deviceId, String endpoint) async {
    try {
      final prefs = await _prefs();
      await prefs.setString('$_endpointPrefix$deviceId', endpoint);
    } catch (e) {
      _log('endpoint persist failed for $deviceId: $e');
    }
  }

  Future<void> forgetEndpoint(String deviceId) async {
    _warmEndpoints.remove(deviceId);
    _warmVerifiedAt.remove(deviceId);
    _identityTrustedAt.remove(deviceId);
    try {
      final prefs = await _prefs();
      await prefs.remove('$_endpointPrefix$deviceId');
    } catch (_) {}
  }

  Future<String> _resolve(String deviceId, String? password) {
    final existing = _resolveInFlight[deviceId];
    if (existing != null) return existing;
    late final Future<String> future;
    future = _discover(deviceId, password).whenComplete(() {
      if (identical(_resolveInFlight[deviceId], future)) {
        _resolveInFlight.remove(deviceId);
      }
    });
    _resolveInFlight[deviceId] = future;
    return future;
  }

  Future<String> _discover(String deviceId, String? password) async {
    final now = DateTime.now();
    final warm = _warmEndpoints[deviceId];
    final warmAt = _warmVerifiedAt[deviceId];
    if (warm != null && warmAt != null && now.difference(warmAt) < kVerifiedEndpointTtl) {
      if (!isUsableHttpHost(warm)) {
        _warmEndpoints.remove(deviceId);
        _warmVerifiedAt.remove(deviceId);
      } else {
        return warm;
      }
    }
    final cached = await _cachedEndpoint(deviceId);
    if (cached != null) {
      final check = await _build(cached, deviceId, password).checkIdentity();
      if (check == LocalIdentityCheck.verified) {
        _warmEndpoints[deviceId] = cached;
        _warmVerifiedAt[deviceId] = now;
        _identityTrustedAt[deviceId] = now;
        _log('verified cached endpoint for $deviceId: $cached');
        return cached;
      }
      if (check == LocalIdentityCheck.mismatch) {
        await forgetEndpoint(deviceId);
        _log('cached endpoint mismatch for $deviceId — discarded $cached');
      }
    }
    final ap = _build(kApAddress, deviceId, password);
    switch (await ap.checkIdentity()) {
      case LocalIdentityCheck.verified:
        _warmEndpoints[deviceId] = kApAddress;
        _warmVerifiedAt[deviceId] = now;
        _identityTrustedAt[deviceId] = now;
        await _storeEndpoint(deviceId, kApAddress);
        _log('verified AP endpoint for $deviceId');
        return kApAddress;
      case LocalIdentityCheck.mismatch:
        _log('AP identity mismatch for $deviceId — refusing');
        throw const DeviceTransportException(
          'The device at 192.168.4.1 is not the paired device. Check the access point.',
          kind: TransportFailureKind.logical,
        );
      case LocalIdentityCheck.refererGated:
        _log('AP referer-gated for $deviceId — HTTP API setup required');
        throw const DeviceTransportException(
          'The device answered but its HTTP API is not enabled yet. Run setup first.',
          kind: TransportFailureKind.logical,
        );
      case LocalIdentityCheck.unavailable:
        throw const DeviceTransportException(
          'The device was not found. Connect to its Wi-Fi access point and retry.',
        );
    }
  }

  void _learnEndpoint(String deviceId, String used, Map<String, dynamic> result) {
    final ip = result['ipAddress'];
    if (ip is! String || ip.isEmpty || ip == used || !isValidLocalIp(ip)) return;
    unawaited(_adoptEndpoint(deviceId, ip));
  }

  Future<void> _adoptEndpoint(String deviceId, String ip) async {
    await _storeEndpoint(deviceId, ip);
    _warmEndpoints[deviceId] = ip;
    _warmVerifiedAt[deviceId] = DateTime.now();
    _identityTrustedAt[deviceId] = DateTime.now();
    _log('learned endpoint for $deviceId: $ip');
  }

  Future<RelayStatusResult> getStatus(String deviceId, {String? password}) async {
    final seq = ++_seq;
    final endpoint = await _resolve(deviceId, password).timeout(kStatusBudget);
    final transport = _build(endpoint, deviceId, password);
    try {
      final data = await transport
          .getStatus(deviceId, identityVerified: _canSkipVerify(deviceId))
          .timeout(kStatusBudget);
      _learnEndpoint(deviceId, endpoint, data);
      _log('status ok for $deviceId via $endpoint');
      return parseRelayStatus(data, source: DeviceTransportSource.local, seq: seq);
    } on DeviceTransportException catch (e) {
      if (e.kind == TransportFailureKind.logical) {
        await forgetEndpoint(deviceId);
      }
      rethrow;
    }
  }

  Future<RelayStatusResult> control(
    String deviceId,
    int channel,
    String state, {
    String? password,
    String? opId,
  }) async {
    final seq = ++_seq;
    final endpoint = await _resolve(deviceId, password).timeout(kControlBudget);
    final transport = _build(endpoint, deviceId, password);
    final data = await transport
        .control(deviceId, channel, state, opId: opId, identityVerified: _canSkipVerify(deviceId))
        .timeout(kControlBudget);
    _learnEndpoint(deviceId, endpoint, data);
    _log('control ok for $deviceId ch$channel=$state via $endpoint');
    return parseRelayStatus(data, source: DeviceTransportSource.local, seq: seq);
  }

  Future<bool> probeAp(String deviceId, {String? password}) async {
    final ap = _build(kApAddress, deviceId, password);
    return ap.verifyIdentity();
  }

  Future<String> runDeviceCommand(String deviceId, String command, {String? password}) async {
    final endpoint = await _resolve(deviceId, password).timeout(kControlBudget);
    final transport = _build(endpoint, deviceId, password);
    if (!await transport.verifyIdentity()) {
      throw const DeviceTransportException(
        'The local device identity could not be verified.',
        kind: TransportFailureKind.logical,
      );
    }
    final fetch = _fetch ?? defaultTasmotaCmFetcher;
    final body = await fetch(endpoint, command, password: password).timeout(kControlBudget);
    _log('device command ok for $deviceId: ${command.split('%20').first}');
    return body;
  }

  Future<void> enableHttpApi(String deviceId, {String? password}) async {
    final transport = _build(kApAddress, deviceId, password, bootstrap: true);
    await transport.enableHttpApi().timeout(kControlBudget);
    if (!await transport.verifyHttpApiEnabled()) {
      throw const DeviceTransportException(
        'The device did not confirm its HTTP API is enabled.',
        kind: TransportFailureKind.logical,
      );
    }
    _warmEndpoints[deviceId] = kApAddress;
    _warmVerifiedAt[deviceId] = DateTime.now();
    _identityTrustedAt[deviceId] = DateTime.now();
    await _storeEndpoint(deviceId, kApAddress);
    _log('HTTP API enabled for $deviceId');
  }
}
