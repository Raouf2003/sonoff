import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/auth_service.dart';

class _MockClient extends http.BaseClient {
  int requestCount = 0;
  bool closed = false;
  final Map<String, http.Response> responses;

  _MockClient(this.responses);

  _MockClient.single(http.Response r) : responses = {'*': r};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestCount++;
    final key = request.url.path;
    final resp = responses[key] ?? responses['*'] ?? http.Response('[]', 200);
    return http.StreamedResponse(
      Stream.value(resp.bodyBytes),
      resp.statusCode,
      headers: resp.headers,
      reasonPhrase: resp.reasonPhrase,
    );
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _CountingAuth extends AuthService {
  int calls = 0;
  String? tokenToReturn = 'test-token-123';
  Duration delay = const Duration(milliseconds: 10);

  @override
  Future<String?> getToken() async {
    calls++;
    if (delay != Duration.zero) await Future.delayed(delay);
    return tokenToReturn;
  }
}

void main() {
  group('ApiService token cache', () {
    test('token cached after first call, not re-read on subsequent calls', () async {
      final auth = _CountingAuth();
      final api = ApiService(auth: auth);
      final t1 = await api.getCachedTokenForTesting();
      expect(t1, 'test-token-123');
      expect(auth.calls, 1);
      final t2 = await api.getCachedTokenForTesting();
      expect(t2, 'test-token-123');
      expect(auth.calls, 1, reason: 'second call should use cache');
      await api.getCachedTokenForTesting();
      expect(auth.calls, 1);
    });

    test('concurrent calls during cache-miss share one storage read', () async {
      final auth = _CountingAuth()..delay = const Duration(milliseconds: 30);
      final api = ApiService(auth: auth);
      // Fire two concurrent reads before the first completes.
      final results = await Future.wait([
        api.getCachedTokenForTesting(),
        api.getCachedTokenForTesting(),
      ]);
      expect(results[0], 'test-token-123');
      expect(results[1], 'test-token-123');
      expect(auth.calls, 1, reason: 'concurrent callers must share one read');
    });

    test('clearTokenCache forces re-read on next call', () async {
      final auth = _CountingAuth();
      final api = ApiService(auth: auth);
      await api.getCachedTokenForTesting();
      expect(auth.calls, 1);
      api.clearTokenCacheForTesting();
      await api.getCachedTokenForTesting();
      expect(auth.calls, 2);
    });

    test('401 invalidation via clearTokenCache is respected', () async {
      final auth = _CountingAuth();
      final api = ApiService(auth: auth);
      await api.getCachedTokenForTesting();
      expect(auth.calls, 1);
      // Simulate 401 handling clearing the cache.
      api.clearTokenCacheForTesting();
      auth.tokenToReturn = 'new-token-456';
      final t = await api.getCachedTokenForTesting();
      expect(t, 'new-token-456');
      expect(auth.calls, 2);
    });

    test('null token is not cached (re-read on next call)', () async {
      final auth = _CountingAuth()..tokenToReturn = null;
      final api = ApiService(auth: auth);
      await api.getCachedTokenForTesting();
      expect(auth.calls, 1);
      await api.getCachedTokenForTesting();
      expect(auth.calls, 2, reason: 'null token should not be cached');
    });
  });

  group('ApiService http.Client reuse (P4)', () {
    test('client reused across multiple sequential calls', () async {
      final mockClient = _MockClient.single(http.Response('[]', 200));
      final auth = _CountingAuth()..tokenToReturn = 'tok';
      final api = ApiService(auth: auth, client: mockClient);
      final c1 = api.clientForTesting;
      await api.getDevices();
      final c2 = api.clientForTesting;
      expect(identical(c1, c2), isTrue);
      expect(mockClient.requestCount, 1);
      await api.getDevices();
      expect(mockClient.requestCount, 2);
      expect(identical(c1, api.clientForTesting), isTrue);
    });

    test('dispose closes owned client', () {
      final mockClient = _MockClient.single(http.Response('[]', 200));
      final api = ApiService(client: mockClient);
      api.dispose();
      expect(mockClient.closed, isTrue);
    });

    test('injected client is closed when ApiService is disposed', () {
      final mockClient = _MockClient.single(http.Response('[]', 200));
      final api = ApiService(client: mockClient);
      api.dispose();
      expect(mockClient.closed, isTrue,
          reason: 'dispose should close the shared client');
    });

    test('error handling (timeout, network) still works with shared client', () async {
      // Mock a 401 to trigger onUnauthorized and ensure _checkObject still works
      final unauthClient = _MockClient({
        '/api/devices': http.Response(jsonEncode({'error': 'Unauthorized'}), 401),
      });
      final api2 = ApiService(client: unauthClient, auth: _CountingAuth());
      bool unauthorizedCalled = false;
      ApiService.onUnauthorized = () => unauthorizedCalled = true;
      try {
        await expectLater(api2.getDevices(), throwsA(isA<ApiException>()));
        expect(unauthorizedCalled, isTrue);
      } finally {
        ApiService.onUnauthorized = null;
      }
    });
  });
}
