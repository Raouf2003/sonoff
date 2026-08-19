import 'package:flutter_test/flutter_test.dart';
import 'package:smart_home_app/services/provisioning_service.dart';

/// Unit tests for the once-at-start snapshot that powers the wizard's RAM-only
/// early duplicate gate. All MAC matching must go through the SAME canonical
/// [normalizeMac], so spelling, case and the presence/absence of the device in
/// the getDevices list are the only things that can change the verdict.
void main() {
  group('ClaimDeviceSnapshot', () {
    test('an empty snapshot never claims a duplicate', () {
      final snap = ClaimDeviceSnapshot.empty();
      expect(snap.macs, isEmpty);
      expect(snap.containsMac('34987AC30304'), isFalse);
    });

    test('containsMac is MAC-normalized across every spelling', () {
      final snap = ClaimDeviceSnapshot.fromMacs(['34987AC30304']);
      // Canonical, dotted, dashed and lower-case spellings all identify it.
      expect(snap.containsMac('34987AC30304'), isTrue);
      expect(snap.containsMac('34:98:7A:C3:03:04'), isTrue);
      expect(snap.containsMac('34-98-7A-C3-03-04'), isTrue);
      expect(snap.containsMac('34987ac30304'), isTrue);
      expect(snap.containsMac(' 34:98:7A:C3:03:04 '), isTrue);
      // A different device is never a match.
      expect(snap.containsMac('18FE34A1B2C3'), isFalse);
    });

    test('fromDevices extracts and normalizes every registered MAC', () {
      final snap = ClaimDeviceSnapshot.fromDevices(<dynamic>[
        {'deviceId': '34:98:7A:C3:03:04', 'name': 'A'},
        {'deviceId': '18FE34A1B2C3', 'name': 'B'},
      ]);
      expect(snap.macs, {'34987AC30304', '18FE34A1B2C3'});
      expect(snap.containsMac('34-98-7A-C3-03-04'), isTrue);
      expect(snap.containsMac('AABBCCDDEEFF'), isFalse);
    });

    test('fromDevices tolerates malformed entries and never errors', () {
      final snap = ClaimDeviceSnapshot.fromDevices(<dynamic>[
        'not-a-map',
        42,
        null,
        {'deviceId': ''},
        {'deviceId': 'not-a-mac'},
        {'deviceId': '34:98:7A:C3:03:04'},
      ]);
      expect(snap.macs, {'34987AC30304'});
    });

    test('fromDevices dedupes duplicate MAC spellings', () {
      final snap = ClaimDeviceSnapshot.fromDevices(<dynamic>[
        {'deviceId': '34987AC30304'},
        {'deviceId': '34:98:7A:C3:03:04'},
        {'deviceId': '34-98-7A-C3-03-04'},
      ]);
      expect(snap.macs.length, 1);
    });

    test('an unparseable MAC is NEVER a false duplicate', () {
      final snap = ClaimDeviceSnapshot.fromMacs(['34987AC30304']);
      expect(snap.containsMac(null), isFalse);
      expect(snap.containsMac(''), isFalse);
      expect(snap.containsMac('   '), isFalse);
      expect(snap.containsMac('not-a-mac'), isFalse);
      expect(snap.containsMac('XX:XX:XX:XX:XX:XX'), isFalse);
    });
  });
}