import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'auth_service.dart';

const String kBaseUrl = 'https://sonoff-3na2.onrender.com';

/// Upper bound for any single HTTP call. Prevents a hung socket from leaving
/// the UI in an endless spinner.
const Duration kApiTimeout = Duration(seconds: 15);

/// HTTP error carrying the status code so callers can give phase-appropriate
/// feedback instead of a generic "make sure you have internet access". When the
/// backend also returns a machine-readable `code`, it is preserved so callers
/// can distinguish e.g. DEVICE_ALREADY_REGISTERED (terminal) from
/// DEVICE_NOT_SEEN (recoverable) without parsing display text.
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.code});
  final String message;
  final int? statusCode;
  final String? code;

  @override
  String toString() => message;
}

/// Result of the provisioning pre-flight duplicate check: whether a given
/// canonical MAC is already registered to the current user, to another user, or
/// not registered at all. Read-only and non-authoritative - the real duplicate /
/// ownership enforcement stays in POST /api/devices/provision.
enum DeviceDuplicateStatus {
  /// The MAC is already a device in the current user's account.
  mine,

  /// The MAC is already registered to another account (ownership never disclosed).
  others,

  /// The MAC is not registered to any account yet.
  notFound,
}

/// Decision the provisioning wizard takes from a pre-flight duplicate-check
/// result. A `null` status (unreachable backend / timeout) is treated exactly
/// like notFound - continue provisioning, never block.
enum PreflightDecision {
  /// Already in the current user's account: stop and offer Remove Device.
  stopMine,

  /// Registered to another account: stop, no Remove Device.
  stopOthers,

  /// Not registered (or the backend was unreachable): continue normally.
  continueProvisioning,
}

PreflightDecision decidePreflight(DeviceDuplicateStatus? status) {
  switch (status) {
    case DeviceDuplicateStatus.mine:
      return PreflightDecision.stopMine;
    case DeviceDuplicateStatus.others:
      return PreflightDecision.stopOthers;
    case DeviceDuplicateStatus.notFound:
    case null:
      return PreflightDecision.continueProvisioning;
  }
}

class ApiService {
  final AuthService _auth = AuthService();

  /// Registered by the app shell to log the user out when any request returns
  /// 401 (missing/expired/invalid token). No-op by default.
  static void Function()? onUnauthorized;

  Future<Map<String, String>> _headers() async {
    final token = await _auth.getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // Runs a request under a timeout and maps low-level failures (timeout, no
  // network, TLS handshake) to a classified ApiException so callers never see
  // raw transport exceptions or a permanently-pending future.
  Future<http.Response> _send(Future<http.Response> Function() run) async {
    try {
      return await run().timeout(kApiTimeout);
    } on TimeoutException {
      throw const ApiException(
        'The request timed out. Please try again.',
        code: 'TIMEOUT',
      );
    } on SocketException {
      throw const ApiException(
        'Could not reach the server. Check your connection.',
        code: 'NETWORK_ERROR',
      );
    } on http.ClientException {
      throw const ApiException(
        'Could not reach the server. Check your connection.',
        code: 'NETWORK_ERROR',
      );
    }
  }

  // Decode a JSON-object response or throw a classified ApiException.
  Map<String, dynamic> _checkObject(
    http.Response res,
    List<int> okCodes,
    String fallbackMessage,
  ) {
    if (okCodes.contains(res.statusCode)) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    _notifyUnauthorized(res.statusCode);
    Map<String, dynamic> body = const {};
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {}
    throw ApiException(
      (body['error'] as String?) ??
          (body['message'] as String?) ??
          fallbackMessage,
      statusCode: res.statusCode,
      code: body['code'] as String?,
    );
  }

  // Decode a JSON-array response or throw a classified ApiException.
  List<dynamic> _checkList(http.Response res, String fallbackMessage) {
    if (res.statusCode == 200) {
      return jsonDecode(res.body) as List<dynamic>;
    }
    _notifyUnauthorized(res.statusCode);
    Map<String, dynamic> body = const {};
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {}
    throw ApiException(
      (body['error'] as String?) ??
          (body['message'] as String?) ??
          fallbackMessage,
      statusCode: res.statusCode,
      code: body['code'] as String?,
    );
  }

  void _notifyUnauthorized(int statusCode) {
    if (statusCode == 401 && ApiService.onUnauthorized != null) {
      ApiService.onUnauthorized!();
    }
  }

  Future<http.Response> post(String path, Map<String, dynamic> body) async {
    final headers = await _headers();
    return _send(
      () => http.post(
        Uri.parse('$kBaseUrl$path'),
        headers: headers,
        body: jsonEncode(body),
      ),
    );
  }

  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    final headers = await _headers();
    var uri = Uri.parse('$kBaseUrl$path');
    if (query != null) {
      uri = uri.replace(queryParameters: query);
    }
    return _send(() => http.get(uri, headers: headers));
  }

