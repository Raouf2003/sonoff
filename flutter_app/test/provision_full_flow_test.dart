import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:smart_home_app/screens/devices_page.dart';
import 'package:smart_home_app/screens/provision_device_screen.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/device_repository_service.dart';
import 'package:smart_home_app/services/device_transport.dart';
import 'package:smart_home_app/services/provisioning_service.dart';
import 'package:smart_home_app/theme/app_theme.dart';

const _canonicalDeviceId = '34987AC30304';

/// Secure storage on the test host is unregistered; a token read must simply
/// return null so the wizard's Socket.IO fast-path (`_startDeviceWatch`) can
/// never throw under an unawaited future.
void _mockSecureStorage(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (_) async => null,
  );
}

/// Stubs the mobile Wi-Fi binding/settings channels. In a pure Dart test an
/// unmocked method channel NEVER completes (there is no platform handler), so
/// without these the AP probe (`ensureBoundToActiveWifi`) and the picker scan
/// would hang forever instead of returning a canned response.
void _mockWifiChannels(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('stees/wifi_binding'),
    (call) async {
      switch (call.method) {
        case 'ensureBoundToActiveWifi':
          return <String, dynamic>{
            'bound': true,
            'matched': true,
            'activeSsid': 'tasmota-XXXX',
          };
        case 'getNetworkInfo':
          return <String, dynamic>{
            'bound': true,
            'wifi': true,
            'internet': true,
          };
        default:
          return null;
      }
    },
  );
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('stees/wifi_settings'),
    (call) async => switch (call.method) {
          'scanWifi' => <String, dynamic>{'available': false},
          _ => null,
        },
  );
}

/// A controllable [ApiService] that models the backend over the whole flow:
/// duplicate pre-flight (`mine` / `notFound`), the online device-seen poll, the
/// authoritative provision call, and the post-claim lastIp learning (the claim
/// response itself never carries `lastIp` for a brand-new device — the wizard
/// must re-read the device list so the Local HTTP gate has a real IP).
class _FlowApi extends ApiService {
  DeviceDuplicateStatus preflightStatus = DeviceDuplicateStatus.notFound;
  int preflightCalls = 0;

  bool deviceSeen = true;
  int deviceSeenCalls = 0;
  final List<String> seenDeviceIds = [];

  int provisionCalls = 0;
  final List<String> provisionedDeviceIds = [];

  /// `lastIp` carried by the claim response. `null` models a brand-new device
  /// (the backend only learns the IP from the first tele/STATE), which forces
  /// the wizard's wait-for-MQTT-IP step.
  String? claimLastIp = '192.168.1.10';

  /// How many `getDevices()` calls return WITHOUT a usable lastIp before the
  /// device's record "catches up" with its MQTT telemetry. Starts at 0: the
  /// device is already known by the first read.
  int devicesCallsWithoutLastIpAfter = 0;
  int getDevicesCalls = 0;

  /// Models a device that was ALREADY registered when the wizard opened: the
  /// account's device list contains its MAC from the very first read, so the
  /// wizard's once-at-start snapshot captures it and the RAM-only early
  /// duplicate gate must stop the flow without any backend call.
  bool registeredAtStart = false;

  int unclaimCalls = 0;
  final List<String> mqttCommands = [];

  @override
  Future<DeviceDuplicateStatus> preflightDeviceCheck(String deviceId) async {
    preflightCalls++;
    return preflightStatus;
  }

  @override
  Future<Map<String, dynamic>> getDeviceSeen(String deviceId) async {
    deviceSeenCalls++;
    seenDeviceIds.add(deviceId);
    return {'seen': deviceSeen};
  }

  @override
  Future<Map<String, dynamic>> provisionDevice({
    required String deviceId,
    required String name,
    required int channels,
  }) async {
    provisionCalls++;
    provisionedDeviceIds.add(deviceId);
    return <String, dynamic>{
      'ok': true,
      if (claimLastIp != null) 'lastIp': claimLastIp,
    };
  }

