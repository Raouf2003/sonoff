import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_home_app/services/local_device_discovery.dart';

const _id = '34987AC30304';
const _key = '$kLocalVerifiedIpPrefix$_id';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('no cache entry reads as no address and no verifiedAt', () async {
    final locator = LocalDeviceDiscovery();
    expect(await locator.cachedAddress(_id), isNull);
    expect(await locator.cachedVerifiedAt(_id), isNull);
  });

  test('storeVerifiedAddress writes an envelope with a timestamp', () async {
    final locator = LocalDeviceDiscovery();
    await locator.storeVerifiedAddress(_id, '192.168.1.5');

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    expect(raw, contains('"ip"'));
    expect(raw, contains('"verifiedAt"'));

    expect(await locator.cachedAddress(_id), '192.168.1.5');
    final verifiedAt = await locator.cachedVerifiedAt(_id);
    expect(verifiedAt, isNotNull);
    expect(
      DateTime.now().difference(verifiedAt!).inSeconds,
      lessThan(5),
    );
  });

  test('legacy bare-IP value still resolves as an address with no timestamp',
      () async {
    SharedPreferences.setMockInitialValues({_key: '10.0.0.7'});
    final locator = LocalDeviceDiscovery();
    expect(await locator.cachedAddress(_id), '10.0.0.7',
        reason: 'legacy entries predate the envelope and must keep working');
    expect(await locator.cachedVerifiedAt(_id), isNull);
  });

  test('discardAddress clears both the envelope and legacy entries', () async {
    SharedPreferences.setMockInitialValues({_key: '10.0.0.7'});
    final locator = LocalDeviceDiscovery();
    await locator.discardAddress(_id);
    expect(await locator.cachedAddress(_id), isNull);
  });
}