  Future<http.Response> put(String path, Map<String, dynamic> body) async {
    final headers = await _headers();
    return _send(
      () => http.put(
        Uri.parse('$kBaseUrl$path'),
        headers: headers,
        body: jsonEncode(body),
      ),
    );
  }

  Future<http.Response> patch(String path, Map<String, dynamic> body) async {
    final headers = await _headers();
    return _send(
      () => http.patch(
        Uri.parse('$kBaseUrl$path'),
        headers: headers,
        body: jsonEncode(body),
      ),
    );
  }

  Future<http.Response> delete(String path) async {
    final headers = await _headers();
    return _send(() => http.delete(Uri.parse('$kBaseUrl$path'), headers: headers));
  }

  Future<Map<String, dynamic>> signup(String username, String password) async {
    final res = await post('/api/auth/signup', {
      'username': username,
      'password': password,
    });
    return _checkObject(res, const [201], 'Signup failed');
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    final res = await post('/api/auth/login', {
      'username': username,
      'password': password,
    });
    return _checkObject(res, const [200], 'Login failed');
  }

  Future<List<dynamic>> getDevices() async {
    final res = await get('/api/devices');
    return _checkList(res, 'Failed to fetch devices');
  }

  // Provisioning: registers a physical device directly from its canonical MAC
  // (== deviceId == MQTT topic). There is no session or claim token - the MAC
  // was read from the device during the offline AP phase, and the backend only
  // accepts it once the device has actually been observed on MQTT (possession
  // gate) and the MAC is not already registered. Duplicates are rejected with
  // a machine-readable code (DEVICE_ALREADY_EXISTS / DEVICE_ALREADY_REGISTERED).
  Future<Map<String, dynamic>> provisionDevice({
    required String deviceId,
    required String name,
    required int channels,
  }) async {
    final res = await post('/api/devices/provision', {
      'deviceId': deviceId,
      'name': name,
      'channels': channels,
    });
    return _checkObject(res, const [201], 'Could not register the device');
  }

  // Whether a device has been observed on the MQTT broker recently. Used by the
  // wizard's WAIT phase to know when the physical device has joined the network.
  Future<Map<String, dynamic>> getDeviceSeen(String deviceId) async {
    final res = await get('/api/devices/seen', query: {'deviceId': deviceId});
    return _checkObject(res, const [200], 'Could not check device status');
  }

  // Best-effort pre-flight duplicate check used by the provisioning wizard
  // BEFORE leaving the offline Tasmota AP (where internet may be unavailable).
  // Returns whether the canonical MAC is already registered to this user, to
  // another user, or not at all. Callers treat any failure as notFound and
  // continue - this is only a UX optimization and is never authoritative.
  Future<DeviceDuplicateStatus> preflightDeviceCheck(String deviceId) async {
    final res = await get('/api/devices/check', query: {'deviceId': deviceId});
    final body = _checkObject(res, const [200], 'Could not check device');
    switch (body['status']) {
      case 'mine':
        return DeviceDuplicateStatus.mine;
      case 'others':
        return DeviceDuplicateStatus.others;
      default:
        return DeviceDuplicateStatus.notFound;
    }
  }