  @override
  Future<List<dynamic>> getDevices() async {
    getDevicesCalls++;
    // Until the claim commits, the account owns nothing — UNLESS the test
    // models a device registered before the wizard opened. That is exactly
    // what the wizard's once-at-start snapshot sees: an empty list (brand-new
    // device, or a device that raced in AFTER the snapshot — the backend
    // pre-flight / provision still stops it), or a list that already contains
    // the canonical MAC (the RAM-only early gate stops it fully offline).
    if (provisionCalls == 0 && !registeredAtStart) {
      return <dynamic>[];
    }
    final armed = getDevicesCalls > devicesCallsWithoutLastIpAfter;
    return <dynamic>[
      <String, dynamic>{
        'deviceId': _canonicalDeviceId,
        'name': 'Controller',
        'channels': 4,
        if (armed) 'lastIp': '192.168.1.10',
      },
    ];
  }

  @override
  Future<void> sendMqttCommand(String deviceId, String command) async {
    mqttCommands.add(command);
  }

  @override
  Future<void> unclaimDevice(String deviceId) async {
    unclaimCalls++;
  }
}

/// A stateful backend model for the delete-then-claim scenario: the device is
/// registered (pre-flight says `mine`) until an authenticated DELETE removes
/// it, after which the pre-flight agrees the device is gone (`notFound`).
class _StatefulApi extends _FlowApi {
  int deleteCalls = 0;

  @override
  Future<void> deleteDevice(String deviceId) async {
    deleteCalls++;
    // The DELETE removes the existing registration; a subsequent claim's
    // pre-flight and authoritative provision will no longer see this MAC.
    preflightStatus = DeviceDuplicateStatus.notFound;
  }
}

/// A scripted Tasmota setup-AP responder (192.168.4.1). Reachability probes and
/// every `cmnd` the wizard sends are routed to canned 15.5.0 responses, and the
/// full command stream is recorded so tests can assert exactly which operations
/// actually hit the device (e.g. no WiFi provisioning for an existing device).
class _TasmotaFake {
  /// Every `cmnd` issued to `/cm`, in order. Reachability probes (path `/`)
  /// carry no `cmnd` and are not recorded.
  final List<String> commands = [];

  /// Every MAC string reported by `Status 5`, in read order.
  final List<String> macsRead = [];

  /// The MAC the fake device always reports. Canonicalized it must equal
  /// [_canonicalDeviceId] (see [normalizeMac]).
  static const reportedMac = '34:98:7A:C3:03:04';

  /// When true, the FIRST `Status 5` read answers without a MAC (the identity
  /// is not readable yet at AP detection), and every later read reports it.
  /// Exercises the fallback hard-gate path in `_provision()`.
  bool failFirstMacRead = false;

  http.Client get client => MockClient((request) async {
        final cmnd = request.url.queryParameters['cmnd'];
        if (cmnd == null || cmnd.isEmpty) {
          // Reachability probe: any HTTP response counts.
          return http.Response('{"Status":true}', 200);
        }
        commands.add(cmnd);
        return http.Response(_bodyFor(cmnd), 200);
      });

  String _bodyFor(String cmnd) {
    // Identity read (Status 5 is read-only, no reboot).
    if (cmnd.startsWith('Status 5')) {
      final isFirstRead = macsRead.isEmpty;
      macsRead.add(reportedMac);
      if (failFirstMacRead && isFirstRead) {
        return '{"StatusNET":{"Mac":""}}';
      }
      return '{"StatusNET":{"Mac":"$reportedMac"}}';
    }
    // Pre-flight WiFi credential test: trigger + verdict poll.
    if (cmnd.startsWith('WifiTest3')) return '{"WifiTest3":"Testing"}';
    if (cmnd == 'WifiTest') return '{"WifiTest":"Successful"}';
    // Read-back verifications.
    if (cmnd == 'Topic') return '{"Topic":"$_canonicalDeviceId"}';
    if (cmnd == 'FullTopic') return '{"FullTopic":"%prefix%/%topic%/"}';
    if (cmnd == 'MqttHost') return '{"MqttHost":"broker.emqx.io"}';
    if (cmnd == 'MqttPort') return '{"MqttPort":"1883"}';
    if (cmnd == 'SSId1') return '{"SSId1":"TestWifi"}';
    // Any write command accepted.
    return '{}';
  }

