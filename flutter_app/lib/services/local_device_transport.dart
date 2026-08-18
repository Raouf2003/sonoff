import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'device_transport.dart';
import 'local_ip.dart';
import 'provisioning_service.dart';

/// Bounded HTTP budgets for direct Tasmota calls. A LAN device must never hold
/// a relay tap hostage: connect and read are each capped, discovery (in the
/// [locator]) is capped separately.
const Duration kLocalConnectTimeout = Duration(seconds: 2);
const Duration kLocalReadTimeout = Duration(seconds: 2);

/// Sends a single `cm?cmnd=<command>` GET to [address] and returns the raw
/// response body. Injectable so unit tests never need hardware or a real
/// network. All low-level failures are converted into availability
/// [DeviceTransportException]s (with the ORIGINAL error preserved as
/// `cause`), never raw socket exceptions.
///
/// [referer] is a per-request override for the `Referer` header. It is only
/// sent by the SetOption128 bootstrap (Tasmota requires a device-matching
/// referer while SO128 is OFF); the normal status/control path never sends it.
typedef TasmotaCmFetcher = Future<String> Function(
  String address,
  String command, {
  String? password,
  String? deviceId,
  String? referer,
});

/// Structured DEBUG-ONLY diagnostic for a local HTTP attempt. Logs only
/// non-sensitive data: deviceId, endpoint, command, status, elapsed time and
/// the original error's type/message/OS error. Credentials, Authorization
/// headers, JWTs and passwords are never passed in or logged.
void _logLocalHttp({
  required String deviceId,
  required String endpoint,
  required String operation,
  int? statusCode,
  Duration? elapsed,
  Object? error,
}) {
  if (!kDebugMode) return;
  final cause = error is DeviceTransportException ? error.cause ?? error : error;
  final osError = cause is SocketException ? cause.osError : null;
  final buffer = StringBuffer('[LOCAL][HTTP]')
    ..write(' device=$deviceId')
    ..write(' endpoint=$endpoint')
    ..write(' operation=$operation')
    ..write(' status=${statusCode ?? '-'}')
    ..write(
      ' elapsed=${elapsed != null ? '${elapsed.inMilliseconds}ms' : '-'}',
    )
    ..write(
      ' type=${cause?.runtimeType ?? error?.runtimeType ?? '-'}',
    )
    ..write(
      ' message=${_logSafe(cause?.toString() ?? error?.toString() ?? '-')}',
    );
  if (osError != null) {
    buffer
      ..write(' osError=${osError.errorCode}')
      ..write(' osMessage=${_logSafe(osError.message)}');
  }
  debugPrint(buffer.toString());
}

/// Keeps log lines free of anything that could carry credentials. Currently a
/// passthrough guard: callers must never pass headers/credentials; this exists
/// as the single choke point if a future caller is tempted to.
String _logSafe(String value) => value;

/// True when a `/cm` response body is Tasmota's referer-denial warning
/// (`{"WARNING":"Referer '...' denied. Use 'SO128 1' ..."}`) — i.e. the
/// SetOption128 enable was NOT accepted. Anything else (a normal SetOption128
/// echo, or a non-JSON body) is not a denial, so only an explicit rejection
/// fails the automatic bootstrap.
bool _isRefererDenied(String body) {
  return body.toLowerCase().contains('denied');
}

/// Normalizes a raw address (from the cache, mDNS, or telemetry) into an
/// `host[:port]` form safe for `http://$address/...`. Strips any scheme that
/// slipped in, removes trailing slashes, and brackets IPv6 (encoding a zone
/// `%`). An IPv4:port is left untouched.
String _normalizeEndpoint(String raw) {
  var s = raw.trim();
  final scheme = s.indexOf('://');
  if (scheme >= 0) s = s.substring(scheme + 3);
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty) return s;
  final colonCount = ':'.allMatches(s).length;
  if (colonCount > 1 && !s.startsWith('[')) {
    s = '[${s.replaceAll('%', '%25')}]';
  }
  return s;
}

