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
}