  /// True when the canned command stream contains at least one actual
  /// provisioning / WiFi-configuration operation (vs. the read-only identity
  /// probe and a terminal stop).
  bool get provisioned => commands.any(_isProvisionCommand);

  static bool _isProvisionCommand(String cmnd) {
    if (cmnd.startsWith('Status 5')) return false;
    return cmnd.isNotEmpty;
  }
}

/// Pushes the wizard onto a real navigator and records the pop result so a
/// successful claim (`Navigator.pop(true)`) can be asserted end-to-end. A
/// wizard left frozen in a terminal state never pops, so the reader returns
/// null in that case.
Future<bool? Function()> _launcher(
  WidgetTester tester,
  _FlowApi api,
  _TasmotaFake tasmota, {
  Future<bool> Function(String deviceId, {String? lastIp})? localSetup,
}) async {
  _mockWifiChannels(tester);
  bool? result;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => ProvisionDeviceScreen.forTest(
                      testApi: api,
                      testHttpClient: tasmota.client,
                      testWarmUp: (_) async {},
                      testLocalSetup:
                          localSetup ?? (_, {lastIp}) async => true,
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return () => result;
}

/// Drives the Connect step: Continue -> AP detection (stabilize delay + probe)
/// -> identity read -> pre-flight duplicate gate.
Future<void> _tapContinue(WidgetTester tester) async {
  await tester.tap(find.text('Continue'));
  // Stabilization delay (1.2s) then the async probe + identity + pre-flight.
  await tester.pump(const Duration(milliseconds: 1400));
  await tester.pumpAndSettle();
}

/// Fills the Configure form via the manual-entry path and submits. The fake
/// Tasmota answers every config command (broker backlog, topic/fulltopic,
/// WifiTest3, credentials) and the online poll sees the device, so the whole
/// flow runs to a successful claim without any real hardware.
Future<void> _fillAndProvision(WidgetTester tester) async {
  // Open the Wi-Fi picker and choose manual entry so the SSID field appears.
  await tester.tap(find.text('Select Wi-Fi network'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Enter network manually'));
  await tester.pumpAndSettle();

  await tester.enterText(
    find.byWidgetPredicate((w) =>
        w is TextField && w.decoration?.hintText == 'Network name (SSID)'),
    'TestWifi',
  );
  await tester.enterText(
    find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Wi-Fi Password'),
    'password',
  );
  await tester.enterText(
    find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Device Name'),
    'Controller',
  );
  await tester.pump();

  // The Configure form is taller than the 600px test viewport; bring the
  // submit button into view before tapping it.
  await tester.ensureVisible(find.text('Test Wi-Fi & Continue'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Test Wi-Fi & Continue'));
  await tester.pumpAndSettle();
}

/// Unmounts everything so page-level timers (status polls, cloud health) are
/// cancelled and no pending-timer assertion fires.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() {
    // Best-effort local cache writes on claim/delete use SharedPreferences.
    SharedPreferences.setMockInitialValues({});
  });

  group('pre-claim duplicate gate runs BEFORE any WiFi provisioning', () {
    testWidgets(
        'new device: pre-flight says notFound, provisioning runs and the '
        'claim succeeds', (tester) async {
      _mockSecureStorage(tester);
      final api = _FlowApi(); // preflightStatus = notFound
      final tasmota = _TasmotaFake();
      final read = await _launcher(tester, api, tasmota);

      await _tapContinue(tester);
      // Backend says "not registered" -> the wizard proceeds to Configure.
      expect(find.text('Test Wi-Fi & Continue'), findsOneWidget);

      await _fillAndProvision(tester);

      // Full end-to-end success: the wizard popped with `true`.
      expect(read(), isTrue, reason: 'claim must complete for a new device');
      expect(api.preflightCalls, 1,
          reason: 'the gate runs once at AP detection; the hard gate skips '
              'its redundant backend round-trip for the same identity');
      expect(api.provisionCalls, 1);
      expect(tasmota.provisioned, isTrue,
          reason: 'WiFi/config commands must actually be sent for a new device');
      expect(tasmota.commands, contains('Backlog MqttHost broker.emqx.io; '
              'MqttPort 1883'));
      expect(tasmota.commands, contains('Topic $_canonicalDeviceId'));
      expect(tasmota.commands, contains('WifiTest3 TestWifi+password'));
      expect(tasmota.commands, contains('WifiTest'));
      expect(tasmota.commands, contains('SSId1 TestWifi'));
      expect(tasmota.commands, contains('Restart 1'));
      expect(api.mqttCommands, isEmpty,
          reason: 'the fire-and-forget MQTT SetOption128/Restart bootstrap is '
              'gone — Local HTTP enable+verify is the only post-claim gate');

      await _unmount(tester);
    });

    testWidgets(
        'local HTTP verify failure fails provisioning: terminal stop, no '
        'success pop, device released', (tester) async {
      _mockSecureStorage(tester);
      final api = _FlowApi();
      final tasmota = _TasmotaFake();
      final read = await _launcher(tester, api, tasmota,
          localSetup: (_, {lastIp}) async => false);

      await _tapContinue(tester);
      await _fillAndProvision(tester);

      // The claim committed, but provisioning must NOT pop success: the wizard
      // freezes on the local-control diagnostic instead.
      expect(api.provisionCalls, 1,
          reason: 'the claim happened (post-claim gate)');
      expect(read(), isNull,
          reason: 'a verify failure must never pop `true`');
      expect(api.unclaimCalls, 1,
          reason: 'the device is released best-effort so the user can re-run '
              'the wizard');
      expect(find.text('Local control not ready'), findsOneWidget);
      expect(find.textContaining('same Wi-Fi as the device'), findsOneWidget);

      await _unmount(tester);
    });

    testWidgets(
        'brand-new claim (lastIp null) learns the IP from the device list '
        'before the hard gate runs', (tester) async {
      _mockSecureStorage(tester);
      final api = _FlowApi()
        ..claimLastIp = null // brand-new device: claim carries no IP
        ..devicesCallsWithoutLastIpAfter = 2; // tele/STATE lands on the 3rd read
      final tasmota = _TasmotaFake();
      String? setupLastIp;
      final read = await _launcher(tester, api, tasmota,
          localSetup: (deviceId, {lastIp}) async {
        setupLastIp = lastIp;
        return true;
      });

      await _tapContinue(tester);
      await _fillAndProvision(tester);

      expect(read(), isTrue, reason: 'the gate still succeeds once an IP exists');
      expect(api.getDevicesCalls, greaterThanOrEqualTo(3),
          reason: 'the wizard waits for the MQTT-learned IP before enabling');
      expect(setupLastIp, '192.168.1.10',
          reason: 'the hard gate is driven by the real learned LAN IP');

      await _unmount(tester);
    });

    testWidgets(
        'existing device: stops at the earliest gate with NO WiFi '
        'provisioning, NO config command, NO re-claim, and the exact message',
        (tester) async {
      _mockSecureStorage(tester);
      final api = _FlowApi()
        ..preflightStatus = DeviceDuplicateStatus.mine;
      final tasmota = _TasmotaFake();
      final read = await _launcher(tester, api, tasmota);

      await _tapContinue(tester);

      // Frozen into the terminal duplicate state before Configure ever shows.
      expect(find.textContaining('delete it before claiming it again'),
          findsOneWidget);
      expect(find.text('Test Wi-Fi & Continue'), findsNothing);
      // Only the read-only identity probe (Status 5) touched the device.
      expect(tasmota.commands, ['Status 5'],
          reason:
              'an existing device must NEVER receive provisioning/config '
              'commands or be connected to the user Wi-Fi');
      expect(tasmota.provisioned, isFalse);
      // No backend claim either.
      expect(api.provisionCalls, 0);
      expect(api.preflightCalls, 1,
          reason: 'a single gate at AP detection certifies the duplicate');
      expect(api.unclaimCalls, 0,
          reason: 'a duplicate is never claimed, so never unclaimed');
      // No re-claim path exists in the wizard.
      expect(find.text('Remove Device'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(read(), isNot(true));

      await _unmount(tester);
    });

    testWidgets(
        'existing device in the wizard-start snapshot: the RAM-only early gate '
        'stops it with NO backend call, NO provisioning, NO claim',
        (tester) async {
      _mockSecureStorage(tester);
      // The account already owns the device when the wizard opens, so the
      // once-at-start `GET /api/devices` snapshot captures the canonical MAC.
      // `preflightStatus` is left at `notFound` on purpose: the RAM gate must
      // stop the flow fully offline — the backend is never consulted at all.
      final api = _FlowApi()..registeredAtStart = true;
      final tasmota = _TasmotaFake();
      final read = await _launcher(tester, api, tasmota);

      await _tapContinue(tester);

      // Frozen into the terminal duplicate state before Configure ever shows.
      expect(find.textContaining('delete it before claiming it again'),
          findsOneWidget);
      expect(find.text('Test Wi-Fi & Continue'), findsNothing);
      // Only the read-only identity probe (Status 5) touched the device.
      expect(tasmota.commands, ['Status 5'],
          reason:
              'a registered device must NEVER receive provisioning/config '
              'commands or be connected to the user Wi-Fi');
      expect(tasmota.provisioned, isFalse);
      // No backend call at all: the snapshot alone certifies the duplicate.
      expect(api.preflightCalls, 0,
          reason: 'the RAM gate works with NO internet on the Tasmota AP — no '
              'backend round-trip is needed to stop an already-owned device');
      expect(api.provisionCalls, 0, reason: 'no claim: the flow never leaves the offline gate');
      expect(api.unclaimCalls, 0,
          reason: 'a duplicate is never claimed, so never unclaimed');
      expect(find.text('Remove Device'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(read(), isNot(true));

      await _unmount(tester);
    });

    testWidgets(
        'MAC unreadable at AP detection: the snapshot gate in _provision still '
        'stops a registered device before any config command', (tester) async {
      _mockSecureStorage(tester);
      // The account owns the device (snapshot hit), but its MAC could not be
      // read at AP detection — so only the Apply-time identity re-read feeds
      // the snapshot gate, which must still stop BEFORE a single config
      // command reaches the device and with no backend call.
      final api = _FlowApi()..registeredAtStart = true;
      final tasmota = _TasmotaFake()
        ..failFirstMacRead = true;
      final read = await _launcher(tester, api, tasmota);

      await _tapContinue(tester);
      // Identity unreadable at detection: the wizard still reaches Configure
      // (the MAC is re-read authority when Apply runs).
      expect(find.text('Test Wi-Fi & Continue'), findsOneWidget);
      expect(find.text('read from the device when it connects'), findsOneWidget,
          reason: 'the unreadable identity is shown as pending, not guessed');

      await _fillAndProvision(tester);

      // The snapshot gate ran once (in _provision), saw the duplicate, froze.
      expect(api.preflightCalls, 0,
          reason: 'the snapshot certifies the duplicate offline — the backend '
              'pre-flight never needs to run');
      expect(api.provisionCalls, 0);
      expect(find.textContaining('delete it before claiming it again'),
          findsOneWidget);
      // Only the two read-only Status 5 identity reads happened.
      expect(tasmota.commands.where((c) => c.startsWith('Status 5')).length, 2,
          reason: 'identity read at AP detection and again at Apply');
      expect(tasmota.commands.where((c) => !c.startsWith('Status 5')), isEmpty,
          reason: 'a registered device must never receive a config/Wi-Fi '
              'command, regardless of when its MAC could first be read');
      expect(tasmota.provisioned, isFalse);
      expect(read(), isNot(true));

      await _unmount(tester);
    });

    testWidgets(
        'MAC not readable at AP detection: the hard gate in _provision still '
        'stops a duplicate before any config command', (tester) async {
      _mockSecureStorage(tester);
      // The backend says the device already exists, but the identity could
      // not be read at AP detection (first Status 5 empty), so NOTHING was
      // checked yet — the hard gate in _provision must certify the re-read MAC
      // before a single config command reaches the device.
      final api = _FlowApi()
        ..preflightStatus = DeviceDuplicateStatus.mine;
      final tasmota = _TasmotaFake()
        ..failFirstMacRead = true;
      await _launcher(tester, api, tasmota);

      await _tapContinue(tester);
      // Identity unreadable at detection: the wizard still reaches Configure
      // (it shows the Device ID as "read from the device when it connects"),
      // because the authoritative identity re-read happens on Apply.
      expect(find.text('Test Wi-Fi & Continue'), findsOneWidget);
      expect(find.text('read from the device when it connects'), findsOneWidget,
          reason: 'the unreadable identity is shown as pending, not guessed');

      await _fillAndProvision(tester);

      // The hard gate ran once (in _provision), saw the duplicate, and froze.
      expect(api.preflightCalls, 1,
          reason: 'no gate ran at AP detection (identity unknown), so the hard '
              'gate is the single authoritative certifier');
      expect(api.provisionCalls, 0);
      expect(find.textContaining('delete it before claiming it again'),
          findsOneWidget);
      // No provisioning/config command reached the device: only the two
      // read-only Status 5 identity reads (detection + Apply-time re-read).
      expect(tasmota.commands.where((c) => c.startsWith('Status 5')).length, 2,
          reason: 'identity read at AP detection and again at Apply');
      expect(tasmota.commands.where((c) => !c.startsWith('Status 5')), isEmpty,
          reason: 'a duplicate must never receive a config/Wi-Fi command, '
              'regardless of when its MAC could first be read');
      expect(tasmota.provisioned, isFalse);

      await _unmount(tester);
    });

    testWidgets(
        'delete from the Devices page, then claim again: pre-flight now says '
        'notFound, provisioning runs and the claim succeeds', (tester) async {
      _mockSecureStorage(tester);

      // The backend starts with the device registered.
      final api = _StatefulApi()
        ..preflightStatus = DeviceDuplicateStatus.mine;

      // Delete it from the Devices page.
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: DevicesPage.test(
              onNavigateToTab: (_) {},
              testRepository: _fakeRepo,
              testSocketFactory: (url, opts) => _FakeSocket(),
              testHealthCheck: () async => true,
              testApi: api,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete Device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(api.deleteCalls, 1);
      expect(find.text('No devices yet'), findsOneWidget);
      await _unmount(tester);

      // Now claim the same device again: the backend no longer knows it, so
      // the pre-flight check passes and a normal provisioning runs to success.
      final tasmota = _TasmotaFake();
      final read = await _launcher(tester, api, tasmota);

      await _tapContinue(tester);
      expect(find.text('Test Wi-Fi & Continue'), findsOneWidget);

      await _fillAndProvision(tester);

      expect(read(), isTrue,
          reason: 'after a successful DELETE the same device claims afresh');
      expect(api.preflightCalls, 1,
          reason: 'the gate runs once at AP detection for the new claim; no '
              'redundant hard-gate round-trip for the same identity');
      expect(api.provisionCalls, 1);
      expect(tasmota.provisioned, isTrue);

      await _unmount(tester);
    });

    testWidgets(
        'MAC consistency: the MAC read during the AP phase is the same '
        'identity used to provision, verify online, and claim', (tester) async {
      _mockSecureStorage(tester);
      final api = _FlowApi(); // preflightStatus = notFound
      final tasmota = _TasmotaFake();
      final read = await _launcher(tester, api, tasmota);

      await _tapContinue(tester);
      expect(find.text('Test Wi-Fi & Continue'), findsOneWidget);
      await _fillAndProvision(tester);

      expect(read(), isTrue, reason: 'claim completes for a new device');

      // Every Status 5 read reports the SAME physical MAC.
      expect(tasmota.macsRead, isNotEmpty,
          reason: 'the AP phase must read the device MAC at least once');
      expect(
          tasmota.macsRead.toSet().length, 1,
          reason: 'the MAC must be stable across every identity read');
      // ...and it canonicalizes to the device identity used everywhere.
      final canonical = normalizeMac(tasmota.macsRead.first);
      expect(canonical, _canonicalDeviceId);

      // The identity burned into the device (Topic == canonical MAC) is the
      // one the backend observed after it joined the LAN, and the final claim
      // registers under that exact canonical MAC - never a different one.
      expect(tasmota.commands,
          contains('Topic $_canonicalDeviceId'));
      expect(api.seenDeviceIds, isNotEmpty,
          reason: 'the online device must be verified by its canonical MAC');
      expect(api.seenDeviceIds.every((id) => id == _canonicalDeviceId), isTrue);
      expect(api.provisionedDeviceIds, [_canonicalDeviceId],
          reason: 'the claim must register the same MAC that was provisioned');

      await _unmount(tester);
    });

    testWidgets(
        'MAC not readable at AP detection: a genuine new device still claims '
        'via the hard gate in _provision, once', (tester) async {
      _mockSecureStorage(tester);
      // The identity is unreadable at AP detection (no gate ran yet), but the
      // backend says "not registered". The Apply-time identity re-read feeds
      // the hard gate, which is the SINGLE certifier here, then provisioning
      // runs to a successful claim.
      final api = _FlowApi(); // preflightStatus = notFound
      final tasmota = _TasmotaFake()
        ..failFirstMacRead = true;
      final read = await _launcher(tester, api, tasmota);

      await _tapContinue(tester);
      expect(find.text('Test Wi-Fi & Continue'), findsOneWidget);

      await _fillAndProvision(tester);

      expect(read(), isTrue, reason: 'a new device claims to completion');
      expect(api.preflightCalls, 1,
          reason: 'the AP-detection gate was skipped (MAC unknown), so the '
              'hard gate in _provision is the one certifier');
      expect(api.provisionCalls, 1);
      expect(tasmota.provisioned, isTrue);

      await _unmount(tester);
    });
  });
}

/// Repository serving one fixed registered device; status reads are inert so
/// the page renders a selectable device card.
final _fakeRepo = _FakeRepo();

class _FakeRepo extends DeviceRepositoryService {
  @override
  Future<void> warmUp(List<Map<String, dynamic>> devices) async {}

  @override
  Future<List<Map<String, dynamic>>> getDevices() async => const [
        {'deviceId': _canonicalDeviceId, 'name': 'Controller', 'channels': 4},
      ];

  @override
  Future<RelayStatusResult> getStatus(
    String deviceId, {
    bool cloudDown = false,
  }) async {
    return RelayStatusResult(
      online: true,
      channels: {for (var i = 1; i <= 4; i++) i: const ChannelReport('OFF')},
      source: DeviceTransportSource.cloud,
      seq: 1,
    );
  }
}

/// Socket-io client without a server: all calls are no-ops so the Devices page
/// wiring can be exercised in isolation.
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