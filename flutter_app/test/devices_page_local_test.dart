import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:smart_home_app/screens/devices_page.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/channel_state_machine.dart';
import 'package:smart_home_app/services/cloud_device_transport.dart';
import 'package:smart_home_app/services/device_repository_service.dart';
import 'package:smart_home_app/services/device_transport.dart';
import 'package:smart_home_app/services/local_device_cache.dart';
import 'package:smart_home_app/services/local_device_discovery.dart';
import 'package:smart_home_app/services/reachability_monitor.dart';
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
  Future<List<dynamic>> getDevices() async => throw const ApiException(
    'Could not reach the server',
    code: 'NETWORK_ERROR',
  );

  @override
  Future<Map<String, dynamic>> getStatus(String deviceId) async =>
      throw const ApiException(
        'Could not reach the server',
        code: 'NETWORK_ERROR',
      );

  @override
  Future<Map<String, dynamic>> control(
    String deviceId,
    int channel,
    String state, {
    String? opId,
  }) async => throw const ApiException(
    'Could not reach the server',
    code: 'NETWORK_ERROR',
  );
}

/// Local Tasmota fetcher stub for widget-level Local Mode tests.
/// Cloud that is available and answers the device list + status normally —
/// used to prove the cold-start progressive render also reconciles ONLINE when
/// the backend is reachable.
class _CloudApi extends ApiService {
  _CloudApi({this.devices = const []});
  final List<Map<String, dynamic>> devices;

  @override
  Future<List<dynamic>> getDevices() async => devices;

  @override
  Future<Map<String, dynamic>> getStatus(String deviceId) async => {
    'online': true,
    'channels': {'1': 'OFF', '2': 'OFF', '3': 'OFF', '4': 'OFF'},
  };

  @override
  Future<Map<String, dynamic>> control(
    String deviceId,
    int channel,
    String state, {
    String? opId,
  }) async => {
    'online': true,
    'channels': {channel: state},
  };
}

/// Cloud whose device list NEVER completes — models the slow/absent backend
/// that used to hold the whole page on the loading spinner until the 15s API
/// timeout. The cold-start fix must render from the local cache regardless.
class _HangingCloudApi extends ApiService {
  @override
  Future<List<dynamic>> getDevices() => Completer<List<dynamic>>().future;

  @override
  Future<Map<String, dynamic>> getStatus(String deviceId) =>
      Completer<Map<String, dynamic>>().future;

  @override
  Future<Map<String, dynamic>> control(
    String deviceId,
    int channel,
    String state, {
    String? opId,
  }) async =>
      throw const ApiException('Cloud unavailable', code: 'NETWORK_ERROR');
}

class _CmFake {
  _CmFake({this.responses = const {}});
  final Map<String, String> responses;

  Future<String> call(
    String address,
    String command, {
    String? password,
    String? deviceId,
    String? referer,
  }) async {
    final body = responses[command];
    if (body == null) throw const DeviceTransportException('HTTP 404');
    return body;
  }
}

/// Discovery stub for widget-level Local Mode tests: a verified cached IP, no.
/// Records mDNS / discard / store calls and can serve mDNS candidates so tests
/// can prove the fast known-IP path avoids mDNS and the fallback uses it.
class _LocatorStub implements DeviceLocator {
  _LocatorStub({this.cached, this.verifiedAt, this.mDnsAddresses = const []});
  String? cached;
  DateTime? verifiedAt;
  final List<String> mDnsAddresses;
  int mDnsCalls = 0;
  final List<String> discarded = [];
  final List<String> storedVerified = [];

  @override
  Future<String?> cachedAddress(String deviceId) async => cached;

  @override
  Future<DateTime?> cachedVerifiedAt(String deviceId) async => verifiedAt;

  @override
  Future<void> storeVerifiedAddress(String deviceId, String ip) async {
    storedVerified.add(ip);
  }

  @override
  Future<void> storeCandidateAddress(String deviceId, String ip) async {}

  @override
  Future<void> discardAddress(String deviceId) async {
    discarded.add(deviceId);
    cached = null;
    verifiedAt = null;
  }

  @override
  Future<List<String>> mDnsCandidates(Duration timeout) async {
    mDnsCalls++;
    return mDnsAddresses;
  }
}

/// Tasmota fetcher that records every command (so tests can count `Status 5`
/// calls and prove no duplicate identity verification, no mDNS, and that a
/// foreign device is never controlled) and dispatches per-address responses.
class _RecordingCmFake {
  _RecordingCmFake(this.responsesByAddress);
  final Map<String, Map<String, String>> responsesByAddress;
  final List<String> log = [];

  bool get hasControlCommand => log.any((entry) => entry.contains('Power'));

  int get status5Count =>
      log.where((entry) => entry.contains('Status%205')).length;

  Future<String> call(
    String address,
    String command, {
    String? password,
    String? deviceId,
    String? referer,
  }) async {
    log.add('$address $command');
    final body = responsesByAddress[address]?[command];
    if (body == null) throw const DeviceTransportException('HTTP 404');
    return body;
  }
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
  DeviceTransportSource source;
  final List<Map<String, dynamic>> devices;
  final Completer<void> releaseControl = Completer<void>();
  int controlCalls = 0;
  int statusCalls = 0;
  bool sameWifi = false;
  int sameWifiProbes = 0;
  ControlRoute? lastRoute;

  @override
  Future<void> warmUp(List<Map<String, dynamic>> devices) async {
    // Discovery warm-up is a real-network path; the fake repo must not run it
    // (it would open mDNS browsers and hold fake-time timers in widget tests).
  }

  @override
  Future<List<Map<String, dynamic>>> getDevices() async => devices;

  @override
  Future<bool> isDeviceOnSameNetwork(String deviceId) async {
    sameWifiProbes++;
    return sameWifi;
  }

