import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/auth_service.dart';

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
}
