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
    String state, {
    String? opId,
  }) async => throw const ApiException('Could not reach the server', code: 'NETWORK_ERROR');
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
  bool? lastCloudDown;

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
    String state, {
    String? opId,
    bool cloudDown = false,
  }) async {
    controlCalls++;
    lastCloudDown = cloudDown;
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

/// Socket-io client that can be DRIVEN by the test: `on`/`onConnect`/
/// `onDisconnect`/`onConnectError` handlers are captured so the test can emit
/// `device_status`/`device_update` events and fire connect/disconnect at will.
class _ScriptableSocket implements io.Socket {
  final Map<String, Function> _handlers = {};
  final List<String> log = [];

  @override
  Function() on(String event, dynamic handler) {
    _handlers[event] = handler as Function;
    return () {};
  }

  @override
  io.Socket connect() {
    log.add('connect');
    return this;
  }

  @override
  io.Socket disconnect() {
    log.add('disconnect');
    return this;
  }

  @override
  void dispose() {}

  @override
  void noSuchMethod(Invocation invocation) {}

  void fireConnect() => _handlers['connect']?.call(null);
  void fireDisconnect() => _handlers['disconnect']?.call(null);
  void fireConnectError() => _handlers['connect_error']?.call(null);
  void push(String event, dynamic data) {
    final h = _handlers[event];
    if (h != null) h(data);
  }
}

/// Repository whose status reads always fail (availability). Used to prove a
/// single poll failure does not flip the card OFFLINE and that only the
/// repeated-failure threshold may.
class _StatusFailingRepo extends _FakeRepo {
  @override
  Future<RelayStatusResult> getStatus(String deviceId) async {
    throw const ApiException('Could not reach the server', code: 'NETWORK_ERROR');
  }
}

/// Repository that succeeds until [failNext] is set, then throws ONCE before
/// succeeding again — models a transient status failure with valid device
/// evidence already present.
class _FailOnceRepo extends _FakeRepo {
  bool failNext = false;

  @override
  Future<RelayStatusResult> getStatus(String deviceId) async {
    if (failNext) {
      failNext = false;
      throw const ApiException('Could not reach the server', code: 'NETWORK_ERROR');
    }
    return super.getStatus(deviceId);
  }
}

/// Repository whose control command reports a STALE (older) device state when
/// it finally resolves — used to prove the late REST response can never
/// regress a newer Socket.IO-confirmed report.
class _StaleControlRepo extends _FakeRepo {
  _StaleControlRepo({super.gateControl = true});

  final DateTime staleAt =
      DateTime.now().subtract(const Duration(minutes: 5));

  @override
  Future<RelayStatusResult> control(
    String deviceId,
    int channel,
    String state, {
    String? opId,
    bool cloudDown = false,
  }) async {
    controlCalls++;
    if (gateControl) await releaseControl.future;
    // Always reports OFF with an OLD timestamp, regardless of the request.
    return RelayStatusResult(
      online: true,
      channels: {channel: ChannelReport('OFF', updatedAt: staleAt)},
      source: source,
      seq: 1,
    );
  }
}

Future<void> _pumpDevicesPage(
  WidgetTester tester, {
  required DeviceRepositoryService repo,
  io.Socket Function(String url, Map<String, dynamic> options)? socketFactory,
}) async {
  _mockSecureStorage(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: DevicesPage.test(
          onNavigateToTab: (_) {},
          testRepository: repo,
          testSocketFactory: socketFactory ?? (url, opts) => _FakeSocket(),
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

    // While the (gated) command is in flight the pill stays TURNING — the
    // confirmed-state label (FLOWING) must never appear before the report.
    expect(repo.controlCalls, 1);
    expect(find.text('TURNING…'), findsOneWidget);
    expect(find.text('FLOWING'), findsNothing,
        reason: 'the confirmed-state pill may only appear after a device report');

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

  testWidgets('LAN requires the cloud confirmed down; a local read alone keeps ONLINE',
      (tester) async {
    final repo = _FakeRepo(source: DeviceTransportSource.local);
    final socket = _ScriptableSocket();
    await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

    // Cloud reachability unknown → the safe cloud-first default keeps ONLINE,
    // even though the freshest result came over the LAN.
    expect(find.text('Online'), findsOneWidget,
        reason: 'a successful local read must not flip the badge to LAN by itself');
    expect(find.text('LAN'), findsNothing);

    // Only a CONFIRMED cloud outage + verified local device = LAN.
    socket.fireDisconnect();
    await tester.pump();
    await tester.tap(find.text('CHANNEL 1'));
    await tester.pumpAndSettle();

    expect(find.text('LAN'), findsOneWidget,
        reason: 'cloud confirmed down + verified LAN device = LAN');
    expect(find.text('Online'), findsNothing);

    await _unmount(tester);
  });

  testWidgets('unconfirmed taps keep the pill TURNING until a report lands',
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

  testWidgets('a tap flips the card optimistically; a fresh report supersedes it',
      (tester) async {
    final repo = _FakeRepo(gateControl: true);
    final socket = _ScriptableSocket();
    await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

    final colors = tester.element(find.text('CHANNEL 1')).steesColors;
    int leafDrops() => find
        .byIcon(Icons.water_drop)
        .evaluate()
        .where((e) => (e.widget as Icon).color == colors.leaf)
        .length;

    expect(find.text('DRY'), findsNWidgets(4));
    expect(leafDrops(), 0);

    await tester.tap(find.text('CHANNEL 1'));
    await tester.pump();

    // The tapped card flips ON immediately (optimistic) while the pill still
    // shows TURNING, so the UI is responsive without faking a confirmed state.
    expect(repo.controlCalls, 1);
    expect(find.text('TURNING…'), findsOneWidget);
    expect(leafDrops(), 1,
        reason: 'the requested state is shown before the device confirms');

    // A FRESH device report contradicting the optimistic flip (the device
    // stayed OFF) must overwrite it: back to the confirmed DRY state.
    socket.push('device_update', {
      'deviceId': _deviceId,
      'channel': 1,
      'state': 'OFF',
      'updatedAt': DateTime.now().toIso8601String(),
    });
    await tester.pump();

    expect(find.text('TURNING…'), findsNothing);
    expect(find.text('DRY'), findsNWidgets(4));
    expect(leafDrops(), 0,
        reason: 'a confirmed report supersedes the optimistic flip');

    // The late REST response re-confirms the requested state once released.
    repo.releaseControl.complete();
    await tester.pump();
    expect(repo.controlCalls, 1);
    expect(find.text('FLOWING'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('cloudDown passed to control tracks the socket cloud monitor',
      (tester) async {
    final repo = _FakeRepo();
    final socket = _ScriptableSocket();
    await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

    // Unknown (no socket event yet): the safe cloud-first default.
    await tester.tap(find.text('CHANNEL 1'));
    await tester.pump();
    expect(repo.lastCloudDown, isFalse,
        reason: 'unknown connectivity must keep cloud-first');

    // Confirmed disconnect → cloud known unreachable → local immediately.
    socket.fireDisconnect();
    await tester.pump();
    await tester.tap(find.text('CHANNEL 2'));
    await tester.pump();
    expect(repo.lastCloudDown, isTrue,
        reason: 'a confirmed disconnect must route local immediately');

    // Reconnect → cloud reachable again → cloud first.
    socket.fireConnect();
    await tester.pump();
    await tester.tap(find.text('CHANNEL 3'));
    await tester.pump();
    expect(repo.lastCloudDown, isFalse,
        reason: 'a connect must restore cloud-first');

    // Connect error → cloud unreachable → local immediately.
    socket.fireConnectError();
    await tester.pump();
    await tester.tap(find.text('CHANNEL 4'));
    await tester.pump();
    expect(repo.lastCloudDown, isTrue,
        reason: 'a connect error must route local immediately');

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
      final socket = _ScriptableSocket();

      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      // The cached list renders instead of the cloud error state.
      expect(find.text('Controller'), findsOneWidget);
      expect(find.textContaining('Could not load devices'), findsNothing);

      // The cloud API is provably down; confirm it via the socket cloud monitor
      // so the verified local status resolves to LAN.
      socket.fireConnectError();
      await tester.pump();

      // Local status resolved the device: LAN pill, reachable, no error snack.
      expect(find.text('LAN'), findsOneWidget);
      expect(find.text('Offline'), findsNothing);
      expect(find.text('Failed to fetch status'), findsNothing);

      await _unmount(tester);
    });

    testWidgets(
        'cloud down + cache present + no local device → SYNCING, not OFFLINE, '
        'after a single status failure (#11)', (tester) async {
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
      // A SINGLE failed status poll is weak evidence: the card must show
      // SYNCING (unknown), never a fabricated OFFLINE. Only the repeated
      // failure threshold (or LWT Offline) may mark it offline.
      expect(find.text('Offline'), findsNothing);
      expect(find.text('SYNCING'), findsWidgets);

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

  group('connectivity model (Phase 1)', () {
    testWidgets('socket disconnect does NOT mark the device OFFLINE',
        (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo();
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      expect(find.text('Online'), findsOneWidget);

      socket.fireDisconnect();
      await tester.pump();

      expect(find.text('Online'), findsOneWidget,
          reason: 'a Socket.IO transport drop is not device-offline evidence');
      expect(find.text('Offline'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('a single REST status failure leaves the card SYNCING, not OFFLINE',
        (tester) async {
      final repo = _StatusFailingRepo();
      await _pumpDevicesPage(tester, repo: repo);

      expect(find.text('Offline'), findsNothing,
          reason: 'one failed poll must not mark the device OFFLINE');
      expect(find.text('SYNCING'), findsWidgets);

      await _unmount(tester);
    });

    testWidgets('repeated consecutive status failures mark the device OFFLINE',
        (tester) async {
      final repo = _StatusFailingRepo();
      await _pumpDevicesPage(tester, repo: repo);

      // The first failure happened during initial load (SYNCING). Two more
      // 15s poll ticks cross the 3-failure threshold (strong evidence).
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();

      expect(find.text('Offline'), findsOneWidget,
          reason: '3 consecutive poll failures are strong offline evidence');

      await _unmount(tester);
    });

    testWidgets('explicit LWT Offline via device_status marks the device OFFLINE',
        (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo();
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      expect(find.text('Online'), findsOneWidget);

      socket.push('device_status', {'deviceId': _deviceId, 'online': false});
      await tester.pump();

      expect(find.text('Offline'), findsOneWidget,
          reason: 'LWT Offline is authoritative device-offline evidence');

      await _unmount(tester);
    });

    testWidgets('a positive device_status report restores ONLINE after LWT Offline',
        (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo();
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      socket.push('device_status', {'deviceId': _deviceId, 'online': false});
      await tester.pump();
      expect(find.text('Offline'), findsOneWidget);

      socket.push('device_status', {'deviceId': _deviceId, 'online': true});
      await tester.pump();

      expect(find.text('Online'), findsOneWidget,
          reason: 'a positive device report restores ONLINE');
      expect(find.text('Offline'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('a cloud device_status event cannot overwrite fresher local evidence',
        (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo(source: DeviceTransportSource.local);
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      // Confirm the cloud is unreachable so the verified local session is LAN.
      socket.fireConnectError();
      await tester.pump();
      expect(find.text('LAN'), findsOneWidget);

      // A cloud LWT-offline event lands while the local session is still fresh.
      socket.push('device_status', {'deviceId': _deviceId, 'online': false});
      await tester.pump();

      expect(find.text('LAN'), findsOneWidget,
          reason: 'fresher local evidence must never be overwritten by a stale '
              'cloud verdict');
      expect(find.text('Offline'), findsNothing);

      await _unmount(tester);
    });
  });

  group('Phase 4: evidence-based ONLINE / LAN / OFFLINE priority', () {
    testWidgets(
        'cloud reachable + recent cloud evidence + successful local poll '
        'keeps ONLINE', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo();
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      // Cloud connected and the device reported ONLINE via cloud.
      expect(find.text('Online'), findsOneWidget);
      socket.push('device_status', {'deviceId': _deviceId, 'online': true});
      await tester.pump();
      expect(find.text('Online'), findsOneWidget);

      // A background LOCAL status poll succeeds while the cloud is still up.
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();

      expect(find.text('Online'), findsOneWidget,
          reason: 'a successful local poll must NOT downgrade ONLINE when the '
              'cloud is reachable');
      expect(find.text('LAN'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('cloud confirmed down + local device success → LAN',
        (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo(source: DeviceTransportSource.local);
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      socket.fireConnectError();
      await tester.pump();
      await tester.tap(find.text('CHANNEL 1'));
      await tester.pumpAndSettle();

      expect(find.text('LAN'), findsOneWidget,
          reason: 'cloud confirmed down + verified local device = LAN');
      expect(find.text('Offline'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('cloud confirmed down + local failure + no evidence → OFFLINE '
        'after the repeated-failure threshold', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _StatusFailingRepo();
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      socket.fireConnectError();
      await tester.pump();
      // A single failure (during initial load) is not OFFLINE evidence.
      expect(find.text('Offline'), findsNothing);

      // Two more 15s poll ticks cross the 3-failure threshold.
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();

      expect(find.text('Offline'), findsOneWidget,
          reason: 'cloud confirmed down + no LAN + no valid evidence → OFFLINE');

      await _unmount(tester);
    });

    testWidgets('LAN + cloud reconnect + fresh device cloud evidence → ONLINE',
        (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo(source: DeviceTransportSource.local);
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      socket.fireConnectError();
      await tester.pump();
      expect(find.text('LAN'), findsOneWidget);

      // Cloud comes back and delivers fresh positive device evidence.
      socket.fireConnect();
      await tester.pump();
      socket.push('device_status', {'deviceId': _deviceId, 'online': true});
      await tester.pump();

      expect(find.text('Online'), findsOneWidget,
          reason: 'cloud reconnect + fresh device evidence → ONLINE');
      expect(find.text('LAN'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('a late local poll cannot downgrade ONLINE after newer cloud '
        'evidence', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo(source: DeviceTransportSource.local);
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      // Cloud evidence confirms ONLINE.
      socket.push('device_status', {'deviceId': _deviceId, 'online': true});
      await tester.pump();
      expect(find.text('Online'), findsOneWidget);

      // An older local poll resolves later; cloud is still reachable.
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();

      expect(find.text('Online'), findsOneWidget,
          reason: 'a late local result must not overwrite ONLINE evidence');
      expect(find.text('LAN'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('a successful cloud control keeps connectivity logically '
        'correct', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo();
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      await tester.tap(find.text('CHANNEL 1'));
      await tester.pumpAndSettle();

      expect(find.text('Online'), findsOneWidget,
          reason: 'cloud control success keeps ONLINE (cloud reachable)');
      expect(find.text('LAN'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('local control succeeds while cloud is confirmed down → LAN',
        (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo(source: DeviceTransportSource.local);
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      socket.fireConnectError();
      await tester.pump();
      await tester.tap(find.text('CHANNEL 2'));
      await tester.pumpAndSettle();

      expect(find.text('LAN'), findsOneWidget,
          reason: 'local command with cloud confirmed down = LAN');
      expect(find.text('Online'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('socket connected but no valid device evidence does NOT mark '
        'ONLINE', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _StatusFailingRepo();
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      // Socket (re)connects, but the device produced NO valid evidence.
      socket.fireConnect();
      await tester.pump();

      expect(find.text('Online'), findsNothing,
          reason: 'a connected socket alone is not per-device online evidence');
      expect(find.text('Offline'), findsNothing,
          reason: 'and a single poll failure is not offline evidence either');
      expect(find.text('SYNCING'), findsWidgets);

      await _unmount(tester);
    });

    testWidgets('a single transient failure keeps ONLINE when valid evidence '
        'exists', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FailOnceRepo();
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);
      expect(find.text('Online'), findsOneWidget);

      // The next background poll fails ONCE; fresh evidence still exists.
      repo.failNext = true;
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();

      expect(find.text('Online'), findsOneWidget,
          reason: 'one transient failure must not mark the device OFFLINE');
      expect(find.text('Offline'), findsNothing);

      await _unmount(tester);
    });
  });

  group('Phase 3: socket-confirmed report resolves pending before REST', () {
    testWidgets('a confirmed device_update resolves TURNING… immediately',
        (tester) async {
      final repo = _FakeRepo(gateControl: true);
      final socket = _ScriptableSocket();
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      expect(find.text('DRY'), findsNWidgets(4));

      await tester.tap(find.text('CHANNEL 1'));
      await tester.pump();
      expect(find.text('TURNING…'), findsOneWidget);
      expect(repo.controlCalls, 1);

      // The device confirms ON over Socket.IO while the REST command is still
      // in flight (gated). The pill must resolve immediately.
      socket.push('device_update', {
        'deviceId': _deviceId,
        'channel': 1,
        'state': 'ON',
        'updatedAt': DateTime.now().toIso8601String(),
      });
      await tester.pump();

      expect(find.text('TURNING…'), findsNothing,
          reason: 'a confirmed device report must resolve the pending tap');
      expect(find.text('FLOWING'), findsOneWidget);
      expect(find.text('DRY'), findsNWidgets(3));

      // The later REST response completes the lifecycle WITHOUT a second
      // command and without re-enabling pending.
      repo.releaseControl.complete();
      await tester.pump();
      expect(repo.controlCalls, 1);
      expect(find.text('TURNING…'), findsNothing);
      expect(find.text('FLOWING'), findsOneWidget);

      await _unmount(tester);
    });

    testWidgets('only a strictly-newer socket report may commit or flip state',
        (tester) async {
      final repo = _FakeRepo(gateControl: true);
      final socket = _ScriptableSocket();
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      await tester.tap(find.text('CHANNEL 1'));
      await tester.pump();
      expect(find.text('TURNING…'), findsOneWidget);

      // Fresh report: commits ON, resolves the pending tap.
      socket.push('device_update', {
        'deviceId': _deviceId,
        'channel': 1,
        'state': 'ON',
        'updatedAt': DateTime.now().toIso8601String(),
      });
      await tester.pump();
      expect(find.text('TURNING…'), findsNothing);
      expect(find.text('FLOWING'), findsOneWidget);

      // A STALE report (older than the confirmed ON) must neither commit nor
      // flip the channel back — only strictly-newer reports may.
      socket.push('device_update', {
        'deviceId': _deviceId,
        'channel': 1,
        'state': 'OFF',
        'updatedAt': DateTime.now()
            .subtract(const Duration(minutes: 10))
            .toIso8601String(),
      });
      await tester.pump();

      expect(find.text('FLOWING'), findsOneWidget,
          reason: 'a stale report must never regress the newer confirmed state');
      // Channels 2-4 were never touched and remain DRY.
      expect(find.text('DRY'), findsNWidgets(3));

      repo.releaseControl.complete();
      await tester.pump();
      expect(repo.controlCalls, 1);
      expect(find.text('FLOWING'), findsOneWidget);

      await _unmount(tester);
    });

    testWidgets('a late REST response cannot regress the newer socket-confirmed state',
        (tester) async {
      final repo = _StaleControlRepo(gateControl: true);
      final socket = _ScriptableSocket();
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      await tester.tap(find.text('CHANNEL 1'));
      await tester.pump();
      expect(find.text('TURNING…'), findsOneWidget);

      // Socket confirms ON (newer).
      socket.push('device_update', {
        'deviceId': _deviceId,
        'channel': 1,
        'state': 'ON',
        'updatedAt': DateTime.now().toIso8601String(),
      });
      await tester.pump();
      expect(find.text('FLOWING'), findsOneWidget);

      // The REST response lands late and reports OFF with an OLDER timestamp.
      // The staleness guard must keep the socket-confirmed ON.
      repo.releaseControl.complete();
      await tester.pump();

      expect(find.text('FLOWING'), findsOneWidget,
          reason: 'a stale REST report must never regress the newer confirmed state');
      expect(find.text('DRY'), findsNWidgets(3));
      expect(repo.controlCalls, 1);

      await _unmount(tester);
    });

    testWidgets('a tap after socket confirmation does not spawn a second command '
        'while REST is in flight', (tester) async {
      final repo = _FakeRepo(gateControl: true);
      final socket = _ScriptableSocket();
      await _pumpDevicesPage(tester, repo: repo, socketFactory: (u, o) => socket);

      await tester.tap(find.text('CHANNEL 1'));
      await tester.pump();
      expect(repo.controlCalls, 1);

      // Socket confirms ON: pending clears but the single-flight guard stays
      // until the REST lifecycle completes.
      socket.push('device_update', {
        'deviceId': _deviceId,
        'channel': 1,
        'state': 'ON',
        'updatedAt': DateTime.now().toIso8601String(),
      });
      await tester.pump();
      expect(find.text('TURNING…'), findsNothing);
      expect(find.text('FLOWING'), findsOneWidget);

      // Second tap during the still-in-flight REST must be ignored.
      await tester.tap(find.text('CHANNEL 1'));
      await tester.pump();
      expect(repo.controlCalls, 1,
          reason: 'exactly one command per tap: the guard persists until REST finishes');

      repo.releaseControl.complete();
      await tester.pump();
      expect(repo.controlCalls, 1);

      await _unmount(tester);
    });
  });
}

