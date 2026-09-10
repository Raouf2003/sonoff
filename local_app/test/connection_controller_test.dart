import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stees_local/connection/connection_controller.dart';
import 'package:stees_local/connection/connection_machine.dart';
import 'package:stees_local/connection/pairing_store.dart';
import 'package:stees_local/connection/session.dart';
import 'package:stees_local/devices/device_repository.dart';
import 'package:stees_local/transport/clock_sync.dart';
import 'package:stees_local/transport/device_transport.dart';

const _mac = '34987AC30304';
const _macBody = '{"StatusNET":{"Mac":"34:98:7A:C3:03:04"}}';

String _iso(DateTime t) {
  String p(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${p(t.month)}-${p(t.day)}T${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
}

Future<String> _okProbe(String address, String command, {String? password, String? referer}) async {
  return _macBody;
}

Future<String> _repoFetch(String address, String command,
    {String? password, String? deviceId, String? referer}) async {
  if (command == 'SetOption128%201') return '{"SetOption128":"1"}';
  if (command == 'Status%205') {
    return '{"StatusNET":{"Mac":"34:98:7A:C3:03:04","HTTP_API":1}}';
  }
  if (command == 'State') return '{"POWER1":"ON"}';
  throw const DeviceTransportException('unexpected');
}

Future<String> _clockFetch(String address, String command,
    {String? password, String? deviceId, String? referer}) async {
  if (command == 'Time') return '{"Time":"${_iso(DateTime.now())}"}';
  return '{}';
}

void _mockChannels({
  required bool wifi,
  bool matched = true,
  bool internet = false,
  List<Map<String, Object?>>? scanNetworks,
  String apStage = 'available',
}) {
  final binding = TestDefaultBinaryMessengerBinding.instance;
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('stees/wifi_settings'),
    (call) async {
      if (call.method == 'scanWifi') {
        if (scanNetworks == null) {
          return {'available': false, 'networks': [], 'reason': 'unavailable'};
        }
        return {'available': true, 'networks': scanNetworks, 'reason': null};
      }
      return null;
    },
  );
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('stees/ap_connect'),
    (call) async {
      if (call.method == 'connectToAp') return {'stage': apStage};
      return null;
    },
  );
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('stees/wifi_binding'),
    (call) async {
      if (call.method == 'ensureBoundToActiveWifi' || call.method == 'getNetworkInfo') {
        return {'bound': true, 'wifi': wifi, 'internet': internet, 'validated': false, 'matched': matched, 'activeSsid': 'tasmota-AB12CD'};
      }
      return null;
    },
  );
}

ConnectionController _controller({
  StatusProbe? probe,
  SessionState? session,
  LocalDeviceRepository? repository,
}) {
  return ConnectionController(
    pairing: PairingStore(),
    repository: repository ?? LocalDeviceRepository(fetch: _repoFetch),
    clock: ClockSync(fetch: _clockFetch),
    session: session,
    probe: probe ?? _okProbe,
    wifiWatchInterval: const Duration(milliseconds: 50),
    wifiWatchTimeout: const Duration(seconds: 5),
  );
}

