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

  test('storeCandidateAddress writes an envelope without a verifiedAt', () async {
    final locator = LocalDeviceDiscovery();
    await locator.storeCandidateAddress(_id, '192.168.1.9');

    expect(await locator.cachedAddress(_id), '192.168.1.9');
    expect(await locator.cachedVerifiedAt(_id), isNull,
        reason: 'a candidate is a hint — never trusted until Status 5');
  });

  test('storeCandidateAddress skips an already-known address (keeps verified)',
      () async {
    final locator = LocalDeviceDiscovery();
    await locator.storeVerifiedAddress(_id, '192.168.1.5');
    final verifiedAt = await locator.cachedVerifiedAt(_id);

    await locator.storeCandidateAddress(_id, '192.168.1.5');

    expect(await locator.cachedVerifiedAt(_id), verifiedAt,
        reason: 'a matching candidate must not downgrade a verified entry');
    expect(await locator.cachedAddress(_id), '192.168.1.5');
  });

  test('storeCandidateAddress overwrites a different known address', () async {
    final locator = LocalDeviceDiscovery();
    await locator.storeVerifiedAddress(_id, '192.168.1.5');
    await locator.storeCandidateAddress(_id, '192.168.1.20');

    expect(await locator.cachedAddress(_id), '192.168.1.20');
    expect(await locator.cachedVerifiedAt(_id), isNull);
  });

  test('storeVerifiedAddress never persists an invalid address (0.0.0.0)',
      () async {
    final locator = LocalDeviceDiscovery();
    await locator.storeVerifiedAddress(_id, '0.0.0.0');
    await locator.storeVerifiedAddress(_id, '127.0.0.1');

    expect(await locator.cachedAddress(_id), isNull);
    expect(await locator.cachedVerifiedAt(_id), isNull);
  });

  test('storeCandidateAddress never persists an invalid address (0.0.0.0)',
      () async {
    final locator = LocalDeviceDiscovery();
    await locator.storeCandidateAddress(_id, '0.0.0.0');
    await locator.storeCandidateAddress(_id, 'not-an-ip');

    expect(await locator.cachedAddress(_id), isNull);
  });

  test('a cached envelope holding 0.0.0.0 is auto-removed at read (self-heal)',
      () async {
    SharedPreferences.setMockInitialValues({
      _key: '{"ip":"0.0.0.0","verifiedAt":"2026-01-01T00:00:00.000"}',
    });
    final locator = LocalDeviceDiscovery();

    expect(await locator.cachedAddress(_id), isNull);
    expect(await locator.cachedVerifiedAt(_id), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_key), isNull,
        reason: 'the invalid cached entry is deleted, not just hidden');
  });

  test('a legacy bare 0.0.0.0 value is auto-removed at read (self-heal)',
      () async {
    SharedPreferences.setMockInitialValues({_key: '0.0.0.0'});
    final locator = LocalDeviceDiscovery();

    expect(await locator.cachedAddress(_id), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_key), isNull);
  });

  test('a valid cached IPv4 still resolves after self-heal validation',
      () async {
    SharedPreferences.setMockInitialValues({
      _key: '{"ip":"192.168.1.5","verifiedAt":"2026-01-01T00:00:00.000"}',
    });
    final locator = LocalDeviceDiscovery();

    expect(await locator.cachedAddress(_id), '192.168.1.5');
    expect(await locator.cachedVerifiedAt(_id), isNotNull);
  });
}
