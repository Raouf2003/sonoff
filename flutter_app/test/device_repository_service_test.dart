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

/// Tasmota stub over the injectable cmd fetcher. `macByAddress` queues MAC
/// bodies per address so a test can make identity CHANGE between discovery and
/// the command-time re-verify (a repurposed box). Once a queue is empty the
/// plain `responses` table is consulted.
class _CmFake {
  _CmFake({
    Map<String, String>? responses,
    Map<String, List<String>>? macByAddress,
  })  : responses = responses ?? {},
        macByAddress = macByAddress ?? {};

  final Map<String, String> responses;

  /// Address → queue of `Status 5` bodies. Shifted on each identity probe so a
  /// test can simulate identity changing between discovery and command.
  final Map<String, List<String>> macByAddress;
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
      final queue = macByAddress[address];
      if (queue != null && queue.isNotEmpty) {
        return queue.removeAt(0);
      }
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
  _FakeLocator({
    this.cached,
    this.verifiedAt,
    this.candidates = const [],
  });

  String? cached;
  DateTime? verifiedAt;
  List<String> candidates;
  int cachedQueries = 0;
  int verifiedAtQueries = 0;
  int mDnsQueries = 0;
  int stores = 0;
  int candidateStores = 0;
  int discards = 0;
  String? lastStored;
  String? lastCandidate;

  @override
  Future<String?> cachedAddress(String deviceId) async {
    cachedQueries++;
    return cached;
  }

  @override
  Future<DateTime?> cachedVerifiedAt(String deviceId) async {
    verifiedAtQueries++;
    return verifiedAt;
  }

  @override
  Future<void> storeVerifiedAddress(String deviceId, String ip) async {
    stores++;
    lastStored = ip;
  }

  @override
  Future<void> storeCandidateAddress(String deviceId, String ip) async {
    candidateStores++;
    lastCandidate = ip;
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

/// A `_CmFake` that serves a normal local relay on the cached IP.
_CmFake _localRelayCm() {
  return _CmFake(
    responses: {
      'Status%205': _macBody,
      'Power1%20ON': '{"POWER1":"ON"}',
      'State': '{"POWER1":"ON"}',
    },
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

  group('local is preferred and wins', () {
    test('control: local success never touches the cloud', () async {
      final cloud = _FakeCloudApi();
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(cloud.controlCalls, 0,
          reason: 'a working LAN relay must not need the cloud');
      expect(result.channels[1]!.state, 'ON');
      expect(result.online, isTrue);
      expect(result.source, DeviceTransportSource.local);
      expect(locator.mDnsQueries, 0,
          reason: 'a cached verified IP avoids mDNS entirely');
      expect(cm.called,
          containsAll(['Status%205', 'Power1%20ON', 'State']));
    });

    test('status: local success never touches the cloud', () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'State': _statusBody,
      });
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.getStatus(_deviceId);

      expect(cloud.statusCalls, 0);
      expect(result.channels[1]!.state, 'ON');
      expect(result.channels[2]!.state, 'OFF');
      expect(result.source, DeviceTransportSource.local);
    });
  });

