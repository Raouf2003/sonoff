import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/cloud_device_transport.dart';
import 'package:smart_home_app/services/device_repository_service.dart';
import 'package:smart_home_app/services/device_transport.dart';
import 'package:smart_home_app/services/local_device_cache.dart';
import 'package:smart_home_app/services/local_device_discovery.dart';

const _deviceId = '34987AC30304';
const _macBody = '{"StatusNET":{"Mac":"34:98:7A:C3:03:04"}}';
const _foreignMacBody = '{"StatusNET":{"Mac":"00:11:22:33:44:55"}}';
const _statusBody = '{"POWER1":"ON","POWER2":"OFF"}';

/// Cloud backend stub: scriptable errors, call counting, no network.
class _FakeCloudApi extends ApiService {
  Object? controlError;
  Object? statusError;
  Object? devicesError;
  bool statusOnline = true;
  int controlCalls = 0;
  int statusCalls = 0;
  int devicesCalls = 0;
  List<Map<String, dynamic>> devices = [];

  @override
  Future<List<dynamic>> getDevices() async {
    devicesCalls++;
    final err = devicesError;
    if (err != null) throw err;
    return devices;
  }

  @override
  Future<Map<String, dynamic>> control(
    String deviceId,
    int channel,
    String state,
  ) async {
    controlCalls++;
    final err = controlError;
    if (err != null) throw err;
    return {'online': true, 'POWER$channel': state};
  }

  @override
  Future<Map<String, dynamic>> getStatus(String deviceId) async {
    statusCalls++;
    final err = statusError;
    if (err != null) throw err;
    return {'online': statusOnline, ...jsonDecode(_statusBody)};
  }
}

/// Tasmota stub over the injectable cmd fetcher.
class _CmFake {
  _CmFake({
    Map<String, String>? responses,
    this.macByAddress = const {},
  }) : responses = responses ?? {};

  final Map<String, String> responses;

  /// Address→MAC body table for `Status 5`, letting a test simulate a foreign
  /// Tasmota (or a repurposed box) at a specific candidate address.
  final Map<String, String> macByAddress;
  bool unreachable = false;
  final List<String> called = [];
  Object? error;

  Future<String> call(String address, String command, {String? password}) async {
    called.add(command);
    final err = error;
    if (err != null) throw err;
    if (unreachable) {
      throw const DeviceTransportException('unreachable');
    }
    if (command == 'Status%205') {
      final macBody = macByAddress[address];
      if (macBody != null) return macBody;
    }
    final body = responses[command];
    if (body == null) {
      throw const DeviceTransportException('HTTP 404');
    }
    return body;
  }
}

/// Discovery stub: scripted cache + mDNS candidates with call tracking.
class _FakeLocator implements DeviceLocator {
  _FakeLocator({this.cached, this.candidates = const []});

  String? cached;
  List<String> candidates;
  int cachedQueries = 0;
  int mDnsQueries = 0;
  int stores = 0;
  int discards = 0;
  String? lastStored;

  @override
  Future<String?> cachedAddress(String deviceId) async {
    cachedQueries++;
    return cached;
  }

  @override
  Future<void> storeVerifiedAddress(String deviceId, String ip) async {
    stores++;
    lastStored = ip;
  }

  @override
  Future<void> discardAddress(String deviceId) async {
    discards++;
  }

  @override
  Future<List<String>> mDnsCandidates(Duration timeout) async {
    mDnsQueries++;
    return candidates;
  }
}

