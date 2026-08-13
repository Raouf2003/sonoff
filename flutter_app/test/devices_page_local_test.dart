import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:smart_home_app/screens/devices_page.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/cloud_device_transport.dart';
import 'package:smart_home_app/services/device_repository_service.dart';
import 'package:smart_home_app/services/device_transport.dart';
import 'package:smart_home_app/services/local_device_cache.dart';
import 'package:smart_home_app/services/local_device_discovery.dart';
import 'package:smart_home_app/theme/app_theme.dart';

const _deviceId = '34987AC30304';
const _macBody = '{"StatusNET":{"Mac":"34:98:7A:C3:03:04"}}';
const _stateBody =
    '{"POWER1":"OFF","POWER2":"OFF","POWER3":"OFF","POWER4":"OFF"}';

/// Secure storage on the test host is unregistered; a token read must simply
/// return null so `_connectSocketAsync` cannot throw unexpectedly.
void _mockSecureStorage(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (_) async => null,
  );
}

/// Cloud that is provably unavailable (availability failure, not a rejection) —
/// used to drive the local-first fallback paths in widget tests.
class _CloudDownApi extends ApiService {
  @override
  Future<List<dynamic>> getDevices() async =>
      throw const ApiException('Could not reach the server', code: 'NETWORK_ERROR');

  @override
  Future<Map<String, dynamic>> getStatus(String deviceId) async =>
      throw const ApiException('Could not reach the server', code: 'NETWORK_ERROR');

  @override
  Future<Map<String, dynamic>> control(
    String deviceId,
    int channel,
    String state,
  ) async => throw const ApiException('Could not reach the server', code: 'NETWORK_ERROR');
}

/// Local Tasmota fetcher stub for widget-level Local Mode tests.
class _CmFake {
  _CmFake({this.responses = const {}});
  final Map<String, String> responses;

  Future<String> call(
    String address,
    String command, {
    String? password,
    String? deviceId,
  }) async {
    final body = responses[command];
    if (body == null) throw const DeviceTransportException('HTTP 404');
    return body;
  }
}

/// Discovery stub for widget-level Local Mode tests: a verified cached IP, no.
class _LocatorStub implements DeviceLocator {
  _LocatorStub({this.cached});
  final String? cached;

  @override
  Future<String?> cachedAddress(String deviceId) async => cached;

  @override
  Future<DateTime?> cachedVerifiedAt(String deviceId) async => null;

  @override
  Future<void> storeVerifiedAddress(String deviceId, String ip) async {}

  @override
  Future<void> storeCandidateAddress(String deviceId, String ip) async {}

  @override
  Future<void> discardAddress(String deviceId) async {}

  @override
  Future<List<String>> mDnsCandidates(Duration timeout) async => const [];
}

/// Scriptable repository: records relay calls, can hold them in flight, and
/// reports which transport produced each result (for the LAN indicator). The
/// device list is served by [getDevices] so the page no longer talks to a
/// cloud API directly. Reports are always CONFIRMED device reports so the page
/// can render FLOWING/DRY from them.
class _FakeRepo extends DeviceRepositoryService {
  _FakeRepo({
    this.gateControl = false,
    this.source = DeviceTransportSource.cloud,
    this.devices = const [
      {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
    ],
  });

  final bool gateControl;
  final DeviceTransportSource source;
  final List<Map<String, dynamic>> devices;
  final Completer<void> releaseControl = Completer<void>();
  int controlCalls = 0;

  @override
  Future<void> warmUp(List<Map<String, dynamic>> devices) async {
    // Discovery warm-up is a real-network path; the fake repo must not run it
    // (it would open mDNS browsers and hold fake-time timers in widget tests).
  }

  @override
  Future<List<Map<String, dynamic>>> getDevices() async => devices;

  @override
  Future<RelayStatusResult> control(
    String deviceId,
    int channel,
    String state,
  ) async {
    controlCalls++;
    if (gateControl) {
      // Hold in flight so the busy state and the double-tap guard can be
      // exercised. The test releases the gate explicitly.
      await releaseControl.future;
    }
    return RelayStatusResult(
      online: true,
      channels: {channel: ChannelReport(state)},
      source: source,
      seq: 1,
    );
  }

  @override
  Future<RelayStatusResult> getStatus(String deviceId) async {
    return RelayStatusResult(
      online: true,
      channels: {
        for (var i = 1; i <= 4; i++) i: const ChannelReport('OFF'),
      },
      source: source,
      seq: 2,
    );
  }
}

/// Socket-io client without a server: all calls are no-ops so the page wiring
/// can be exercised in isolation.
class _FakeSocket implements io.Socket {
  @override
  Function() on(String event, dynamic handler) => () {};

  @override
  io.Socket connect() => this;

  @override
  io.Socket disconnect() => this;

  @override
  void dispose() {}

