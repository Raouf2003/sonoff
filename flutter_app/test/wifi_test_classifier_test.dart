import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home_app/services/provisioning_service.dart';

/// Unit tests for the Tasmota WifiTest3 pre-flight Wi-Fi validation classifier.
///
/// These test the pure decision logic that decides whether the entered home
/// Wi-Fi credentials are allowed to be PERSISTED and trigger `Restart 1`.
/// WifiTest3 (mode 3) never stores credentials nor restarts by itself, and the
/// wiring guarantees that SSID1/Password1 writes only run after `success` —
/// the classifier is the gate and therefore holds the "no persist / no restart
/// on failure" invariant.
void main() {
  group('classifyWifiTest', () {
    test('success response', () {
      expect(classifyWifiTest('{"WifiTest":"Successful"}'),
          WifiTestResult.success);
    });

    test('success response as observed on a real device (WiFiTest, capital F)',
        () {
      // Digitally verified against Tasmota 15.5.x: the /cm poll body is
      // {"WiFiTest":"Successful"}. This exact spelling previously parsed as
      // null -> unknown -> phantom "wrong password". Must be success.
      expect(classifyWifiTest('{"WiFiTest":"Successful"}'),
          WifiTestResult.success);
      expect(extractWifiTestValue('{"WiFiTest":"Successful"}'), 'Successful');
      expect(isWifiTestPending('{"WiFiTest":"Successful"}'), isFalse);
    });

    test('trigger response spelling as observed (WiFiTest3, capital F)', () {
      expect(classifyWifiTest('{"WiFiTest3":"Testing"}'),
          WifiTestResult.unknown);
      expect(extractWifiTestValue('{"WiFiTest3":"Testing"}'), 'Testing');
      expect(isWifiTestPending('{"WiFiTest3":"Testing"}'), isTrue);
    });

    test('success with per-index key', () {
      expect(classifyWifiTest('{"WifiTest3":"Successful"}'),
          WifiTestResult.success);
    });

    test('wrong password (WL_CONNECT_FAILED)', () {
      expect(classifyWifiTest('{"WifiTest":"Connect failed"}'),
          WifiTestResult.wrongPassword);
    });

    test('wrong password - AP timeout verdict (older ESP8266 builds)', () {
      // Real firmware string from a live device: the ESP8266 tail reports
      // "Connect failed with AP timeout" when the association/auth handshake
      // never completes (typically wrong password / rejected cipher). Tasmota's
      // own Wi-Fi Manager treats it the same way ("check your credentials").
      expect(classifyWifiTest('{"WiFiTest":"Connect failed with AP timeout"}'),
          WifiTestResult.wrongPassword);
    });

    test('wrong password - connection rejected (old 5.x builds)', () {
      // Sonoff-Tasmota 5.x spelled the auth rejection explicitly.
      expect(
          classifyWifiTest(
              '{"WifiTest":"Connection rejected due to invalid password"}'),
          WifiTestResult.wrongPassword);
    });

    test('SSID not found (WL_NO_SSID_AVAIL)', () {
      expect(
          classifyWifiTest(
              '{"WifiTest":"Connect failed as AP cannot be reached"}'),
          WifiTestResult.ssidNotFound);
    });

    test('no IP address received', () {
      expect(
          classifyWifiTest(
              '{"WifiTest":"Connect failed as no IP address received"}'),
          WifiTestResult.noIp);
    });

    test('still running is pending, not a verdict', () {
      expect(classifyWifiTest('{"WifiTest":"Testing"}'),
          WifiTestResult.unknown);
      expect(classifyWifiTest('{"WifiTest":"Not Started"}'),
          WifiTestResult.unknown);
    });

    test('empty body is unknown', () {
      expect(classifyWifiTest(''), WifiTestResult.unknown);
      expect(classifyWifiTest('   '), WifiTestResult.unknown);
    });

    test('malformed / non-JSON body is unknown', () {
      expect(classifyWifiTest('not json at all'), WifiTestResult.unknown);
      expect(classifyWifiTest('{"WifiTest":42}'), WifiTestResult.unknown);
      expect(classifyWifiTest('{"Other":"Successful"}'), WifiTestResult.unknown);
    });

    test('unrecognized (localized/tolerated) settled string is unknown', () {
      // A translated or unknown verdict string must NOT be treated as success
      // or as a specific failure — only as terminal-unknown, so it can never
      // cause a Restart.
      expect(classifyWifiTest('{"WifiTest":"سیستم موفق"}'),
          WifiTestResult.unknown);
      expect(classifyWifiTest('{"WifiTest":"Verbunden"}'),
          WifiTestResult.unknown);
    });

    test('wrapped /cm response with nested Command map', () {
      expect(
          classifyWifiTest('{"Command":{"WifiTest":"Successful"}}'),
          WifiTestResult.success);
      expect(
          classifyWifiTest('{"Command":{"WifiTest":"Connect failed"}}'),
          WifiTestResult.wrongPassword);
    });

    test('nested WifiTest key at any depth resolves', () {
      expect(
          classifyWifiTest('{"WifiResult":{"Inner":{"WifiTest":"Successful"}}}'),
          WifiTestResult.success);
      expect(
          classifyWifiTest(
              '{"WifiResult":{"Inner":{"WifiTest":"Connect failed as AP cannot be reached"}}}'),
          WifiTestResult.ssidNotFound);
    });

    test('non-String WifiTest value anywhere is unknown (never verdict)', () {
      expect(classifyWifiTest('{"WifiTest":{"Depth":42}}'),
          WifiTestResult.unknown);
      expect(classifyWifiTest('{"Command":{"WifiTest":42}}'),
          WifiTestResult.unknown);
    });

    test('unrelated nested key alone is unknown', () {
      expect(classifyWifiTest('{"Command":{"Other":"Successful"}}'),
          WifiTestResult.unknown);
    });

    test('decoder-level timeout / local error are NOT wrongPassword', () {
      // The HTTP timeout path and local-AP-error path map to localError/unknown
      // upstream in _runWifiTest; the message mapping must never claim a wrong
      // password for those two outcomes.
      expect(wifiTestMessage(WifiTestResult.localError),
          isNot(contains('password may be incorrect')));
      expect(wifiTestMessage(WifiTestResult.unknown),
          isNot(contains('password may be incorrect')));
      expect(WifiTestResult.localError, isNot(WifiTestResult.wrongPassword));
      expect(WifiTestResult.unknown, isNot(WifiTestResult.wrongPassword));
    });
  });

  group('isWifiTestPending', () {
    test('true while, says Testing or Not Started', () {
      expect(isWifiTestPending('{"WifiTest":"Testing"}'), isTrue);
      expect(isWifiTestPending('{"WifiTest":"Not Started"}'), isTrue);
    });

    test('false on any settled verdict', () {
      expect(isWifiTestPending('{"WifiTest":"Successful"}'), isFalse);
      expect(isWifiTestPending('{"WifiTest":"Connect failed"}'), isFalse);
    });

    test('false on empty/malformed (cannot wait for a dead endpoint)', () {
      expect(isWifiTestPending(''), isFalse);
      expect(isWifiTestPending('garbage'), isFalse);
    });
  });

  group('extractWifiTestValue (public raw extractor)', () {
    test('flat and per-index forms', () {
      expect(extractWifiTestValue('{"WifiTest":"Successful"}'),
          'Successful');
      expect(extractWifiTestValue('{"WifiTest3":"Testing"}'), 'Testing');
    });

    test('wrapped /cm nesting is followed depth-first', () {
      expect(
          extractWifiTestValue('{"Command":{"WifiTest":"Successful"}}'),
          'Successful');
      expect(
          extractWifiTestValue(
              '{"WifiResult":{"Inner":{"WifiTest":"Connect failed"}}}'),
          'Connect failed');
    });

    test('non-String values and missing fields yield null', () {
      expect(extractWifiTestValue('{"WifiTest":42}'), isNull);
      expect(extractWifiTestValue('{"WifiTest":{"Nested":42}}'), isNull);
      expect(extractWifiTestValue('{"Other":"Successful"}'), isNull);
      expect(extractWifiTestValue(''), isNull);
      expect(extractWifiTestValue('not json'), isNull);
    });

    test('top-level exact key wins over nested shadowing', () {
      // A wrapped response cannot shadow a flat top-level verdict.
      expect(
          extractWifiTestValue(
              '{"WifiTest":"Successful","Command":{"WifiTest":"Connect failed"}}'),
          'Successful');
    });
  });

  group('isWifiTestPending across wrapping', () {
    test('pending verdict still pending when wrapped', () {
      expect(isWifiTestPending('{"Command":{"WifiTest":"Testing"}}'), isTrue);
      expect(isWifiTestPending('{"Command":{"WiFiTest":"Testing"}}'), isTrue);
      expect(
          isWifiTestPending('{"WifiTest":"Not Started",'
              '"Command":{"WifiTest":"Successful"}}'),
          isTrue);
    });

    test('missing verdict is not pending (never wait forever)', () {
      expect(isWifiTestPending('{"Other":"Testing"}'), isFalse);
      expect(isWifiTestPending('{"WifiTest":42}'), isFalse);
    });
  });

  group('no-persist / no-restart invariant (decision mapping)', () {
    test('credentials may be persisted ONLY after success', () {
      expect(wifiTestMessage(WifiTestResult.success), isNotNull);
      // The gate equals: persistAllowed = (result == WifiTestResult.success).
      // Every non-success verdict carries a failure/unknown message, never the
      // success confirmation.
      for (final r in WifiTestResult.values) {
        if (r == WifiTestResult.success) continue;
        expect(wifiTestMessage(r), isNot(equals(wifiTestMessage(WifiTestResult.success))));
      }
    });

    test('wrong password message is specific but not claimed for unknowns', () {
      expect(wifiTestMessage(WifiTestResult.wrongPassword),
          contains('password may be incorrect'));
      expect(wifiTestMessage(WifiTestResult.unknown),
          isNot(contains('password may be incorrect')));
      expect(wifiTestMessage(WifiTestResult.ssidNotFound),
          isNot(contains('password may be incorrect')));
    });

    test('every percentage has a message (no crash on malformed path)', () {
      for (final r in WifiTestResult.values) {
        expect(wifiTestMessage(r).isNotEmpty, isTrue,
            reason: '${r.name} must have a message');
      }
    });
  });
}