import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'device_transport.dart';
import 'provisioning_service.dart';

/// Bounded HTTP budgets for direct Tasmota calls. A LAN device must never hold
/// a relay tap hostage: connect and read are each capped, discovery (in the
/// [locator]) is capped separately.
const Duration kLocalConnectTimeout = Duration(seconds: 2);
const Duration kLocalReadTimeout = Duration(seconds: 2);

/// Sends a single `cm?cmnd=<command>` GET to [address] and returns the raw
/// response body. Injectable so unit tests never need hardware or a real
/// network. All low-level failures are converted into availability
/// [DeviceTransportException]s, never raw socket exceptions.
typedef TasmotaCmFetcher = Future<String> Function(
  String address,
  String command, {
  String? password,
});

/// Production fetcher: dart:io HttpClient with a bounded connect timeout and
/// read timeouts on both the response headers and the body.
Future<String> defaultTasmotaCmFetcher(
  String address,
  String command, {
  String? password,
}) async {
  final client = HttpClient()
    ..connectionTimeout = kLocalConnectTimeout
    ..autoUncompress = true;
  try {
    final request = await client.getUrl(
      Uri.parse('http://$address/cm?cmnd=$command'),
    );
    // Tasmota's WebPassword uses HTTP Basic auth with the "admin" user.
    if (password != null && password.isNotEmpty) {
      final cred = base64Encode(utf8.encode('admin:$password'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Basic $cred');
    }
    final response = await request.close().timeout(kLocalReadTimeout);
    if (response.statusCode != 200) {
      throw DeviceTransportException(
        'The local device returned HTTP ${response.statusCode}.',
      );
    }
    final body =
        await response.transform(utf8.decoder).join().timeout(kLocalReadTimeout);
    return body;
  } on TimeoutException catch (e) {
    throw DeviceTransportException(
      'The device did not respond in time.',
      cause: e,
    );
  } on SocketException catch (e) {
    throw DeviceTransportException(
      'Could not reach the device on the local network.',
      cause: e,
    );
  } finally {
    client.close(force: true);
  }
}

/// Direct HTTP transport to an already-provisioned Tasmota device on the LAN.
///
/// The [address] (an IP) is ONLY a temporary locator and is never trusted on
/// its own. Identity is the canonical MAC == [deviceId], which is re-verified
/// through `Status 5` before EACH status read and relay command. A repurposed
/// or foreign device occupying the address is detected by `normalizeMac()`
/// comparison and rejected before any command is sent.
class LocalDeviceTransport implements DeviceTransport {
  LocalDeviceTransport({
    required this.address,
    required this.deviceId,
    this.password,
    TasmotaCmFetcher? fetcher,
    this.connectTimeout = kLocalConnectTimeout,
    this.readTimeout = kLocalReadTimeout,
  }) : _fetcher = fetcher ?? defaultTasmotaCmFetcher;

  final String address;
  final String deviceId;
  final String? password;
  final TasmotaCmFetcher _fetcher;

  /// Injected timeouts; kept as fields so the bounded-timeout behavior is
  /// unit-testable without waiting for the production constants.
  final Duration connectTimeout;
  final Duration readTimeout;

  @override
  DeviceTransportSource get source => DeviceTransportSource.local;

  Future<String> _cm(String command) async {
    try {
      return await _fetcher(address, command, password: password)
          .timeout(readTimeout);
    } on TimeoutException catch (e) {
      throw DeviceTransportException(
        'The device did not respond in time.',
        cause: e,
      );
    }
  }

  /// True when the device at [address] truthfully reports the expected
  /// canonical MAC. Called by the repository before caching and by every
  /// [getStatus]/[control] call. This is a pure probe: any failure — unreachable
  /// host, timeout, foreign identity — just means "not our device here".
  Future<bool> verifyIdentity() async {
    try {
      await _verifyIdentity();
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _verifyIdentity() async {
    final body = await _cm('Status%205');
    final mac = normalizeMac(extractMacFromStatus5(body));
    if (mac == null || mac != deviceId) {
      throw const DeviceTransportException(
        'The local device identity could not be verified.',
        kind: TransportFailureKind.logical,
      );
    }
  }

  void _assertTarget(String requested) {
    if (requested != deviceId) {
      throw const DeviceTransportException(
        'Mismatched target device.',
        kind: TransportFailureKind.logical,
      );
    }
  }

  @override
  Future<Map<String, dynamic>> getStatus(String deviceId) async {
    _assertTarget(deviceId);
    await _verifyIdentity();
    final body = await _cm('State');
    return parseLocalState(body);
  }

  @override
  Future<Map<String, dynamic>> control(
    String deviceId,
    int channel,
    String state,
  ) async {
    _assertTarget(deviceId);
    await _verifyIdentity();
    final body = await _cm('Power$channel%20${state.toUpperCase()}');
    return parseLocalState(body);
  }
}

/// Extracts the reported MAC from a Tasmota `Status 5` response, however it is
/// wrapped. Tasmota nests it as `{"StatusNET":{"Mac":"34:98:7A:C3:03:04",...}}`,
/// but the `/cm` web layer may add an outer `{"Command":{...}}`, so the whole
/// tree is walked. Returns null (never throws) for empty/non-JSON bodies.
String? extractMacFromStatus5(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;
  try {
    return _findMacValue(jsonDecode(trimmed));
  } catch (_) {
    return null;
  }
}

String? _findMacValue(Object? node) {
  if (node is Map) {
    for (final entry in node.entries) {
      if (entry.key is String &&
          (entry.key as String).toLowerCase() == 'mac' &&
          entry.value is String) {
        return entry.value as String;
      }
    }
    for (final v in node.values) {
      final found = _findMacValue(v);
      if (found != null) return found;
    }
    return null;
  }
  if (node is List) {
    for (final v in node) {
      final found = _findMacValue(v);
      if (found != null) return found;
    }
  }
  return null;
}

/// Converts a Tasmota `State` / `Power` response body into the logical status
/// shape the devices page already consumes: `online: true` plus the `POWERn`
/// channels as 'ON'/'OFF' (single-relay `POWER` included). Channels absent from
/// the response are simply absent — the page treats any channel key that isn't
/// 'ON' as OFF, matching how a fresh cloud status behaves.
Map<String, dynamic> parseLocalState(String body) {
  final power = <String, dynamic>{};
  final trimmed = body.trim();
  if (trimmed.isNotEmpty) {
    try {
      _collectPowerKeys(jsonDecode(trimmed), power);
    } catch (_) {
      // Not JSON (e.g. an error page): channels simply stay absent.
    }
  }
  return <String, dynamic>{'online': true, ...power};
}

void _collectPowerKeys(Object? node, Map<String, dynamic> out) {
  if (node is Map) {
    for (final entry in node.entries) {
      final key = entry.key is String ? (entry.key as String).toUpperCase() : null;
      if (key != null && key.startsWith('POWER') && entry.value is String) {
        out[key] = entry.value as String;
      }
    }
    for (final v in node.values) {
      _collectPowerKeys(v, out);
    }
  } else if (node is List) {
    for (final v in node) {
      _collectPowerKeys(v, out);
    }
  }
}