  @override
  void noSuchMethod(Invocation invocation) {}
}

Future<void> _pumpDevicesPage(
  WidgetTester tester, {
  required DeviceRepositoryService repo,
}) async {
  _mockSecureStorage(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: DevicesPage.test(
          onNavigateToTab: (_) {},
          testRepository: repo,
          testSocketFactory: (url, opts) => _FakeSocket(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Unmounts the page so the 15s status poll timer is cancelled, leaving no
/// pending timers behind.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  testWidgets('relay taps drive the repository and confirm via device report',
      (tester) async {
    final repo = _FakeRepo(gateControl: true);
    await _pumpDevicesPage(tester, repo: repo);

    // Initial confirmed status: all four relays reported OFF.
    expect(find.text('DRY'), findsNWidgets(4));

    // Card rendered and the relay tap routes through the repository.
    expect(find.text('CHANNEL 1'), findsOneWidget);
    await tester.tap(find.text('CHANNEL 1'));
    await tester.pump();

    // While the (gated) command is in flight the intent is PENDING — the UI
    // must NOT commit ON (no optimistic flip), so the pill shows TURNING.
    expect(repo.controlCalls, 1);
    expect(find.text('TURNING…'), findsOneWidget);
    expect(find.text('FLOWING'), findsNothing,
        reason: 'no optimistic ON may be shown before the device confirms');

    // Release the command: the confirmed report flips channel 1 to FLOWING.
    // `pump()` (not `pumpAndSettle`) so fake time never reaches the 15s poll
    // that would re-read the static all-OFF status.
    repo.releaseControl.complete();
    await tester.pump();
    expect(repo.controlCalls, 1);
    expect(find.text('FLOWING'), findsOneWidget);
    expect(find.text('DRY'), findsNWidgets(3));

    await _unmount(tester);
  });

  testWidgets('double-tap while a relay command is in flight sends it once',
      (tester) async {
    final repo = _FakeRepo(gateControl: true);
    await _pumpDevicesPage(tester, repo: repo);

    await tester.tap(find.text('CHANNEL 1'));
    await tester.pump();
    // Second tap lands while the first command is still pending (channel
    // loading). The _pendingRelays guard + loading state must block it.
    await tester.tap(find.text('CHANNEL 1'));
    await tester.pump();

    expect(repo.controlCalls, 1,
        reason: 'a pending relay must not be re-sent on a second tap');

    await _unmount(tester);
  });

  testWidgets('successful local operation shows the subtle LAN indicator',
      (tester) async {
    final repo = _FakeRepo(source: DeviceTransportSource.local);
    await _pumpDevicesPage(tester, repo: repo);

    await tester.tap(find.text('CHANNEL 1'));
    await tester.pumpAndSettle();

    expect(find.text('LAN'), findsOneWidget,
        reason: 'Local Mode is shown implicitly, never via a mode dialog');
    expect(find.text('Online'), findsNothing);

    await _unmount(tester);
  });

  testWidgets('unconfirmed taps never flip a channel ON until a report lands',
      (tester) async {
    final repo = _FakeRepo(gateControl: true);
    await _pumpDevicesPage(tester, repo: repo);

    // Device reports OFF initially.
    expect(find.text('DRY'), findsNWidgets(4));

    await tester.tap(find.text('CHANNEL 2'));
    await tester.pump();

    // Pending only — still no FLOWING anywhere, channel 2 shows intent.
    expect(find.text('TURNING…'), findsOneWidget);
    expect(find.text('FLOWING'), findsNothing);

    // A failure clears the intent and degrades to UNKNOWN, never a fake OFF.
    repo.releaseControl.completeError(Exception('nope'));
    await tester.pumpAndSettle();

    expect(find.text('TURNING…'), findsNothing);
    expect(find.textContaining('nope'), findsWidgets,
        reason: 'the failure is surfaced to the user');
    await _unmount(tester);
  });

  group('cloud-unavailable device list', () {
    testWidgets(
        'cached device renders and LAN status succeeds — no red error (#10)',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final cache = LocalDeviceCache();
      await cache.upsert(
          {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4});
      final cm = _CmFake(responses: {'Status%205': _macBody, 'State': _stateBody});
      final repo = DeviceRepositoryService(
        cloud: CloudDeviceTransport(api: _CloudDownApi()),
        locator: _LocatorStub(cached: '192.168.1.5'),
        fetch: cm.call,
        cache: cache,
      );

      await _pumpDevicesPage(tester, repo: repo);

      // The cached list renders instead of the cloud error state.
      expect(find.text('Controller'), findsOneWidget);
      expect(find.textContaining('Could not load devices'), findsNothing);

      // Local status resolved the device: LAN pill, reachable, no error snack.
      expect(find.text('LAN'), findsOneWidget);
      expect(find.text('Offline'), findsNothing);
      expect(find.text('Failed to fetch status'), findsNothing);

      await _unmount(tester);
    });

    testWidgets(
        'cloud down + cache present + no local device → offline, not a load '
        'error (#11)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final cache = LocalDeviceCache();
      await cache.upsert(
          {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4});
      final repo = DeviceRepositoryService(
        cloud: CloudDeviceTransport(api: _CloudDownApi()),
        locator: _LocatorStub(),
        cache: cache,
      );

      await _pumpDevicesPage(tester, repo: repo);

      expect(find.text('Controller'), findsOneWidget);
      expect(find.textContaining('Could not load devices'), findsNothing);
      // Both transports failed for the STATUS, so the card is offline.
      expect(find.text('Offline'), findsOneWidget);

      await _unmount(tester);
    });

    testWidgets('cloud down + empty cache → original load error is kept',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repo = DeviceRepositoryService(
        cloud: CloudDeviceTransport(api: _CloudDownApi()),
        locator: _LocatorStub(),
        cache: LocalDeviceCache(),
      );

      await _pumpDevicesPage(tester, repo: repo);

      expect(find.text('Could not load devices'), findsOneWidget);
      expect(find.textContaining('Check your connection'), findsOneWidget);

      await _unmount(tester);
    });

    testWidgets('no manual IP entry UI is ever exposed (#16)', (tester) async {
      final repo = _FakeRepo(
        devices: const [
          {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
        ],
      );
      await _pumpDevicesPage(tester, repo: repo);

      // Device renders, but no raw address / IP input / locator is shown to
      // the user — Local Mode is fully automatic.
      expect(find.text('Controller'), findsOneWidget);
      expect(find.textContaining('192.168'), findsNothing);
      expect(find.textContaining('IP address'), findsNothing);
      expect(find.textContaining('Enter IP'), findsNothing);

      await _unmount(tester);
    });
  });
}
