import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/channel_state_machine.dart';
import 'package:smart_home_app/services/cloud_device_transport.dart';
import 'package:smart_home_app/services/device_repository_service.dart';
import 'package:smart_home_app/services/device_transport.dart';
import 'package:smart_home_app/services/local_device_cache.dart';
import 'package:smart_home_app/services/local_device_discovery.dart';

const _deviceId = '34987AC30304';
const _macBody = '{"StatusNET":{"Mac":"34:98:7A:C3:03:04","HTTP_API":1}}';
const _macBodyHttpApi0 = '{"StatusNET":{"Mac":"34:98:7A:C3:03:04","HTTP_API":0}}';
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

  /// Current POWER1 relay state as `State` would report it. Flips to `ON`
  /// after a `Power1%20ON` command and back on `Power1%20OFF`, mirroring a real
  /// device read-back. Used by tests that script the whole post-claim lifecycle
  /// (setup → status → relay) without per-command `State` bodies.
  String powerState = 'OFF';

  /// Models a Tasmota with SetOption128 OFF: every referer-less `/cm` command
  /// answers the referer-denial warning (HTTP 200, no MAC/state) exactly like
  /// the real device. Once a `SetOption128%201` has been sent (called), the
  /// fake transitions to the enabled state where referer-less commands work —
  /// mirroring a real device after the enable takes effect.
  bool preSO128 = false;
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
    if (preSO128 &&
        (referer == null || referer.isEmpty) &&
        !called.contains('SetOption128%201')) {
      return '{"WARNING":"Referer \'\' denied. Use \'SO128 1\' for HTTP API commands."}';
    }
    if (command == 'Status%205') {
      final queue = macByAddress[address];
      if (queue != null && queue.isNotEmpty) {
        return queue.removeAt(0);
      }
    }
    if (command == 'Power1%20ON') {
      powerState = 'ON';
      return '{"POWER1":"ON"}';
    }
    if (command == 'Power1%20OFF') {
      powerState = 'OFF';
      return '{"POWER1":"OFF"}';
    }
    if (command == 'State') {
      final body = responses['State'];
      if (body != null) return body;
      return '{"POWER1":"$powerState"}';
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

  group('isDeviceRegistered (hard provisioning-boundary duplicate invariant)', () {
    test('cloud list contains the MAC: registered', () async {
      final cloud = _FakeCloudApi()
        ..devices = const [
          {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
        ];
      final repo = _repo(cloud);

      expect(await repo.isDeviceRegistered(_deviceId), isTrue);
      expect(await repo.isDeviceRegistered('34987AC30304'), isTrue,
          reason: 'canonical form identifies the same device');
      expect(cloud.devicesCalls, 2);
    });

    test('MAC matching is normalized (dotted list entry, canonical query)', () async {
      final cloud = _FakeCloudApi()
        ..devices = const [
          {'deviceId': '34:98:7A:C3:03:04', 'name': 'Controller', 'channels': 4},
        ];
      final repo = _repo(cloud);

      expect(await repo.isDeviceRegistered('34987AC30304'), isTrue);
    });

    test('a different / unlisted MAC is NOT registered', () async {
      final cloud = _FakeCloudApi()
        ..devices = const [
          {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
        ];
      final repo = _repo(cloud);

      expect(await repo.isDeviceRegistered('18FE34A1B2C3'), isFalse);
      expect(await repo.isDeviceRegistered('not-a-mac'), isFalse,
          reason: 'an unparseable identity is never a duplicate');
    });

    test('cloud unreachable: the PERSISTED local mirror still certifies the '
        'MAC (survives wizard reopen / offline AP)', () async {
      final cache = LocalDeviceCache();
      await cache.replaceAll(const [
        {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
      ]);
      // Cloud is down, exactly like the phone sitting on the Tasmota setup AP.
      final cloud = _FakeCloudApi()
        ..devicesError = const ApiException('down', code: 'NETWORK_ERROR');
      final repo = _repo(cloud, cache: cache);

      expect(await repo.isDeviceRegistered(_deviceId), isTrue,
          reason: 'a device claimed on this phone stays blocked even when the '
              'backend cannot be reached');
      // A FRESH repository instance (reopening Add Device spins up a new
      // repository) reads the SAME persisted mirror: reopening cannot bypass.
      final reopened = _repo(_FakeCloudApi()..devicesError = const ApiException(
          'down', code: 'NETWORK_ERROR'));
      expect(await reopened.isDeviceRegistered(_deviceId), isTrue,
          reason: 'the persisted mirror is SharedPreferences-backed, so a '
              'brand-new repository instance still sees the registered MAC');
    });

    test('cloud unreachable AND empty mirror: failsafe false (offline race)',
        () async {
      final repo = _repo(_FakeCloudApi()
        ..devicesError = const ApiException('down', code: 'NETWORK_ERROR'));

      expect(await repo.isDeviceRegistered(_deviceId), isFalse,
          reason: 'a device claimed on ANOTHER phone is unknown offline here — '
              'the backend pre-claim check + provision stay the final net');
    });

    test('cloud unreachable + empty mirror + NO snapshot → UNKNOWN (three-state '
        'honesty: a network failure is not evidence of absence)', () async {
      final repo = _repo(_FakeCloudApi()
        ..devicesError = const ApiException('down', code: 'NETWORK_ERROR'));

      expect(await repo.registrationState(_deviceId),
          RegistrationState.unknown,
          reason: 'the state MUST NOT collapse to a confident '
              '"not registered" when no source could establish anything');
    });

    test('a fresh cloud success refreshes the persisted account snapshot',
        () async {
      final cloud = _FakeCloudApi()
        ..devices = const [
          {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
        ];
      final repo = _repo(cloud);
      final cache = LocalDeviceCache();

      expect(await repo.registrationState(_deviceId),
          RegistrationState.registered);
      // The authoritative list was persisted, so a later offline check certifies.
      expect(await cache.loadAccountSnapshotMacs(), contains(_deviceId));
    });

    test('cloud unreachable: the PERSISTED ACCOUNT SNAPSHOT certifies '
        '(cross-client — display mirror is EMPTY)', () async {
      final cache = LocalDeviceCache();
      // Phone B: empty display mirror (Claimed from Phone A), but an online
      // GET /api/devices refresh captured M into the account snapshot.
      await cache.saveAccountSnapshot(const [
        {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
      ]);
      expect(await cache.cachedDevices(), isEmpty,
          reason: 'the display mirror is genuinely empty — only the snapshot '
              'knows the device');
      final cloud = _FakeCloudApi()
        ..devicesError = const ApiException('down', code: 'NETWORK_ERROR');
      final repo = _repo(cloud, cache: cache);

      expect(await repo.registrationState(_deviceId),
          RegistrationState.registered,
          reason: 'a device claimed from another client must still block '
              'offline once the account snapshot knows it');
      expect(await repo.isDeviceRegistered(_deviceId), isTrue);

      // A FRESH repository (reopening Add Device) reads the SAME persisted
      // snapshot — reopening cannot bypass.
      final reopened = _repo(_FakeCloudApi()
        ..devicesError = const ApiException('down', code: 'NETWORK_ERROR'));
      expect(await reopened.isDeviceRegistered(_deviceId), isTrue);
    });

    test('a VALID persisted account snapshot that lacks the MAC is evidence of '
        'absence (new device on offline AP)', () async {
      final cache = LocalDeviceCache();
      await cache.saveAccountSnapshot(const [
        {'deviceId': 'AAAAAAAAAAAA', 'name': 'Gate', 'channels': 4},
      ]);
      final cloud = _FakeCloudApi()
        ..devicesError = const ApiException('down', code: 'NETWORK_ERROR');
      final repo = _repo(cloud, cache: cache);

      expect(await repo.registrationState(_deviceId),
          RegistrationState.notRegistered,
          reason: 'a refreshed snapshot that does not contain the MAC IS '
              'authoritative evidence of absence');
    });

    test('registrationState persists the cloud list and then certifies it '
        'even when the next fetch fails', () async {
      // First call: cloud up, contains M → registered + persisted.
      final up = _FakeCloudApi()
        ..devices = const [
          {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
        ];
      final repo = _repo(up);
      expect(await repo.registrationState(_deviceId),
          RegistrationState.registered);

      // Second call: cloud down (offline AP) → persisted snapshot still certifies.
      final down = _FakeCloudApi()
        ..devicesError = const ApiException('down', code: 'NETWORK_ERROR');
      final reopened = _repo(down);
      expect(await reopened.isDeviceRegistered(_deviceId), isTrue,
          reason: 'an unavailable network must never erase already-known '
              'information');
    });
  });

  group('control: one-path route dispatch (same-WiFi → local, else → cloud)', () {
    test('cloudOnly success returns the cloud result; the LAN is never touched',
        () async {
      final cloud = _FakeCloudApi();
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result =
          await repo.control(_deviceId, 1, 'ON', route: ControlRoute.cloudOnly);

      expect(cloud.controlCalls, 1);
      expect(result.channels[1]!.state, 'ON');
      expect(result.online, isTrue);
      expect(result.source, DeviceTransportSource.cloud);
      expect(cm.called, isEmpty,
          reason: 'the LAN is never probed on a cloud-only tap');
      expect(locator.cachedQueries, 0,
          reason: 'no local discovery runs on a cloud-only tap');
      expect(locator.mDnsQueries, 0);
    });

    test('default route is cloudOnly (no route argument)', () async {
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

    test('cloudOnly + cloud availability failure → single fallback to the LAN succeeds',
        () async {
      // The 504 scenario: a same-WiFi device was routed cloud-first (stale
      // verdict), the cloud times out (availability), and the bounded safety
      // net retries the LAN exactly once — which succeeds.
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result =
          await repo.control(_deviceId, 1, 'ON', route: ControlRoute.cloudOnly);

      expect(cloud.controlCalls, 1,
          reason: 'the cloud was attempted exactly once before the fallback');
      expect(result.source, DeviceTransportSource.local,
          reason: 'the LAN fallback completed the command');
      expect(result.channels[1]!.state, 'ON');
      expect(cm.called, containsAll(['Status%205', 'Power1%20ON', 'State']));
      expect(locator.cachedQueries, 1,
          reason: 'the fallback ran exactly one local probe, no more');
    });

    test('cloudOnly + cloud 5xx → single fallback to the LAN succeeds '
        '(the 504 regression fix)', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('boom', statusCode: 503);
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result =
          await repo.control(_deviceId, 1, 'ON', route: ControlRoute.cloudOnly);

      expect(cloud.controlCalls, 1);
      expect(result.source, DeviceTransportSource.local,
          reason: 'a 5xx is availability: the bounded fallback reaches the LAN');
      expect(cm.called, containsAll(['Status%205', 'Power1%20ON', 'State']));
    });

    test('cloudOnly + BOTH cloud and LAN unavailable → combined error, '
        'exactly one attempt per transport', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final repo = _repo(cloud, locator: _FakeLocator()); // no local device

      await expectLater(
        repo.control(_deviceId, 1, 'ON', route: ControlRoute.cloudOnly),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => e.message,
            'message',
            contains('locally or online'),
          ),
        ),
      );
      expect(cloud.controlCalls, 1,
          reason: 'the cloud was tried once, then the LAN once — no retry loop');
      expect(cloud.controlCalls, lessThanOrEqualTo(1));
    });

    test('cloudOnly business rejection is surfaced; the LAN is never touched',
        () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('Forbidden', statusCode: 403);
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await expectLater(
        repo.control(_deviceId, 1, 'ON', route: ControlRoute.cloudOnly),
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

    test('cloud logical rejection is surfaced even when the LAN would succeed',
        () async {
      // A rejection is NOT availability: it must surface immediately and never
      // fall back, even though the LAN endpoint exists and would work.
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('Forbidden', statusCode: 403);
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await expectLater(
        repo.control(_deviceId, 1, 'ON', route: ControlRoute.cloudOnly),
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
          reason: 'a logical rejection must never trigger the LAN fallback');
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
        repo.control(_deviceId, 1, 'ON', route: ControlRoute.cloudOnly),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.code, 'code', 'DEVICE_OFFLINE'),
        ),
      );
      expect(cloud.controlCalls, 1);
    });

    test('opId is propagated to the cloud transport', () async {
      final cloud = _FakeCloudApi();
      final repo = _repo(cloud);

      await repo.control(_deviceId, 1, 'ON', opId: 'tap-42');

      expect(cloud.lastControlOpId, 'tap-42');
    });

    test('localOnly + LAN success returns locally; the cloud is never called',
        () async {
      final cloud = _FakeCloudApi();
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result =
          await repo.control(_deviceId, 1, 'ON', route: ControlRoute.localOnly);

      expect(cloud.controlCalls, 0,
          reason: 'a same-WiFi tap must never reach the cloud');
      expect(result.source, DeviceTransportSource.local);
      expect(result.channels[1]!.state, 'ON');
      expect(cm.called, containsAll(['Status%205', 'Power1%20ON', 'State']));
    });

    test('localOnly + LAN availability failure → single fallback to the cloud succeeds',
        () async {
      // A stale same-WiFi verdict sent the tap local-first; the LAN is
      // unreachable (device moved networks) but the cloud is up — the bounded
      // safety net retries the cloud exactly once and completes the command.
      final cloud = _FakeCloudApi();
      final repo = _repo(cloud, locator: _FakeLocator()); // no local device

      final result =
          await repo.control(_deviceId, 1, 'ON', route: ControlRoute.localOnly);

      expect(cloud.controlCalls, 1,
          reason: 'the cloud was tried exactly once as the single fallback');
      expect(result.source, DeviceTransportSource.cloud);
      expect(result.channels[1]!.state, 'ON');
    });

    test('localOnly + BOTH LAN and cloud unavailable → combined error, exactly '
        'one attempt per transport', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final repo = _repo(cloud, locator: _FakeLocator()); // no local device

      await expectLater(
        repo.control(_deviceId, 1, 'ON', route: ControlRoute.localOnly),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => e.message,
            'message',
            contains('locally or online'),
          ),
        ),
      );
      expect(cloud.controlCalls, 1,
          reason: 'the fallback fired once and stopped — no retry loop');
      expect(cloud.controlCalls, lessThanOrEqualTo(1));
    });

    test('localOnly + LAN logical rejection is surfaced; the cloud is untouched',
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
        repo.control(_deviceId, 1, 'ON', route: ControlRoute.localOnly),
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
  });

  group('control: scoped fallback by sameWifi at tap time', () {
    test('sameWifi==true + cloud availability failure → full fallback still succeeds (regression guard)', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON',
          route: ControlRoute.cloudOnly, sameWifiAtTap: true);

      expect(cloud.controlCalls, 1);
      expect(result.source, DeviceTransportSource.local,
          reason: 'sameWifi==true must keep full 6s fallback');
      expect(result.channels[1]!.state, 'ON');
      expect(locator.cachedQueries, 1);
    });

    test('sameWifi==false + cloud failure + warm cache valid → fast fallback succeeds (stale-verdict edge case)', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON',
          route: ControlRoute.cloudOnly, sameWifiAtTap: false);

      expect(cloud.controlCalls, 1);
      expect(result.source, DeviceTransportSource.local,
          reason: 'stale sameWifi==false but warm cache valid → fast probe must succeed');
      expect(result.channels[1]!.state, 'ON');
      expect(locator.mDnsQueries, 0,
          reason: 'fast fallback must not run mDNS');
    });

    test('sameWifi==false + cloud failure + no local cache → fast fallback surfaces cloud error immediately (no 6s wait)', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final repo = _repo(cloud, locator: _FakeLocator()); // no cache

      final sw = Stopwatch()..start();
      await expectLater(
        repo.control(_deviceId, 1, 'ON',
            route: ControlRoute.cloudOnly, sameWifiAtTap: false),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'NETWORK_ERROR')),
      );
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(1000),
          reason: 'fast fallback must not wait 6s');
      expect(cloud.controlCalls, 1);
    });

    test('sameWifi==false + cloud 5xx → fast fallback still scoped (no full discovery)', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('boom', statusCode: 503);
      final repo = _repo(cloud, locator: _FakeLocator());

      final sw = Stopwatch()..start();
      await expectLater(
        repo.control(_deviceId, 1, 'ON',
            route: ControlRoute.cloudOnly, sameWifiAtTap: false),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 's', 503)),
      );
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });

    test('logical rejection never triggers fallback regardless of sameWifi (true)', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('Forbidden', statusCode: 403);
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await expectLater(
        repo.control(_deviceId, 1, 'ON',
            route: ControlRoute.cloudOnly, sameWifiAtTap: true),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 's', 403)),
      );
      expect(cloud.controlCalls, 1);
      expect(cm.called, isEmpty, reason: 'logical rejection must never fallback');
      expect(locator.cachedQueries, 0);
    });

    test('logical rejection never triggers fast fallback regardless of sameWifi (false)', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('Forbidden', statusCode: 403);
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await expectLater(
        repo.control(_deviceId, 1, 'ON',
            route: ControlRoute.cloudOnly, sameWifiAtTap: false),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 's', 403)),
      );
      expect(cloud.controlCalls, 1);
      expect(cm.called, isEmpty);
      expect(locator.cachedQueries, 0);
    });

    test('sameWifi null (unknown) defaults to full fallback (safety)', () async {
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      // No sameWifiAtTap passed (null) → should behave like true (full fallback)
      final result = await repo.control(_deviceId, 1, 'ON',
          route: ControlRoute.cloudOnly);
      expect(result.source, DeviceTransportSource.local);
    });
  });

  group('same-WiFi detection (isDeviceOnSameNetwork)', () {
    test('no cached IP → false (defaults to cloud)', () async {
      final cloud = _FakeCloudApi();
      final locator = _FakeLocator(); // no cached address
      final repo = _repo(cloud, locator: locator, cm: _CmFake());

      expect(await repo.isDeviceOnSameNetwork(_deviceId), isFalse);
      expect(locator.cachedQueries, 1);
      expect(locator.discards, 0, reason: 'no probe ran, nothing to discard');
    });

    test('cached verified IP → true; probe warms the cache for the next tap',
        () async {
      final cloud = _FakeCloudApi();
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      expect(await repo.isDeviceOnSameNetwork(_deviceId), isTrue);
      expect(cm.called, contains('Status%205'));

      // The following local-only tap must hit the warm endpoint with NO second
      // identity probe.
      final result = await repo.control(_deviceId, 1, 'ON',
          route: ControlRoute.localOnly);
      expect(result.source, DeviceTransportSource.local);
      expect(cm.called.where((c) => c == 'Status%205').length, 1,
          reason: 'the warm endpoint skips the redundant identity probe');
    });

    test('cached IP with a foreign MAC → false and discards the entry', () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake(macByAddress: {
        '192.168.1.5': [_foreignMacBody],
      });
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      expect(await repo.isDeviceOnSameNetwork(_deviceId), isFalse);
      expect(locator.discards, 1);
    });

    test('cached IP unreachable → false (ambiguous → cloud default)', () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake()..unreachable = true;
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      expect(await repo.isDeviceOnSameNetwork(_deviceId), isFalse);
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
    test('control: LAN identity mismatch surfaces on a local-only tap',
        () async {
      // A same-WiFi tap (local-only) probes the cached IP and discovers the box
      // has been repurposed — a security rejection that must surface, never be
      // retried on the cloud.
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
        repo.control(_deviceId, 1, 'ON', route: ControlRoute.localOnly),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => e.kind,
            'kind',
            TransportFailureKind.logical,
          ),
        ),
      );
      expect(cloud.controlCalls, 0,
          reason: 'a local-only tap must never reach the cloud');
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
        repo.control(_deviceId, 1, 'ON', route: ControlRoute.localOnly),
        throwsA(
          isA<DeviceTransportException>()
              .having((e) => e.kind, 'kind', TransportFailureKind.logical)
              .having((e) => e.code, 'code', 'UNCONFIRMED'),
        ),
      );
      expect(cloud.controlCalls, 0,
          reason: 'a local-only tap must never reach the cloud');
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
    test('concurrent local reads share ONE discovery window', () async {
      // Two status refreshes land on the LAN and must share one discovery
      // ladder instead of opening two mDNS browsers.
      final cloud = _FakeCloudApi();
      final cm = _CmFake(
        responses: {
          'Status%205': _macBody,
          'State': '{"POWER1":"ON"}',
        },
        macByAddress: {'192.168.1.5': [_macBody]},
      );
      final locator = _FakeLocator(candidates: ['192.168.1.5']);
      final repo = _repo(cloud, locator: locator, cm: cm);

      final results = await Future.wait([
        repo.getStatus(_deviceId),
        repo.getStatus(_deviceId),
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

      final result = await repo.getStatus(_deviceId);

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

      final result = await repo.getStatus(_deviceId);

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

      final result = await repo.getStatus(_deviceId);

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
          'State': '{"POWER1":"ON"}',
        },
        macByAddress: {'192.168.1.5': [_macBody]},
      );
      final locator = _FakeLocator(candidates: ['192.168.1.5']);
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.getStatus(_deviceId);

      expect(result.channels[1]!.state, 'ON');
      expect(locator.mDnsQueries, 1);
      expect(locator.stores, 1);
      expect(locator.lastStored, '192.168.1.5');
    });

    test('foreign mDNS candidates are ignored (never cached, never commanded)',
        () async {
      // The cloud-only tap fails with availability (backend down). The LAN is
      // never attempted on this route, so the only mDNS hits (a foreign box)
      // are never reached: nothing is cached, nothing is commanded, and the tap
      // ends in a wrapped availability failure instead of reaching a stranger.
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake(
        responses: {'Power1%20ON': '{"POWER1":"ON"}', 'State': '{"POWER1":"ON"}'},
        macByAddress: {'10.0.0.2': [_foreignMacBody]},
      );
      final locator = _FakeLocator(candidates: ['10.0.0.2']);
      final repo = _repo(cloud, locator: locator, cm: cm);

      await expectLater(
        repo.control(_deviceId, 1, 'ON', route: ControlRoute.cloudOnly),
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
      expect(locator.mDnsQueries, 0,
          reason: 'a cloud-only tap never starts LAN discovery');
      expect(
        cm.called.where((c) => c.startsWith('Power')).toList(),
        isEmpty,
        reason: 'no relay command may target a foreign device',
      );
    });

    test('warmUp populates the warm endpoint so a local-only tap skips discovery',
        () async {
      final cloud = _FakeCloudApi();
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await repo.warmUp(const [
        {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
      ]);

      final result = await repo.control(_deviceId, 1, 'ON',
          route: ControlRoute.localOnly);

      expect(result.channels[1]!.state, 'ON');
      expect(locator.cachedQueries, 1,
          reason: 'warm-up discovered once; the tap hits the warm endpoint');
      expect(locator.mDnsQueries, 0);
      expect(cloud.controlCalls, 0,
          reason: 'a local-only tap never reaches the cloud');
    });
  });

  group('cold LAN: one identity probe, operations reuse it', () {
    test('a local-only control probes the cached IP once and reuses it',
        () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
        'State': '{"POWER1":"ON","POWER2":"OFF"}',
      });
      final locator = _FakeLocator(cached: '192.168.1.5'); // verifiedAt == null
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON',
          route: ControlRoute.localOnly);

      expect(result.source, DeviceTransportSource.local);
      expect(cm.called, ['Status%205', 'Power1%20ON', 'State'],
          reason: 'the cached IP is identity-checked once; the control reuses '
              'that verification (no duplicate Status 5 probe)');
      expect(cloud.controlCalls, 0);
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

    test('subsequent local-only controls reuse the warm endpoint, no re-probe',
        () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
        'Power2%20OFF': '{"POWER2":"OFF"}',
        'State': '{"POWER1":"ON","POWER2":"OFF"}',
      });
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await repo.control(_deviceId, 1, 'ON', route: ControlRoute.localOnly);
      cm.called.clear();

      final result = await repo.control(_deviceId, 2, 'OFF',
          route: ControlRoute.localOnly);

      expect(result.source, DeviceTransportSource.local);
      expect(cm.called, ['Power2%20OFF', 'State'],
          reason: 'the warm verified endpoint is reused directly; no duplicate '
              'identity probe on later controls');
      expect(cloud.controlCalls, 0);
    });

    test('multiple local reads share ONE discovery and ONE identity probe',
        () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'State': '{"POWER1":"ON","POWER2":"OFF","POWER3":"ON"}',
      });
      final locator = _FakeLocator(candidates: ['192.168.1.5']);
      final repo = _repo(cloud, locator: locator, cm: cm);

      final results = await Future.wait([
        repo.getStatus(_deviceId),
        repo.getStatus(_deviceId),
        repo.getStatus(_deviceId),
      ]);

      expect(locator.mDnsQueries, 1,
          reason: 'all three reads share the single in-flight discovery');
      expect(cm.called.where((c) => c == 'Status%205').length, 1,
          reason: 'the shared discovery verifies once; every read reuses it');
      expect(results.every((r) => r.source == DeviceTransportSource.local),
          isTrue);
    });

    test('a fresh verified cached IP STILL re-verifies before command',
        () async {
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
        repo.control(_deviceId, 1, 'ON', route: ControlRoute.localOnly),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => e.kind,
            'kind',
            TransportFailureKind.logical,
          ),
        ),
      );
      expect(cloud.controlCalls, 0,
          reason: 'the command-time re-verify catches the repurposed box as a '
              'logical rejection that must surface — never retried on the cloud');
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
        'a same-WiFi tap uses the cloud-learned candidate: local-only route',
        () async {
      // The exact reported scenario: phone and device on the same Wi-Fi.
      // The tap is routed local-only, and the cloud-learned IP (seeded while
      // online) lets the local control find the device WITHOUT mDNS — and
      // without any cloud round-trip.
      final cloud = _FakeCloudApi();
      final cm = _localRelayCm();
      final locator = _FakeLocator(cached: '192.168.1.5'); // verifiedAt == null
      final repo = _repo(cloud, locator: locator, cm: cm);

      final result = await repo.control(_deviceId, 1, 'ON',
          route: ControlRoute.localOnly);

      expect(cloud.controlCalls, 0,
          reason: 'a same-WiFi tap is routed local-only; the cloud is never '
              'attempted');
      expect(result.channels[1]!.state, 'ON');
      expect(result.source, DeviceTransportSource.local);
      expect(locator.mDnsQueries, 0,
          reason: 'the candidate IP verified — mDNS was never needed');
      expect(locator.stores, 1,
          reason: 'the verified candidate is promoted to a verified entry');
    });

    test('an unreachable candidate is KEPT (device may be off)', () async {
      // Both transports unavailable (candidate off AND cloud down): the local
      // fast path keeps the cloud-learned hint for next time (never discards an
      // unconfirmed candidate) and the combined error surfaces after the single
      // fallback — the local-only fast path never runs mDNS.
      final cloud = _FakeCloudApi()
        ..controlError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake()..unreachable = true;
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await expectLater(
        repo.control(_deviceId, 1, 'ON', route: ControlRoute.localOnly),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => e.message,
            'message',
            contains('locally or online'),
          ),
        ),
      );
      expect(locator.discards, 0,
          reason: 'a cloud-learned hint survives transient unavailability');
      expect(locator.mDnsQueries, 0,
          reason: 'the local-only fast path never starts an mDNS browser');
      expect(cloud.controlCalls, 1,
          reason: 'the single fallback fired once and stopped');
    });

    test('a candidate with a foreign MAC is discarded', () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake(
        responses: {'Power1%20ON': '{"POWER1":"ON"}', 'State': '{"POWER1":"ON"}'},
        macByAddress: {'192.168.1.5': [_foreignMacBody]},
      );
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await expectLater(
        repo.control(_deviceId, 1, 'ON', route: ControlRoute.localOnly),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => e.kind,
            'kind',
            TransportFailureKind.logical,
          ),
        ),
      );
      expect(locator.discards, 1,
          reason: 'a repurposed address must never be trusted');
      expect(cloud.controlCalls, 0);
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

      await repo.control(_deviceId, 1, 'ON', route: ControlRoute.localOnly);
      await pumpEventQueue();

      expect(locator.lastStored, '192.168.1.77',
          reason: 'the freshest reported address is remembered for next time');
      expect(cloud.controlCalls, 0);
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

      await repo.control(_deviceId, 1, 'ON', route: ControlRoute.localOnly);
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
      // The status ladder finds only an invalid cached address: it is dropped
      // and never fetched, the local miss falls through to the cloud, and the
      // cloud failure surfaces — 0.0.0.0 is never the target of an HTTP call.
      final cloud = _FakeCloudApi()
        ..statusError = const ApiException('down', code: 'NETWORK_ERROR');
      final cm = _CmFake();
      final locator = _FakeLocator(cached: '0.0.0.0');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await expectLater(
        repo.getStatus(_deviceId),
        throwsA(isA<ApiException>()),
      );
      expect(locator.discards, 1,
          reason: 'the invalid cached endpoint is dropped, never retried');
      expect(cm.called, isEmpty,
          reason: 'no HTTP may ever target 0.0.0.0');
    });

    test('a local report carrying IPAddress 0.0.0.0 is never learned',
        () async {
      final cloud = _FakeCloudApi();
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
        'State': '{"POWER1":"ON","IPAddress":"0.0.0.0"}',
      });
      final locator = _FakeLocator(cached: '192.168.1.5');
      final repo = _repo(cloud, locator: locator, cm: cm);

      await repo.control(_deviceId, 1, 'ON', route: ControlRoute.localOnly);
      await pumpEventQueue();

      expect(locator.stores, 1,
          reason: 'only the candidate-promotion write happens; the invalid '
              'reported IP adds no write');
      expect(locator.lastStored, '192.168.1.5',
          reason: '0.0.0.0 must never be stored as this device IP');
      expect(cloud.controlCalls, 0);
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

    test('pre-SO128 device: referer-less probes are denied, bootstrap still works',
        () async {
      // THE real-device failure. SetOption128 is OFF, so Tasmota answers EVERY
      // referer-less /cm (including the Status 5 identity probe) with the
      // denial warning — no MAC. The old flow ran discovery's referer-less
      // probe first, read a MISMATCH, discarded the IP, and never reached the
      // SetOption128 enable. The bootstrap transport now probes WITH the
      // device-matching Referer, so probe → enable → read-back all succeed.
      final cm = _CmFake(responses: {
        'Status%205': _macBody,
        'SetOption128%201': '{"SetOption128":"1"}',
        'State': '{"POWER1":"ON"}',
      })..preSO128 = true;
      final locator = _FakeLocator(candidates: const []);
      final repo = _repo(_FakeCloudApi(), locator: locator, cm: cm);

      final ok =
          await repo.enableLocalHttpApi(_deviceId, lastIp: '192.168.1.33');

      expect(ok, isTrue);
      // Every request carried the bootstrap Referer — the identity probe too —
      // EXCEPT the final read-back, which must run on the NORMAL (referer-less)
      // transport: proof that a real relay command works once SO128 is ON.
      expect(cm.refererByCommand['Status%205'], 'http://192.168.1.33/');
      expect(cm.refererByCommand['SetOption128%201'], 'http://192.168.1.33/');
      expect(cm.refererByCommand['State'], isNull,
          reason: 'the final read-back is referer-less — the device must now '
              'accept normal local control');
      expect(locator.candidateStores, 1,
          reason: 'the backend lastIp was seeded as the bootstrap hint');
      expect(locator.lastStored, '192.168.1.33');
      expect(repo.lastSource, DeviceTransportSource.local);
    });

    test('verify-failure (StatusNET.HTTP_API still 0) fails the gate, nothing '
        'persisted', () async {
      // The device accepted `SetOption128 1` (HTTP 200, positive body) but its
      // Status 5 still reports HTTP_API 0. This is the exact "success with
      // HTTP_API:0" bug the hard gate exists to catch: the enable was NOT
      // proven, so provisioning must fail even though every HTTP call returned
      // 200.
      final cm = _CmFake(responses: {
        'SetOption128%201': '{"SetOption128":"1"}',
        'Status%205': _macBodyHttpApi0,
      });
      final locator = _FakeLocator(candidates: const []);
      final repo = _repo(_FakeCloudApi(), locator: locator, cm: cm);

      final ok =
          await repo.enableLocalHttpApi(_deviceId, lastIp: '192.168.1.33');

      expect(ok, isFalse,
          reason: 'HTTP_API:0 after the enable must fail the hard gate');
      expect(cm.called, isNot(contains('State')),
          reason: 'verification stops at the HTTP_API probe — the final '
              'referer-less read-back is never reached');
      expect(repo.lastLocalSetupError, isNotNull,
          reason: 'the wizard needs a precise diagnostic');
      expect(repo.lastSource, isNull,
          reason: 'no local transport result was produced');
    });

    test('SetOption128 denial (referer-check still blocking) fails the gate',
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
          reason: 'a denied/inconclusive enable fails the hard gate');
      expect(cm.called, ['Status%205', 'SetOption128%201'],
          reason: 'verification stops at the denied enable');
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
          reason: 'a denied/inconclusive enable fails the hard gate');
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

  group('post-claim local control (hard gate produced a verified endpoint)', () {
    test('a verified enable keeps relay taps LOCAL and referer-less', () async {
      // THE end-state this whole feature exists to guarantee: once the
      // claim-time enable + verify succeeded, a subsequent Power ON/OFF must be
      // served by the verified LAN transport WITHOUT any Referer (SO128 is ON)
      // and without any cloud round-trip.
final cm = _CmFake(responses: {
        'SetOption128%201': '{"SetOption128":"1"}',
        'Status%205': _macBody,
      });
      final locator = _FakeLocator(candidates: const []);
      final repo = _repo(_FakeCloudApi(), locator: locator, cm: cm);

      final ok =
          await repo.enableLocalHttpApi(_deviceId, lastIp: '192.168.1.33');
      expect(ok, isTrue);
      expect(repo.hasVerifiedLocalIp(_deviceId), isTrue,
          reason: 'the verified IP is warm-cached for immediate local taps');

      final off = await repo.getStatus(_deviceId);
      expect(off.online, isTrue);
      expect(off.channels[1]?.state, 'OFF');

      final on = await repo.control(_deviceId, 1, 'ON',
          route: ControlRoute.localOnly);
      expect(on.channels[1]?.state, 'ON',
          reason: 'Power1 ON is confirmed by the read-back');
expect(cm.called, contains('Power1%20ON'));
      expect(cm.refererByCommand['Power1%20ON'], isNull,
          reason: 'the relay command must be referer-less — the post-enable '
              'transport is the normal local control transport');
      expect(cm.refererByCommand['State'], isNull);
      expect(repo.lastSource, DeviceTransportSource.local);
    });
  });
}