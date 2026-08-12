import 'api_service.dart';
import 'device_transport.dart';

/// The cloud/backend path, wrapping the existing [ApiService] behavior 1:1.
///
/// Authentication, ACK semantics, status shapes and error classification are
/// untouched: this transport is bit-equivalent to the path the app used before
/// Local Mode existed, and it remains the PRIMARY transport. The repository
/// only consults a local transport when this one is provably unavailable.
class CloudDeviceTransport implements DeviceTransport {
  CloudDeviceTransport({ApiService? api}) : _api = api ?? ApiService();

  final ApiService _api;

  @override
  DeviceTransportSource get source => DeviceTransportSource.cloud;

  /// The registered device documents (display metadata, ownership-checked by
  /// the backend). Guarded to map-like entries only, matching what the devices
  /// page consumes.
  Future<List<Map<String, dynamic>>> getDevices() async {
    final raw = await _api.getDevices();
    return raw.whereType<Map<String, dynamic>>().toList();
  }

  @override
  Future<Map<String, dynamic>> getStatus(String deviceId) {
    return _api.getStatus(deviceId);
  }

  @override
  Future<Map<String, dynamic>> control(
    String deviceId,
    int channel,
    String state,
  ) {
    return _api.control(deviceId, channel, state);
  }
}