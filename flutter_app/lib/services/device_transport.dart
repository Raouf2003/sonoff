import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'api_service.dart';

/// Which transport produced the latest result. Used ONLY for the optional,
/// subtle connection indicator on the devices page — the UI decision logic
/// never branches on it.
enum DeviceTransportSource { cloud, local }

/// A single channel's reported state. `state` is `'ON'`/`'OFF'` only when the
/// DEVICE itself reported it; `null` means UNKNOWN (never observed, or the
/// report was not confirmed). `updatedAt` is the device/server receive-time
/// when available, and is used to reject stale reports.
class ChannelReport {
  final String? state;
  final DateTime? updatedAt;
  const ChannelReport(this.state, {this.updatedAt});

  bool get isUnknown => state == null || state == 'UNKNOWN';
  bool get isOn => state == 'ON';
}

/// Result of a status read or a relay command: the device's reported state.
/// `channels` is keyed by 1-based channel number. The UI must only commit a
/// channel's ON/OFF from a non-null `state` here — never from the user's tap
/// or from a bare command ACK.
class RelayStatusResult {
  final bool online;
  final Map<int, ChannelReport> channels;
  final DeviceTransportSource source;
  final int seq;
  const RelayStatusResult({
    required this.online,
    required this.channels,
    required this.source,
    required this.seq,
  });
}

/// Normalizes a transport response map (the canonical `channels` shape, or the
/// legacy flat `POWERn` keys) into [RelayStatusResult]. `seq` is the
/// monotonic operation sequence assigned by the caller.
RelayStatusResult parseRelayStatus(
  Map<String, dynamic> data, {
  required DeviceTransportSource source,
  required int seq,
}) {
  final channels = <int, ChannelReport>{};

  final rawChannels = data['channels'];
  if (rawChannels is Map) {
    for (final e in rawChannels.entries) {
      final idx = int.tryParse('${e.key}');
      if (idx == null || idx < 1) continue;
      final c = e.value;
      String? state;
      DateTime? ts;
      if (c is Map) {
        final s = c['state'];
        state = s is String ? s : null;
        final ua = c['updatedAt'];
        ts = ua is String ? DateTime.tryParse(ua) : null;
      }
      channels[idx] = ChannelReport(state == 'UNKNOWN' ? null : state,
          updatedAt: ts);
    }
  }

  // Legacy fallback: flat `POWERn` keys (transports/tests that don't emit the
  // `channels` map). A 'UNKNOWN' flat value is treated as unknown.
  if (channels.isEmpty) {
    for (var i = 1; i <= 16; i++) {
      final v = data['POWER$i'];
      if (v is String) {
        channels[i] = ChannelReport(v == 'UNKNOWN' ? null : v);
      }
    }
    final bare = data['POWER'];
    if (bare is String && !channels.containsKey(1)) {
      channels[1] = ChannelReport(bare == 'UNKNOWN' ? null : bare);
    }
  }

  return RelayStatusResult(
    online: data['online'] == true,
    channels: channels,
    source: source,
    seq: seq,
  );
}

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

/// Outcome of a local identity probe (`Status 5` MAC check). Lets discovery
/// distinguish "that IP no longer answers" (keep a cloud-learned candidate as
/// a hint) from "that IP belongs to a different device" (discard it).
enum LocalIdentityCheck {
  /// The box at the address truthfully reported the expected MAC.
  verified,

  /// The address could not be reached (off, network change, timeout).
  unavailable,

  /// The address answered but with a different MAC — the IP was repurposed.
  mismatch,
}

/// Transport-level failure carrying a stable category so the repository can
/// decide whether a fallback is allowed. The message is always human-readable.
class DeviceTransportException implements Exception {
  const DeviceTransportException(
    this.message, {
    this.kind = TransportFailureKind.availability,
    this.cause,
    this.code,
  });

  final String message;
  final TransportFailureKind kind;
  final Object? cause;

  /// Stable machine-readable discriminator (e.g. `UNCONFIRMED`) so callers
  /// can branch without parsing display text.
  final String? code;

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

  /// Turn relay [channel] (1-based) to [state] ('ON'/'OFF'). [opId] is the
  /// per-tap command correlation id threaded to the backend for the end-to-end
  /// timing timeline; transports that ignore it still complete identically.
  Future<Map<String, dynamic>> control(
    String deviceId,
    int channel,
    String state, {
    String? opId,
  });
}