  @override
  Future<RelayStatusResult> control(
    String deviceId,
    int channel,
    String state, {
    String? opId,
    ControlRoute route = ControlRoute.cloudOnly,
  }) async {
    controlCalls++;
    lastRoute = route;
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
  Future<RelayStatusResult> getStatus(
    String deviceId, {
    bool cloudDown = false,
  }) async {
    statusCalls++;
    return RelayStatusResult(
      online: true,
      channels: {for (var i = 1; i <= 4; i++) i: const ChannelReport('OFF')},
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
  Future<RelayStatusResult> getStatus(
    String deviceId, {
    bool cloudDown = false,
  }) async {
    throw const ApiException(
      'Could not reach the server',
      code: 'NETWORK_ERROR',
    );
  }
}

/// Repository that succeeds until [failNext] is set, then throws ONCE before
/// succeeding again — models a transient status failure with valid device
/// evidence already present.
class _FailOnceRepo extends _FakeRepo {
  bool failNext = false;

  @override
  Future<RelayStatusResult> getStatus(
    String deviceId, {
    bool cloudDown = false,
  }) async {
    if (failNext) {
      failNext = false;
      throw const ApiException(
        'Could not reach the server',
        code: 'NETWORK_ERROR',
      );
    }
    return super.getStatus(deviceId);
  }
}

/// Repository whose NEXT status read returns a successful CLOUD poll that
/// still reports the device OFFLINE (`online:false`) — the stale / contradicted
/// verdict that previously caused ONLINE↔OFFLINE flapping. All other reads
/// behave like [_FakeRepo].
class _CloudOfflineRepo extends _FakeRepo {
  bool nextOffline = false;

  @override
  Future<RelayStatusResult> getStatus(
    String deviceId, {
    bool cloudDown = false,
  }) async {
    if (nextOffline) {
      nextOffline = false;
      statusCalls++;
      return RelayStatusResult(
        online: false,
        channels: {for (var i = 1; i <= 4; i++) i: const ChannelReport('OFF')},
        source: DeviceTransportSource.cloud,
        seq: 2,
      );
    }
    return super.getStatus(deviceId);
  }
}

/// Repository whose FIRST status read runs over the CLOUD (so no fresh local
/// evidence exists) and whose later reads return verified LOCAL evidence —
/// models the "UI stays ONLINE after a cloud drop until a LAN read happens"
/// delay that the disconnect probe eliminates.
class _CloudThenLocalRepo extends _FakeRepo {
  @override
  Future<RelayStatusResult> getStatus(
    String deviceId, {
    bool cloudDown = false,
  }) async {
    statusCalls++;
    final viaLocal = statusCalls > 1;
    return RelayStatusResult(
      online: true,
      channels: {for (var i = 1; i <= 4; i++) i: const ChannelReport('OFF')},
      source: viaLocal
          ? DeviceTransportSource.local
          : DeviceTransportSource.cloud,
      seq: 2,
    );
  }
}

/// Repository whose status reads can be held in flight (and are counted), so a
/// test can prove the disconnect probe reuses an in-flight status read instead
/// of spawning a duplicate.
class _GatedStatusRepo extends _FakeRepo {
  _GatedStatusRepo({super.source});
  final Completer<void> releaseStatus = Completer<void>();

  @override
  Future<RelayStatusResult> getStatus(
    String deviceId, {
    bool cloudDown = false,
  }) async {
    statusCalls++;
    await releaseStatus.future;
    return super.getStatus(deviceId);
  }
}

/// Repository whose control command reports a STALE (older) device state when
/// it finally resolves — used to prove the late REST response can never
/// regress a newer Socket.IO-confirmed report.
class _StaleControlRepo extends _FakeRepo {
  _StaleControlRepo({super.gateControl = true});

  final DateTime staleAt = DateTime.now().subtract(const Duration(minutes: 5));

  @override
  Future<RelayStatusResult> control(
    String deviceId,
    int channel,
    String state, {
    String? opId,
    ControlRoute route = ControlRoute.cloudOnly,
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
  Future<bool> Function()? healthCheck,
  ReachabilityMonitor? monitor,
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
          // Healthy cloud by default so the fast reachability probe never
          // disturbs existing tests; fast-failure tests inject their own probe.
          testHealthCheck: healthCheck ?? () async => true,
          testMonitor: monitor,
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
  await tester.pump(); // Ensure dispose() runs and cancels timers
}

void main() {
  testWidgets('relay taps drive the repository and confirm via device report', (
    tester,
  ) async {
    final repo = _FakeRepo(gateControl: true);
    await _pumpDevicesPage(tester, repo: repo);

    // Initial confirmed status: all four relays reported OFF.
    expect(find.text('DRY'), findsNWidgets(4));

    // Card rendered and the relay tap routes through the repository.
    expect(find.text('CHANNEL 1'), findsOneWidget);
    await tester.tap(find.text('CHANNEL 1'));
    await tester.pump();

    // TURNING ON appears immediately after the tap (no 200ms delay).
    // The optimistic flip happens instantly.
    expect(repo.controlCalls, 1);
    expect(find.text('TURNING ON…'), findsOneWidget);
    expect(
      find.text('FLOWING'),
      findsNothing,
      reason: 'the confirmed-state pill may only appear after a device report',
    );

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

  testWidgets('double-tap while a relay command is in flight sends it once', (
    tester,
  ) async {
    final repo = _FakeRepo(gateControl: true);
    await _pumpDevicesPage(tester, repo: repo);

    await tester.tap(find.text('CHANNEL 1'));
    await tester.pump();
    // With the delayed pending indicator, TURNING doesn't appear immediately.
    // The second tap lands while the first command is still pending.
    // The _pendingRelays guard + loading state must block it.
    await tester.tap(find.text('CHANNEL 1'));
    await tester.pump();

    expect(
      repo.controlCalls,
      1,
      reason: 'a pending relay must not be re-sent on a second tap',
    );

    await _unmount(tester);
  });

  testWidgets(
    'a local read alone confirms same-WiFi → badge LAN, no cloud outage needed',
    (tester) async {
      final repo = _FakeRepo(source: DeviceTransportSource.local);
      final socket = _ScriptableSocket();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      // The initial status read resolved over the LAN: the monitor confirms the
      // device is on the same network, so routing is local and the badge shows
      // LAN immediately — regardless of the cloud socket. Badge and reality
      // agree (this is the fix for the old ONLINE-while-local lie).
      expect(
        find.text('LAN'),
        findsOneWidget,
        reason: 'same-WiFi routing must render LAN even with the cloud up',
      );
      expect(find.text('Online'), findsNothing);

      // A confirmed cloud outage keeps the same-WiFi verdict → LAN stays.
      socket.fireDisconnect();
      await tester.pump();
      expect(find.text('LAN'), findsOneWidget);
      expect(find.text('Online'), findsNothing);

      await _unmount(tester);
    },
  );

  testWidgets('unconfirmed taps keep the pill TURNING until a report lands', (
    tester,
  ) async {
    final repo = _FakeRepo(gateControl: true);
    await _pumpDevicesPage(tester, repo: repo);

    // Device reports OFF initially.
    expect(find.text('DRY'), findsNWidgets(4));

    await tester.tap(find.text('CHANNEL 2'));
    await tester.pump();

    // TURNING ON appears immediately after the tap (no 200ms delay).
    // The optimistic flip happens instantly (tapping DRY → ON).
    expect(find.text('TURNING ON…'), findsOneWidget);
    expect(find.text('FLOWING'), findsNothing);

    // A failure clears the intent and degrades to UNKNOWN, never a fake OFF.
    repo.releaseControl.completeError(Exception('nope'));
    await tester.pumpAndSettle();

    expect(find.text('TURNING ON…'), findsNothing);
    expect(
      find.textContaining('nope'),
      findsWidgets,
      reason: 'the failure is surfaced to the user',
    );
    await _unmount(tester);
  });

  testWidgets(
    'a tap flips the card optimistically; a fresh report supersedes it',
    (tester) async {
      final repo = _FakeRepo(gateControl: true);
      final socket = _ScriptableSocket();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

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

      // The tapped card flips ON immediately (optimistic). The TURNING ON… pill
      // appears immediately after the tap (no 200ms delay).
      expect(repo.controlCalls, 1);
      expect(find.text('TURNING ON…'), findsOneWidget);
      expect(
        leafDrops(),
        2,
        reason: 'the requested state is shown before the device confirms (main icon + toggle icon)',
      );

      // A FRESH device report contradicting the optimistic flip (the device
      // stayed OFF) must overwrite it: back to the confirmed DRY state.
      socket.push('device_update', {
        'deviceId': _deviceId,
        'channel': 1,
        'state': 'OFF',
        'updatedAt': DateTime.now().toIso8601String(),
      });
      await tester.pump();

      expect(find.text('TURNING ON…'), findsNothing);
      expect(find.text('DRY'), findsNWidgets(4));
      expect(
        leafDrops(),
        0,
        reason: 'a confirmed report supersedes the optimistic flip',
      );

      // The late REST response re-confirms the requested state once released.
      repo.releaseControl.complete();
      await tester.pump();
      expect(repo.controlCalls, 1);
      expect(find.text('FLOWING'), findsOneWidget);

      await _unmount(tester);
    },
  );

  testWidgets('route passed to control follows the live reachability state', (
    tester,
  ) async {
    final repo = _FakeRepo();
    final socket = _ScriptableSocket();
    final monitor = ReachabilityMonitor(repo);
    await _pumpDevicesPage(
      tester,
      repo: repo,
      socketFactory: (u, o) => socket,
      monitor: monitor,
    );

    // Unknown / no local evidence: the safe cloud default.
    await tester.tap(find.text('CHANNEL 1'));
    await tester.pump();
    expect(
      repo.lastRoute,
      ControlRoute.cloudOnly,
      reason: 'ambiguous/unknown reachability must default to cloud-only',
    );

    // The background monitor confirms same WiFi → the tap is local-only with
    // ZERO probe latency (no fresh probe at tap time).
    repo.sameWifiProbes = 0;
    monitor.state.value = monitor.state.value.copyWith(sameWifi: true);
    await tester.tap(find.text('CHANNEL 2'));
    await tester.pump();
    expect(repo.lastRoute, ControlRoute.localOnly);
    expect(
      repo.sameWifiProbes,
      0,
      reason: 'the tap reads the live state; it must not start a fresh probe',
    );

    // The monitor confirms a different network → cloud-only again.
    monitor.state.value = monitor.state.value.copyWith(sameWifi: false);
    await tester.tap(find.text('CHANNEL 3'));
    await tester.pump();
    expect(repo.lastRoute, ControlRoute.cloudOnly);

    await _unmount(tester);
  });

  testWidgets('same-WiFi tap is dispatched local-only (no cloud round-trip)',
      (tester) async {
    final repo = _FakeRepo(source: DeviceTransportSource.local);
    final socket = _ScriptableSocket();
    final monitor = ReachabilityMonitor(repo);
    await _pumpDevicesPage(
      tester,
      repo: repo,
      socketFactory: (u, o) => socket,
      monitor: monitor,
    );

    // The background monitor confirmed the device is on the same network.
    monitor.state.value = monitor.state.value.copyWith(sameWifi: true);
    await tester.tap(find.text('CHANNEL 1'));
    await tester.pump();

    expect(repo.lastRoute, ControlRoute.localOnly,
        reason: 'a same-WiFi tap must be dispatched local-only');
    expect(repo.controlCalls, 1);

    // The fake's LOCAL-source result confirms: the command was confirmed by the
    // device over LAN, never over the cloud.
    expect(find.text('FLOWING'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('different-network tap is dispatched cloud-only (no LAN attempt)',
      (tester) async {
    final repo = _FakeRepo(source: DeviceTransportSource.cloud);
    final socket = _ScriptableSocket();
    final monitor = ReachabilityMonitor(repo);
    await _pumpDevicesPage(
      tester,
      repo: repo,
      socketFactory: (u, o) => socket,
      monitor: monitor,
    );

    // Background state: different network + cloud socket connected.
    monitor.state.value = monitor.state.value.copyWith(sameWifi: false);
    await tester.tap(find.text('CHANNEL 1'));
    await tester.pump();

    expect(repo.lastRoute, ControlRoute.cloudOnly,
        reason: 'a different-network tap must be dispatched cloud-only');
    expect(repo.controlCalls, 1);

    await _unmount(tester);
  });

  group('background reachability monitor (continuous routing state)', () {
    testWidgets(
      'network-change events trigger exactly one debounced re-probe (no burst)',
      (tester) async {
        final repo = _FakeRepo();
        final socket = _ScriptableSocket();
        final monitor = ReachabilityMonitor(repo);
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
          monitor: monitor,
        );

        repo.sameWifiProbes = 0;
        // A real network transition fires several OS events in a burst: the
        // debounce must collapse them into ONE probe after the transition
        // settles, never one per event.
        monitor.notifyNetworkChanged(_deviceId);
        monitor.notifyNetworkChanged(_deviceId);
        monitor.notifyNetworkChanged(_deviceId);
        await tester.pump(const Duration(milliseconds: 100));
        expect(repo.sameWifiProbes, 0,
            reason: 'still inside the settle window — no probe yet');
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          repo.sameWifiProbes,
          1,
          reason: 'the trailing edge of the burst fires exactly one probe',
        );
        await tester.pump(const Duration(seconds: 1));
        expect(
          repo.sameWifiProbes,
          1,
          reason: 'no second probe fires after the debounced one',
        );

        await _unmount(tester);
      },
    );

    testWidgets(
      'same-WiFi + cloud up → LAN badge: the badge follows the routing mode, '
      'not the cloud socket (Issue 1)',
      (tester) async {
        // First status read is cloud-sourced (device not yet confirmed on the
        // LAN) → starts ONLINE; later reads resolve local (same-WiFi).
        final repo = _CloudThenLocalRepo();
        final socket = _ScriptableSocket();
        final monitor = ReachabilityMonitor(repo);
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
          monitor: monitor,
        );
        expect(find.text('Online'), findsOneWidget);

        // The background monitor confirms same-WiFi while the cloud socket stays
        // UP: routing flips to local (routingPolicy sameWifi-first) and the
        // badge must show LAN — no cloud outage is required. Badge and reality
        // agree; the old ONLINE-while-local lie is gone.
        monitor.state.value = monitor.state.value.copyWith(sameWifi: true);
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('LAN'), findsOneWidget);
        expect(find.text('Online'), findsNothing);

        // A socket drop keeps the same-WiFi verdict → LAN stays (the probe
        // read resolves local again).
        socket.fireDisconnect();
        await tester.pump();
        await tester.pump();
        expect(find.text('LAN'), findsOneWidget);
        expect(find.text('Online'), findsNothing);

        await _unmount(tester);
      },
    );

    testWidgets(
      'rapid ReachabilityState writes inside the settle window produce ONE '
      'badge update, not a flicker per write (Issue 2)',
      (tester) async {
        final repo = _FakeRepo(); // cloud source: starts ONLINE
        final socket = _ScriptableSocket();
        final monitor = ReachabilityMonitor(repo);
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
          monitor: monitor,
        );
        expect(find.text('Online'), findsOneWidget);

        // Simulate the Online→LAN transition burst from the trace: socket drop
        // (S2) → local-status result (S4) → socket reconnect (S1) → debounced
        // probe (S5), all landing within kBadgeSettleDelay.
        monitor.state.value =
            monitor.state.value.copyWith(cloudSocketReady: false); // S2
        await tester.pump(const Duration(milliseconds: 100));
        monitor.state.value = monitor.state.value
            .copyWith(sameWifi: true, cloudSocketReady: false); // S4
        await tester.pump(const Duration(milliseconds: 100));
        monitor.state.value =
            monitor.state.value.copyWith(cloudSocketReady: true); // S1
        await tester.pump(const Duration(milliseconds: 100));
        monitor.state.value =
            monitor.state.value.copyWith(sameWifi: true); // S5
        await tester.pump(const Duration(milliseconds: 100));

        // No intermediate write rendered: the badge is debounced.
        expect(
          find.text('Online'),
          findsOneWidget,
          reason: 'mid-transition writes must not flicker the badge',
        );
        expect(find.text('LAN'), findsNothing);

        // After the settle window the final same-WiFi verdict renders ONCE.
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('LAN'), findsOneWidget);
        expect(find.text('Online'), findsNothing);

        await _unmount(tester);
      },
    );

    testWidgets(
      'a same-WiFi badge stays LAN when the cloud socket drops — no tap '
      'required',
      (tester) async {
        final repo = _FakeRepo(source: DeviceTransportSource.local);
        final socket = _ScriptableSocket();
        final monitor = ReachabilityMonitor(repo);
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
          monitor: monitor,
        );

        // The local status read confirmed same-WiFi: LAN immediately.
        expect(find.text('LAN'), findsOneWidget);
        expect(find.text('Online'), findsNothing);

        // The socket drops (cloud outage): the same background state keeps the
        // badge on LAN — no toggle tap, no status poll needed.
        socket.fireDisconnect();
        await tester.pump();
        expect(find.text('LAN'), findsOneWidget);
        expect(find.text('Online'), findsNothing);

        await _unmount(tester);
      },
    );

    testWidgets(
      'tap during a genuine transition still succeeds via the single fallback '
      '(stale same-WiFi verdict → LAN fails → cloud completes)',
      (tester) async {
        final repo = _FakeRepo(source: DeviceTransportSource.cloud);
        final socket = _ScriptableSocket();
        final monitor = ReachabilityMonitor(repo);
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
          monitor: monitor,
        );

        // Let the initial status fetch resolve so the tap toggles from the
        // confirmed OFF baseline (otherwise its late all-OFF result would
        // overwrite the REST-confirmed ON).
        await tester.pumpAndSettle();

        // The background monitor still says same-WiFi (stale during the
        // transition), so the tap routes local-only even though the command
        // will complete over the cloud via the repository's internal fallback.
        monitor.state.value = monitor.state.value.copyWith(sameWifi: true);
        await tester.tap(find.text('CHANNEL 1'));
        // Single pump (not pumpAndSettle): the ripple animates forever, so
        // settle would advance fake time into the 15s status poll and its
        // all-OFF result would overwrite the REST-confirmed ON.
        await tester.pump();
        await tester.pump();

        // The repository's bounded fallback completed the command (cloud
        // result) even though the tap was routed local-only from stale state:
        // the card confirms and no hard error is surfaced.
        expect(repo.lastRoute, ControlRoute.localOnly);
        expect(repo.source, DeviceTransportSource.cloud);
        expect(find.text('FLOWING'), findsOneWidget);
        expect(find.textContaining('not be reached'), findsNothing);

        await _unmount(tester);
      },
    );

    testWidgets(
      'status reads feed the monitor so the tap route stays fresh with no '
      'extra probes',
      (tester) async {
        final repo = _FakeRepo(source: DeviceTransportSource.cloud);
        final socket = _ScriptableSocket();
        final monitor = ReachabilityMonitor(repo);
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
          monitor: monitor,
        );

        // The initial status read resolved via the cloud: the monitor now knows
        // the device is not on the local network, with no dedicated probe.
        expect(monitor.state.value.sameWifi, isFalse);
        expect(monitor.state.value.isUnknown, isFalse);

        // A later local read (device reconnected to the same WiFi) updates the
        // routing state passively: the next tap is local-only.
        repo.source = DeviceTransportSource.local;
        socket.fireConnect(); // reconnect path triggers a fresh status read
        await tester.pump();
        await tester.pump();
        expect(monitor.state.value.sameWifi, isTrue);
        await tester.tap(find.text('CHANNEL 1'));
        await tester.pump();
        expect(repo.lastRoute, ControlRoute.localOnly);

        await _unmount(tester);
      },
    );
  });

  group('ReachabilityMonitor hysteresis (sameWifi downgrade confirmation)', () {
    test(
      'a single transient cloud-sourced read never downgrades a confirmed '
      'same-WiFi verdict — the sticky window absorbs it',
      () {
        final repo = _FakeRepo();
        final monitor = ReachabilityMonitor(repo);
        var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
        monitor.now = () => fakeNow;

        // Device confirmed on the same network (local status read).
        monitor.noteStatusResult(_deviceId, DeviceTransportSource.local);
        expect(monitor.state.value.sameWifi, isTrue);

        // One transient cloud fallback (e.g. a single 15s poll that lost the
        // local HTTP round-trip) inside kDowngradeStickyWindow (10s).
        fakeNow = fakeNow.add(const Duration(seconds: 5));
        monitor.noteStatusResult(_deviceId, DeviceTransportSource.cloud);
        expect(
          monitor.state.value.sameWifi,
          isTrue,
          reason: 'a single cloud-sourced read must not downgrade the verdict',
        );

        monitor.dispose();
      },
    );

    test(
      'a downgrade needs 2 consecutive cloud-sourced reads AFTER the sticky '
      'window; a local read resets the counter and restores LAN instantly',
      () {
        final repo = _FakeRepo();
        final monitor = ReachabilityMonitor(repo);
        var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
        monitor.now = () => fakeNow;

        monitor.noteStatusResult(_deviceId, DeviceTransportSource.local);
        expect(monitor.state.value.sameWifi, isTrue);

        // Sticky window expires; the next cloud read only starts counting.
        fakeNow = fakeNow.add(kDowngradeStickyWindow + const Duration(seconds: 1));
        monitor.noteStatusResult(_deviceId, DeviceTransportSource.cloud);
        expect(
          monitor.state.value.sameWifi,
          isTrue,
          reason: 'one cloud read after the sticky window is not enough',
        );

        // Second consecutive cloud read (no local confirmation in between).
        fakeNow = fakeNow.add(const Duration(seconds: 15));
        monitor.noteStatusResult(_deviceId, DeviceTransportSource.cloud);
        expect(
          monitor.state.value.sameWifi,
          isFalse,
          reason: '2 consecutive cloud reads with no local confirmation '
              'confirm the downgrade',
        );

        // A local read immediately restores same-WiFi and resets the counter.
        fakeNow = fakeNow.add(const Duration(seconds: 15));
        monitor.noteStatusResult(_deviceId, DeviceTransportSource.local);
        expect(monitor.state.value.sameWifi, isTrue);

        // After the reset, one stray cloud read again cannot downgrade.
        fakeNow = fakeNow.add(kDowngradeStickyWindow + const Duration(seconds: 1));
        monitor.noteStatusResult(_deviceId, DeviceTransportSource.cloud);
        expect(
          monitor.state.value.sameWifi,
          isTrue,
          reason: 'a reset counter needs 2 consecutive cloud reads again',
        );

        monitor.dispose();
      },
    );

    testWidgets(
      'a failed fast probe is subject to the same downgrade hysteresis '
      '(probe path)',
      (tester) async {
        final repo = _FakeRepo();
        final monitor = ReachabilityMonitor(repo);
        var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
        monitor.now = () => fakeNow;

        monitor.noteStatusResult(_deviceId, DeviceTransportSource.local);
        expect(monitor.state.value.sameWifi, isTrue);

        // One failed probe (debounced 400ms after the network event) is a
        // transient miss → no downgrade.
        repo.sameWifi = false;
        monitor.notifyNetworkChanged(_deviceId);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(
          monitor.state.value.sameWifi,
          isTrue,
          reason: 'a single failed fast probe must not downgrade the verdict',
        );

        // After the sticky window, one more failed probe only starts counting.
        fakeNow = fakeNow.add(kDowngradeStickyWindow + const Duration(seconds: 1));
        monitor.notifyNetworkChanged(_deviceId);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(
          monitor.state.value.sameWifi,
          isTrue,
          reason: 'one failed probe after the sticky window is not enough',
        );

        // A second consecutive failed probe (still no local confirmation)
        // confirms the downgrade.
        fakeNow = fakeNow.add(const Duration(seconds: 15));
        monitor.notifyNetworkChanged(_deviceId);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(
          monitor.state.value.sameWifi,
          isFalse,
          reason: '2 consecutive failed probes with no local confirmation '
              'confirm the downgrade',
        );

        monitor.dispose();
      },
    );

    test(
      'no-op writes do not fire the ValueNotifier listener (value equality)',
      () {
        final repo = _FakeRepo();
        final monitor = ReachabilityMonitor(repo);
        var fires = 0;
        monitor.state.addListener(() => fires++);

        monitor.setCloudSocketReady(false); // real change true→false
        expect(fires, 1);
        monitor.setCloudSocketReady(false); // no-op → must NOT notify
        expect(
          fires,
          1,
          reason: 'identical field values must not fire the listener',
        );

        // The first negative read on an UNKNOWN state stamps it as a known
        // cloud verdict (isUnknown flips) → notifies once.
        monitor.noteStatusResult(_deviceId, DeviceTransportSource.cloud);
        expect(fires, 2);
        // A repeat negative read on an already-false verdict changes nothing →
        // no notify (the badge listener is not re-armed by meaningless writes).
        monitor.noteStatusResult(_deviceId, DeviceTransportSource.cloud);
        expect(
          fires,
          2,
          reason: 'a negative signal that changes no field must not notify',
        );

        // A real upgrade notifies.
        monitor.noteStatusResult(_deviceId, DeviceTransportSource.local);
        expect(fires, 3);

        monitor.state.dispose();
      },
    );
  });

  group('cloud-unavailable device list', () {
    testWidgets(
      'cached device renders and LAN status succeeds — no red error (#10)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final cache = LocalDeviceCache();
        await cache.upsert({
          'deviceId': _deviceId,
          'name': 'Controller',
          'channels': 4,
        });
        final cm = _CmFake(
          responses: {'Status%205': _macBody, 'State': _stateBody},
        );
        final repo = DeviceRepositoryService(
          cloud: CloudDeviceTransport(api: _CloudDownApi()),
          locator: _LocatorStub(cached: '192.168.1.5'),
          fetch: cm.call,
          cache: cache,
        );
        final socket = _ScriptableSocket();

        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

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
      },
    );

    testWidgets(
      'cloud down + cache present + no local device → SYNCING, not OFFLINE, '
      'after a single status failure (#11)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final cache = LocalDeviceCache();
        await cache.upsert({
          'deviceId': _deviceId,
          'name': 'Controller',
          'channels': 4,
        });
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
      },
    );

    testWidgets('cloud down + empty cache → original load error is kept', (
      tester,
    ) async {
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
    testWidgets('socket disconnect does NOT mark the device OFFLINE', (
      tester,
    ) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      expect(find.text('Online'), findsOneWidget);

      socket.fireDisconnect();
      await tester.pump();

      expect(
        find.text('Online'),
        findsOneWidget,
        reason: 'a Socket.IO transport drop is not device-offline evidence',
      );
      expect(find.text('Offline'), findsNothing);

      await _unmount(tester);
    });

    testWidgets(
      'a single REST status failure leaves the card SYNCING, not OFFLINE',
      (tester) async {
        final repo = _StatusFailingRepo();
        await _pumpDevicesPage(tester, repo: repo);

        expect(
          find.text('Offline'),
          findsNothing,
          reason: 'one failed poll must not mark the device OFFLINE',
        );
        expect(find.text('SYNCING'), findsWidgets);

        await _unmount(tester);
      },
    );

    testWidgets(
      'repeated consecutive status failures mark the device OFFLINE',
      (tester) async {
        final repo = _StatusFailingRepo();
        await _pumpDevicesPage(tester, repo: repo);

        // The first failure happened during initial load (SYNCING). Two more
        // 15s poll ticks cross the 3-failure threshold (strong evidence).
        await tester.pump(const Duration(seconds: 16));
        await tester.pump();
        await tester.pump(const Duration(seconds: 16));
        await tester.pump();

        expect(
          find.text('Offline'),
          findsOneWidget,
          reason: '3 consecutive poll failures are strong offline evidence',
        );

        await _unmount(tester);
      },
    );

    testWidgets(
      'explicit LWT Offline via device_status marks the device OFFLINE',
      (tester) async {
        final socket = _ScriptableSocket();
        final repo = _FakeRepo();
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

        expect(find.text('Online'), findsOneWidget);

        socket.push('device_status', {'deviceId': _deviceId, 'online': false});
        await tester.pump();

        expect(
          find.text('Offline'),
          findsOneWidget,
          reason: 'LWT Offline is authoritative device-offline evidence',
        );

        await _unmount(tester);
      },
    );

    testWidgets(
      'a positive device_status report restores ONLINE after LWT Offline',
      (tester) async {
        final socket = _ScriptableSocket();
        final repo = _FakeRepo();
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

        socket.push('device_status', {'deviceId': _deviceId, 'online': false});
        await tester.pump();
        expect(find.text('Offline'), findsOneWidget);

        socket.push('device_status', {'deviceId': _deviceId, 'online': true});
        await tester.pump();

        expect(
          find.text('Online'),
          findsOneWidget,
          reason: 'a positive device report restores ONLINE',
        );
        expect(find.text('Offline'), findsNothing);

        await _unmount(tester);
      },
    );

    testWidgets(
      'a cloud device_status event cannot overwrite fresher local evidence',
      (tester) async {
        final socket = _ScriptableSocket();
        final repo = _FakeRepo(source: DeviceTransportSource.local);
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

        // Confirm the cloud is unreachable so the verified local session is LAN.
        socket.fireConnectError();
        await tester.pump();
        expect(find.text('LAN'), findsOneWidget);

        // A cloud LWT-offline event lands while the local session is still fresh.
        socket.push('device_status', {'deviceId': _deviceId, 'online': false});
        await tester.pump();

        expect(
          find.text('LAN'),
          findsOneWidget,
          reason:
              'fresher local evidence must never be overwritten by a stale '
              'cloud verdict',
        );
        expect(find.text('Offline'), findsNothing);

        await _unmount(tester);
      },
    );
  });

  group('Phase 4: evidence-based ONLINE / LAN / OFFLINE priority', () {
    testWidgets(
      'cloud reachable + recent cloud evidence + successful local poll '
      'keeps ONLINE',
      (tester) async {
        final socket = _ScriptableSocket();
        final repo = _FakeRepo();
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

        // Cloud connected and the device reported ONLINE via cloud.
        expect(find.text('Online'), findsOneWidget);
        socket.push('device_status', {'deviceId': _deviceId, 'online': true});
        await tester.pump();
        expect(find.text('Online'), findsOneWidget);

        // A background LOCAL status poll succeeds while the cloud is still up.
        await tester.pump(const Duration(seconds: 16));
        await tester.pump();

        expect(
          find.text('Online'),
          findsOneWidget,
          reason:
              'a successful local poll must NOT downgrade ONLINE when the '
              'cloud is reachable',
        );
        expect(find.text('LAN'), findsNothing);

        await _unmount(tester);
      },
    );

    testWidgets('cloud confirmed down + local device success → LAN', (
      tester,
    ) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo(source: DeviceTransportSource.local);
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      socket.fireConnectError();
      await tester.pump();
      await tester.tap(find.text('CHANNEL 1'));
      await tester.pumpAndSettle();

      expect(
        find.text('LAN'),
        findsOneWidget,
        reason: 'cloud confirmed down + verified local device = LAN',
      );
      expect(find.text('Offline'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('cloud confirmed down + local failure + no evidence → OFFLINE '
        'after the repeated-failure threshold', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _StatusFailingRepo();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      socket.fireConnectError();
      await tester.pump();
      // A single failure (during initial load) is not OFFLINE evidence.
      expect(find.text('Offline'), findsNothing);

      // Two more 15s poll ticks cross the 3-failure threshold.
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();

      expect(
        find.text('Offline'),
        findsOneWidget,
        reason: 'cloud confirmed down + no LAN + no valid evidence → OFFLINE',
      );

      await _unmount(tester);
    });

    testWidgets(
      'LAN + cloud reconnect + fresh device cloud evidence → badge stays LAN '
      '(the device is on the same network, so routing never bounced to cloud)',
      (tester) async {
        final socket = _ScriptableSocket();
        final repo = _FakeRepo(source: DeviceTransportSource.local);
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

        socket.fireConnectError();
        await tester.pump();
        expect(find.text('LAN'), findsOneWidget);

        // Cloud comes back and delivers fresh positive device evidence. The
        // device is still on the same network (local source) so routing stays
        // local: the badge must NOT bounce to ONLINE (Issue 1 fix).
        socket.fireConnect();
        await tester.pump();
        socket.push('device_status', {'deviceId': _deviceId, 'online': true});
        await tester.pump();

        expect(
          find.text('LAN'),
          findsOneWidget,
          reason: 'a same-WiFi device stays LAN when the cloud reconnects',
        );
        expect(find.text('Online'), findsNothing);

        await _unmount(tester);
      },
    );

    testWidgets('a late local poll cannot downgrade the same-WiFi LAN verdict '
        'after newer cloud evidence', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo(source: DeviceTransportSource.local);
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      // Cloud evidence confirms the device online; the same-WiFi verdict from
      // the initial local read still routes locally → LAN.
      socket.push('device_status', {'deviceId': _deviceId, 'online': true});
      await tester.pump();
      expect(find.text('LAN'), findsOneWidget);

      // An older local poll resolves later; cloud is still reachable. The
      // same-WiFi routing (and its LAN badge) must not be downgraded.
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();

      expect(
        find.text('LAN'),
        findsOneWidget,
        reason: 'a late local result must not flip the same-WiFi LAN verdict',
      );
      expect(find.text('Online'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('a successful cloud control keeps connectivity logically '
        'correct', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      await tester.tap(find.text('CHANNEL 1'));
      await tester.pumpAndSettle();

      expect(
        find.text('Online'),
        findsOneWidget,
        reason: 'cloud control success keeps ONLINE (cloud reachable)',
      );
      expect(find.text('LAN'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('local control succeeds while cloud is confirmed down → LAN', (
      tester,
    ) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo(source: DeviceTransportSource.local);
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      socket.fireConnectError();
      await tester.pump();
      await tester.tap(find.text('CHANNEL 2'));
      await tester.pumpAndSettle();

      expect(
        find.text('LAN'),
        findsOneWidget,
        reason: 'local command with cloud confirmed down = LAN',
      );
      expect(find.text('Online'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('socket connected but no valid device evidence does NOT mark '
        'ONLINE', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _StatusFailingRepo();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      // Socket (re)connects, but the device produced NO valid evidence.
      socket.fireConnect();
      await tester.pump();

      expect(
        find.text('Online'),
        findsNothing,
        reason: 'a connected socket alone is not per-device online evidence',
      );
      expect(
        find.text('Offline'),
        findsNothing,
        reason: 'and a single poll failure is not offline evidence either',
      );
      expect(find.text('SYNCING'), findsWidgets);

      await _unmount(tester);
    });

    testWidgets('a single transient failure keeps ONLINE when valid evidence '
        'exists', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FailOnceRepo();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );
      expect(find.text('Online'), findsOneWidget);

      // The next background poll fails ONCE; fresh evidence still exists.
      repo.failNext = true;
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();

      expect(
        find.text('Online'),
        findsOneWidget,
        reason: 'one transient failure must not mark the device OFFLINE',
      );
      expect(find.text('Offline'), findsNothing);

      await _unmount(tester);
    });
  });

  group('disconnect probe: instant LAN when the LAN device answers', () {
    testWidgets('cloud drop probes the verified LAN IP immediately → LAN', (
      tester,
    ) async {
      final socket = _ScriptableSocket();
      final repo = _CloudThenLocalRepo();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      // The device was last seen over the CLOUD: no fresh local evidence yet.
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('LAN'), findsNothing);

      // Cloud drops: the disconnect probe must re-read the LAN at once and
      // flip the badge to LAN without waiting for the next 15s poll.
      socket.fireDisconnect();
      await tester.pump();

      expect(
        find.text('LAN'),
        findsOneWidget,
        reason: 'disconnect probe re-establishes local evidence immediately',
      );
      expect(find.text('Online'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('connect error probes the LAN too → LAN', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _CloudThenLocalRepo();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      socket.fireConnectError();
      await tester.pump();

      expect(
        find.text('LAN'),
        findsOneWidget,
        reason: 'a connect error is a confirmed cloud outage too',
      );
      expect(find.text('Online'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('unreachable LAN device → no false LAN, stays SYNCING', (
      tester,
    ) async {
      final socket = _ScriptableSocket();
      final repo = _StatusFailingRepo();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      // Cloud drops and the LAN cannot be reached: the probe fails (silently)
      // and a single failure is NOT offline evidence.
      socket.fireConnectError();
      await tester.pump();

      expect(
        find.text('LAN'),
        findsNothing,
        reason: 'no local evidence must never fabricate LAN',
      );
      expect(
        find.text('Offline'),
        findsNothing,
        reason: 'one probe failure is not the repeated-failure threshold',
      );
      expect(find.text('SYNCING'), findsWidgets);

      await _unmount(tester);
    });

    testWidgets('repeated cloud-down events do not spawn duplicate probes', (
      tester,
    ) async {
      final socket = _ScriptableSocket();
      final repo = _CloudThenLocalRepo();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );
      final base = repo.statusCalls;

      socket.fireDisconnect();
      await tester.pump();
      expect(
        repo.statusCalls,
        base + 1,
        reason: 'the first cloud-down event triggers exactly one probe',
      );

      socket.fireConnectError();
      await tester.pump();
      expect(
        repo.statusCalls,
        base + 1,
        reason:
            'a repeated cloud-down event while already down must not probe again',
      );

      // A real reconnect resets the gate: a later drop probes again.
      socket.fireConnect();
      await tester.pump();
      expect(
        repo.statusCalls,
        base + 2,
        reason: 'reconnect refetches status (existing reconcile behavior)',
      );

      socket.fireDisconnect();
      await tester.pump();
      expect(
        repo.statusCalls,
        base + 3,
        reason: 'a new outage after reconnect probes again',
      );

      await _unmount(tester);
    });

    testWidgets('probe reuses a status read already in flight', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _GatedStatusRepo(source: DeviceTransportSource.local);
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      // The initial status read is still held in flight.
      expect(repo.statusCalls, 1);

      socket.fireDisconnect();
      await tester.pump();
      expect(
        repo.statusCalls,
        1,
        reason:
            'the probe must reuse the in-flight status read, not duplicate it',
      );

      socket.fireConnectError();
      await tester.pump();
      expect(
        repo.statusCalls,
        1,
        reason: 'repeated events while down never add a second probe',
      );

      // Once the in-flight read resolves, the verified local evidence shows LAN.
      repo.releaseStatus.complete();
      await tester.pumpAndSettle();
      expect(find.text('LAN'), findsOneWidget);

      await _unmount(tester);
    });

    testWidgets('reconnect keeps the LAN badge while the device stays on the same '
      'network — the badge follows routing and never bounces (Issue 1)', (
      tester,
    ) async {
      final socket = _ScriptableSocket();
      final repo = _CloudThenLocalRepo();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      // First read was cloud-sourced (device not yet on same WiFi) → ONLINE.
      expect(find.text('Online'), findsOneWidget);

      socket.fireDisconnect();
      await tester.pump();
      expect(find.text('LAN'), findsOneWidget);

      socket.fireConnect();
      await tester.pump();
      // The device is STILL on the same network (subsequent reads are local),
      // so routing stays local and the badge must stay LAN — no bounce to
      // ONLINE just because the cloud socket recovered.
      expect(
        find.text('LAN'),
        findsOneWidget,
        reason: 'a same-WiFi device keeps the LAN badge after a socket reconnect',
      );
      expect(find.text('Online'), findsNothing);

      socket.push('device_status', {'deviceId': _deviceId, 'online': true});
      await tester.pump();
      expect(
        find.text('LAN'),
        findsOneWidget,
        reason: 'fresh cloud device evidence does not flip a same-WiFi device',
      );

      await _unmount(tester);
    });

    testWidgets('a different-network device (cloud source) shows ONLINE after a '
        'socket reconnect — cloud routing restored', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo(); // cloud source: device NOT on the same network
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('LAN'), findsNothing);

      socket.fireDisconnect();
      await tester.pump();
      socket.fireConnect();
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Online'),
        findsOneWidget,
        reason: 'cloud reachability restores ONLINE for a cloud-routed device',
      );
      expect(find.text('LAN'), findsNothing);

      await _unmount(tester);
    });

    testWidgets(
      'healthy-cloud local polls keep the LAN badge — a same-WiFi probe never '
      'downgrades the verdict',
      (tester) async {
        final socket = _ScriptableSocket();
        final repo = _FakeRepo(source: DeviceTransportSource.local);
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

        expect(find.text('LAN'), findsOneWidget);

        // A background local poll while the cloud is still up keeps the
        // same-WiFi verdict (and its LAN badge).
        await tester.pump(const Duration(seconds: 16));
        await tester.pump();
        expect(find.text('LAN'), findsOneWidget);
        expect(find.text('Online'), findsNothing);

        await _unmount(tester);
      },
    );

    testWidgets('multiple taps during cold LAN reuse the one probe', (
      tester,
    ) async {
      final socket = _ScriptableSocket();
      final repo = _CloudThenLocalRepo();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      socket.fireDisconnect();
      await tester.pump();
      expect(
        find.text('LAN'),
        findsOneWidget,
        reason:
            'the single disconnect probe already established local evidence',
      );

      await tester.tap(find.text('CHANNEL 1'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('CHANNEL 2'));
      await tester.pump();
      await tester.pump();

      expect(
        repo.statusCalls,
        2,
        reason: 'initial load + the ONE disconnect probe — taps add no probe',
      );
      expect(
        repo.controlCalls,
        2,
        reason: 'each tap sends its own command but never a duplicate probe',
      );

      await _unmount(tester);
    });
  });

  group('Phase 3: socket-confirmed report resolves pending before REST', () {
    testWidgets('a confirmed device_update resolves TURNING… immediately', (
      tester,
    ) async {
      final repo = _FakeRepo(gateControl: true);
      final socket = _ScriptableSocket();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      expect(find.text('DRY'), findsNWidgets(4));

      await tester.tap(find.text('CHANNEL 1'));
      await tester.pump();

      // TURNING ON appears immediately after the tap (no 200ms delay).
      expect(repo.controlCalls, 1);
      expect(find.text('TURNING ON…'), findsOneWidget);

      // The device confirms ON over Socket.IO while the REST command is still
      // in flight (gated). The pill must resolve immediately.
      socket.push('device_update', {
        'deviceId': _deviceId,
        'channel': 1,
        'state': 'ON',
        'updatedAt': DateTime.now().toIso8601String(),
      });
      await tester.pump();

      expect(
        find.text('TURNING ON…'),
        findsNothing,
        reason: 'a confirmed device report must resolve the pending tap',
      );
      expect(find.text('FLOWING'), findsOneWidget);
      expect(find.text('DRY'), findsNWidgets(3));

      // The later REST response completes the lifecycle WITHOUT a second
      // command and without re-enabling pending.
      repo.releaseControl.complete();
      await tester.pump();
      expect(repo.controlCalls, 1);
      expect(find.text('TURNING ON…'), findsNothing);
      expect(find.text('FLOWING'), findsOneWidget);

      await _unmount(tester);
    });

    testWidgets(
      'only a strictly-newer socket report may commit or flip state',
      (tester) async {
        final repo = _FakeRepo(gateControl: true);
        final socket = _ScriptableSocket();
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

        await tester.tap(find.text('CHANNEL 1'));
        await tester.pump();

        // TURNING ON appears immediately after the tap (no 200ms delay).
        expect(find.text('TURNING ON…'), findsOneWidget);

        // Fresh report: commits ON, resolves the pending tap.
        socket.push('device_update', {
          'deviceId': _deviceId,
          'channel': 1,
          'state': 'ON',
          'updatedAt': DateTime.now().toIso8601String(),
        });
        await tester.pump();
        expect(find.text('TURNING ON…'), findsNothing);
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

        expect(
          find.text('FLOWING'),
          findsOneWidget,
          reason: 'a stale report must never regress the newer confirmed state',
        );
        // Channels 2-4 were never touched and remain DRY.
        expect(find.text('DRY'), findsNWidgets(3));

        repo.releaseControl.complete();
        await tester.pump();
        expect(repo.controlCalls, 1);
        expect(find.text('FLOWING'), findsOneWidget);

        await _unmount(tester);
      },
    );

    testWidgets(
      'a late REST response cannot regress the newer socket-confirmed state',
      (tester) async {
        final repo = _StaleControlRepo(gateControl: true);
        final socket = _ScriptableSocket();
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

        await tester.tap(find.text('CHANNEL 1'));
        await tester.pump();

        // TURNING ON appears immediately after the tap (no 200ms delay).
        expect(find.text('TURNING ON…'), findsOneWidget);

        // Socket confirms ON (newer).
        socket.push('device_update', {
          'deviceId': _deviceId,
          'channel': 1,
          'state': 'ON',
          'updatedAt': DateTime.now().toIso8601String(),
        });
        await tester.pump();
        expect(find.text('TURNING ON…'), findsNothing);
        expect(find.text('FLOWING'), findsOneWidget);

        // The REST response lands late and reports OFF with an OLDER timestamp.
        // The staleness guard must keep the socket-confirmed ON.
        repo.releaseControl.complete();
        await tester.pump();

        expect(
          find.text('FLOWING'),
          findsOneWidget,
          reason:
              'a stale REST report must never regress the newer confirmed state',
        );
        expect(find.text('DRY'), findsNWidgets(3));
        expect(repo.controlCalls, 1);

        await _unmount(tester);
      },
    );

    testWidgets('a tap after socket confirmation does not spawn a second command '
        'while REST is in flight', (tester) async {
      final repo = _FakeRepo(gateControl: true);
      final socket = _ScriptableSocket();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      await tester.tap(find.text('CHANNEL 1'));
      await tester.pump();
      expect(repo.controlCalls, 1);
      expect(find.text('TURNING ON…'), findsOneWidget);

      // Socket confirms ON: pending clears but the single-flight guard stays
      // until the REST lifecycle completes.
      socket.push('device_update', {
        'deviceId': _deviceId,
        'channel': 1,
        'state': 'ON',
        'updatedAt': DateTime.now().toIso8601String(),
      });
      await tester.pump();
      expect(find.text('TURNING ON…'), findsNothing);
      expect(find.text('FLOWING'), findsOneWidget);

      // Second tap during the still-in-flight REST must be ignored.
      await tester.tap(find.text('CHANNEL 1'));
      await tester.pump();
      expect(
        repo.controlCalls,
        1,
        reason:
            'exactly one command per tap: the guard persists until REST finishes',
      );

      repo.releaseControl.complete();
      await tester.pump();
      expect(repo.controlCalls, 1);

      await _unmount(tester);
    });
  });

  group('cold-start LAN loading (progressive render)', () {
    testWidgets('cold start: cloud + LAN both up → device renders from cache '
        'quickly and reconciles to LAN (same-WiFi routing)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final cache = LocalDeviceCache();
      await cache.upsert({
        'deviceId': _deviceId,
        'name': 'Controller',
        'channels': 4,
      });
      final cm = _CmFake(
        responses: {'Status%205': _macBody, 'State': _stateBody},
      );
      final repo = DeviceRepositoryService(
        cloud: CloudDeviceTransport(
          api: _CloudApi(
            devices: [
              {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
            ],
          ),
        ),
        locator: _LocatorStub(cached: '192.168.1.5'),
        fetch: cm.call,
        cache: cache,
      );
      final socket = _ScriptableSocket();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      // Card rendered without waiting on anything and the confirmed local
      // status filled in the ON/OFF states.
      expect(find.text('Controller'), findsOneWidget);
      expect(find.text('DRY'), findsNWidgets(4));

      // The local status read confirmed same-WiFi: routing is local, so the
      // badge shows LAN even though the cloud socket is up (Issue 1).
      expect(find.text('LAN'), findsOneWidget);
      expect(find.text('Online'), findsNothing);

      // Socket connects: cloud confirmed reachable → the same-WiFi device
      // stays LAN (routing never bounced to cloud).
      socket.fireConnect();
      await tester.pump();
      expect(find.text('LAN'), findsOneWidget);
      expect(find.text('Online'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('cold start: cloud list hangs but LAN device answers → page '
        'renders immediately, no 15s cloud timeout wait, then LAN badge', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final cache = LocalDeviceCache();
      await cache.upsert({
        'deviceId': _deviceId,
        'name': 'Controller',
        'channels': 4,
      });
      final cm = _CmFake(
        responses: {'Status%205': _macBody, 'State': _stateBody},
      );
      final repo = DeviceRepositoryService(
        cloud: CloudDeviceTransport(api: _HangingCloudApi()),
        locator: _LocatorStub(cached: '192.168.1.5'),
        fetch: cm.call,
        cache: cache,
      );
      final socket = _ScriptableSocket();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      // The device card + confirmed states render WITHOUT the cloud list ever
      // resolving (previously the page stayed on the spinner until the 15s
      // API timeout expired).
      expect(find.text('Controller'), findsOneWidget);
      expect(find.text('DRY'), findsNWidgets(4));
      expect(find.text('Could not load devices'), findsNothing);
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: 'the page must never sit on an infinite spinner',
      );

      // Confirm the cloud outage via the socket monitor → the verified local
      // evidence resolves the badge to LAN.
      socket.fireConnectError();
      await tester.pump();
      expect(find.text('LAN'), findsOneWidget);
      expect(find.text('Online'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('cold start: cloud down + LAN down + empty cache → proper '
        'error state, never an infinite spinner', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repo = DeviceRepositoryService(
        cloud: CloudDeviceTransport(api: _CloudDownApi()),
        locator: _LocatorStub(),
        cache: LocalDeviceCache(),
      );
      await _pumpDevicesPage(tester, repo: repo);

      expect(find.text('Could not load devices'), findsOneWidget);
      expect(find.textContaining('Check your connection'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await _unmount(tester);
    });

    testWidgets('cold start: socket still UNKNOWN + no device evidence → '
        'SYNCING, never a fabricated ONLINE', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final cache = LocalDeviceCache();
      await cache.upsert({
        'deviceId': _deviceId,
        'name': 'Controller',
        'channels': 4,
      });
      final repo = DeviceRepositoryService(
        cloud: CloudDeviceTransport(api: _CloudDownApi()),
        locator: _LocatorStub(), // no LAN device reachable
        cache: cache,
      );
      await _pumpDevicesPage(tester, repo: repo);

      // The card structure renders from the cache, but with NO device evidence
      // the page must show SYNCING — never ONLINE just because the socket
      // cloud state is still UNKNOWN (safe cloud-first default).
      expect(find.text('Controller'), findsOneWidget);
      expect(find.text('Online'), findsNothing);
      expect(find.text('Offline'), findsNothing);
      expect(find.text('SYNCING'), findsWidgets);

      await _unmount(tester);
    });

    testWidgets('cold start: LAN displayed, then cloud reconnects → the same-WiFi '
        'badge stays LAN (routing never bounced)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final cache = LocalDeviceCache();
      await cache.upsert({
        'deviceId': _deviceId,
        'name': 'Controller',
        'channels': 4,
      });
      final cm = _CmFake(
        responses: {'Status%205': _macBody, 'State': _stateBody},
      );
      final repo = DeviceRepositoryService(
        cloud: CloudDeviceTransport(api: _CloudDownApi()),
        locator: _LocatorStub(cached: '192.168.1.5'),
        fetch: cm.call,
        cache: cache,
      );
      final socket = _ScriptableSocket();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      socket.fireConnectError();
      await tester.pump();
      expect(find.text('LAN'), findsOneWidget);

      // Cloud comes back: the same-WiFi device keeps the LAN badge — the
      // reconnect must not bounce routing (or the badge) to ONLINE.
      socket.fireConnect();
      await tester.pump();
      expect(find.text('LAN'), findsOneWidget);
      expect(find.text('Online'), findsNothing);

      await _unmount(tester);
    });
  });

  group('fast cloud-failure detection (health monitor)', () {
    testWidgets('Online → Internet lost → fast confirmed failure → immediate '
        'LAN probe → LAN (no socket timeout wait)', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _CloudThenLocalRepo(); // first read cloud (Online) → probe local (LAN)
      var healthy = true;
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
        healthCheck: () async => healthy,
      );
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('LAN'), findsNothing);

      // Internet dies. The first health probe fails (weak evidence alone) and
      // schedules an immediate confirm; the second consecutive failure confirms
      // the outage and fires the existing LAN probe at once. The probe read is
      // local → the badge flips to LAN (same-WiFi routing).
      healthy = false;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(
        repo.statusCalls,
        2,
        reason: 'initial load + the single fast-failure LAN probe',
      );
      expect(
        find.text('LAN'),
        findsOneWidget,
        reason: 'confirmed cloud loss + verified local device = LAN',
      );
      expect(find.text('Online'), findsNothing);
      expect(find.text('Offline'), findsNothing);

      await _unmount(tester);
    });

    testWidgets(
      'cloud fails but the LAN device is unreachable → no false LAN',
      (tester) async {
        final socket = _ScriptableSocket();
        final repo = _StatusFailingRepo();
        var healthy = true;
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
          healthCheck: () async => healthy,
        );
        expect(find.text('SYNCING'), findsWidgets);

        healthy = false;
        await tester.pump(const Duration(seconds: 5));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();

        expect(
          find.text('LAN'),
          findsNothing,
          reason: 'no fresh local device evidence must never fabricate LAN',
        );
        expect(
          find.text('Offline'),
          findsNothing,
          reason: 'one failed probe is not the repeated-failure threshold',
        );
        expect(find.text('SYNCING'), findsWidgets);

        await _unmount(tester);
      },
    );

    testWidgets('cloud recovers → socket reconnect keeps the same-WiFi LAN badge '
        '(health-down never wedges, reconnect never bounces)', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo(source: DeviceTransportSource.local);
      var healthy = true;
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
        healthCheck: () async => healthy,
      );
      expect(find.text('LAN'), findsOneWidget);

      // Internet lost → fast-confirmed → the same-WiFi badge stays LAN.
      healthy = false;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('LAN'), findsOneWidget);

      // Internet returns: the socket reconnect must NOT bounce the same-WiFi
      // device's badge to ONLINE — routing is still local (Issue 1).
      healthy = true;
      socket.fireConnect();
      await tester.pump();
      await tester.pump();

      expect(
        find.text('LAN'),
        findsOneWidget,
        reason: 'a same-WiFi device keeps LAN after recovery — no wedge, no bounce',
      );
      expect(find.text('Online'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('healthy cloud: one bounded probe per interval, no bursts', (
      tester,
    ) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo(source: DeviceTransportSource.local);
      var checks = 0;
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
        healthCheck: () async {
          checks++;
          return true;
        },
      );

      expect(find.text('LAN'), findsOneWidget);
      await tester.pump(const Duration(seconds: 16)); // ticks at 5/10/15s
      await tester.pump();

      expect(
        checks,
        3,
        reason: 'a healthy cloud gets exactly one bounded probe per interval',
      );
      expect(find.text('LAN'), findsOneWidget);
      expect(find.text('Online'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('health-confirmed outage: the socket later dropping does NOT '
        'spawn a duplicate probe', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _CloudThenLocalRepo();
      var healthy = true;
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
        healthCheck: () async => healthy,
      );
      final base = repo.statusCalls;
      expect(base, 1, reason: 'one status read on initial load');

      healthy = false;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(
        repo.statusCalls,
        base + 1,
        reason: 'the confirmed outage triggers exactly one LAN probe',
      );
      expect(find.text('LAN'), findsOneWidget);

      // The socket now notices the same outage on its own: cloud already marked
      // down, so no second probe is spawned.
      socket.fireDisconnect();
      await tester.pump();
      socket.fireConnectError();
      await tester.pump();
      expect(
        repo.statusCalls,
        base + 1,
        reason: 'repeated cloud-down signals while already down never re-probe',
      );

      await _unmount(tester);
    });
  });

  group('fast LAN probe after cloud-down uses the known IP fast path', () {
    const foreignMac = '{"StatusNET":{"Mac":"00:11:22:33:44:55"}}';

    testWidgets(
      'cloud down + warm verified endpoint → direct probe, no mDNS, no '
      're-verification',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final cm = _RecordingCmFake({
          '192.168.1.5': {'Status%205': _macBody, 'State': _stateBody},
        });
        final locator = _LocatorStub(cached: '192.168.1.5');
        final repo = DeviceRepositoryService(
          cloud: CloudDeviceTransport(
            api: _CloudApi(
              devices: const [
                {'deviceId': _deviceId, 'name': 'Controller', 'channels': 4},
              ],
            ),
          ),
          locator: locator,
          fetch: cm.call,
          cache: LocalDeviceCache(),
        );
        final socket = _ScriptableSocket();

        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

        // First contact discovered the candidate and identity-verified it once.
        expect(
          cm.status5Count,
          1,
          reason: 'one identity verification on first contact',
        );
        expect(find.text('LAN'), findsOneWidget);

        socket.fireDisconnect();
        await tester.pump();
        await tester.pump();

        // LAN resolves through the warm verified endpoint: no second Status 5,
        // no mDNS, no cloud re-probe.
        expect(find.text('LAN'), findsOneWidget);
        expect(
          cm.status5Count,
          1,
          reason: 'warm verified endpoint skips re-verification',
        );
        expect(
          locator.mDnsCalls,
          0,
          reason: 'the fast path never falls back to mDNS',
        );
        expect(
          cm.log.where((e) => e == '192.168.1.5 State').length,
          2,
          reason: 'both reads went straight to the known verified IP',
        );

        await _unmount(tester);
      },
    );

    testWidgets('cloud down + freshly persisted verified IP → fast probe', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final cache = LocalDeviceCache();
      await cache.upsert({
        'deviceId': _deviceId,
        'name': 'Controller',
        'channels': 4,
      });
      final cm = _RecordingCmFake({
        '192.168.1.5': {'Status%205': _macBody, 'State': _stateBody},
      });
      final locator = _LocatorStub(
        cached: '192.168.1.5',
        verifiedAt: DateTime.now().subtract(const Duration(seconds: 5)),
      );
      final repo = DeviceRepositoryService(
        cloud: CloudDeviceTransport(api: _CloudDownApi()),
        locator: locator,
        fetch: cm.call,
        cache: cache,
      );
      final socket = _ScriptableSocket();

      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      // Fresh persisted verified IP short-circuits discovery; the transport
      // still re-verifies (Status 5) before reading, but no mDNS runs.
      expect(locator.mDnsCalls, 0);
      expect(cm.log.first, '192.168.1.5 Status%205');

      socket.fireDisconnect();
      await tester.pump();
      await tester.pump();

      expect(find.text('LAN'), findsOneWidget);
      expect(
        locator.mDnsCalls,
        0,
        reason: 'the persisted verified IP kept discovery off the mDNS path',
      );
      expect(cm.log.where((e) => e == '192.168.1.5 State').length, 2);

      await _unmount(tester);
    });

    testWidgets(
      'cloud-learned lastIp is never trusted blindly — Status 5 identity '
      'verification still runs before reading',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final cm = _RecordingCmFake({
          '192.168.1.5': {'Status%205': _macBody, 'State': _stateBody},
        });
        final locator = _LocatorStub(cached: '192.168.1.5');
        final repo = DeviceRepositoryService(
          cloud: CloudDeviceTransport(
            api: _CloudApi(
              devices: const [
                {
                  'deviceId': _deviceId,
                  'name': 'Controller',
                  'channels': 4,
                  'lastIp': '192.168.1.5',
                },
              ],
            ),
          ),
          locator: locator,
          fetch: cm.call,
          cache: LocalDeviceCache(),
        );
        final socket = _ScriptableSocket();

        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

        // The cloud-learned IP was not trusted as-is: the first contact is the
        // identity check, never a raw status read.
        expect(cm.log.first, '192.168.1.5 Status%205');
        expect(cm.status5Count, 1);
        expect(find.text('LAN'), findsOneWidget);

        socket.fireDisconnect();
        await tester.pump();
        await tester.pump();

        expect(find.text('LAN'), findsOneWidget);
        expect(cm.log.where((e) => e == '192.168.1.5 State').length, 2);

        await _unmount(tester);
      },
    );

    testWidgets('repurposed IP (foreign MAC) is rejected, never controlled, and '
        're-discovered', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final cache = LocalDeviceCache();
      await cache.upsert({
        'deviceId': _deviceId,
        'name': 'Controller',
        'channels': 4,
      });
      final cm = _RecordingCmFake({
        '192.168.1.5': {'Status%205': foreignMac},
      });
      final locator = _LocatorStub(cached: '192.168.1.5');
      final repo = DeviceRepositoryService(
        cloud: CloudDeviceTransport(api: _CloudDownApi()),
        locator: locator,
        fetch: cm.call,
        cache: cache,
      );
      final socket = _ScriptableSocket();

      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      // The known IP holds a different device → identity mismatch → discarded,
      // mDNS searched (nothing found) → SYNCING, never OFFLINE.
      expect(find.text('Controller'), findsOneWidget);
      expect(locator.discarded, contains(_deviceId));
      expect(locator.mDnsCalls, greaterThanOrEqualTo(1));
      expect(cm.hasControlCommand, isFalse);

      socket.fireDisconnect();
      await tester.pump();
      await tester.pump();

      // Even after cloud-down the foreign box is never read or controlled.
      expect(cm.hasControlCommand, isFalse);
      expect(
        cm.log.where((e) => e.contains('State')),
        isEmpty,
        reason: 'a mismatched identity must never be status-read',
      );
      expect(find.text('LAN'), findsNothing);

      await _unmount(tester);
    });

    testWidgets('known IP unreachable → mDNS discovery fallback still runs', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final cache = LocalDeviceCache();
      await cache.upsert({
        'deviceId': _deviceId,
        'name': 'Controller',
        'channels': 4,
      });
      final cm = _RecordingCmFake({});
      final locator = _LocatorStub(cached: '192.168.1.5');
      final repo = DeviceRepositoryService(
        cloud: CloudDeviceTransport(api: _CloudDownApi()),
        locator: locator,
        fetch: cm.call,
        cache: cache,
      );
      final socket = _ScriptableSocket();

      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      // HTTP 404 on Status 5 = unreachable → identity unavailable → candidate
      // kept, then mDNS searched; nothing found → SYNCING (not OFFLINE).
      expect(locator.mDnsCalls, greaterThanOrEqualTo(1));
      expect(find.text('SYNCING'), findsWidgets);

      socket.fireDisconnect();
      await tester.pump();
      await tester.pump();

      expect(find.text('LAN'), findsNothing);
      expect(
        locator.mDnsCalls,
        greaterThanOrEqualTo(2),
        reason: 'the fallback ladder runs again on the cloud-down probe',
      );
      expect(cm.hasControlCommand, isFalse);

      await _unmount(tester);
    });

    testWidgets(
      'device changed IP → repurposed old IP is discarded and mDNS finds the '
      'new address, which is re-verified and cached',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final cache = LocalDeviceCache();
        await cache.upsert({
          'deviceId': _deviceId,
          'name': 'Controller',
          'channels': 4,
        });
        final cm = _RecordingCmFake({
          '192.168.1.5': {'Status%205': foreignMac},
          '192.168.1.50': {'Status%205': _macBody, 'State': _stateBody},
        });
        final locator = _LocatorStub(
          cached: '192.168.1.5',
          verifiedAt: DateTime.now().subtract(const Duration(seconds: 5)),
          mDnsAddresses: const ['192.168.1.50'],
        );
        final repo = DeviceRepositoryService(
          cloud: CloudDeviceTransport(api: _CloudDownApi()),
          locator: locator,
          fetch: cm.call,
          cache: cache,
        );
        final socket = _ScriptableSocket();

        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

        // Fresh verified old IP → transport re-verifies → foreign MAC → identity
        // mismatch → endpoint invalidated → mDNS finds 192.168.1.50 → verified.
        expect(cm.log, contains('192.168.1.5 Status%205'));
        expect(
          cm.log,
          isNot(contains('192.168.1.5 State')),
          reason: 'the repurposed old IP is never status-read',
        );
        expect(locator.discarded, contains(_deviceId));
        expect(locator.storedVerified, contains('192.168.1.50'));
        expect(locator.mDnsCalls, greaterThanOrEqualTo(1));
        expect(
          cm.log.where((e) => e == '192.168.1.50 State').length,
          1,
          reason: 'the status read happened at the freshly discovered IP',
        );

        socket.fireDisconnect();
        await tester.pump();
        await tester.pump();

        // The newly learned verified IP now serves the cloud-down probe directly.
        expect(find.text('LAN'), findsOneWidget);
        expect(cm.log.where((e) => e == '192.168.1.50 State').length, 2);
        expect(cm.log, isNot(contains('192.168.1.5 State')));

        await _unmount(tester);
      },
    );

    testWidgets(
      'cloud-down probe reuses a status read already in flight — no second '
      'probe',
      (tester) async {
        final repo = _GatedStatusRepo(source: DeviceTransportSource.local);
        final socket = _ScriptableSocket();

        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

        // Initial load holds one status read in flight.
        expect(repo.statusCalls, 1);

        // Every cloud-down signal while that read is still pending reuses it.
        socket.fireDisconnect();
        await tester.pump();
        socket.fireConnectError();
        await tester.pump();
        expect(
          repo.statusCalls,
          1,
          reason: 'the single-flight status read is not duplicated',
        );

        repo.releaseStatus.complete();
        await tester.pumpAndSettle();
        expect(find.text('LAN'), findsOneWidget);

        await _unmount(tester);
      },
    );
  });

  group('evidence ordering: ONLINE↔OFFLINE flapping guard', () {
    testWidgets('a cloud poll reporting offline cannot flip a device confirmed '
        'online by a committed device_update', (tester) async {
      final socket = _ScriptableSocket();
      final repo = _CloudOfflineRepo();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      expect(find.text('Online'), findsOneWidget);

      // Fresh positive MQTT evidence.
      socket.push('device_update', {
        'deviceId': _deviceId,
        'channel': 1,
        'state': 'ON',
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
      await tester.pump();
      expect(find.text('Online'), findsOneWidget);

      // The very next 15s poll comes back "offline" from the cloud.
      repo.nextOffline = true;
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();

      expect(
        find.text('Offline'),
        findsNothing,
        reason:
            'a stale cloud offline verdict must not overwrite newer '
            'positive device evidence',
      );
      expect(find.text('Online'), findsOneWidget);

      await _unmount(tester);
    });

    testWidgets(
      'repeated cloud offline verdicts never flip a healthy device — no '
      'ONLINE↔OFFLINE flapping',
      (tester) async {
        final socket = _ScriptableSocket();
        final repo = _CloudOfflineRepo();
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

        expect(find.text('Online'), findsOneWidget);

        for (var round = 0; round < 3; round++) {
          socket.push('device_update', {
            'deviceId': _deviceId,
            'channel': 1,
            'state': 'ON',
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
          });
          await tester.pump();
          repo.nextOffline = true;
          await tester.pump(const Duration(seconds: 16));
          await tester.pump();
        }

        expect(
          find.text('Offline'),
          findsNothing,
          reason:
              'each committed device report re-freshes evidence ahead of '
              'the stale offline verdict',
        );
        expect(find.text('Online'), findsOneWidget);

        await _unmount(tester);
      },
    );

    testWidgets(
      'a newer committed device_update overwrites an older LWT Offline',
      (tester) async {
        final socket = _ScriptableSocket();
        final repo = _FakeRepo();
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

        socket.push('device_status', {'deviceId': _deviceId, 'online': false});
        await tester.pump();
        expect(find.text('Offline'), findsOneWidget);

        socket.push('device_update', {
          'deviceId': _deviceId,
          'channel': 1,
          'state': 'ON',
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        });
        await tester.pump();

        expect(
          find.text('Online'),
          findsOneWidget,
          reason:
              'a device that demonstrably talked to MQTT supersedes an '
              'older authoritative Offline',
        );
        expect(find.text('Offline'), findsNothing);

        await _unmount(tester);
      },
    );

    testWidgets(
      'LWT Offline after fresh device evidence is still authoritative and '
      'stays OFFLINE',
      (tester) async {
        final socket = _ScriptableSocket();
        final repo = _CloudOfflineRepo();
        await _pumpDevicesPage(
          tester,
          repo: repo,
          socketFactory: (u, o) => socket,
        );

        socket.push('device_update', {
          'deviceId': _deviceId,
          'channel': 1,
          'state': 'ON',
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        });
        await tester.pump();
        expect(find.text('Online'), findsOneWidget);

        // A real LWT Offline always wins, even right after fresh evidence.
        socket.push('device_status', {'deviceId': _deviceId, 'online': false});
        await tester.pump();
        expect(find.text('Offline'), findsOneWidget);

        // Subsequent cloud polls keep the card OFFLINE — the offline verdict's
        // own channel reports must never re-fresh liveness evidence.
        repo.nextOffline = true;
        await tester.pump(const Duration(seconds: 16));
        await tester.pump();
        repo.nextOffline = true;
        await tester.pump(const Duration(seconds: 16));
        await tester.pump();

        expect(
          find.text('Offline'),
          findsOneWidget,
          reason:
              'only positive device evidence newer than the LWT Offline '
              'may hold the card online',
        );
        expect(find.text('Online'), findsNothing);

        await _unmount(tester);
      },
    );

    testWidgets('a successful control ACK revives a device LWT put OFFLINE', (
      tester,
    ) async {
      final socket = _ScriptableSocket();
      final repo = _FakeRepo();
      await _pumpDevicesPage(
        tester,
        repo: repo,
        socketFactory: (u, o) => socket,
      );

      socket.push('device_status', {'deviceId': _deviceId, 'online': false});
      await tester.pump();
      expect(find.text('Offline'), findsOneWidget);

      await tester.tap(find.text('CHANNEL 1'));
      await tester.pumpAndSettle();

      expect(
        find.text('Online'),
        findsOneWidget,
        reason:
            'a successful control ACK is strong, newer positive '
            'evidence that revives the device',
      );
      expect(find.text('Offline'), findsNothing);

      await _unmount(tester);
    });
  });
}
