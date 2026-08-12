import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'api_service.dart';

/// Which transport produced the latest result. Used ONLY for the optional,
/// subtle connection indicator on the devices page — the UI decision logic
/// never branches on it.
enum DeviceTransportSource { cloud, local }

/// Category of a [DeviceTransportException].
enum TransportFailureKind {
  /// The transport itself is unavailable (no network, timeout, backend/server
  /// failure, LAN device unreachable). Falling back to another transport is
  /// allowed.
  availability,

  /// The request was rejected as invalid (4xx backend errors, identity
  /// mismatch, ownership/validation). It must be surfaced, never silently
  /// rerouted to another transport.
  logical,
}

/// Transport-level failure carrying a stable category so the repository can
/// decide whether a fallback is allowed. The message is always human-readable.
class DeviceTransportException implements Exception {
  const DeviceTransportException(
    this.message, {
    this.kind = TransportFailureKind.availability,
    this.cause,
  });

  final String message;
  final TransportFailureKind kind;
  final Object? cause;

  @override
  String toString() => message;
}

/// True when [error] represents a transport that is currently UNAVAILABLE
/// rather than a request the transport rejected.
///
/// The cloud→local fallback is allowed ONLY for these cases:
///  * no network / connection failure / timeout / backend 5xx on the cloud path
///  * a 409 WITHOUT a machine `code` — the backend's "device is not connected
///    or is powered off": the device is unavailable AT the cloud, so the LAN
///    must get a chance before the app declares it offline
///  * a local transport being unreachable
///
/// Every logical rejection — 400/401/403/404 ownership & validation, coded 409
/// duplicates, command conflicts, MAC identity mismatches — is NOT availability
/// and must surface.
bool isAvailabilityFailure(Object error) {
  if (error is DeviceTransportException) {
    return error.kind == TransportFailureKind.availability;
  }
  if (error is ApiException) {
    // ApiService maps transport-level failures (timeout / no network) to
    // ApiExceptions WITHOUT a statusCode; anything with an HTTP status is a
    // classified backend response. Only server failures (5xx) and the
    // device-offline 409 (see above) count as availability for fallback.
    if (error.statusCode == null) return true;
    if (error.statusCode! >= 500) return true;
    if (error.statusCode == 409 && error.code == null) return true;
    return false;
  }
  return error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException;
}

/// Small transport abstraction. [DevicesPage] talks to a
/// [DeviceRepositoryService], which picks either a cloud or a local transport —
/// the UI never knows which one ran.
abstract class DeviceTransport {
  /// Stable source used for the subtle connection indicator.
  DeviceTransportSource get source;

  /// Relay status in the shape the devices page already consumes
  /// (`online: true` plus `POWERn` as 'ON'/'OFF' for every channel).
  Future<Map<String, dynamic>> getStatus(String deviceId);

  /// Turn relay [channel] (1-based) to [state] ('ON'/'OFF').
  Future<Map<String, dynamic>> control(
    String deviceId,
    int channel,
    String state,
  );
}