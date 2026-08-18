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
  String? lastControlOpId;
  List<Map<String, dynamic>> devices = [];
  Map<String, dynamic> statusBody = {};
  Map<String, dynamic> controlBody = {};

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
    String state, {
    String? opId,
  }) async {
    controlCalls++;
    lastControlOpId = opId;
    final err = controlError;
    if (err != null) throw err;
    return {'online': true, 'POWER$channel': state, ...controlBody};
  }

  @override
  Future<Map<String, dynamic>> getStatus(String deviceId) async {
    statusCalls++;
    final err = statusError;
    if (err != null) throw err;
    return {'online': statusOnline, ...jsonDecode(_statusBody), ...statusBody};
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
  final Map<String, String?> refererByCommand = {};
  Object? error;

  Future<String> call(
    String address,
    String command, {
    String? password,
    String? deviceId,
    String? referer,
  }) async {
    called.add(command);
    refererByCommand[command] = referer;
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
    // Mirror the real locator: a DIFFERENT hint replaces the stored entry as
    // an unverified candidate; the same address leaves the entry untouched
    // (so a fresh verified entry is never downgraded).
    if (cached != ip) {
      cached = ip;
      verifiedAt = null;
    }
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

  group('control: cloud-first, local fallback on availability only', () {
    test('cloud success returns the cloud result; the LAN is never touched',
        () async {
      final cloud = _FakeCloudApi();
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(cloud.controlCalls, 1);
      expect(result.channels[1]!.state, 'ON');
      expect(result.online, isTrue);
      expect(result.source, DeviceTransportSource.cloud);
      expect(cm.called, isEmpty,
          reason: 'the LAN is never probed when the cloud answered');
      expect(locator.cachedQueries, 0,
          reason: 'no local discovery runs on a cloud-first tap');
      expect(locator.mDnsQueries, 0);
    });

    test('cloud availability failure falls back to the LAN', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(cloud.controlCalls, 1);
      expect(result.channels[1]!.state, 'ON');
      expect(result.source, DeviceTransportSource.local);
      expect(locator.mDnsQueries, 0,
          reason: 'the cached verified IP avoids mDNS entirely');
      expect(cm.called,
          containsAll(['Status%205', 'Power1%20ON', 'State']));
    });

    test('cloud business rejection is surfaced; the LAN is never touched',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('Forbidden', statusCode: 403);
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await expectLater(
        repo.control(_deviceId, 1, 'ON'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
      expect(cloud.controlCalls, 1);
      expect(cm.called, isEmpty,
          reason: 'a business rejection must never fall back to the LAN');
      expect(locator.cachedQueries, 0);
    });

    test('cloud 5xx is availability: the LAN gets its chance', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('boom', statusCode: 503);
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(cloud.controlCalls, 1);
      expect(result.source, DeviceTransportSource.local);
    });

    test('coded cloud 409 (device offline) is surfaced; the LAN is untouched',
        () async {
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
      expect(cloud.controlCalls, 1);
    });

    test('cloud unavailable + LAN unavailable → wrapped availability error',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
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
      expect(cloud.controlCalls, 1);
      expect(repo.lastSource, isNull,
          reason: 'both transports failed — no transport wins');
    });

    test('opId is propagated to the cloud transport', () async {
      final cloud = _FakeCloudApi();
      final repo = _repo(cloud);

      await repo.control(_deviceId, 1, 'ON', opId: 'tap-42');

      expect(cloud.lastControlOpId, 'tap-42');
    });

    test('cloudDown=true + LAN success returns locally; cloud never called',
        () async {
      final cloud = _FakeCloudApi();
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON', cloudDown: true);

      expect(cloud.controlCalls, 0,
          reason: 'a known-unreachable cloud must not be waited on');
      expect(result.source, DeviceTransportSource.local);
      expect(result.channels[1]!.state, 'ON');
      expect(cm.called, containsAll(['Status%205', 'Power1%20ON', 'State']));
    });

    test('cloudDown=true + LAN availability failure falls back to the cloud',
        () async {
      final cloud = _FakeCloudApi();
      final repo = _repo(cloud, locator: _FakeLocator()); // no local device

      final result = await repo.control(_deviceId, 1, 'ON', cloudDown: true);

      expect(cloud.controlCalls, 1,
          reason: 'the cloud is the safety fallback when the LAN is unavailable');
      expect(result.source, DeviceTransportSource.cloud);
      expect(result.channels[1]!.state, 'ON');
    });

    test('cloudDown=true + LAN logical rejection is surfaced; cloud untouched',
        () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake(macByAddress: {
        '192.168.1.5': [_foreignMacBody],
      });
      final locator = _FakeLocator(
        cached: '192.168.1.5',
        verifiedAt: DateTime.now(),
      );
      final repo = _repo(cloud, locator: locator, cm: cm);

      await expectLater(
        repo.control(_deviceId, 1, 'ON', cloudDown: true),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => e.kind,
            'kind',
            TransportFailureKind.logical,
          ),
        ),
      );
      expect(cloud.controlCalls, 0,
          reason: 'a logical LAN rejection must never reach the cloud');
    });

    test('cloudDown=false keeps the cloud-first default unchanged', () async {
      final cloud = _FakeCloudApi();
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(cloud.controlCalls, 1);
      expect(result.source, DeviceTransportSource.cloud);
      expect(cm.called, isEmpty,
          reason: 'no local discovery runs before the cloud when it is reachable');
    });
  });

  group('status: local-first with cloud fallback', () {
    test('local success never touches the cloud', () async {
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

    test('no local device → cloud is used once', () async {
      final cloud = _FakeCloudApi();
      final repo = _repo(cloud, locator: _FakeLocator());

      final result = await repo.getStatus(_deviceId);

      expect(cloud.statusCalls, 1);
      expect(result.channels[1]!.state, 'ON');
      expect(result.source, DeviceTransportSource.cloud);
    });
  });

  group('logical rejections are NEVER rerouted', () {
    test('control: LAN identity mismatch surfaces after a cloud outage',
        () async {
      // Cloud unavailable → the LAN fallback runs, and its command-time
      // re-verify discovers the box has been repurposed — a security rejection
      // that must surface, never be retried.
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
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
      expect(cloud.controlCalls, 1);
    });

    test('control: unconfirmed command (read-back mismatch) is surfaced',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
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
      expect(cloud.controlCalls, 1);
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
      // Cloud unavailable → both taps land on the LAN fallback and must share
      // one discovery ladder instead of opening two mDNS browsers.
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
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
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
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
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
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
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
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
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
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
      // Cloud unavailable → the LAN fallback runs. Its only mDNS hit is a
      // foreign box: never cached, never commanded, so the tap ends in a
      // wrapped availability failure instead of reaching a stranger's relay.
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake(
        responses: {'Power1%20ON': '{"POWER1":"ON"}', 'State': '{"POWER1":"ON"}'},
        macByAddress: {'10.0.0.2': [_foreignMacBody]},
      );
      final locator = _FakeLocator(candidates: ['10.0.0.2']);
      final repo = _repo(cloud, locator: locator, cm: cm);

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
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
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
      expect(cloud.controlCalls, 1,
          reason: 'the cloud is attempted first; the offline tap then uses '
              'the warm endpoint');
    });
  });

  group('cold LAN: one identity probe, operations reuse it', () {
    test('a just-probed discovery lets the first control skip the duplicate '
        'Status 5 probe', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
        'State': '{"POWER1":"ON","POWER2":"OFF"}',
      });
      final locator = _FakeLocator(cached: '192.168.1.5'); // verifiedAt == null
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON');

      expect(result.source, DeviceTransportSource.local);
      expect(cm.called, ['Status%205', 'Power1%20ON', 'State'],
          reason: 'discovery verified once; the control must not re-probe '
              'Status 5 (the cold-start LAN cost)');
    });

    test('a status read right after discovery reuses the probe too',
        () async {
      final cloud = _FakeCloudApi()
        ..statusError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'State': '{"POWER1":"ON","POWER2":"OFF"}',
      });
      final locator = _FakeLocator(cached: '192.168.1.5'); // verifiedAt == null
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.getStatus(_deviceId);

      expect(result.source, DeviceTransportSource.local);
      expect(cm.called, ['Status%205', 'State'],
          reason: 'the discovery probe satisfies the identity check; no second '
              'Status 5 before the status read');
    });

    test('subsequent local controls reuse the verified endpoint, no re-probe',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
        'Power2%20OFF': '{"POWER2":"OFF"}',
        'State': '{"POWER1":"ON","POWER2":"OFF"}',
      });
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await repo.control(_deviceId, 1, 'ON');
      cm.called.clear();

      final result = await repo.control(_deviceId, 2, 'OFF');

      expect(result.source, DeviceTransportSource.local);
      expect(cm.called, ['Power2%20OFF', 'State'],
          reason: 'the warm verified endpoint is reused directly; no duplicate '
              'identity probe on later controls');
    });

    test('multiple cold controls share ONE discovery and ONE identity probe',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
        'Power2%20OFF': '{"POWER2":"OFF"}',
        'Power3%20ON': '{"POWER3":"ON"}',
        'State': '{"POWER1":"ON","POWER2":"OFF","POWER3":"ON"}',
      });
      final locator = _FakeLocator(candidates: ['192.168.1.5']);
      final repo = _repo(cloud, locator: locator, cm: cm);

      final results = await Future.wait([
        repo.control(_deviceId, 1, 'ON'),
        repo.control(_deviceId, 2, 'OFF'),
        repo.control(_deviceId, 3, 'ON'),
      ]);

      expect(locator.mDnsQueries, 1,
          reason: 'all three controls share the single in-flight discovery');
      expect(cm.called.where((c) => c == 'Status%205').length, 1,
          reason: 'the shared discovery verifies once; every control reuses it');
      expect(results.every((r) => r.source == DeviceTransportSource.local),
          isTrue);
    });

    test('a fresh verified cached IP STILL re-verifies before command',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
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
      expect(cloud.controlCalls, 1,
          reason: 'the cloud is tried once (cloud-first); the command-time '
              're-verify then catches the repurposed box as a logical rejection '
              'that must surface — never retried on the cloud or the LAN');
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

    test('a cloud status response with lastIp seeds the candidate', () async {
      final cloud = _FakeCloudApi()
        ..statusBody = {'lastIp': '192.168.1.5'};
      final locator = _FakeLocator();
      final repo = _repo(cloud, locator: locator);

      await repo.getStatus(_deviceId);

      expect(cloud.statusCalls, 1);
      expect(locator.candidateStores, 1);
      expect(locator.lastCandidate, '192.168.1.5',
          reason: 'the online status poll self-seeds without a list refresh');
    });

    test('a cloud control response with lastIp seeds the candidate', () async {
      final cloud = _FakeCloudApi()
        ..controlBody = {'lastIp': '192.168.1.5'};
      final locator = _FakeLocator();
      final repo = _repo(cloud, locator: locator);

      await repo.control(_deviceId, 1, 'ON');

      expect(locator.candidateStores, 1);
      expect(locator.lastCandidate, '192.168.1.5');
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

      expect(cloud.controlCalls, 1,
          reason: 'cloud is attempted first and fails; the candidate IP is '
              'then used offline');
      expect(result.channels[1]!.state, 'ON');
      expect(result.source, DeviceTransportSource.local);
      expect(locator.mDnsQueries, 0,
          reason: 'the candidate IP verified — mDNS was never needed');
      expect(locator.stores, 1,
          reason: 'the verified candidate is promoted to a verified entry');
    });

    test('an unreachable candidate is KEPT (device may be off)', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake()..unreachable = true;
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

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
      expect(locator.discards, 0,
          reason: 'a cloud-learned hint survives transient unavailability');
      expect(locator.mDnsQueries, 1,
          reason: 'mDNS still gets a chance after the candidate fails');
    });

    test('a candidate with a foreign MAC is discarded', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake(
        responses: {'Power1%20ON': '{"POWER1":"ON"}', 'State': '{"POWER1":"ON"}'},
        macByAddress: {'192.168.1.5': [_foreignMacBody]},
      );
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

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
      expect(locator.discards, 1,
          reason: 'a repurposed address must never be trusted');
    });

    test('a local report with a new IPAddress refreshes the discovery cache',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
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
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
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

  group('invalid addresses are rejected everywhere', () {
    test('getDevices never seeds a candidate from a lastIp of 0.0.0.0',
        () async {
      final cloud = _FakeCloudApi()
        ..devices = [
          {
            'deviceId': _deviceId,
            'name': 'Controller',
            'channels': 4,
            'lastIp': '0.0.0.0',
          },
        ];
      final locator = _FakeLocator();
      final repo = _repo(cloud, locator: locator);

      await repo.getDevices();

      expect(locator.candidateStores, 0,
          reason: 'a transient 0.0.0.0 must never seed a discovery candidate');
    });

    test('getDevices never seeds a candidate from loopback or multicast',
        () async {
      final cloud = _FakeCloudApi()
        ..devices = [
          {
            'deviceId': _deviceId,
            'name': 'Controller',
            'channels': 4,
            'lastIp': '127.0.0.1',
          },
          {
            'deviceId': '222222222222',
            'name': 'NoIP',
            'channels': 1,
            'lastIp': '239.255.255.250',
          },
        ];
      final locator = _FakeLocator();
      final repo = _repo(cloud, locator: locator);

      await repo.getDevices();

      expect(locator.candidateStores, 0);
    });

    test('an invalid cached address is discarded and never reaches the fetcher',
        () async {
      // Cloud unavailable → the LAN fallback runs, but its only cached address
      // is invalid: it is dropped and never fetched, so the tap ends in a
      // wrapped availability failure.
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake();
      final locator = _FakeLocator(cached: '0.0.0.0');
      final repo = _repo(cloud, locator: locator, cm: cm);

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
      expect(locator.discards, 1,
          reason: 'the invalid cached endpoint is dropped, never retried');
      expect(cm.called, isEmpty,
          reason: 'no HTTP may ever target 0.0.0.0');
    });

    test('a local report carrying IPAddress 0.0.0.0 is never learned',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
        'State': '{"POWER1":"ON","IPAddress":"0.0.0.0"}',
      });
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await repo.control(_deviceId, 1, 'ON');
      await pumpEventQueue();

      expect(locator.stores, 1,
          reason: 'only the candidate-promotion write happens; the invalid '
              'reported IP adds no write');
      expect(locator.lastStored, '192.168.1.5',
          reason: '0.0.0.0 must never be stored as this device IP');
    });
  });

  group('enableLocalHttpApi (automatic SetOption128 after claim)', () {
    test('Case 1: reachable device -> SO128 + status verify + verified IP',
        () async {
      // No cached IP yet (a fresh claim): the phone finds the device via mDNS,
      // which identity-verifies it with `Status 5` before it is used.
      final cm = _CmFake(responses: {
        'SetOption128%201': '{"SetOption128":"1"}',
        'Status%205': _macBody,
        'State': '{"POWER1":"ON"}',
      });
      final locator = _FakeLocator(candidates: ['192.168.1.5']);
      final repo = _repo(_FakeCloudApi(), locator: locator, cm: cm);

      final ok = await repo.enableLocalHttpApi(_deviceId);

      expect(ok, isTrue);
      // Identity probe -> SetOption128 enable -> read-only State verification.
      expect(
          cm.called, containsAll(['Status%205', 'SetOption128%201', 'State']));
      // The enable request carries a device-matching Referer bootstrap.
      expect(cm.refererByCommand['SetOption128%201'], 'http://192.168.1.5/');
      // The verified IP is persisted via the existing mechanism.
      expect(locator.lastStored, '192.168.1.5');
      expect(repo.lastSource, DeviceTransportSource.local);
    });

    test('Case 1b: a fresh verified cached IP still runs setup + verification',
        () async {
      final cm = _CmFake(responses: {
        'SetOption128%201': '{"SetOption128":"1"}',
        'Status%205': _macBody,
        'State': '{"POWER1":"ON"}',
      });
      final locator = _FakeLocator(
        cached: '192.168.1.5',
        verifiedAt: DateTime.now(),
      );
      final repo = _repo(_FakeCloudApi(), locator: locator, cm: cm);

      final ok = await repo.enableLocalHttpApi(_deviceId);

      expect(ok, isTrue);
      expect(cm.called, containsAll(['SetOption128%201', 'State']));
      expect(cm.refererByCommand['SetOption128%201'], 'http://192.168.1.5/');
      expect(locator.lastStored, '192.168.1.5',
          reason: 'the setup path explicitly persists the verified IP');
    });

    test('Case 1c: mDNS finds nothing but the backend lastIp succeeds',
        () async {
      // The real-device failure: the phone's mDNS enumeration came back empty
      // even though the device was HTTP-reachable. The claim response's
      // lastIp is seeded as an unverified candidate and identity-verified
      // (`Status 5`) before SetOption128 is sent — no mDNS required.
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'SetOption128%201': '{"SetOption128":"1"}',
        'State': '{"POWER1":"ON"}',
      });
      final locator = _FakeLocator(candidates: const []);
      final repo = _repo(_FakeCloudApi(), locator: locator, cm: cm);

      final ok =
          await repo.enableLocalHttpApi(_deviceId, lastIp: '192.168.1.33');

      expect(ok, isTrue);
      expect(locator.candidateStores, 1,
          reason: 'the backend lastIp is seeded as an unverified hint');
      expect(locator.lastCandidate, '192.168.1.33');
      expect(
        cm.called,
        containsAll(['Status%205', 'SetOption128%201', 'State']),
      );
      expect(cm.refererByCommand['SetOption128%201'], 'http://192.168.1.33/');
      expect(locator.lastStored, '192.168.1.33');
      expect(repo.lastSource, DeviceTransportSource.local);
    });

    test('Case 1d: backend lastIp overrides a stale cached verified IP',
        () async {
      // The cache holds an OLD verified IP that the backend lastIp replaces
      // (DHCP changed the lease): the fresh telemetry hint wins via the seed,
      // is re-verified, and the setup completes against the new address.
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'SetOption128%201': '{"SetOption128":"1"}',
        'State': '{"POWER1":"ON"}',
      });
      final locator = _FakeLocator(
        cached: '192.168.1.5',
        verifiedAt: DateTime.now().subtract(const Duration(minutes: 20)),
      );
      final repo = _repo(_FakeCloudApi(), locator: locator, cm: cm);

      final ok =
          await repo.enableLocalHttpApi(_deviceId, lastIp: '192.168.1.33');

      expect(ok, isTrue);
      expect(locator.lastStored, '192.168.1.33');
      expect(cm.refererByCommand['SetOption128%201'], 'http://192.168.1.33/');
    });

    test('Case 1e: invalid backend lastIp is rejected, never seeded/probed',
        () async {
      final cm = _CmFake();
      final locator = _FakeLocator(candidates: const []);
      final repo = _repo(_FakeCloudApi(), locator: locator, cm: cm);

      final ok = await repo.enableLocalHttpApi(_deviceId, lastIp: '0.0.0.0');

      expect(ok, isFalse);
      expect(locator.candidateStores, 0,
          reason: '0.0.0.0 is transient boot state, never a LAN hint');
      expect(cm.called, isEmpty,
          reason: 'an unusable hint must not trigger any HTTP request');
    });

    test('Case 3: no local IP -> clean skip, claim untouched, no HTTP',
        () async {
      final locator = _FakeLocator(candidates: const []);
      final repo = _repo(_FakeCloudApi(), locator: locator);

      final ok = await repo.enableLocalHttpApi(_deviceId);

      expect(ok, isFalse);
      expect(locator.mDnsQueries, 1,
          reason: 'discovery ran, but nothing on the LAN was found');
      expect(locator.stores, 0,
          reason: 'nothing was verified so nothing may be persisted');
    });

    test('Case 2/1: already-enabled device is idempotent and still verified',
        () async {
      // SetOption128 echoed back already-"1" is NOT a denial: the setup
      // proceeds to verification and marks the IP verified.
      final cm = _CmFake(responses: {
        'SetOption128%201': '{"SetOption128":"1"}',
        'Status%205': _macBody,
        'State': '{"POWER1":"ON"}',
      });
      final locator = _FakeLocator(candidates: ['192.168.1.5']);
      final repo = _repo(_FakeCloudApi(), locator: locator, cm: cm);

      final ok = await repo.enableLocalHttpApi(_deviceId);

      expect(ok, isTrue);
      expect(cm.called, containsAll(['SetOption128%201', 'State']));
      expect(locator.lastStored, '192.168.1.5');
    });

    test('setup DENIED (referer-check still blocking) never marks verified',
        () async {
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'SetOption128%201':
            '{"WARNING":"Referer \'\' denied. Use \'SO128 1\' for HTTP API commands."}',
      });
      final locator = _FakeLocator(candidates: ['192.168.1.5']);
      final repo = _repo(_FakeCloudApi(), locator: locator, cm: cm);

      final ok = await repo.enableLocalHttpApi(_deviceId);

      expect(ok, isFalse,
          reason: 'setup failure must NEVER make the claim look failed');
      // The only verified write is the discovery promotion from MAC-verifying
      // the box; the failed setup adds no further verified write and the
      // read-back verification is never reached.
      expect(locator.stores, 1);
      expect(locator.lastStored, '192.168.1.5');
      expect(cm.called, ['Status%205', 'SetOption128%201'],
          reason: 'verification stops at the denied enable');
    });

    test('setup timeout/unreachable -> false, no rollback, no verified store',
        () async {
      final cm = _CmFake()..unreachable = true;
      final locator = _FakeLocator(candidates: ['192.168.1.5']);
      final repo = _repo(_FakeCloudApi(), locator: locator, cm: cm);

      final ok = await repo.enableLocalHttpApi(_deviceId);

      expect(ok, isFalse);
      expect(locator.stores, 0);
    });
  });
}
