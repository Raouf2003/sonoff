import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/cloud_device_transport.dart';
import 'package:smart_home_app/services/device_transport.dart';
import 'package:smart_home_app/services/local_device_transport.dart';

const _deviceId = '34987AC30304';
const _macBody = '{"StatusNET":{"Mac":"34:98:7A:C3:03:04"}}';
const _otherMacBody = '{"StatusNET":{"Mac":"00:11:22:33:44:55"}}';
const _garbageBody = '<html>401 Unauthorized</html>';
const _refererDeniedBody =
    '{"WARNING":"Referer \'\' denied. Use \'SO128 1\' for HTTP API commands."}';

/// Controllable [TasmotaCmFetcher] backed by a command→body table.
class _CmFake {
  _CmFake(this.responses);

  final Map<String, String> responses;
  final List<String> called = [];
  final Map<String, String?> referers = {};
  Object? error;
  Duration delay = Duration.zero;
  String? lastReferer;

  Future<String> call(
    String address,
    String command, {
    String? password,
    String? deviceId,
    String? referer,
  }) async {
    called.add(command);
    lastReferer = referer;
    referers[command] = referer;
    if (delay != Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final err = error;
    if (err != null) throw err;
    final body = responses[command];
    if (body == null) {
      throw const DeviceTransportException('HTTP 404');
    }
    return body;
  }
}

/// A fake cloud API that records calls and returns scripted results, so the
/// cloud transport's passthrough behavior can be verified without a backend.
class _FakeCloudApi extends ApiService {
  int controlCalls = 0;
  int statusCalls = 0;
  Object? controlError;
  Object? statusError;