  group('local availability failure falls back to cloud', () {
    test('control: no local device → cloud is used once', () async {
      final cloud = _FakeCloudApi();
      final repo = _repo(cloud, locator: _FakeLocator());

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(cloud.controlCalls, 1);
      expect(result.channels[1]!.state, 'ON');
      expect(result.source, DeviceTransportSource.cloud);
    });

    test('control: local unreachable → cloud is used once', () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake()..unreachable = true;
      // A previously-VERIFIED address that no longer answers is dead weight and
      // must be discarded (a cloud-learned CANDIDATE would instead be kept).
      final locator = _FakeLocator(
        cached: '192.168.1.5',
        verifiedAt: DateTime.now().subtract(kVerifiedIpTtl * 2),
      );
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(cloud.controlCalls, 1);
      expect(result.source, DeviceTransportSource.cloud);
      expect(locator.discards, 1,
          reason: 'the dead verified cached IP must not be trusted next time');
    });

    test('status: no local device → cloud is used once', () async {
      final cloud = _FakeCloudApi();
      final repo = _repo(cloud, locator: _FakeLocator());

      final result = await repo.getStatus(_deviceId);

      expect(cloud.statusCalls, 1);
      expect(result.channels[1]!.state, 'ON');
      expect(result.source, DeviceTransportSource.cloud);
    });

    test('control: local unavailable + cloud 5xx → both down, wrapped failure',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('boom', statusCode: 503);
      final repo = _repo(cloud, locator: _FakeLocator());

      await expectLater(
        repo.control(_deviceId, 1, 'ON'),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => e.cause,
            'cause',
            isNotNull,
          ),
        ),
      );
      expect(cloud.controlCalls, 1,
          reason: 'cloud is attempted after local fails, then both are down');
    });
  });

  group('local logical rejections are NEVER rerouted to cloud', () {
    test('control: identity mismatch at command time is surfaced', () async {
      // Discovery trusts the (fresh) verified cache; the command-time re-verify
      // discovers the box has been repurposed — a security rejection that must
      // surface, never fall back to the cloud.
      final cloud = _FakeCloudApi();
      final cm = _CmFake(
        responses: {'Power1%20ON': '{"POWER1":"ON"}', 'State': '{"POWER1":"ON"}'},
        macByAddress: {'192.168.1.5': [_foreignMacBody]},
      );
      final locator = _FakeLocator(
        cached: '192.168.1.5',
        verifiedAt: DateTime.now(),
      );
      final repo = _repo(cloud, locator: locator, cm: cm);

      await expectLater(
        repo.control(_deviceId, 1, 'ON'),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => e.kind,
            'kind',
            TransportFailureKind.logical,
          ),
        ),
      );
      expect(cloud.controlCalls, 0,
          reason: 'a foreign device must never trigger a cloud command');
    });

    test('control: unconfirmed command (read-back mismatch) is surfaced',
        () async {
      final cloud = _FakeCloudApi();
      // The relay answers Power1 ON but the follow-up State reads back OFF.
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
        'State': '{"POWER1":"OFF"}',
      });
      final repo = _repo(
        cloud,
        locator: _FakeLocator(cached: '192.168.1.5'),
        cm: cm,
      );

      await expectLater(
        repo.control(_deviceId, 1, 'ON'),
        throwsA(
          isA<DeviceTransportException>()
              .having((e) => e.kind, 'kind', TransportFailureKind.logical)
              .having((e) => e.code, 'code', 'UNCONFIRMED'),
        ),
      );
      expect(cloud.controlCalls, 0,
          reason: 'the device was already contacted — no cloud resend');
    });

    test('control: local unavailable + coded cloud 409 is surfaced', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException(
          'Device is offline',
          statusCode: 409,
          code: 'DEVICE_OFFLINE',
        );
      final repo = _repo(cloud, locator: _FakeLocator());

      await expectLater(
        repo.control(_deviceId, 1, 'ON'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.code, 'code', 'DEVICE_OFFLINE'),
        ),
      );
    });
  });

  group('both transports unavailable', () {
    test('control: local + cloud both down → DeviceTransportException wrapping '
        'the local failure', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException(
          'Could not reach the server. Check your connection.',
          code: 'NETWORK_ERROR',
        );
      final repo = _repo(cloud, locator: _FakeLocator());

      await expectLater(
        repo.control(_deviceId, 1, 'ON'),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => e.cause,
            'cause',
            isNotNull,
          ),
        ),
      );
      expect(repo.lastSource, isNull,
          reason: 'both transports failed — no transport wins');
    });

    test('status: local + cloud both down → cloud error is surfaced', () async {
      final cloud = _FakeCloudApi()
        ..statusError = const ApiException('down', code: 'NETWORK_ERROR');
      final repo = _repo(cloud, locator: _FakeLocator());

      await expectLater(
        repo.getStatus(_deviceId),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'NETWORK_ERROR'),
        ),
      );
    });
  });

  group('cloud offline handling', () {
    test('cloud says offline + LAN unreachable → cloud truth kept, no throw',
        () async {
      final cloud = _FakeCloudApi()..statusOnline = false;
      final repo = _repo(cloud, locator: _FakeLocator());

      final result = await repo.getStatus(_deviceId);

      expect(cloud.statusCalls, 1);
      expect(result.online, isFalse);
      expect(result.source, DeviceTransportSource.cloud,
          reason: 'no LAN device — the cloud offline answer stays authoritative');
    });

    test('local report wins even though the cloud would claim offline',
        () async {
      final cloud = _FakeCloudApi()..statusOnline = false;
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'State': '{"POWER1":"ON"}',
      });
      final repo = _repo(
        cloud,
        locator: _FakeLocator(cached: '192.168.1.5'),
        cm: cm,
      );

      final result = await repo.getStatus(_deviceId);

      expect(cloud.statusCalls, 0,
          reason: 'the live LAN report is consulted before the cloud');
      expect(result.channels[1]!.state, 'ON');
      expect(result.source, DeviceTransportSource.local);
    });
  });

  group('discovery ladder and identity verification', () {
    test('concurrent local fallbacks share ONE discovery window', () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake(
        responses: {
          'Status%205': _macBody,
          'Power1%20ON': '{"POWER1":"ON"}',
          'State': '{"POWER1":"ON"}',
        },
        macByAddress: {'192.168.1.5': [_macBody]},
      );
      final locator = _FakeLocator(candidates: ['192.168.1.5']);
      final repo = _repo(cloud, locator: locator, cm: cm);

      final results = await Future.wait([
        repo.control(_deviceId, 1, 'ON'),
        repo.control(_deviceId, 1, 'ON'),
      ]);

      expect(results[0].channels[1]!.state, 'ON');
      expect(results[1].channels[1]!.state, 'ON');
      expect(locator.cachedQueries, 1,
          reason: 'only one discovery ladder may run for the same device');
      expect(locator.mDnsQueries, 1,
          reason: 'a second concurrent caller reuses the in-flight window');
      expect(locator.stores, 1);
    });

    test('fresh verified cached IP is used without re-verification', () async {
      final cloud = _FakeCloudApi();
      final cm = _localRelayCm();
      final locator = _FakeLocator(
        cached: '192.168.1.5',
        verifiedAt: DateTime.now(),
      );
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(result.channels[1]!.state, 'ON');
      expect(locator.mDnsQueries, 0);
      expect(locator.verifiedAtQueries, 1);
    });

    test('stale verified cached IP is re-verified before use', () async {
      final cloud = _FakeCloudApi();
      final cm = _localRelayCm();
      final locator = _FakeLocator(
        cached: '192.168.1.5',
        verifiedAt: DateTime.now().subtract(kVerifiedIpTtl * 2),
      );
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(result.channels[1]!.state, 'ON');
      expect(locator.discards, 0,
          reason: 're-verification succeeded — the cache stays');
      expect(locator.mDnsQueries, 0);
    });

    test('stale cached IP with a foreign MAC is discarded, mDNS re-discovered',
        () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake(
        responses: {
          'Status%205': _macBody,
          'Power1%20ON': '{"POWER1":"ON"}',
          'State': '{"POWER1":"ON"}',
        },
        macByAddress: {
          '192.168.1.5': [_foreignMacBody],
          '10.0.0.9': [_macBody],
        },
      );
      final locator = _FakeLocator(
        cached: '192.168.1.5',
        verifiedAt: DateTime.now().subtract(kVerifiedIpTtl * 2),
        candidates: ['10.0.0.9'],
      );
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(result.channels[1]!.state, 'ON');
      expect(locator.discards, 1,
          reason: 'a repurposed/foreign cached IP must never be trusted');
      expect(locator.lastStored, '10.0.0.9',
          reason: 'the identity-verified mDNS candidate is cached instead');
    });

    test('cache miss: identity-verified mDNS candidate is cached', () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake(
        responses: {
          'Status%205': _macBody,
          'Power1%20ON': '{"POWER1":"ON"}',
          'State': '{"POWER1":"ON"}',
        },
        macByAddress: {'192.168.1.5': [_macBody]},
      );
      final locator = _FakeLocator(candidates: ['192.168.1.5']);
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(result.channels[1]!.state, 'ON');
      expect(locator.mDnsQueries, 1);
      expect(locator.stores, 1);
      expect(locator.lastStored, '192.168.1.5');
    });

    test('foreign mDNS candidates are ignored (never cached, never commanded)',
        () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake(
        responses: {'Power1%20ON': '{"POWER1":"ON"}', 'State': '{"POWER1":"ON"}'},
        macByAddress: {'10.0.0.2': [_foreignMacBody]},
      );
      final locator = _FakeLocator(candidates: ['10.0.0.2']);
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(result.source, DeviceTransportSource.cloud,
          reason: 'no verified local device found — cloud fallback');
      expect(locator.stores, 0,
          reason: 'no foreign device may ever be cached as this device');
      expect(
        cm.called.where((c) => c.startsWith('Power')).toList(),
        isEmpty,
        reason: 'no relay command may target a foreign device',
      );
    });

    test('warmUp populates the warm endpoint so a tap skips discovery',
        () async {
      final cloud = _FakeCloudApi();
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await repo.warmUp(const [
        {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
      ]);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(result.channels[1]!.state, 'ON');
      expect(locator.cachedQueries, 1,
          reason: 'the tap hit the warm endpoint, no further discovery');
      expect(locator.mDnsQueries, 0);
      expect(cloud.controlCalls, 0);
    });
  });

  group('cloud-learned IP candidates seed local discovery', () {
    test('getDevices seeds a candidate for every device lastIp', () async {
      final cloud = _FakeCloudApi()
        ..devices = [
          {
            'deviceId': _deviceId,
            'name': 'Controller',
            'channels': 4,
            'lastIp': '192.168.1.5',
          },
        ];
      final locator = _FakeLocator();
      final repo = _repo(cloud, locator: locator);

      final devices = await repo.getDevices();

      expect(devices, hasLength(1));
      expect(locator.candidateStores, 1);
      expect(locator.lastCandidate, '192.168.1.5',
          reason: 'the cloud-learned IP becomes an unverified local hint');
    });

    test('offline getDevices seeds candidates from the cached list', () async {
      final cloud = _FakeCloudApi()
        ..devicesError = const ApiException('down', code: 'NETWORK_ERROR');
      final cache = LocalDeviceCache();
      await cache.replaceAll([
        {
          'deviceId': _deviceId,
          'name': 'Controller',
          'channels': 4,
          'lastIp': '192.168.1.5',
        },
      ]);
      final locator = _FakeLocator();
      final repo = _repo(cloud, locator: locator, cache: cache);

      final devices = await repo.getDevices();

      expect(devices, hasLength(1));
      expect(locator.candidateStores, 1);
      expect(locator.lastCandidate, '192.168.1.5');
    });

    test('getDevices ignores non-IP and missing lastIp values', () async {
      final cloud = _FakeCloudApi()
        ..devices = [
          {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
          {
            'deviceId': '222222222222',
            'name': 'NoIP',
            'channels': 1,
            'lastIp': 'not-an-ip',
          },
        ];
      final locator = _FakeLocator();
      final repo = _repo(cloud, locator: locator);

      await repo.getDevices();

      expect(locator.candidateStores, 0);
    });

    test(
        'offline control works via a candidate: cloud down + reachable device',
        () async {
      // The exact reported scenario: internet OFF, phone and device on the same
      // Wi-Fi. The cloud cannot help, but the cloud-learned IP (seeded while
      // online) lets discovery find the device WITHOUT mDNS.
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5'); // verifiedAt == null
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(cloud.controlCalls, 0,
          reason: 'the LAN device was reachable — no cloud needed');
      expect(result.channels[1]!.state, 'ON');
      expect(result.source, DeviceTransportSource.local);
      expect(locator.mDnsQueries, 0,
          reason: 'the candidate IP verified — mDNS was never needed');
      expect(locator.stores, 1,
          reason: 'the verified candidate is promoted to a verified entry');
    });

    test('an unreachable candidate is KEPT (device may be off)', () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake()..unreachable = true;
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(result.source, DeviceTransportSource.cloud);
      expect(locator.discards, 0,
          reason: 'a cloud-learned hint survives transient unavailability');
      expect(locator.mDnsQueries, 1,
          reason: 'mDNS still gets a chance after the candidate fails');
    });

    test('a candidate with a foreign MAC is discarded', () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake(
        responses: {'Power1%20ON': '{"POWER1":"ON"}', 'State': '{"POWER1":"ON"}'},
        macByAddress: {'192.168.1.5': [_foreignMacBody]},
      );
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(result.source, DeviceTransportSource.cloud);
      expect(locator.discards, 1,
          reason: 'a repurposed address must never be trusted');
    });

    test('a local report with a new IPAddress refreshes the discovery cache',
        () async {
      final cloud = _FakeCloudApi();
      // The box answers at 192.168.1.5 but reports its current address as
      // 192.168.1.77 (DHCP lease changed).
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
        'State': '{"POWER1":"ON","IPAddress":"192.168.1.77"}',
      });
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await repo.control(_deviceId, 1, 'ON');
      await pumpEventQueue();

      expect(locator.lastStored, '192.168.1.77',
          reason: 'the freshest reported address is remembered for next time');
    });

    test('a matching reported IPAddress does not churn the cache', () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
        'State': '{"POWER1":"ON","IPAddress":"192.168.1.5"}',
      });
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await repo.control(_deviceId, 1, 'ON');
      await pumpEventQueue();

      expect(locator.stores, 1,
          reason: 'only the candidate-promotion write happens; the matching '
              'report adds no extra write');
      expect(locator.lastStored, '192.168.1.5');
    });
  });
}
