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

/// Controllable [TasmotaCmFetcher] backed by a command→body table.
class _CmFake {
  _CmFake(this.responses);

  final Map<String, String> responses;
  final List<String> called = [];
  Object? error;
  Duration delay = Duration.zero;

  Future<String> call(String address, String command, {String? password}) async {
    called.add(command);
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
    test('relay ON: verifies identity then sends Power<N> ON', () async {
      final cm = _CmFake({
        'Status%205': _macBody,
        'Power1%20ON': '{"POWER1":"ON"}',
      });
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      final result = await t.control(_deviceId, 1, 'ON');
      expect(cm.called, ['Status%205', 'Power1%20ON']);
      expect(result['POWER1'], 'ON');
      expect(result['online'], isTrue);
    });

    test('relay OFF on channel 3 sends Power3 OFF', () async {
      final cm = _CmFake({
        'Status%205': _macBody,
        'Power3%20OFF': '{"POWER3":"OFF"}',
      });
      final t = LocalDeviceTransport(
        address: '192.168.1.5',
        deviceId: _deviceId,
        fetcher: cm.call,
      );
      final result = await t.control(_deviceId, 3, 'OFF');
      expect(cm.called, ['Status%205', 'Power3%20OFF']);
      expect(result['POWER3'], 'OFF');
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
}

const _moreOtherMacBody = '{"StatusNET":{"Mac":"AA:BB:CC:DD:EE:FF"}}';