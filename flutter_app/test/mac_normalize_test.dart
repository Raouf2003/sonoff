import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home_app/services/provisioning_service.dart';

/// Unit tests for the canonical MAC device-identity normalization.
///
/// The physical Tasmota MAC IS the deviceId/MQTT topic. `normalizeMac` is the
/// single client-side spelling of that identity and must stay deterministic,
/// case-insensitive and strict: every representation of one physical address
/// yields exactly one canonical value, and anything that is not exactly 12 hex
/// digits after stripping separators/whitespace is rejected.
void main() {
  group('normalizeMac', () {
    test('colon-separated uppercase', () {
      expect(normalizeMac('34:98:7A:C3:03:04'), '34987AC30304');
    });

    test('colon-separated lowercase', () {
      expect(normalizeMac('34:98:7a:c3:03:04'), '34987AC30304');
    });

    test('dash-separated', () {
      expect(normalizeMac('34-98-7A-C3-03-04'), '34987AC30304');
    });

    test('bare (no separators)', () {
      expect(normalizeMac('34987AC30304'), '34987AC30304');
    });

    test('mixed separators and surrounding whitespace', () {
      expect(normalizeMac('  34:98-7A:c3-03:04  '), '34987AC30304');
    });

    test('deterministic: same address always maps to same id', () {
      final a = normalizeMac('34:98:7A:C3:03:04');
      final b = normalizeMac('34-98-7a-c3-03-04');
      final c = normalizeMac(' 34:98-7A:c3-03:04 ');
      expect(a, b);
      expect(a, c);
    });

    test('too short is rejected', () {
      expect(normalizeMac('34:98:7A:C3:03'), isNull);
    });

    test('non-hex characters are rejected', () {
      expect(normalizeMac('34:98:7A:C3:03:G4'), isNull);
    });

    test('user-invented STEES id is not a valid MAC', () {
      expect(normalizeMac('stees_0123456789abcdef'), isNull);
    });

    test('null / empty input is rejected', () {
      expect(normalizeMac(null), isNull);
      expect(normalizeMac(''), isNull);
    });
  });

  group('isCanonicalDeviceId', () {
    test('canonical value passes', () {
      expect(isCanonicalDeviceId('34987AC30304'), isTrue);
    });

    test('legacy stees_ device id is not canonical', () {
      expect(isCanonicalDeviceId('stees_c8b8d2e4f6a0b1'), isFalse);
    });

    test('lowercase is not canonical (strict form)', () {
      expect(isCanonicalDeviceId('34987ac30304'), isFalse);
    });
  });
}