/// Production fetcher: dart:io HttpClient with a bounded connect timeout and
/// read timeouts on both the response headers and the body. Every failure is
/// wrapped in a [DeviceTransportException] whose `cause` keeps the original
/// error (SocketException / TimeoutException / HttpException / FormatException)
/// so debug logs can reveal the exact underlying fault.
Future<String> defaultTasmotaCmFetcher(
  String address,
  String command, {
  String? password,
  String? deviceId,
  String? referer,
  Duration? connectTimeout,
  Duration? readTimeout,
}) async {
  final connectBudget = connectTimeout ?? kLocalConnectTimeout;
  final readBudget = readTimeout ?? kLocalReadTimeout;
  final client = HttpClient()
    ..connectionTimeout = connectBudget
    ..autoUncompress = true;
  final stopwatch = Stopwatch()..start();
  final endpoint = address;
  final who = deviceId ?? '-';
  try {
    final request = await client.getUrl(
      Uri.parse('http://$address/cm?cmnd=$command'),
    );
    // Tasmota's WebPassword uses HTTP Basic auth with the "admin" user.
    if (password != null && password.isNotEmpty) {
      final cred = base64Encode(utf8.encode('admin:$password'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Basic $cred');
    }
    // While SetOption128 is OFF Tasmota rejects referer-less HTTP API commands
    // (`Referer '' denied. Use 'SO128 1' ...`). The automatic SO128 bootstrap
    // therefore sends a Referer matching the device's own address — same header
    // shape the built-in console produces — so the enable request is accepted
    // in the very state it fixes. Once SO128 is ON, referer-less commands
    // (status/control) are accepted; no other request sends a referer.
    if (referer != null && referer.isNotEmpty) {
      request.headers.set(HttpHeaders.refererHeader, referer);
    }
    final response = await request.close().timeout(readBudget);
    if (response.statusCode != 200) {
      final status = response.statusCode;
      _logLocalHttp(
        deviceId: who,
        endpoint: endpoint,
        operation: command,
        statusCode: status,
        elapsed: stopwatch.elapsed,
      );
      throw DeviceTransportException(
        'The local device returned HTTP $status.',
        cause: HttpException('HTTP $status'),
      );
    }
    final body =
        await response.transform(utf8.decoder).join().timeout(readBudget);
    _logLocalHttp(
      deviceId: who,
      endpoint: endpoint,
      operation: command,
      statusCode: 200,
      elapsed: stopwatch.elapsed,
    );
    return body;
  } on TimeoutException catch (e) {
    _logLocalHttp(
      deviceId: who,
      endpoint: endpoint,
      operation: command,
      elapsed: stopwatch.elapsed,
      error: e,
    );
    throw DeviceTransportException(
      'The device did not respond in time.',
      cause: e,
    );
  } on SocketException catch (e) {
    _logLocalHttp(
      deviceId: who,
      endpoint: endpoint,
      operation: command,
      elapsed: stopwatch.elapsed,
      error: e,
    );
    throw DeviceTransportException(
      'Could not reach the device on the local network.',
      cause: e,
    );
  } on DeviceTransportException {
    rethrow; // already logged by the status branch above
  } on Object catch (e) {
    // e.g. a FormatException from a malformed URL or an HttpException from the
    // socket layer: wrap with the original preserved for diagnostics.
    _logLocalHttp(
      deviceId: who,
      endpoint: endpoint,
      operation: command,
      elapsed: stopwatch.elapsed,
      error: e,
    );
    throw DeviceTransportException(
      'The local request failed.',
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
    required String address,
    required this.deviceId,
    this.password,
    TasmotaCmFetcher? fetcher,
    this.connectTimeout = kLocalConnectTimeout,
    this.readTimeout = kLocalReadTimeout,
  })  : address = _normalizeEndpoint(address),
        _fetcher = fetcher ?? defaultTasmotaCmFetcher;

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

  Future<String> _cm(String command, {String? referer}) async {
    // Last-line guard: an unusable address (e.g. `0.0.0.0`, multicast) can
    // never reach HttpClient, even if one was somehow cached before validation.
    if (!isUsableHttpHost(address)) {
      const failure = DeviceTransportException(
        'The local device address is invalid.',
        cause: FormatException('Invalid local endpoint'),
      );
      _logLocalHttp(
        deviceId: deviceId,
        endpoint: address,
        operation: command,
        error: failure,
      );
      throw failure;
    }
    final stopwatch = Stopwatch()..start();
    try {
      return await _fetcher(
        address,
        command,
        password: password,
        deviceId: deviceId,
        referer: referer,
      ).timeout(readTimeout);
    } on TimeoutException catch (e) {
      // The whole local attempt (connect + headers + body) exceeded the budget.
      _logLocalHttp(
        deviceId: deviceId,
        endpoint: address,
        operation: command,
        elapsed: stopwatch.elapsed,
        error: e,
      );
      throw DeviceTransportException(
        'The device did not respond in time.',
        cause: e,
      );
    } on DeviceTransportException {
      rethrow; // the fetcher has already logged its classified failure
    } on Object catch (e) {
      // A raw escape from a custom/injected fetcher (e.g. a test fake that
      // throws a bare SocketException) must keep the original error as cause.
      _logLocalHttp(
        deviceId: deviceId,
        endpoint: address,
        operation: command,
        elapsed: stopwatch.elapsed,
        error: e,
      );
      throw DeviceTransportException(
        'Local HTTP request failed.',
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

  /// Like [verifyIdentity] but distinguishes WHY the probe failed, so discovery
  /// can keep a transiently-unreachable candidate while dropping a repurposed
  /// address (identity mismatch).
  Future<LocalIdentityCheck> checkIdentity() async {
    try {
      await _verifyIdentity();
      return LocalIdentityCheck.verified;
    } on DeviceTransportException catch (e) {
      return e.kind == TransportFailureKind.logical
          ? LocalIdentityCheck.mismatch
          : LocalIdentityCheck.unavailable;
    } on Object {
      return LocalIdentityCheck.unavailable;
    }
  }

  Future<void> _verifyIdentity() async {
    final body = await _cm('Status%205');
    final mac = normalizeMac(extractMacFromStatus5(body));
    debugPrint('[LOCAL] candidate MAC: $mac, expected deviceId: $deviceId');
    if (mac == null || mac != deviceId) {
      debugPrint('[LOCAL] identity MISMATCH at $address');
      throw const DeviceTransportException(
        'The local device identity could not be verified.',
        kind: TransportFailureKind.logical,
      );
    }
    debugPrint('[LOCAL] identity MATCH at $address');
  }

  void _assertTarget(String requested) {
    if (requested != deviceId) {
      throw const DeviceTransportException(
        'Mismatched target device.',
        kind: TransportFailureKind.logical,
      );
    }
  }

  /// Automatically enables Tasmota's local HTTP API (`SetOption128 1`) so
  /// direct `/cm` relay commands from the app are accepted WITHOUT a browser
  /// console command. Idempotent: sending `SetOption128 1` when it is already
  /// enabled succeeds harmlessly, which is why this is safe to run on every
  /// claim.
  ///
  /// The single request deliberately carries a `Referer` matching the device's
  /// own address (the same header shape the built-in console sends). While
  /// SetOption128 is OFF Tasmota rejects referer-less HTTP API commands — the
  /// exact state this fixes — so the bootstrap must present a valid referer.
  /// Once enabled, the existing referer-less status/control commands are
  /// accepted.
  ///
  /// Any failure (unreachable, timeout, denied, invalid address) propagates as
  /// a [DeviceTransportException] so the caller can decide whether local
  /// control is ready; it never affects the cloud claim.
  Future<void> enableHttpApi() async {
    final body = await _cm('SetOption128%201', referer: 'http://$address/');
    if (_isRefererDenied(body)) {
      const failure = DeviceTransportException(
        'The local device rejected the HTTP API enable command.',
        cause: FormatException('Referer denied'),
      );
      _logLocalHttp(
        deviceId: deviceId,
        endpoint: address,
        operation: 'SetOption128%201',
        error: failure,
      );
      throw failure;
    }
    debugPrint('[LOCAL] HTTP API enabled (SetOption128) at $address');
  }

  @override
  Future<Map<String, dynamic>> getStatus(
    String deviceId, {
    bool identityVerified = false,
  }) async {
    _assertTarget(deviceId);
    // Identity is verified by discovery (or a fresh cached verification) before
    // any endpoint is returned. [identityVerified] lets the repository reuse
    // that just-completed probe so a cold LAN transition does not pay a second,
    // redundant `Status 5` round trip before the very first local read.
    if (!identityVerified) await _verifyIdentity();
    final body = await _cm('State');
    return parseLocalState(body);
  }

  @override
  Future<Map<String, dynamic>> control(
    String deviceId,
    int channel,
    String state, {
    String? opId,
    bool identityVerified = false,
  }) async {
    _assertTarget(deviceId);
    if (!identityVerified) await _verifyIdentity();
    final expected = state.toUpperCase();
    // Send the command. If this itself fails the device was never reached
    // (availability) — the caller may fall back to cloud.
    await _cm('Power$channel%20$expected');
    // Read back the device's resulting state and CONFIRM it matches. The UI
    // must never treat the tap as fact; only a device report may.
    String body;
    try {
      body = await _cm('State');
    } on Object {
      throw const DeviceTransportException(
        'The device did not confirm the command before timing out.',
        kind: TransportFailureKind.logical,
        code: 'UNCONFIRMED',
      );
    }
    final status = parseLocalState(body);
    final reported = status['POWER$channel'] ?? status['POWER'];
    if (reported != expected) {
      throw DeviceTransportException(
        'The device reported $reported instead of $expected.',
        kind: TransportFailureKind.logical,
        code: 'UNCONFIRMED',
      );
    }
    return status;
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
/// channels as 'ON'/'OFF' (single-relay `POWER` included), and a per-channel
/// `channels` map with a receive-time `updatedAt` so downstream staleness
/// checks can treat a fresh LAN read as authoritative. Channels absent from
/// the response are simply absent — the page treats any channel key that isn't
/// 'ON' as OFF, matching how a fresh cloud status behaves.
///
/// When the response carries the device's LAN address (`IPAddress`), it is
/// surfaced as `ipAddress` so the repository can refresh its discovery cache
/// when the device's DHCP lease changes.
Map<String, dynamic> parseLocalState(String body) {
  final power = <String, dynamic>{};
  String? ipAddress;
  final trimmed = body.trim();
  if (trimmed.isNotEmpty) {
    try {
      final decoded = jsonDecode(trimmed);
      _collectPowerKeys(decoded, power);
      final ip = _findStringValue(decoded, 'ipaddress');
      if (ip != null && ip.isNotEmpty) ipAddress = ip;
    } catch (_) {
      // Not JSON (e.g. an error page): channels simply stay absent.
    }
  }
  final now = DateTime.now().toIso8601String();
  final channels = <String, dynamic>{};
  for (final e in power.entries) {
    final ch = _channelNumberFromKey(e.key);
    if (ch != null) {
      channels[ch.toString()] = {
        'state': e.value,
        'updatedAt': now,
      };
    }
  }
  return <String, dynamic>{
    'online': true,
    ...power,
    'ipAddress': ?ipAddress,
    'channels': channels,
  };
}

/// First string value whose key matches [keyLower] (case-insensitive), found
/// anywhere in the decoded JSON tree. Returns null when absent.
String? _findStringValue(Object? node, String keyLower) {
  if (node is Map) {
    for (final entry in node.entries) {
      if (entry.key is String &&
          (entry.key as String).toLowerCase() == keyLower &&
          entry.value is String) {
        return entry.value as String;
      }
    }
    for (final v in node.values) {
      final found = _findStringValue(v, keyLower);
      if (found != null) return found;
    }
  } else if (node is List) {
    for (final v in node) {
      final found = _findStringValue(v, keyLower);
      if (found != null) return found;
    }
  }
  return null;
}

/// 'POWER3' -> 3, 'POWER' -> 1, anything else -> null.
int? _channelNumberFromKey(String key) {
  final upper = key.toUpperCase();
  if (upper == 'POWER') return 1;
  if (upper.startsWith('POWER')) {
    final digits = upper.substring(5);
    if (digits.isEmpty) return 1;
    return int.tryParse(digits);
  }
  return null;
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