/// Builds a repository wired to the given stubs.
DeviceRepositoryService _repo(
  _FakeCloudApi cloud, {
  _FakeLocator? locator,
  _CmFake? cm,
  LocalDeviceCache? cache,
}) {
  return DeviceRepositoryService(
    cloud: CloudDeviceTransport(api: cloud),
    locator: locator ?? _FakeLocator(),
    fetch: cm?.call,
    cache: cache ?? LocalDeviceCache(),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('device list: cloud-primary with local cache fallback', () {
    test('cloud success returns devices and refreshes the cache', () async {
      final cloud = _FakeCloudApi()
        ..devices = const [
          {
            'deviceId': 'AAAAAAAAAAAA',
            'name': 'Gate',
            'type': 'sonoff-4ch',
            'channels': 4,
          },
          {
            'deviceId': _deviceId,
            'name': 'Controller',
            'channels': 2,
          },
        ];
      final repo = _repo(cloud);

      final result = await repo.getDevices();

      expect(cloud.devicesCalls, 1);
      expect(result.length, 2);
      expect(repo.lastSource, DeviceTransportSource.cloud);

      // Now the cloud is down: the cache written on success must be readable.
      cloud.devicesError =
          const ApiException('down', code: 'NETWORK_ERROR');
      final cached = await repo.getDevices();
      expect(cached.length, 2);
      expect(repo.lastSource, DeviceTransportSource.local);
      expect(
        cached.map((d) => d['deviceId']).toList(),
        containsAll(['AAAAAAAAAAAA', _deviceId]),
      );
    });

    test('cloud availability failure falls back to cached devices', () async {
      final cache = LocalDeviceCache();
      await cache.replaceAll(const [
        {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
      ]);
      final cloud = _FakeCloudApi()
        ..devicesError = const ApiException(
          'Could not reach the server.',
          code: 'NETWORK_ERROR',
        );
      final repo = _repo(cloud, cache: cache);

      final result = await repo.getDevices();

      expect(cloud.devicesCalls, 1);
      expect(result.single['deviceId'], _deviceId);
      expect(repo.lastSource, DeviceTransportSource.local);
    });

    test('cloud down + empty cache surfaces the original error', () async {
      final cloud = _FakeCloudApi()
        ..devicesError = const ApiException(
          'Could not reach the server.',
          code: 'NETWORK_ERROR',
        );
      final repo = _repo(cloud);

      await expectLater(
        repo.getDevices(),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'NETWORK_ERROR'),
        ),
      );
    });

    test('logical cloud error is surfaced, cache never consulted', () async {
      final cache = LocalDeviceCache();
      await cache.replaceAll(const [
        {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
      ]);
      final cloud = _FakeCloudApi()
        ..devicesError = const ApiException('Unauthorized', statusCode: 401);
      final repo = _repo(cloud, cache: cache);

      await expectLater(
        repo.getDevices(),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 's', 401)),
      );
    });

    test('cloud returns to being preferred after an outage', () async {
      final cache = LocalDeviceCache();
      await cache.replaceAll(const [
        {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
      ]);
      final cloud = _FakeCloudApi()
        ..devicesError = const ApiException('down', code: 'NETWORK_ERROR');
      final repo = _repo(cloud, cache: cache);

      final first = await repo.getDevices();
      expect(first.single['deviceId'], _deviceId,
          reason: 'outage served from cache');
      expect(repo.lastSource, DeviceTransportSource.local);

      // Internet returns: the same repository prefers the (fresh) cloud list.
      cloud.devicesError = null;
      cloud.devices = const [
        {'deviceId': _deviceId, 'name': 'Renamed', 'channels': 4},
      ];
      final second = await repo.getDevices();
      expect(second.single['name'], 'Renamed');
      expect(repo.lastSource, DeviceTransportSource.cloud);

      // The refreshed cloud list overwrote the stale cached name.
      final cached = await cache.cachedDevices();
      expect(cached.single['name'], 'Renamed');
    });
  });

  group('cloud is preferred and wins', () {
    test('control: cloud success never touches discovery', () async {
      final cloud = _FakeCloudApi();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(cloud.controlCalls, 1);
      expect(locator.cachedQueries, 0, reason: 'no fallback when cloud works');
      expect(locator.mDnsQueries, 0);
      expect(result['POWER1'], 'ON');
      expect(repo.lastSource, DeviceTransportSource.cloud);
    });

    test('status: cloud success never touches discovery', () async {
      final cloud = _FakeCloudApi();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator);

      final result = await repo.getStatus(_deviceId);

      expect(cloud.statusCalls, 1);
      expect(locator.cachedQueries, 0);
      expect(result['POWER1'], 'ON');
      expect(repo.lastSource, DeviceTransportSource.cloud);
    });
  });

  group('availability failures fall back to local', () {
    test('control: cloud NETWORK_ERROR → verified cached IP is used',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException(
          'Could not reach the server',
          code: 'NETWORK_ERROR',
        );
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
      });
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(cloud.controlCalls, 1);
      expect(locator.cachedQueries, 1);
      // Identity is re-verified at discovery AND immediately before the relay
      // command (a device could be repurposed between the two moments).
      expect(cm.called, ['Status%205', 'Status%205', 'Power1%20ON']);
      expect(result['POWER1'], 'ON');
      expect(repo.lastSource, DeviceTransportSource.local);
      expect(locator.mDnsQueries, 0);
    });

    test('control: cloud TIMEOUT → local fallback is attempted', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('Timed out', code: 'TIMEOUT');
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power2%20OFF': '{"POWER2":"OFF"}',
      });
      final repo = _repo(
        cloud,
        locator: _FakeLocator(cached: '10.0.0.7'),
        cm: cm,
      );

      final result = await repo.control(_deviceId, 2, 'OFF');

      expect(result['POWER2'], 'OFF');
      expect(repo.lastSource, DeviceTransportSource.local);
    });

    test('status: cloud 5xx → local fallback is allowed', () async {
      final cloud = _FakeCloudApi()
        ..statusError = const ApiException('boom', statusCode: 503);
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'State': _statusBody,
      });
      final repo = _repo(
        cloud,
        locator: _FakeLocator(cached: '192.168.1.5'),
        cm: cm,
      );

      final result = await repo.getStatus(_deviceId);

      expect(cloud.statusCalls, 1);
      expect(result['POWER1'], 'ON');
      expect(repo.lastSource, DeviceTransportSource.local);
    });

    test('control: cloud 409 DEVICE_OFFLINE → local fallback is attempted',
        () async {
      // The backend is healthy but the device is not on MQTT — exactly when the
      // LAN must get a chance. The real 409 carries NO machine code.
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException(
          'Device is not connected or is powered off',
          statusCode: 409,
        );
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
      });
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(cloud.controlCalls, 1);
      expect(locator.cachedQueries, 1,
          reason: 'local discovery must run for a device-offline 409');
      expect(result['POWER1'], 'ON');
      expect(repo.lastSource, DeviceTransportSource.local);
      expect(locator.mDnsQueries, 0);
    });

    test('control: cloud 409 + local unreachable → ORIGINAL 409 is surfaced',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException(
          'Device is not connected or is powered off',
          statusCode: 409,
        );
      final repo = _repo(cloud, locator: _FakeLocator(cached: null));

      await expectLater(
        repo.control(_deviceId, 1, 'ON'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.statusCode,
            'statusCode',
            409,
          ),
        ),
      );
      expect(repo.lastSource, isNull,
          reason: 'both clouds failed — no transport wins');
    });
  });

  group('cloud-200 device-offline status probes local', () {
    test('cloud reports offline but LAN verifies → live LAN status wins',
        () async {
      final cloud = _FakeCloudApi()..statusOnline = false;
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'State':
            '{"POWER1":"ON","POWER2":"ON","POWER3":"OFF","POWER4":"OFF"}',
      });
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.getStatus(_deviceId);

      expect(cloud.statusCalls, 1);
      expect(locator.cachedQueries, 1,
          reason: 'a cloud-offline device must still probe the LAN');
      expect(result['online'], isTrue);
      expect(result['POWER2'], 'ON');
      expect(repo.lastSource, DeviceTransportSource.local);
    });

    test('cloud offline + LAN unreachable → cloud offline truth kept, no throw',
        () async {
      final cloud = _FakeCloudApi()..statusOnline = false;
      final repo = _repo(cloud, locator: _FakeLocator(cached: null));

      final result = await repo.getStatus(_deviceId);

      expect(cloud.statusCalls, 1);
      expect(result['online'], isFalse);
      expect(repo.lastSource, DeviceTransportSource.cloud,
          reason: 'no LAN device — cloud truth stays authoritative');
    });
  });

  group('logical cloud errors NEVER fall back', () {
    test('control: cloud 4xx is surfaced, discovery untouched', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException(
          'Device is offline',
          statusCode: 409,
          code: 'DEVICE_OFFLINE',
        );
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator);

      await expectLater(
        repo.control(_deviceId, 1, 'ON'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.code, 'code', 'DEVICE_OFFLINE'),
        ),
      );
      expect(locator.cachedQueries, 0);
      expect(locator.mDnsQueries, 0);
    });

    test('status: cloud 400 is surfaced, no fallback', () async {
      final cloud = _FakeCloudApi()
        ..statusError = const ApiException('Bad request', statusCode: 400);
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator);

      await expectLater(
        repo.getStatus(_deviceId),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 's', 400)),
      );
      expect(locator.cachedQueries, 0);
    });
  });

  group('cache + mDNS ladder and identity verification', () {
    test('verified IP cache is used first (mDNS not consulted)', () async {
      final cloud = _FakeCloudApi()
        ..controlError =
            const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
      });
      final locator = _FakeLocator(
        cached: '192.168.1.5',
        candidates: ['10.0.0.9'],
      );
      final repo = _repo(cloud, locator: locator, cm: cm);

      await repo.control(_deviceId, 1, 'ON');

      expect(locator.cachedQueries, 1);
      expect(locator.mDnsQueries, 0,
          reason: 'cached, verified IP wins — mDNS must not run');
    });

    test('identity-verified mDNS candidate is cached for next time', () async {
      final cloud = _FakeCloudApi()
        ..controlError =
            const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
      });
      final locator = _FakeLocator(
        cached: null,
        candidates: ['192.168.1.5'],
      );
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(result['POWER1'], 'ON');
      expect(locator.mDnsQueries, 1);
      expect(locator.stores, 1);
      expect(locator.lastStored, '192.168.1.5');
      expect(repo.lastSource, DeviceTransportSource.local);
    });

    test('stale cached IP (MAC mismatch) is discarded, mDNS re-discovered',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError =
            const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake(responses: {
        // cached IP replies but with a FOREIGN MAC
        'Status%205': _foreignMacBody,
      });
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await expectLater(
        repo.control(_deviceId, 1, 'ON'),
        throwsA(isA<ApiException>()),
      );

      expect(locator.discards, 1,
          reason: 'a repurposed/foreign IP must never be trusted or kept');
      expect(locator.cachedQueries, 1);
    });

    test('cache miss + MAC-match mDNS candidate is used and cached', () async {
      final cloud = _FakeCloudApi()
        ..controlError =
            const ApiException('down', code: 'NETWORK_ERROR');
      // 10.0.0.2 answers but as a FOREIGN Tasmota; only 192.168.1.5 reports
      // the expected MAC, so the ladder must skip the first and pick the match.
      final cm = _CmFake(
        responses: {
          'Power1%20ON': '{"POWER1":"ON"}',
        },
        macByAddress: {
          '10.0.0.2': _foreignMacBody,
          '192.168.1.5': _macBody,
        },
      );
      final locator = _FakeLocator(
        cached: null,
        candidates: ['10.0.0.2', '192.168.1.5'],
      );
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(result['POWER1'], 'ON');
      expect(locator.lastStored, '192.168.1.5',
          reason: 'the address that truthfully owns the device MAC is cached');
    });

    test('foreign discovered Tasmota devices are ignored (never cached)',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError =
            const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake(responses: {
        'Status%205': _foreignMacBody,
        'Power1%20ON': '{"POWER1":"ON"}',
      });
      final locator = _FakeLocator(
        cached: null,
        candidates: ['10.0.0.2', '192.168.1.5'],
      );
      final repo = _repo(cloud, locator: locator, cm: cm);

      await expectLater(
        repo.control(_deviceId, 1, 'ON'),
        throwsA(isA<ApiException>()),
      );

      expect(locator.stores, 0,
          reason: 'no foreign device may ever be cached as this device');
      expect(
        cm.called.where((c) => c.startsWith('Power')).toList(),
        isEmpty,
        reason: 'no relay command may target a foreign device',
      );
    });
  });

  group('both transports unavailable', () {
    test('offline result: ORIGINAL cloud availability error is surfaced',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException(
          'Could not reach the server. Check your connection.',
          code: 'NETWORK_ERROR',
        );
      final locator = _FakeLocator(cached: null, candidates: []);
      final repo = _repo(cloud, locator: locator);

      await expectLater(
        repo.control(_deviceId, 1, 'ON'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'NETWORK_ERROR',
          ),
        ),
      );
      expect(repo.lastSource, isNull);
    });

    test('cloud down + local unreachable cached IP → offline error, cache dropped',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError =
            const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake(responses: {})..unreachable = true;
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await expectLater(
        repo.control(_deviceId, 1, 'ON'),
        throwsA(isA<ApiException>()),
      );
      expect(locator.discards, 1);
    });
  });

  group('cloud preference recovery', () {
    test('when the cloud returns, it is preferred again automatically',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError =
            const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
      });
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      // First attempt: cloud down → local succeeds.
      final first = await repo.control(_deviceId, 1, 'ON');
      expect(first['POWER1'], 'ON');
      expect(repo.lastSource, DeviceTransportSource.local);
      expect(locator.cachedQueries, 1);

      // Cloud comes back: next attempt must never consult local discovery.
      cloud.controlError = null;
      final second = await repo.control(_deviceId, 1, 'OFF');
      expect(second['POWER1'], 'OFF');
      expect(cloud.controlCalls, 2);
      expect(locator.cachedQueries, 1, reason: 'cloud is preferred again');
      expect(repo.lastSource, DeviceTransportSource.cloud);
    });
  });
}