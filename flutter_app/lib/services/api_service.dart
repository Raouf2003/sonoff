import 'dart:convert';
import 'package:http/http.dart' as http;
import 'auth_service.dart';

const String kBaseUrl = 'https://sonoff-3na2.onrender.com';

class ApiService {
  final AuthService _auth = AuthService();

  Future<Map<String, String>> _headers() async {
    final token = await _auth.getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  Future<http.Response> post(String path, Map<String, dynamic> body) async {
    final headers = await _headers();
    return await http.post(
      Uri.parse('$kBaseUrl$path'),
      headers: headers,
      body: jsonEncode(body),
    );
  }

  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    final headers = await _headers();
    var uri = Uri.parse('$kBaseUrl$path');
    if (query != null) {
      uri = uri.replace(queryParameters: query);
    }
    return await http.get(uri, headers: headers);
  }

  Future<http.Response> put(String path, Map<String, dynamic> body) async {
    final headers = await _headers();
    return await http.put(
      Uri.parse('$kBaseUrl$path'),
      headers: headers,
      body: jsonEncode(body),
    );
  }

  Future<http.Response> delete(String path) async {
    final headers = await _headers();
    return await http.delete(Uri.parse('$kBaseUrl$path'), headers: headers);
  }

  Future<Map<String, dynamic>> signup(String username, String password) async {
    final res = await post('/api/auth/signup', {
      'username': username,
      'password': password,
    });
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 201) {
      throw Exception(body['error'] ?? 'Signup failed');
    }
    return body;
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    final res = await post('/api/auth/login', {
      'username': username,
      'password': password,
    });
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception(body['error'] ?? 'Login failed');
    }
    return body;
  }

  Future<List<dynamic>> getDevices() async {
    final res = await get('/api/devices');
    if (res.statusCode != 200) {
      throw Exception('Failed to fetch devices');
    }
    return jsonDecode(res.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> claimDevice(String deviceId, String name) async {
    final res = await post('/api/devices/claim', {
      'deviceId': deviceId,
      'name': name,
    });
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception(body['error'] ?? 'Claim failed');
    }
    return body;
  }

  Future<Map<String, dynamic>> getStatus(String deviceId) async {
    final res = await get('/api/status', query: {'deviceId': deviceId});
    if (res.statusCode != 200) {
      throw Exception('Failed to fetch status');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> control(String deviceId, int channel, String state) async {
    final res = await post('/api/control', {
      'deviceId': deviceId,
      'channel': channel,
      'state': state,
    });
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception(body['error'] ?? 'Control failed');
    }
    return body;
  }

  Future<List<dynamic>> getSensors() async {
    final res = await get('/api/sensors');
    if (res.statusCode != 200) throw Exception('Failed to fetch sensors');
    return jsonDecode(res.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> createSensor({
    required String name,
    String type = 'generic',
    String? deviceId,
    required String field,
    String mode = 'change_or_interval',
    int intervalSeconds = 300,
    double epsilon = 0,
  }) async {
    final res = await post('/api/sensors', {
      'name': name,
      'type': type,
      'deviceId': deviceId,
      'field': field,
      'persistence': {
        'mode': mode,
        'intervalSeconds': intervalSeconds,
        'epsilon': epsilon,
      },
    });
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 201) throw Exception(body['error'] ?? 'Failed to create sensor');
    return body;
  }

  Future<void> deleteSensor(String sensorId) async {
    final res = await delete('/api/sensors/$sensorId');
    if (res.statusCode != 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'Failed to delete sensor');
    }
  }

  Future<List<dynamic>> getSensorTelemetry(String sensorId, {int limit = 30}) async {
    final res = await get('/api/sensors/$sensorId/telemetry', query: {'limit': '$limit'});
    if (res.statusCode != 200) throw Exception('Failed to fetch telemetry');
    return jsonDecode(res.body) as List<dynamic>;
  }

  Future<List<dynamic>> getRules() async {
    final res = await get('/api/rules');
    if (res.statusCode != 200) throw Exception('Failed to fetch rules');
    return jsonDecode(res.body) as List<dynamic>;
  }

  Future<List<dynamic>> getRuleLogs({int limit = 50}) async {
    final res = await get('/api/rules/logs', query: {'limit': '$limit'});
    if (res.statusCode != 200) throw Exception('Failed to fetch rule logs');
    return jsonDecode(res.body) as List<dynamic>;
  }

  Future<Map<String, dynamic>> createRule({
    required String name,
    required String sensorId,
    required Map<String, dynamic> condition,
    required Map<String, dynamic> action,
    int cooldownS = 0,
    int freshnessS = 3600,
    int priority = 0,
  }) async {
    final res = await post('/api/rules', {
      'name': name,
      'sensorId': sensorId,
      'condition': condition,
      'action': action,
      'cooldownS': cooldownS,
      'freshnessS': freshnessS,
      'priority': priority,
    });
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 201) throw Exception(body['error'] ?? 'Failed to create rule');
    return body;
  }

  Future<Map<String, dynamic>> updateRule(String id, {
    required String name,
    required String sensorId,
    required Map<String, dynamic> condition,
    required Map<String, dynamic> action,
    int cooldownS = 0,
    int freshnessS = 3600,
    int priority = 0,
  }) async {
    final res = await put('/api/rules/$id', {
      'name': name,
      'sensorId': sensorId,
      'condition': condition,
      'action': action,
      'cooldownS': cooldownS,
      'freshnessS': freshnessS,
      'priority': priority,
    });
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Failed to update rule');
    return body;
  }

  Future<Map<String, dynamic>> toggleRule(String id) async {
    final res = await post('/api/rules/$id/toggle', {});
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Failed to toggle rule');
    return body;
  }

  Future<void> deleteRule(String id) async {
    final res = await delete('/api/rules/$id');
    if (res.statusCode != 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'Failed to delete rule');
    }
  }

  Future<bool> getEmergencyStop() async {
    final res = await get('/api/runtime/emergency-stop');
    if (res.statusCode != 200) throw Exception('Failed to fetch emergency stop');
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['emergencyStop'] == true;
  }

  Future<void> setEmergencyStop(bool on) async {
    final res = await post('/api/runtime/emergency-stop', {'on': on});
    if (res.statusCode != 200) throw Exception('Failed to set emergency stop');
  }

  Future<void> unclaimDevice(String deviceId) async {
    final res = await post('/api/devices/unclaim', {'deviceId': deviceId});
    if (res.statusCode != 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'Failed to unclaim device');
    }
  }

  Future<void> deleteDevice(String deviceId) async {
    final res = await delete('/api/devices/$deviceId');
    if (res.statusCode != 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      throw Exception(body['error'] ?? 'Failed to delete device');
    }
  }
}