  Future<Map<String, dynamic>> getStatus(String deviceId) async {
    final res = await get('/api/status', query: {'deviceId': deviceId});
    return _checkObject(res, const [200], 'Failed to fetch status');
  }

  Future<Map<String, dynamic>> control(String deviceId, int channel, String state) async {
    final res = await post('/api/control', {
      'deviceId': deviceId,
      'channel': channel,
      'state': state,
    });
    return _checkObject(res, const [200], 'Control failed');
  }

  Future<void> unclaimDevice(String deviceId) async {
    final res = await post('/api/devices/unclaim', {'deviceId': deviceId});
    _checkObject(res, const [200], 'Failed to unclaim device');
  }

  Future<void> deleteDevice(String deviceId) async {
    final res = await delete('/api/devices/$deviceId');
    _checkObject(res, const [200], 'Failed to delete device');
  }

  Future<List<dynamic>> getSensors() async {
    final res = await get('/api/sensors');
    return _checkList(res, 'Failed to fetch sensors');
  }

  Future<Map<String, dynamic>> createSensor(String name, String sensorId, String deviceId) async {
    final res = await post('/api/sensors', {
      'name': name,
      'sensorId': sensorId,
      'deviceId': deviceId,
    });
    return _checkObject(res, const [200], 'Failed to add sensor');
  }

  Future<void> deleteSensor(String sensorId) async {
    final res = await delete('/api/sensors/$sensorId');
    _checkObject(res, const [200], 'Failed to delete sensor');
  }

  Future<List<dynamic>> getRules() async {
    final res = await get('/api/rules');
    return _checkList(res, 'Failed to fetch rules');
  }

  Future<Map<String, dynamic>> createRule({
    required String name,
    required String sensorId,
    required List<int> channels,
    required String condition,
    required double threshold,
    required String action,
  }) async {
    final res = await post('/api/rules', {
      'name': name,
      'sensorId': sensorId,
      'channels': channels,
      'condition': condition,
      'threshold': threshold,
      'action': action,
    });
    return _checkObject(res, const [201], 'Failed to create rule');
  }

  Future<Map<String, dynamic>> updateRule(String ruleId, {
    String? name,
    List<int>? channels,
    String? condition,
    double? threshold,
    String? action,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (channels != null) body['channels'] = channels;
    if (condition != null) body['condition'] = condition;
    if (threshold != null) body['threshold'] = threshold;
    if (action != null) body['action'] = action;
    final res = await patch('/api/rules/$ruleId', body);
    return _checkObject(res, const [200], 'Failed to update rule');
  }

  Future<Map<String, dynamic>> toggleRule(String ruleId) async {
    final res = await patch('/api/rules/$ruleId/enable', {});
    return _checkObject(res, const [200], 'Failed to toggle rule');
  }

  Future<void> deleteRule(String ruleId) async {
    final res = await delete('/api/rules/$ruleId');
    _checkObject(res, const [200], 'Failed to delete rule');
  }

  Future<List<dynamic>> getSchedules() async {
    final res = await get('/api/schedules');
    return _checkList(res, 'Failed to fetch schedules');
  }

  Future<Map<String, dynamic>> createSchedule({
    required String name,
    required String deviceId,
    required List<int> channels,
    required Map<String, dynamic> recurrence,
    required List<Map<String, String>> timeRanges,
  }) async {
    final res = await post('/api/schedules', {
      'name': name,
      'deviceId': deviceId,
      'channels': channels,
      'recurrence': recurrence,
      'timeRanges': timeRanges,
    });
    return _checkObject(res, const [201], 'Failed to create schedule');
  }

  Future<Map<String, dynamic>> updateSchedule(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final res = await patch('/api/schedules/$id', payload);
    return _checkObject(res, const [200], 'Failed to update schedule');
  }

  Future<Map<String, dynamic>> toggleSchedule(String id) async {
    final res = await patch('/api/schedules/$id/enable', {});
    return _checkObject(res, const [200], 'Failed to toggle schedule');
  }

  Future<void> deleteSchedule(String id) async {
    final res = await delete('/api/schedules/$id');
    _checkObject(res, const [200], 'Failed to delete schedule');
  }
}