Future<void> _waitFor(WidgetTester tester, ConnectionController c) async {
  for (var i = 0; i < 200 && !c.state.isTerminal; i++) {
    if (c.awaitingConfirm) await c.confirmPairing('Test Device');
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    _mockChannels(wifi: true);
  });

  testWidgets('new device flows to succeeded and establishes the session', (tester) async {
    final session = SessionState();
    final c = _controller(session: session);
    await c.start();
    await _waitFor(tester, c);
    expect(c.state.phase, ConnectionPhase.succeeded);
    expect(c.isWatching, isFalse);
    expect(session.session?.mac, _mac);
    expect(await PairingStore().pairedMac(), _mac);
    c.dispose();
  });

  testWidgets('AP with internet capability still completes (no-internet is normal)', (tester) async {
    _mockChannels(wifi: true, internet: true);
    final session = SessionState();
    final c = _controller(session: session);
    await c.start();
    await _waitFor(tester, c);
    expect(c.state.phase, ConnectionPhase.succeeded);
    expect(session.session?.mac, _mac);
    c.dispose();
  });

  testWidgets('concurrent starts run a single attempt', (tester) async {
    var opens = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('stees/wifi_settings'),
      (call) async {
        opens++;
        return null;
      },
    );
    final c = _controller();
    await Future.wait([c.start(), c.start()]);
    await _waitFor(tester, c);
    expect(opens, 1);
    expect(c.state.phase, ConnectionPhase.succeeded);
    c.dispose();
  });

  testWidgets('unreachable device fails with unreachable and stops the watch', (tester) async {
    Future<String> down(String a, String cmd, {String? password, String? referer}) async {
      throw const DeviceTransportException('down');
    }
    final c = _controller(probe: down);
    await c.start();
    await _waitFor(tester, c);
    expect(c.state.phase, ConnectionPhase.failed);
    expect(c.state.failure, ConnectionFailure.unreachable);
    expect(failureMessage(c.state), contains('192.168.4.1'));
    expect(c.isWatching, isFalse);
    c.dispose();
  });

  testWidgets('non-tasmota answer fails as notTasmota', (tester) async {
    Future<String> junk(String a, String cmd, {String? password, String? referer}) async {
      return '<html>router login</html>';
    }
    final c = _controller(probe: junk);
    await c.start();
    await _waitFor(tester, c);
    expect(c.state.failure, ConnectionFailure.notTasmota);
    c.dispose();
  });

  testWidgets('different MAC than paired fails as macMismatch', (tester) async {
    SharedPreferences.setMockInitialValues({
      'stees_local.paired_mac': 'AAAAAAAAAAAAAAAA',
      'stees_local.device_name': 'Old',
    });
    final c = _controller();
    await c.start();
    await _waitFor(tester, c);
    expect(c.state.failure, ConnectionFailure.macMismatch);
    expect(c.state.expectedMac, 'AAAAAAAAAAAAAAAA');
    expect(c.state.foundMacValue, _mac);
    c.dispose();
  });

  testWidgets('HTTP 401 maps to badPassword', (tester) async {
    Future<String> locked(String a, String cmd, {String? password, String? referer}) async {
      throw DeviceTransportException('HTTP 401', cause: HttpException('HTTP 401'));
    }
    final c = _controller(probe: locked);
    await c.start();
    await _waitFor(tester, c);
    expect(c.state.failure, ConnectionFailure.badPassword);
    c.dispose();
  });

  testWidgets('wifi timeout fails when wifi never appears', (tester) async {
    _mockChannels(wifi: false);
    final session = SessionState();
    final c = ConnectionController(
      pairing: PairingStore(),
      repository: LocalDeviceRepository(fetch: _repoFetch),
      clock: ClockSync(fetch: _clockFetch),
      session: session,
      probe: _okProbe,
      wifiWatchInterval: const Duration(milliseconds: 50),
      wifiWatchTimeout: const Duration(milliseconds: 200),
    );
    await c.start();
    await _waitFor(tester, c);
    expect(c.state.failure, ConnectionFailure.wifiTimeout);
    expect(c.isWatching, isFalse);
    c.dispose();
  });

  testWidgets('retry after failure rescans the flow again', (tester) async {
    var calls = 0;
    Future<String> flaky(String a, String cmd, {String? password, String? referer}) async {
      calls++;
      if (calls == 1) throw const DeviceTransportException('down');
      return _macBody;
    }
    final session = SessionState();
    final c = _controller(probe: flaky, session: session);
    await c.start();
    await _waitFor(tester, c);
    expect(c.state.failure, ConnectionFailure.unreachable);
    _mockChannels(
      wifi: true,
      scanNetworks: [
        {'name': 'HomeNet', 'rssi': -50, 'bssid': null},
        {'name': 'tasmota-AB12CD', 'rssi': -70, 'bssid': null},
      ],
    );
    await c.retry();
    await _waitFor(tester, c);
    expect(c.state.phase, ConnectionPhase.networksAvailable);
    expect(c.networks.first.name, 'tasmota-AB12CD');
    await c.select('tasmota-AB12CD');
    await _waitFor(tester, c);
    expect(c.state.phase, ConnectionPhase.succeeded);
    expect(session.session?.mac, _mac);
    c.dispose();
  });

  testWidgets('scan unavailable fails with scanFailed', (tester) async {
    _mockChannels(wifi: false);
    final c = _controller();
    await c.scan();
    await _waitFor(tester, c);
    expect(c.state.phase, ConnectionPhase.failed);
    expect(c.state.failure, ConnectionFailure.scanFailed);
    c.dispose();
  });

  testWidgets('select with join timeout fails as wifiTimeout', (tester) async {
    _mockChannels(
      wifi: true,
      scanNetworks: [
        {'name': 'tasmota-AB12CD', 'rssi': -60, 'bssid': null},
      ],
      apStage: 'timeout',
    );
    final c = _controller();
    await c.scan();
    await _waitFor(tester, c);
    expect(c.state.phase, ConnectionPhase.networksAvailable);
    await c.select('tasmota-AB12CD');
    await _waitFor(tester, c);
    expect(c.state.failure, ConnectionFailure.wifiTimeout);
    c.dispose();
  });

  testWidgets('duplicate select runs a single join', (tester) async {
    var joins = 0;
    _mockChannels(
      wifi: true,
      scanNetworks: [
        {'name': 'tasmota-AB12CD', 'rssi': -60, 'bssid': null},
      ],
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('stees/ap_connect'),
      (call) async {
        joins++;
        return {'stage': 'available'};
      },
    );
    final session = SessionState();
    final c = _controller(session: session);
    await c.scan();
    await _waitFor(tester, c);
    await Future.wait([c.select('tasmota-AB12CD'), c.select('tasmota-AB12CD')]);
    await _waitFor(tester, c);
    expect(joins, 1);
    expect(c.state.phase, ConnectionPhase.succeeded);
    c.dispose();
  });

  testWidgets('paired device skips setup and goes straight through', (tester) async {
    SharedPreferences.setMockInitialValues({
      'stees_local.paired_mac': _mac,
      'stees_local.device_name': 'Sonoff',
    });
    var setups = 0;
    Future<String> countingRepo(String address, String command,
        {String? password, String? deviceId, String? referer}) async {
      if (command == 'SetOption128%201') setups++;
      return _repoFetch(address, command, password: password, deviceId: deviceId, referer: referer);
    }
    final session = SessionState();
    final c = _controller(
      session: session,
      repository: LocalDeviceRepository(fetch: countingRepo),
    );
    await c.start();
    await _waitFor(tester, c);
    expect(c.state.phase, ConnectionPhase.succeeded);
    expect(setups, 0);
    expect(session.session?.mac, _mac);
    c.dispose();
  });
}
