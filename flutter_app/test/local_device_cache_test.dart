import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_home_app/services/local_device_cache.dart';

const _id = '34987AC30304';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('empty or missing cache reads as an empty list', () async {
    final cache = LocalDeviceCache();
    expect(await cache.cachedDevices(), isEmpty);
  });

  test('replaceAll keeps only non-sensitive display metadata', () async {
    final cache = LocalDeviceCache();
    await cache.replaceAll(const [
      {
        'deviceId': _id,
        'name': 'Controller',
        'type': 'sonoff-4ch',
        'channels': 4,
        'ownerId': 'should-never-be-stored',
        'token': 'secret',
        'password': 'secret',
      },
    ]);

    final devices = await cache.cachedDevices();
    expect(devices.single['deviceId'], _id);
    expect(devices.single['name'], 'Controller');
    expect(devices.single['channels'], 4);
    expect(devices.single.containsKey('ownerId'), isFalse);
    expect(devices.single.containsKey('token'), isFalse);
    expect(devices.single.containsKey('password'), isFalse);
  });

  test('missing fields get safe defaults; entries without deviceId are dropped',
      () async {
    final cache = LocalDeviceCache();
    await cache.replaceAll(const [
      {'deviceId': _id, 'name': ''},
      {'deviceId': '', 'name': 'ghost'},
      {'name': 'no-id'},
    ]);

    final devices = await cache.cachedDevices();
    expect(devices.length, 1);
    expect(devices.single['name'], _id, reason: 'empty name falls back to id');
    expect(devices.single['type'], 'sonoff-4ch');
    expect(devices.single['channels'], 4);
  });

  test('provision upsert inserts a new device (#13)', () async {
    final cache = LocalDeviceCache();
    await cache.replaceAll(const [
      {'deviceId': 'AAAAAAAAAAAA', 'name': 'Gate', 'channels': 2},
    ]);

    await cache.upsert({'deviceId': _id, 'name': 'Controller', 'channels': 4});

    final devices = await cache.cachedDevices();
    expect(devices.length, 2);
    final added = devices.firstWhere((d) => d['deviceId'] == _id);
    expect(added['name'], 'Controller');
    expect(added['channels'], 4);
  });

  test('upsert replaces, never duplicates, an existing deviceId', () async {
    final cache = LocalDeviceCache();
    await cache.upsert({'deviceId': _id, 'name': 'Old', 'channels': 4});
    await cache.upsert({'deviceId': _id, 'name': 'New', 'channels': 1});

    final devices = await cache.cachedDevices();
    expect(devices.length, 1);
    expect(devices.single['name'], 'New');
    expect(devices.single['channels'], 1);
  });

  test('removal deletes the device AND its verified-IP locator (#14)',
      () async {
    SharedPreferences.setMockInitialValues({
      'stees.local.ip.$_id': '192.168.1.5',
      'stees.local.ip.OTHER': '10.0.0.7',
    });
    final cache = LocalDeviceCache();
    await cache.replaceAll(const [
      {'deviceId': _id, 'name': 'Controller', 'channels': 4},
      {'deviceId': 'OTHER', 'name': 'Gate', 'channels': 2},
    ]);

    await cache.remove(_id);

    final devices = await cache.cachedDevices();
    expect(devices.single['deviceId'], 'OTHER',
        reason: 'removed device no longer listed locally');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('stees.local.ip.$_id'), isNull,
        reason: 'the removed device can never be targeted locally again');
    expect(prefs.getString('stees.local.ip.OTHER'), '10.0.0.7');
  });

  test('corrupt stored JSON reads as an empty list (never throws)', () async {
    SharedPreferences.setMockInitialValues({'stees.local.devices': '{oops'});
    final cache = LocalDeviceCache();
    expect(await cache.cachedDevices(), isEmpty);
  });

  group('account snapshot (registered canonical MACs)', () {
    test('no snapshot yet reads as null (unknown, not empty evidence)', () async {
      final cache = LocalDeviceCache();
      expect(await cache.loadAccountSnapshotMacs(), isNull);
    });

    test('saveAccountSnapshot stores ONLY canonical MACs, skips the rest',
        () async {
      final cache = LocalDeviceCache();
      await cache.saveAccountSnapshot(const [
        {'deviceId': '34:98:7A:C3:03:04', 'name': 'Controller'},
        {'deviceId': '34987AC30304', 'name': 'duplicate-form'},
        {'deviceId': 'stees_legacy', 'name': 'legacy'},
        {'deviceId': 'not-a-mac', 'name': 'junk'},
        {'name': 'no-id'},
      ]);

      final macs = await cache.loadAccountSnapshotMacs();
      expect(macs, {'34987AC30304'},
          reason: 'only the canonical MAC is stored, never legacy/non-MAC ids');
    });

    test('an EMPTY refreshed snapshot is valid evidence of no devices',
        () async {
      final cache = LocalDeviceCache();
      await cache.saveAccountSnapshot(const []);
      expect(await cache.loadAccountSnapshotMacs(), isEmpty,
          reason: 'an empty snapshot was refreshed online — absence is evidence');
    });

    test('upsertAccountSnapshot adds a MAC without dropping the others',
        () async {
      final cache = LocalDeviceCache();
      await cache.saveAccountSnapshot(const [
        {'deviceId': 'AAAAAAAAAAAA', 'name': 'Gate'},
      ]);
      await cache.upsertAccountSnapshot('34987AC30304');

      expect(await cache.loadAccountSnapshotMacs(),
          containsAll(['AAAAAAAAAAAA', '34987AC30304']));
    });

    test('removeFromAccountSnapshot drops the MAC, keeps the rest', () async {
      final cache = LocalDeviceCache();
      await cache.saveAccountSnapshot(const [
        {'deviceId': '34987AC30304', 'name': 'Controller'},
        {'deviceId': 'AAAAAAAAAAAA', 'name': 'Gate'},
      ]);
      await cache.removeFromAccountSnapshot('34987AC30304');

      final macs = await cache.loadAccountSnapshotMacs();
      expect(macs, contains('AAAAAAAAAAAA'));
      expect(macs, isNot(contains('34987AC30304')));
    });

    test('a corrupt snapshot reads as null (unknown, never a guess)', () async {
      SharedPreferences.setMockInitialValues({
        kAccountSnapshotKey: '{oops',
      });
      final cache = LocalDeviceCache();
      expect(await cache.loadAccountSnapshotMacs(), isNull);
    });

    test('account scope isolation: another user snapshot is not reused',
        () async {
      final alice = LocalDeviceCache(accountScope: 'alice');
      await alice.saveAccountSnapshot(const [
        {'deviceId': '34987AC30304', 'name': 'Controller'},
      ]);

      final bob = LocalDeviceCache(accountScope: 'bob');
      expect(await bob.loadAccountSnapshotMacs(), isNull,
          reason: 'one user must never borrow another user registered-set');
      // Alice keeps her snapshot.
      expect(await alice.loadAccountSnapshotMacs(), contains('34987AC30304'));
      // Bob's own refresh writes an independent snapshot.
      await bob.saveAccountSnapshot(const [
        {'deviceId': 'AAAAAAAAAAAA', 'name': 'Gate'},
      ]);
      expect(await bob.loadAccountSnapshotMacs(), contains('AAAAAAAAAAAA'));
      expect(await bob.loadAccountSnapshotMacs(), isNot(contains('34987AC30304')));
    });
  });
}