  @override
  Future<Map<String, dynamic>> control(
    String deviceId,
    int channel,
    String state, {
    String? opId,
  }) async {
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
    return {'online': true, 'POWER1': 'ON', 'POWER2': 'OFF'};
  }
}

void main() {
  group('availability classification (isAvailabilityFailure)', () {
    test('ApiException without statusCode (timeout/network) is availability',
        () {
      expect(
        isAvailabilityFailure(
          const ApiException('Timed out', code: 'TIMEOUT'),
        ),
        isTrue,
      );
      expect(
        isAvailabilityFailure(
          const ApiException('No network', code: 'NETWORK_ERROR'),
        ),
        isTrue,
      );
    });

    test('4xx backend errors are NEVER availability', () {
      for (final code in const [400, 401, 403, 404]) {
        expect(
          isAvailabilityFailure(
            ApiException('rejected', statusCode: code),
          ),
          isFalse,
          reason: '$code must not trigger a fallback',
        );
      }
      // A CODED 409 (duplicate/ownership, e.g. during provisioning) is a
      // logical rejection and must never fall back either.
      expect(
        isAvailabilityFailure(
          ApiException('dup', statusCode: 409, code: 'DEVICE_ALREADY_EXISTS'),
        ),
        isFalse,
      );
    });

    test('409 without a machine code means DEVICE_OFFLINE: availability', () {
      expect(
        isAvailabilityFailure(
          ApiException('Device is not connected or is powered off',
              statusCode: 409),
        ),
        isTrue,
        reason:
            'the device is unreachable at the cloud, so the LAN must get a chance',
      );
    });

    test('5xx backend errors are availability', () {
      for (final code in const [500, 502, 503]) {
        expect(
          isAvailabilityFailure(
            ApiException('server error', statusCode: code),
          ),
          isTrue,
        );
      }
    });

    test('raw transport failures are availability', () {
      expect(isAvailabilityFailure(const SocketException('x')), isTrue);
      expect(isAvailabilityFailure(TimeoutException('x')), isTrue);
      expect(isAvailabilityFailure(http.ClientException('x')), isTrue);
    });

    test('DeviceTransportException categories map through', () {
      expect(
        isAvailabilityFailure(
          const DeviceTransportException('down'),
        ),
        isTrue,
      );
      expect(
        isAvailabilityFailure(
          const DeviceTransportException(
            'bad',
            kind: TransportFailureKind.logical,
          ),
        ),
        isFalse,
      );
    });
  });

  group('Tasmota response parsing (pure)', () {
    test('Status 5 MAC is extracted and normalized', () {
      expect(extractMacFromStatus5(_macBody), '34:98:7A:C3:03:04');
    });

    test('Status 5 MAC extraction tolerates the /cm wrapper', () {
      expect(
        extractMacFromStatus5(
          '{"Command":{"StatusNET":{"Mac":"34-98-7A-C3-03-04"}}}',
        ),
        '34-98-7A-C3-03-04',
      );
    });

    test('Status 5 garbage / empty yields null (never throws)', () {
      expect(extractMacFromStatus5(_garbageBody), isNull);
      expect(extractMacFromStatus5(''), isNull);
      expect(extractMacFromStatus5('not json at all'), isNull);
    });

    test('State with multi-relay POWER keys → cloud status shape', () {
      final status = parseLocalState(
        '{"POWER1":"ON","POWER2":"OFF","Wifi":{"AP":1,"SSId":"home"}}',
      );
      expect(status['online'], isTrue);
      expect(status['POWER1'], 'ON');
      expect(status['POWER2'], 'OFF');
    });

    test('State with IPAddress surfaces it as ipAddress (DHCP self-heal)', () {
      final status = parseLocalState(
        '{"POWER1":"ON","IPAddress":"192.168.1.77"}',
      );
      expect(status['ipAddress'], '192.168.1.77');
      expect(status['POWER1'], 'ON');
    });

    test('State without IPAddress has no ipAddress key', () {
      final status = parseLocalState('{"POWER1":"ON"}');
      expect(status.containsKey('ipAddress'), isFalse);
    });

    test('State nesting under /cm Command wrapper is resolved', () {
      final status = parseLocalState('{"Command":{"Power":"OFF"}}');
      expect(status['online'], isTrue);
      expect(status['POWER'], 'OFF');
    });

    test('Non-JSON status body → online only, no channels', () {
      final status = parseLocalState('upstream error page');
      expect(status['online'], isTrue);
      expect(status.containsKey('POWER1'), isFalse);
    });

    test('single-relay Power response uses the POWER key', () {
      final status = parseLocalState('{"POWER":"ON"}');
      expect(status['POWER'], 'ON');
      expect(status['online'], isTrue);
    });
  });

  group('parseRelayStatus / ChannelReport (pure)', () {
    test('canonical channels map is parsed into per-channel reports', () {
      final iso = DateTime.now().toIso8601String();
      final result = parseRelayStatus(
        {
          'online': true,
          'channels': {
            '1': {'state': 'ON', 'updatedAt': iso},
            '2': {'state': 'OFF', 'updatedAt': iso},
            '3': {'state': 'UNKNOWN', 'updatedAt': null},
          },
        },
        source: DeviceTransportSource.cloud,
        seq: 7,
      );
      expect(result.online, isTrue);
      expect(result.source, DeviceTransportSource.cloud);
      expect(result.seq, 7);
      expect(result.channels[1]!.state, 'ON');
      expect(result.channels[2]!.state, 'OFF');
      expect(result.channels[2]!.updatedAt, isNotNull);
      expect(result.channels[3]!.isUnknown, isTrue,
          reason: "backend 'UNKNOWN' maps to a null/unknown report");
      expect(result.channels[1]!.isOn, isTrue);
      expect(result.channels[2]!.isOn, isFalse);
    });

    test('legacy flat POWERn keys are read when channels is absent', () {
      final result = parseRelayStatus(
        {'online': true, 'POWER1': 'ON', 'POWER2': 'UNKNOWN'},
        source: DeviceTransportSource.local,
        seq: 1,
      );
      expect(result.channels[1]!.state, 'ON');
      expect(result.channels[2]!.isUnknown, isTrue);
    });

    test('bare POWER maps to channel 1 when no numbered keys exist', () {
      final result = parseRelayStatus(
        {'online': true, 'POWER': 'OFF'},
        source: DeviceTransportSource.cloud,
        seq: 1,
      );
      expect(result.channels[1]!.state, 'OFF');
    });

    test('offline flag is preserved', () {
      final result = parseRelayStatus(
        {'online': false},
        source: DeviceTransportSource.cloud,
        seq: 1,
      );
      expect(result.online, isFalse);
      expect(result.channels, isEmpty);
    });
  });

  group('LocalDeviceTransport identity gate', () {
    test('matching Status 5 MAC → identity verified', () async {
      final cm = _CmFake({
        'Status%205': _macBody,
        'State': '{"POWER1":"ON"}',
      });
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      expect(await t.verifyIdentity(), isTrue);
    });

    test('foreign Status 5 MAC → identity rejected', () async {
      final cm = _CmFake({'Status%205': _otherMacBody});
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      expect(await t.verifyIdentity(), isFalse);
    });

    test('unparseable Status 5 → identity rejected', () async {
      final cm = _CmFake({'Status%205': _garbageBody});
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      expect(await t.verifyIdentity(), isFalse);
    });

    test('referer-denied Status 5 (pre-SO128) → refererGated, NOT mismatch',
        () async {
      // While SetOption128 is OFF Tasmota answers a referer-less `Status 5`
      // with the denial warning and NO MAC. That must be classified as
      // `refererGated` (reachable, pre-SO128) so discovery keeps the IP for the
      // bootstrap instead of treating it as a repurposed foreign box.
      final cm = _CmFake({'Status%205': _refererDeniedBody});
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      expect(await t.checkIdentity(), LocalIdentityCheck.refererGated);
      expect(await t.verifyIdentity(), isFalse);
      expect(cm.called, ['Status%205', 'Status%205']);
    });

    test('control is never sent before identity verification succeeds',
        () async {
      final cm = _CmFake({'Status%205': _moreOtherMacBody});
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      await expectLater(
        t.control(_deviceId, 1, 'ON'),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => e.kind,
            'kind',
            TransportFailureKind.logical,
          ),
        ),
      );
      expect(
        cm.called,
        ['Status%205'],
        reason: 'a Power command must never run against an unverified device',
      );
    });

    test('mismatched target deviceId is rejected', () async {
      final cm = _CmFake({'Status%205': _macBody});
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      await expectLater(
        t.control('SOME_OTHER_ID', 1, 'ON'),
        throwsA(isA<DeviceTransportException>()),
      );
      expect(cm.called, isEmpty);
    });
  });

  group('LocalDeviceTransport commands', () {
    test('relay ON: verifies identity, commands, then CONFIRMS via read-back',
        () async {
      final cm = _CmFake({
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
        'State': '{"POWER1":"ON"}',
      });
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      final result = await t.control(_deviceId, 1, 'ON');
      expect(cm.called, ['Status%205', 'Power1%20ON', 'State']);
      expect(result['POWER1'], 'ON');
      expect(result['online'], isTrue);
    });

    test('relay OFF on channel 3 sends Power3 OFF and confirms', () async {
      final cm = _CmFake({
        'Status%205': _macBody,
        'Power3%20OFF': '{"POWER3":"OFF"}',
        'State': '{"POWER3":"OFF"}',
      });
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      final result = await t.control(_deviceId, 3, 'OFF');
      expect(cm.called, ['Status%205', 'Power3%20OFF', 'State']);
      expect(result['POWER3'], 'OFF');
    });

    test('relay command whose read-back disagrees throws logical UNCONFIRMED',
        () async {
      final cm = _CmFake({
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
        'State': '{"POWER1":"OFF"}',
      });
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      await expectLater(
        t.control(_deviceId, 1, 'ON'),
        throwsA(
          isA<DeviceTransportException>()
              .having((e) => e.kind, 'kind', TransportFailureKind.logical)
              .having((e) => e.code, 'code', 'UNCONFIRMED'),
        ),
      );
    });

    test('relay command whose read-back fails throws logical UNCONFIRMED',
        () async {
      final cm = _CmFake({'Status%205': _macBody, 'Power1%20ON': '{"POWER1":"ON"'});
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      await expectLater(
        t.control(_deviceId, 1, 'ON'),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => e.code,
            'code',
            'UNCONFIRMED',
          ),
        ),
      );
    });

    test('getStatus reads State and returns device status shape', () async {
      final cm = _CmFake({
        'Status%205': _macBody,
        'State': '{"POWER1":"ON","POWER2":"OFF"}',
      });
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      final result = await t.getStatus(_deviceId);
      expect(cm.called, ['Status%205', 'State']);
      expect(result['online'], isTrue);
      expect(result['POWER1'], 'ON');
      expect(result['POWER2'], 'OFF');
    });

    test('local timeout is bounded (readBudget enforced)', () async {
      final cm = _CmFake({'Status%205': _macBody})
        ..delay = const Duration(milliseconds: 300);
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
        connectTimeout: const Duration(milliseconds: 20),
        readTimeout: const Duration(milliseconds: 30),
      );
      final sw = Stopwatch()..start();
      await expectLater(
        t.getStatus(_deviceId),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => e.kind,
            'kind',
            TransportFailureKind.availability,
          ),
        ),
      );
      sw.stop();
      expect(sw.elapsedMilliseconds < 150, isTrue,
          reason: 'a 30ms budget must yield long before the 300ms delay');
    });

    test('identity verification fails fast with unreachable device', () async {
      final cm = _CmFake({})..error = const SocketException('unreachable');
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      expect(await t.verifyIdentity(), isFalse);
    });
  });

  group('LocalDeviceTransport auto HTTP API setup (enableHttpApi)', () {
    test('sends SetOption128 with a device-matching Referer, no identity probe',
        () async {
      final cm = _CmFake({'SetOption128%201': '{"SetOption128":"1"}'});
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      await t.enableHttpApi();
      expect(cm.called, ['SetOption128%201']);
      // The Referer matches the device's own address (what the console sends),
      // so the enable command passes Tasmota's check even while SO128 is OFF.
      expect(cm.lastReferer, 'http://192.168.1.5/');
    });

    test('idempotent when SetOption128 is already enabled', () async {
      final cm = _CmFake({'SetOption128%201': '{"SetOption128":"1"}'});
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      // No exception: re-running the setup on an already-configured device is a
      // normal, safe outcome.
      await t.enableHttpApi();
      await t.enableHttpApi();
      expect(cm.called, ['SetOption128%201', 'SetOption128%201']);
    });

    test('a referer-denied response fails the setup visibly', () async {
      final cm = _CmFake({
        'SetOption128%201':
            '{"WARNING":"Referer \'\' denied. Use \'SO128 1\' for HTTP API commands."}',
      });
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      await expectLater(
        t.enableHttpApi(),
        throwsA(
          isA<DeviceTransportException>()
              .having((e) => e.message, 'message', contains('rejected')),
        ),
      );
    });

    test('unreachable device propagates an availability failure', () async {
      final cm = _CmFake({})..error = const SocketException('unreachable');
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      await expectLater(
        t.enableHttpApi(),
        throwsA(
          isA<DeviceTransportException>()
              .having((e) => e.kind, 'kind', TransportFailureKind.availability),
        ),
      );
    });

    test('invalid address never reaches the fetcher', () async {
      final cm = _CmFake({});
      final t = LocalDeviceTransport(
        address: '0.0.0.0',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      await expectLater(
        t.enableHttpApi(),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => e.message,
            'message',
            contains('address is invalid'),
          ),
        ),
      );
      expect(cm.called, isEmpty);
    });

    test('bootstrap mode attaches the Referer to EVERY request, probe included',
        () async {
      // While SO128 is OFF Tasmota answers a referer-less `Status 5` with the
      // denial warning (no MAC), which discovery would read as a MISMATCH. The
      // bootstrap transport must therefore send the device-matching Referer on
      // the identity probe, the enable, and the read-back.
      final cm = _CmFake({
        'Status%205': _macBody,
        'SetOption128%201': '{"SetOption128":"1"}',
        'State': '{"POWER1":"ON"}',
      });
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
        bootstrap: true,
      );
      expect(await t.checkIdentity(), LocalIdentityCheck.verified);
      await t.enableHttpApi();
      await t.getStatus(_deviceId, identityVerified: true);
      expect(cm.referers['Status%205'], 'http://192.168.1.5/');
      expect(cm.referers['SetOption128%201'], 'http://192.168.1.5/');
      expect(cm.referers['State'], 'http://192.168.1.5/');
    });

    test('normal mode NEVER sends a Referer on probe/status/control', () async {
      final cm = _CmFake({
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
        'State': '{"POWER1":"ON"}',
      });
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      expect(await t.checkIdentity(), LocalIdentityCheck.verified);
      await t.getStatus(_deviceId, identityVerified: true);
      await t.control(_deviceId, 1, 'ON', identityVerified: true);
      expect(cm.referers.values.every((r) => r == null), isTrue,
          reason: 'the production status/control path stays referer-less');
    });
  });

  group('CloudDeviceTransport passthrough', () {
    test('delegates 1:1 to ApiService and reports cloud source', () async {
      final api = _FakeCloudApi();
      final t = CloudDeviceTransport(api: api);
      expect(t.source, DeviceTransportSource.cloud);

      final status = await t.getStatus(_deviceId);
      expect(api.statusCalls, 1);
      expect(status['POWER1'], 'ON');

      final ctl = await t.control(_deviceId, 2, 'ON');
      expect(api.controlCalls, 1);
      expect(ctl['POWER2'], 'ON');
    });

    test('propagates the underlying ApiException unmodified', () async {
      final api = _FakeCloudApi()
        ..controlError = const ApiException(
          'Device is offline',
          statusCode: 409,
          code: 'DEVICE_OFFLINE',
        );
      final t = CloudDeviceTransport(api: api);
      await expectLater(
        t.control(_deviceId, 1, 'ON'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.code, 'code', 'DEVICE_OFFLINE'),
        ),
      );
    });
  });

  group('defaultTasmotaCmFetcher (real local HTTP)', () {
    Future<HttpServer> startServer(
      Future<void> Function(HttpRequest req) handler,
    ) async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        try {
          await handler(req);
        } catch (_) {}
      });
      return server;
    }

    test('HTTP 200 returns the raw body', () async {
      final server = await startServer((req) async {
        expect(req.uri.path, '/cm');
        expect(req.uri.queryParameters['cmnd'], 'State');
        req.response.write('{"POWER1":"ON"}');
        await req.response.close();
      });
      try {
        final body = await defaultTasmotaCmFetcher(
          '127.0.0.1:${server.port}',
          'State',
          deviceId: _deviceId,
        );
        expect(body, '{"POWER1":"ON"}');
      } finally {
        await server.close(force: true);
      }
    });

    test('a supplied Referer reaches the underlying HTTP request on the wire',
        () async {
      // Regression: the SetOption128 bootstrap request must carry the device-
      // matching Referer at the NETWORK level (proving no abstraction between
      // the transport and the socket drops it).
      String? observed;
      final server = await startServer((req) async {
        observed = req.headers.value('referer');
        req.response.write('{"SetOption128":"1"}');
        await req.response.close();
      });
      try {
        final sentReferer = 'http://127.0.0.1:${server.port}/';
        final body = await defaultTasmotaCmFetcher(
          '127.0.0.1:${server.port}',
          'SetOption128%201',
          deviceId: _deviceId,
          referer: sentReferer,
        );
        expect(body, '{"SetOption128":"1"}');
        // The exact header value we supplied is what the peer observed.
        expect(observed, sentReferer);
      } finally {
        await server.close(force: true);
      }
    });

    test('without referer the request carries NO Referer header on the wire',
        () async {
      String? observed;
      final server = await startServer((req) async {
        observed = req.headers.value('referer');
        req.response.write('{"POWER1":"ON"}');
        await req.response.close();
      });
      try {
        await defaultTasmotaCmFetcher(
          '127.0.0.1:${server.port}',
          'State',
          deviceId: _deviceId,
        );
        expect(observed, isNull,
            reason: 'the normal status/control path must stay referer-less');
      } finally {
        await server.close(force: true);
      }
    });

    test('HTTP 401 wraps with the status in the message and an HttpException cause',
        () async {
      final server = await startServer((req) async {
        req.response.statusCode = HttpStatus.unauthorized;
        req.response.write('Unauthorized');
        await req.response.close();
      });
      try {
        await expectLater(
          defaultTasmotaCmFetcher(
            '127.0.0.1:${server.port}',
            'Status%205',
            deviceId: _deviceId,
          ),
          throwsA(
            isA<DeviceTransportException>()
                .having((e) => e.kind, 'kind', TransportFailureKind.availability)
                .having(
                  (e) => e.message,
                  'message',
                  contains('401'),
                )
                .having(
                  (e) => e.cause,
                  'cause',
                  isA<HttpException>(),
                ),
          ),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('HTTP 500 wraps with the status preserved', () async {
      final server = await startServer((req) async {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.write('boom');
        await req.response.close();
      });
      try {
        await expectLater(
          defaultTasmotaCmFetcher(
            '127.0.0.1:${server.port}',
            'State',
            deviceId: _deviceId,
          ),
          throwsA(
            isA<DeviceTransportException>()
                .having((e) => e.kind, 'kind', TransportFailureKind.availability)
                .having((e) => e.message, 'message', contains('500')),
          ),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('read timeout wraps a TimeoutException as the cause', () async {
      final server = await startServer((req) async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        req.response.write('late');
        await req.response.close();
      });
      try {
        await expectLater(
          defaultTasmotaCmFetcher(
            '127.0.0.1:${server.port}',
            'State',
            deviceId: _deviceId,
            readTimeout: const Duration(milliseconds: 50),
          ),
          throwsA(
            isA<DeviceTransportException>()
                .having((e) => e.kind, 'kind', TransportFailureKind.availability)
                .having(
                  (e) => e.cause,
                  'cause',
                  isA<TimeoutException>(),
                ),
          ),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('connection refused wraps the SocketException as the cause', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final port = server.port;
      await server.close(force: true);
      // The port is now closed: connecting must surface a SocketException
      // (connection refused) wrapped as availability with the original cause.
      await expectLater(
        defaultTasmotaCmFetcher(
          '127.0.0.1:$port',
          'State',
          deviceId: _deviceId,
        ),
        throwsA(
          isA<DeviceTransportException>()
              .having((e) => e.kind, 'kind', TransportFailureKind.availability)
              .having(
                (e) => e.cause,
                'cause',
                isA<SocketException>(),
              ),
        ),
      );
    });

    test('a malformed URL wraps the FormatException as the cause', () async {
      await expectLater(
        defaultTasmotaCmFetcher(
          'bad host', // a space is invalid in a URL host — Uri.parse throws
          'State',
          deviceId: _deviceId,
        ),
        throwsA(
          isA<DeviceTransportException>()
              .having((e) => e.kind, 'kind', TransportFailureKind.availability)
              .having(
                (e) => e.cause,
                'cause',
                isA<FormatException>(),
              ),
        ),
      );
    });
  });

  group('LocalDeviceTransport diagnostics', () {
    test('a bare SocketException escape keeps the original as cause', () async {
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: (address, command, {password, deviceId, referer}) async {
          throw const SocketException(
            'Connection refused',
            osError: OSError('refused', 111),
          );
        },
      );
      await expectLater(
        t.getStatus(_deviceId),
        throwsA(
          isA<DeviceTransportException>()
              .having((e) => e.kind, 'kind', TransportFailureKind.availability)
              .having(
                (e) => e.cause,
                'cause',
                isA<SocketException>().having(
                  (e) => e.osError?.errorCode,
                  'osErrorCode',
                  111,
                ),
              ),
        ),
      );
    });

    test('a connect-timeout SocketException (OSError 110) is preserved', () async {
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: (address, command, {password, deviceId, referer}) async {
          throw const SocketException(
            'Connection timed out',
            osError: OSError('timed out', 110),
          );
        },
      );
      await expectLater(
        t.getStatus(_deviceId),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => (e.cause as SocketException).osError?.errorCode,
            'osErrorCode',
            110,
          ),
        ),
      );
    });

    test('an outer read timeout wraps the TimeoutException as cause', () async {
      final cm = _CmFake({'Status%205': _macBody})
        ..delay = const Duration(milliseconds: 200);
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
        readTimeout: const Duration(milliseconds: 30),
      );
      await expectLater(
        t.getStatus(_deviceId),
        throwsA(
          isA<DeviceTransportException>()
              .having((e) => e.kind, 'kind', TransportFailureKind.availability)
              .having(
                (e) => e.cause,
                'cause',
                isA<TimeoutException>(),
              ),
        ),
      );
    });

    test('a classified DeviceTransportException passes through with its cause',
        () async {
      final original = DeviceTransportException(
        'The local device returned HTTP 401.',
        cause: HttpException('HTTP 401'),
      );
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: (address, command, {password, deviceId, referer}) async {
          throw original;
        },
      );
      await expectLater(
        t.getStatus(_deviceId),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => identical(e, original),
            'same instance',
            isTrue,
          ),
        ),
      );
    });

    test('scheme + trailing slash are normalized before HTTP (same endpoint)',
        () async {
      final cm = _CmFake({
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
        'State': '{"POWER1":"ON"}',
      });
      final t = LocalDeviceTransport(
        address: 'http://192.168.1.5/',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      expect(t.address, '192.168.1.5',
          reason: 'the endpoint is normalized to host[:port] form');
      final result = await t.control(_deviceId, 1, 'ON');
      expect(cm.called, ['Status%205', 'Power1%20ON', 'State']);
      expect(result['POWER1'], 'ON');
    });

    test('IPv6 addresses are bracketed (with zone encoding)', () async {
      final t = LocalDeviceTransport(
        address: 'fe80::1',
        deviceId: _deviceId,
        fetcher: (address, command, {password, deviceId, referer}) async => '',
      );
      expect(t.address, '[fe80::1]');
      final withZone = LocalDeviceTransport(
        address: 'fe80::1%wlan0',
        deviceId: _deviceId,
        fetcher: (address, command, {password, deviceId, referer}) async => '',
      );
      expect(withZone.address, '[fe80::1%25wlan0]');
    });

    test('IPv4:port stays untouched', () async {
      final t = LocalDeviceTransport(
        address: '192.168.1.20:8080',
        deviceId: _deviceId,
        fetcher: (address, command, {password, deviceId, referer}) async => '',
      );
      expect(t.address, '192.168.1.20:8080');
    });
  });

  group('LocalDeviceTransport invalid-address guard', () {
    test('0.0.0.0 never reaches the HTTP fetcher (status)', () async {
      final cm = _CmFake({'Status%205': _macBody});
      final t = LocalDeviceTransport(
        address: '0.0.0.0',
        deviceId: _deviceId,
        fetcher: cm.call,
      );

      await expectLater(
        t.getStatus(_deviceId),
        throwsA(
          isA<DeviceTransportException>().having(
            (e) => e.kind,
            'kind',
            TransportFailureKind.availability,
          ),
        ),
      );
      expect(cm.called, isEmpty,
          reason: 'no socket may ever be opened against 0.0.0.0');
    });

    test('0.0.0.0 fails identity verification without any HTTP call',
        () async {
      final cm = _CmFake({'Status%205': _macBody});
      final t = LocalDeviceTransport(
        address: '0.0.0.0',
        deviceId: _deviceId,
        fetcher: cm.call,
      );

      expect(await t.verifyIdentity(), isFalse);
      expect(await t.checkIdentity(), LocalIdentityCheck.unavailable);
      expect(cm.called, isEmpty);
    });

    test('0.0.0.0 never reaches the HTTP fetcher (control)', () async {
      final cm = _CmFake({'Status%205': _macBody});
      final t = LocalDeviceTransport(
        address: '0.0.0.0',
        deviceId: _deviceId,
        fetcher: cm.call,
      );

      await expectLater(
        t.control(_deviceId, 1, 'ON'),
        throwsA(isA<DeviceTransportException>()),
      );
      expect(cm.called, isEmpty,
          reason: 'a Power command must never target 0.0.0.0');
    });

    test('a valid LAN IPv4 still reaches the fetcher normally', () async {
      final cm = _CmFake({
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
        'State': '{"POWER1":"ON"}',
      });
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );

      final result = await t.control(_deviceId, 1, 'ON');
      expect(cm.called, ['Status%205', 'Power1%20ON', 'State']);
      expect(result['POWER1'], 'ON');
    });
  });
}

const _moreOtherMacBody = '{"StatusNET":{"Mac":"AA:BB:CC:DD:EE:FF"}}';