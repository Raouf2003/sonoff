import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:smart_home_app/models/device_type.dart';
import 'package:smart_home_app/screens/devices_page.dart';
import 'package:smart_home_app/screens/provision_device_screen.dart';
import 'package:smart_home_app/services/api_service.dart';
import 'package:smart_home_app/services/cloud_device_transport.dart';
import 'package:smart_home_app/services/device_repository_service.dart';
import 'package:smart_home_app/services/device_transport.dart';
import 'package:smart_home_app/services/local_device_cache.dart';
import 'package:smart_home_app/services/provisioning_service.dart';
import 'package:smart_home_app/theme/app_theme.dart';

const _canonicalDeviceId = '34987AC30304';

/// The broker the test backend exposes via `getMqttBrokerInfo` — deliberately
/// NOT Tasmota's factory default, so tests prove the wizard writes and read-back
/// verifies the backend-served address (the bug being guarded against is a
/// hardcoded `broker.emqx.io`).
const _testBrokerHost = 'mqtt.stees.test';
const _testBrokerPort = 1883;

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
/// would hang forever instead of returning a canned response. [scanNetworks]
/// (default: none → `available: false`) feeds the in-app picker's scan list.
/// [apConnect] (default: none) controls `stees/ap_connect`; when omitted that
/// channel is explicitly cleared so the wizard sees an unsupported SDK and
/// keeps the manual Wi-Fi-settings flow (existing tests stay untouched).
void _mockWifiChannels(
  WidgetTester tester, {
  List<String> scanNetworks = const [],
  _ApConnectMock? apConnect,
}) {
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
          'scanWifi' => scanNetworks.isEmpty
              ? <String, dynamic>{'available': false}
              : <String, dynamic>{'available': true, 'networks': scanNetworks},
          _ => null,
        },
  );
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('stees/ap_connect'),
    apConnect?.handle,
  );
}

/// Controllable stub for the `stees/ap_connect` channel (the in-app device-AP
/// specifier join). Defaults to SDK 33 with an instantly-available specifier so
/// a pick-then-Continue flow reaches the probe without fake async gymnastics.
class _ApConnectMock {
  int connectCalls = 0;
  String? lastSsid;
  int cancelCalls = 0;

  /// When true, `connectToAp` throws PERMISSION_DENIED (models a denied
  /// NEARBY_WIFI_DEVICES grant) so the wizard falls back to the manual flow.
  bool denyPermission = false;

  /// Terminal specifier stage `getState` reports; override to 'unavailable' /
  /// 'lost' / 'failed' to exercise the error + fallback path.
  String stage = 'available';

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'sdkInfo':
        return <String, dynamic>{'sdkInt': 33};
      case 'connectToAp':
        if (denyPermission) {
          throw PlatformException(code: 'PERMISSION_DENIED');
        }
        connectCalls++;
        lastSsid = (call.arguments as Map)['ssid'] as String?;
        // New contract (B): the native side resolves connectToAp itself with
        // the terminal stage — no getState polling on the Dart side anymore.
        return <String, dynamic>{'stage': stage};
      case 'getState':
        return <String, dynamic>{'stage': stage};
      case 'cancel':
        cancelCalls++;
        return null;
      default:
        return null;
    }
  }
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

  int unclaimCalls = 0;
  int deleteCalls = 0;
  final List<String> mqttCommands = [];

  /// When true, `getDevices()` throws (the phone is mid network transition
  /// and cannot reach the backend). The local-setup loop must still run in
  /// that state, driven by the last-known claimed IP. Best-effort model of the
  /// AP → home-Wi-Fi handoff window.
  bool getDevicesDown = false;

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

  /// Models the phone sitting on the OFFLINE Tasmota setup AP: every cloud
  /// list fetch and the duplicate pre-flight fail immediately. The wizard's
  /// persisted account snapshot (SharedPreferences) must still block a
  /// registered MAC, and a brand-new device with no snapshot must still be
  /// claimable (the backend remains the final net).
  bool offline = false;

  /// Broker info failures model the pre-fetch at wizard start failing (phone
  /// offline / backend unreachable), which must BLOCK the wizard before AP
  /// connect. Independent of [offline] so the offline duplicate-gate tests
  /// (whose subject is the persisted snapshot, not the broker) keep a known
  /// broker and exercise their gate; the broker-failure tests opt in.
  bool brokerInfoDown = false;

  @override
  Future<DeviceDuplicateStatus> preflightDeviceCheck(String deviceId) async {
    if (offline) {
      throw const ApiException('offline', code: 'NETWORK_ERROR');
    }
    preflightCalls++;
    return preflightStatus;
  }

  @override
  Future<MqttBrokerInfo> getMqttBrokerInfo() async {
    if (brokerInfoDown) {
      throw const ApiException('broker info down', code: 'NETWORK_ERROR');
    }
    return const MqttBrokerInfo(host: _testBrokerHost, port: _testBrokerPort);
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
    if (offline || getDevicesDown) {
      throw const ApiException('offline', code: 'NETWORK_ERROR');
    }
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

  @override
  Future<void> deleteDevice(String deviceId) async {
    deleteCalls++;
  }
}

/// A stateful backend model for the delete-then-claim scenario: the device is
/// registered (pre-flight says `mine`) until an authenticated DELETE removes
/// it, after which the pre-flight agrees the device is gone (`notFound`).
class _StatefulApi extends _FlowApi {
  @override
  Future<void> deleteDevice(String deviceId) async {
    deleteCalls++;
    // The DELETE removes the existing registration: a subsequent claim's
    // pre-flight agrees the device is gone (`notFound`) and the account's
    // registered list (wizard-start snapshot + boundary verdict) is now empty.
    preflightStatus = DeviceDuplicateStatus.notFound;
    registeredAtStart = false;
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

  /// When true, the FIRST `Topic` read-back returns a mismatching value, then
  /// subsequent reads are correct. Models a device that rebooted mid-Backlog
  /// (Tasmota restarts on Topic) and dropped the write: the batched identity
  /// verify fails, forcing the sequential Topic/FullTopic fallback path, which
  /// then re-writes and verifies both settings.
  bool failFirstTopicReadback = false;
  bool _topicMismatchDone = false;

  /// The broker the fake device reports back on `MqttHost`/`MqttPort` read-back.
  /// Defaults to the configured backend-served broker so the read-back verify
  /// succeeds. Override to the Tasmota factory default (broker.emqx.io) to
  /// model a device that ignored/never received the write and is still on the
  /// stock broker — the wizard must halt instead of accepting it.
  final String _brokerHost = _testBrokerHost;
  final int _brokerPort = _testBrokerPort;

  /// When true, the fake ALWAYS reports Tasmota's factory-default broker on
  /// read-back, regardless of what was configured. Models the real-hardware bug
  /// this regression guards against: the device stayed connected to
  /// `broker.emqx.io` instead of the backend's broker.
  bool stuckOnFactoryBroker = false;

  /// When true, the fake reports the STOCK single-relay module (Sonoff Basic)
  /// on `Module` read-back even after the wizard wrote `Module 23`. Models the
  /// bug this feature fixes: a 4-channel device left on Tasmota's default
  /// single-relay module, which the read-back verify must halt on.
  bool ignoresModuleWrite = false;

  /// Values written by `DeviceName` / `MqttUser` commands, echoed back on the
  /// corresponding read-back (C1 verification).
  String? deviceName;
  String? mqttUser;

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
    if (cmnd == 'Topic') {
      if (failFirstTopicReadback && !_topicMismatchDone) {
        _topicMismatchDone = true;
        return '{"Topic":"WRONGTOPIC"}';
      }
      return '{"Topic":"$_canonicalDeviceId"}';
    }
    if (cmnd == 'FullTopic') return '{"FullTopic":"%prefix%/%topic%/"}';
    // Echo the CONFIGURED broker (backend-served), never Tasmota's factory
    // default: the read-back verify must see exactly what the wizard wrote.
    // `stuckOnFactoryBroker` models a device that never got the write.
    if (stuckOnFactoryBroker) {
      if (cmnd == 'MqttHost') return '{"MqttHost":"broker.emqx.io"}';
      if (cmnd == 'MqttPort') return '{"MqttPort":"1883"}';
    } else {
      if (cmnd == 'MqttHost') return '{"MqttHost":"$_brokerHost"}';
      if (cmnd == 'MqttPort') return '{"MqttPort":"$_brokerPort"}';
    }
    if (cmnd == 'SSId1') return '{"SSId1":"TestWifi"}';
    // C1 read-backs: the wizard now verifies these two writes pre-Restart too.
    if (cmnd == 'DeviceName') return '{"DeviceName":"${deviceName ?? ''}"}';
    if (cmnd == 'MqttUser') return '{"MqttUser":"${mqttUser ?? ''}"}';
    // Module read-back. Firmware 15.x answers the bare `Module` command with the
    // name map {"23":"Sonoff 4CH Pro"}. `ignoresModuleWrite` models a device
    // stuck on the stock single-relay module (the bug): the wizard wrote
    // `Module 23` but the read-back must still be caught as a mismatch.
    if (cmnd == 'Module') {
      return ignoresModuleWrite
          ? '{"Module":{"1":"Sonoff Basic"}}'
          : '{"Module":{"23":"Sonoff 4CH Pro"}}';
    }
    // C1 contract: restart-prone writes answer with a bare `{}` on success
    // (real 15.5.0 behavior) — accepted because each gets a dedicated
    // read-back. Values are still STORED so later verifications match.
    // The broker `Backlog` is requireEcho:true and echoes its written values.
    if (cmnd == 'Restart 1') return '{"Restart":true}';
    if (cmnd.startsWith('Backlog')) {
      final host = RegExp(r'MqttHost ([^;]+)').firstMatch(cmnd)?.group(1)?.trim();
      final port = RegExp(r'MqttPort ([^;\s]+)').firstMatch(cmnd)?.group(1);
      final user = RegExp(r'MqttUser ([^;]+)').firstMatch(cmnd)?.group(1)?.trim();
      if (user != null && user.isNotEmpty) mqttUser = user;
      return '{"MqttHost":"${host ?? _brokerHost}","MqttPort":"${port ?? _brokerPort}"}';
    }
    final spaceIdx = cmnd.indexOf(' ');
    if (spaceIdx > 0) {
      final key = cmnd.substring(0, spaceIdx).trim();
      final value = cmnd.substring(spaceIdx + 1).trim();
      switch (key) {
        case 'DeviceName':
          deviceName = value;
          break;
        case 'MqttUser':
          mqttUser = value;
          break;
        default:
          break;
      }
      return '{}'; // real-firmware silent ack for restart-prone writes
    }
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

/// A scripted local-setup hook. Returns `false` for the first
/// [failuresBeforeSuccess] calls and `true` afterwards, so tests can drive
/// both the bounded auto-retry window and a manual Retry deterministically.
/// Every call records the `lastIp` the wizard chose — proving the known IP is
/// reused across the AP → home-Wi-Fi transition — and [onCall] can flip
/// external state (e.g. the cloud device list going down mid-flow).
class _ScriptedLocalSetup {
  _ScriptedLocalSetup(this.failuresBeforeSuccess, {this.onCall});

  final int failuresBeforeSuccess;
  final void Function(int calls)? onCall;
  int calls = 0;
  final List<String?> lastIps = [];

  Future<bool> run(String deviceId, {String? lastIp}) async {
    calls++;
    lastIps.add(lastIp);
    onCall?.call(calls);
    return calls > failuresBeforeSuccess;
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
  Future<bool> Function(String canonical)? isRegistered,
  bool useRealBoundaryCheck = false,
  DeviceRepositoryService? repo,
  List<String> scanNetworks = const [],
  _ApConnectMock? apConnect,
}) async {
  _mockWifiChannels(tester,
      scanNetworks: scanNetworks, apConnect: apConnect);
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
                      // With a real boundary check the Gate B seam is NOT
                      // injected, so the authoritative repository bound is
                      // exercised against the (mocked) persisted snapshot.
                      testIsDeviceRegistered: useRealBoundaryCheck
                          ? null
                          : (isRegistered ??
                              (canonical) async =>
                                  api.registeredAtStart &&
                                  canonical == _canonicalDeviceId),
                      testRepository: repo,
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

/// A cloud transport whose device list and pre-flight fail immediately, modeling
/// the offline Tasmota setup AP. Used with a REAL [DeviceRepositoryService] and
/// the mocked SharedPreferences so the persisted account snapshot is the only
/// offline source Gate B can consult.
class _OfflineCloudApi extends ApiService {
  @override
  Future<List<dynamic>> getDevices() async {
    throw const ApiException('offline', code: 'NETWORK_ERROR');
  }
}

DeviceRepositoryService _offlineRepo() => DeviceRepositoryService(
      cloud: CloudDeviceTransport(api: _OfflineCloudApi()),
      cache: LocalDeviceCache(),
    );

/// Drives the Connect step: Continue -> AP detection (stabilize delay + probe)
/// -> identity read -> pre-flight duplicate gate.
Future<void> _tapContinue(WidgetTester tester) async {
  // Taps whichever advance action the current selection state renders:
  // 'Join Device Network' post-selection, 'Continue' otherwise.
  final join = find.text('Join Device Network');
  await tester.tap(join.evaluate().isNotEmpty ? join : find.text('Continue'));
  // Stabilization delay (1.2s) then the async probe + identity + pre-flight.
  await tester.pump(const Duration(milliseconds: 1400));
  await tester.pumpAndSettle();
}

/// Fills the Configure form via the manual-entry path and submits. The fake
/// Tasmota answers every config command (broker backlog, topic/fulltopic,
/// WifiTest3, credentials) and the online poll sees the device, so the whole
/// flow runs to a successful claim without any real hardware.
Future<void> _fillAndProvision(
  WidgetTester tester, {
  DeviceType deviceType = DeviceType.fourRelay,
}) async {
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

  // Pick the physical relay layout (the wizard must turn the chosen channel
  // count into the matching Tasmota module, not store metadata only).
  await tester.ensureVisible(find.text(deviceType.label));
  await tester.tap(find.text(deviceType.label));
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

/// Drives the Connect step through the in-app device-AP list: opens it,
/// selects [ssid], then continues (the explicit second tap per the spec).
Future<void> _pickDeviceApAndContinue(
  WidgetTester tester,
  String ssid,
) async {
  await tester.tap(find.text('Select Device Wi-Fi'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(ssid));
  await tester.pumpAndSettle();
  await _tapContinue(tester);
}

void main() {
  setUp(() {
    // Best-effort local cache writes on claim/delete use SharedPreferences.
    SharedPreferences.setMockInitialValues({});
  });

  test(
      'provisioning path contains no hardcoded broker endpoint literals '
      '(the backend is the single source of truth for MqttHost/MqttPort)',
      () {
    final source =
        File('lib/screens/provision_device_screen.dart').readAsStringSync();

    expect(
        source,
        isNot(contains("TextEditingController(text: 'broker.emqx.io')")),
        reason: 'the MqttHost controller must be empty until the backend '
            'brokder info is fetched — never seeded with the factory default');
    expect(source, isNot(contains("TextEditingController(text: '1883')")),
        reason: 'the MqttPort controller must be empty until the backend '
            'brokder info is fetched');
    expect(source, isNot(contains("'broker.emqx.io'")),
        reason: 'the wizard source must contain no factory-broker string '
            'literal at all (host comes from GET /api/mqtt/broker-info)');
    expect(source, isNot(contains('"broker.emqx.io"')),
        reason: 'ditto for double-quoted literals');
  });

  group('Connect step: in-app device-AP list (programmatic join)', () {
    testWidgets(
        'regression Bug 1: tapping Select Device Wi-Fi opens the in-app scan '
        'sheet and never fires openWifiSettings', (tester) async {
      _mockSecureStorage(tester);
      final ap = _ApConnectMock();
      final api = _FlowApi();
      final tasmota = _TasmotaFake();
      await _launcher(tester, api, tasmota,
          scanNetworks: ['tasmota-ABCD'], apConnect: ap);

      // The support probe resolved AND rebuilt the UI: the button label must
      // have flipped to the in-app one (no stale "Open Wi-Fi Settings").
      expect(find.text('Select Device Wi-Fi'), findsOneWidget);

      // Record any (forbidden) settings-intent request after launch.
      final openedSettings = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('stees/wifi_settings'),
        (call) async {
          if (call.method == 'openWifiSettings') {
            openedSettings.add('openWifiSettings');
            return null;
          }
          if (call.method == 'scanWifi') {
            return <String, dynamic>{
              'available': true,
              'networks': ['tasmota-ABCD'],
            };
          }
          return null;
        },
      );

      await tester.tap(find.text('Select Device Wi-Fi'));
      await tester.pumpAndSettle();

      // The in-app sheet is up with the scanned list; nothing external fired.
      expect(find.text('tasmota-ABCD'), findsOneWidget);
      expect(openedSettings, isEmpty,
          reason: 'the primary in-app scan button must never reach the '
              'system-settings intent (Bug 1)');

      await _unmount(tester);
    });

    testWidgets(
        'SDK 29+: picking tasmota-ABCD in the in-app list then Continue '
        'requests that exact SSID ONCE and reaches the Configure step',
        (tester) async {
      _mockSecureStorage(tester);
      final ap = _ApConnectMock();
      final api = _FlowApi();
      final tasmota = _TasmotaFake();
      final read = await _launcher(tester, api, tasmota,
          scanNetworks: ['HomeRouter', 'tasmota-ABCD'], apConnect: ap);

      // The primary action is now the in-app list, not the settings hop.
      expect(find.text('Select Device Wi-Fi'), findsOneWidget);
      expect(find.text('Open Wi-Fi Settings'), findsNothing);

      await tester.tap(find.text('Select Device Wi-Fi'));
      await tester.pumpAndSettle();
      expect(find.text('tasmota-ABCD'), findsOneWidget);
      expect(find.text('HomeRouter'), findsOneWidget);

      // Selecting is a SEPARATE step from connecting: the specifier must not
      // fire until the user taps Continue.
      await tester.tap(find.text('tasmota-ABCD'));
      await tester.pumpAndSettle();
      expect(ap.connectCalls, 0,
          reason: 'picking an SSID only stores it; Continue triggers the join');

      await _tapContinue(tester);

      expect(ap.connectCalls, 1, reason: 'single request, no retry loop');
      expect(ap.lastSsid, 'tasmota-ABCD');
      expect(find.text('Test Wi-Fi & Continue'), findsOneWidget,
          reason: 'a successful specifier join proceeds to the Configure step');

      await _fillAndProvision(tester);
      expect(read(), isTrue,
          reason: 'the programmatic path still claims end-to-end');
      expect(api.provisionCalls, 1);
      expect(ap.cancelCalls, greaterThanOrEqualTo(1),
          reason: 'the process network must be unbound on wizard teardown');

      await _unmount(tester);
    });

    testWidgets(
        'a terminal specifier failure (unavailable) surfaces the in-app error '
        'with Try-a-different-network and Open-Wi-Fi-Settings fallbacks and '
        'NEVER reaches the Configure step', (tester) async {
      _mockSecureStorage(tester);
      final ap = _ApConnectMock()..stage = 'unavailable';
      final api = _FlowApi();
      final tasmota = _TasmotaFake();
      await _launcher(tester, api, tasmota,
          scanNetworks: ['tasmota-ABCD'], apConnect: ap);

      await _pickDeviceApAndContinue(tester, 'tasmota-ABCD');

      expect(ap.connectCalls, 1,
          reason: 'exactly one request even when it fails');
      expect(find.text('Try a different network'), findsOneWidget);
      expect(find.text('Open Wi-Fi Settings'), findsOneWidget);
      expect(find.text('Test Wi-Fi & Continue'), findsNothing,
          reason: 'a failed join must not proceed to provisioning');

      await _unmount(tester);
    });

    testWidgets(
        'a permission-denied connectToAp disables the in-app flow for the '
        'session and opens Wi-Fi Settings (manual fallback)', (tester) async {
      _mockSecureStorage(tester);
      final ap = _ApConnectMock()..denyPermission = true;
      final api = _FlowApi();
      final tasmota = _TasmotaFake();
      await _launcher(tester, api, tasmota, apConnect: ap);

      // _launcher installs the default scanWifi stub; the picker interaction
      // below needs a populated scan list, so override it here (after launch).
      final openedSettings = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('stees/wifi_settings'),
        (call) async {
          if (call.method == 'openWifiSettings') {
            openedSettings.add('openWifiSettings');
            return null;
          }
          if (call.method == 'scanWifi') {
            return <String, dynamic>{'available': true, 'networks': ['tasmota-ABCD']};
          }
          return null;
        },
      );

      await _pickDeviceApAndContinue(tester, 'tasmota-ABCD');

      expect(openedSettings, ['openWifiSettings'],
          reason: 'permission denial routes to the manual settings hop');
      // The session is now manual: the primary action reverts to the settings
      // hop, so no in-app list is offered any more.
      expect(find.text('Open Wi-Fi Settings'), findsWidgets);

      await _unmount(tester);
    });
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
      expect(tasmota.commands, contains('Backlog MqttHost $_testBrokerHost; '
              'MqttPort $_testBrokerPort'));
      expect(tasmota.commands, contains('Module 23'),
          reason: 'picking 4 Relays must pin the device to the Sonoff 4CH Pro '
              'module (23), not leave it on Tasmota\u2019s stock single-relay '
              'module');
      expect(
          tasmota.commands,
          contains('Backlog Topic $_canonicalDeviceId; '
              'FullTopic %prefix%/%topic%/'),
          reason: 'Topic + FullTopic are batched into ONE Backlog so the '
              'write-triggered AP reboot happens once instead of twice');
      expect(tasmota.commands.where((c) => c.startsWith('Topic ')), isEmpty,
          reason: 'the batched identity Backlog replaces the standalone Topic '
              'write — no separate round-trip for it');
      expect(tasmota.commands.where((c) => c.startsWith('FullTopic ')), isEmpty,
          reason: 'same for FullTopic: covered by the identity Backlog');
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
        'picking 1 Relay leaves the Tasmota module untouched: no Module command '
        'is ever written', (tester) async {
      _mockSecureStorage(tester);
      final api = _FlowApi();
      final tasmota = _TasmotaFake();
      final read = await _launcher(tester, api, tasmota);

      await _tapContinue(tester);
      expect(find.text('Test Wi-Fi & Continue'), findsOneWidget);
      await _fillAndProvision(tester, deviceType: DeviceType.oneRelay);

      expect(read(), isTrue,
          reason: 'a 1-relay choice still claims (stock Tasmota already has one '
              'relay, so the module stays as-is)');
      expect(api.provisionCalls, 1);
      expect(tasmota.commands.any((c) => c.startsWith('Module ')), isFalse,
          reason: 'oneRelay maps to NO module write — the factory single-relay '
              'layout is left alone');

      await _unmount(tester);
    });

    testWidgets(
        'device that IGNORES the Module 23 write is halted by the read-back '
        'verify: still on the stock single-relay module, so it is never '
        'restarted or claimed as a 4-channel device', (tester) async {
      _mockSecureStorage(tester);
      final api = _FlowApi(); // fourRelay (default) -> Module 23
      final tasmota = _TasmotaFake()..ignoresModuleWrite = true;
      final read = await _launcher(tester, api, tasmota);

      await _tapContinue(tester);
      expect(find.text('Test Wi-Fi & Continue'), findsOneWidget);
      await _fillAndProvision(tester);

      expect(tasmota.commands, contains('Module 23'),
          reason: 'the wizard writes the 4CH Pro module for a 4-relay device');
      expect(read(), isNot(true),
          reason: 'a device that never accepted the 4-relay module must not be '
              'certified as one');
      expect(api.provisionCalls, 0,
          reason: 'the wrong-module device is never claimed');
      expect(find.textContaining('didn\u2019t accept a setting'), findsWidgets,
          reason: 'the Module read-back mismatch surfaces the errored step');
      expect(tasmota.commands.any((c) => c == 'Restart 1'), isFalse,
          reason: 'the Module verify halt happens BEFORE the final Restart 1');

      await _unmount(tester);
    });

    testWidgets(
        'identity Backlog read-back mismatch falls back to the sequential '
        'Topic/FullTopic path and the claim still commits exactly once',
        (tester) async {
      _mockSecureStorage(tester);
      final api = _FlowApi();
      // ONE Topic read-back returns a mismatch (models the device rebooting
      // mid-Backlog and dropping the write); every later read is correct, so
      // the sequential fallback re-writes Topic + FullTopic and recovers.
      final tasmota = _TasmotaFake()..failFirstTopicReadback = true;
      final read = await _launcher(tester, api, tasmota);

      await _tapContinue(tester);
      await _fillAndProvision(tester);

      // The batch was attempted first...
      expect(
          tasmota.commands,
          contains('Backlog Topic $_canonicalDeviceId; '
              'FullTopic %prefix%/%topic%/'),
          reason: 'the batching optimization ran first');
      // ...its verify caught the dropped write, and the proven sequential path
      // re-wrote both settings so the flow still verified + restarted.
      expect(tasmota.commands, contains('Topic $_canonicalDeviceId'),
          reason: 'the sequential fallback re-writes Topic after the batch '
              'verify mismatch');
      expect(tasmota.commands, contains('FullTopic %prefix%/%topic%/'),
          reason: 'and FullTopic, preserving the verify-before-restart rule');
      expect(read(), isTrue,
          reason: 'the fallback restores the settings and the claim succeeds');
      expect(api.provisionCalls, 1,
          reason: 'exactly one backend claim — the fallback is a local-config '
              'recovery, never a re-provision');
      expect(api.unclaimCalls, 0);
      expect(api.deleteCalls, 0);

      await _unmount(tester);
    });

    testWidgets(
        'temporary LAN failure after the claim keeps ownership: recoverable '
        '"Local control not ready" screen, NO unclaim, NO delete, NO second '
        'provision', (tester) async {
      _mockSecureStorage(tester);
      final api = _FlowApi();
      final tasmota = _TasmotaFake();
      final read = await _launcher(tester, api, tasmota,
          localSetup: (_, {lastIp}) async => false);

      await _tapContinue(tester);
      await _fillAndProvision(tester);

      // The claim committed BEFORE the local-setup loop even started, and the
      // ownership is FINAL regardless of local readiness.
      expect(api.provisionCalls, 1,
          reason: 'the backend claim committed exactly once');
      expect(read(), isNull,
          reason: 'a verify failure must never pop `true` by itself');
      expect(api.unclaimCalls, 0,
          reason: 'a temporary LAN miss must NEVER roll back the committed '
              'backend claim');
      // The bounded loop exhausted (first attempt + 2s/2s/3s/5s backoff), so
      // the recoverable screen is visible.
      expect(find.text('Local control not ready'), findsOneWidget);
      expect(find.textContaining('same Wi-Fi as the device'), findsOneWidget);
      expect(find.text('Retry Local Control'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
      expect(
          find.textContaining('already added to your account'), findsOneWidget,
          reason: 'the recoverable screen must state that the device is '
              'owned while local control is pending');

      // Close accepts the added device WITHOUT unclaiming or deleting it.
      await tester.ensureVisible(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(read(), isTrue,
          reason: 'Close keeps the committed claim and retires the wizard');
      expect(api.provisionCalls, 1,
          reason: 'still exactly one backend claim');
      expect(api.unclaimCalls, 0);

      await _unmount(tester);
    });

    testWidgets(
        'temporary LAN failure on the FIRST local attempt only: the bounded '
        'auto-retry succeeds on the next gap and pops true, with exactly one '
        'claim and no rollback', (tester) async {
      _mockSecureStorage(tester);
      final api = _FlowApi();
      final tasmota = _TasmotaFake();
      final setup = _ScriptedLocalSetup(1);
      final read = await _launcher(tester, api, tasmota,
          localSetup: setup.run);

      await _tapContinue(tester);
      await _fillAndProvision(tester);

      expect(read(), isTrue,
          reason: 'a temporary first-attempt miss must not cost the claim');
      expect(api.provisionCalls, 1,
          reason: 'the backend claim committed exactly once');
      expect(api.unclaimCalls, 0,
          reason: 'a transient local miss never rolls ownership back');
      expect(api.deleteCalls, 0);
      expect(setup.calls, 2,
          reason: 'first attempt failed, the next backoff-gap succeeded');
      expect(setup.lastIps, everyElement('192.168.1.10'),
          reason: 'every attempt is driven by the backend-learned lastIp');

      await _unmount(tester);
    });

    testWidgets(
        'phone network transition: the cloud device list is unreachable '
        'during the local setup, but every attempt still runs on the '
        'last-known claimed IP and the claim survives',
        (tester) async {
      _mockSecureStorage(tester);
      final api = _FlowApi();
      final tasmota = _TasmotaFake();
      // After the first (succeeding) local attempt, the phone is mid
      // transition: GET /api/devices throws for every later attempt, exactly
      // like the phone dropping off during the AP -> home-Wi-Fi handoff.
      final setup = _ScriptedLocalSetup(0,
          onCall: (calls) {
            if (calls >= 2) api.getDevicesDown = true;
          });
      final read = await _launcher(tester, api, tasmota,
          localSetup: setup.run);

      await _tapContinue(tester);
      await _fillAndProvision(tester);

      // The first attempt succeeds immediately, so the loop never needs a
      // retry — but the very next refresh (from the now-down device list) must
      // NOT throw the wizard into a terminal state.
      expect(read(), isTrue, reason: 'the claim completes');
      expect(api.provisionCalls, 1);
      expect(api.unclaimCalls, 0);
      expect(api.deleteCalls, 0);
      expect(setup.lastIps, isNotEmpty);
      expect(setup.lastIps.first, '192.168.1.10',
          reason: 'the claimed IP drives the first local attempt');

      await _unmount(tester);
    });

    testWidgets(
        'network transition during the whole local window: the auto-retry '
        'still pushes through on the last-known IP and pops true',
        (tester) async {
      _mockSecureStorage(tester);
      final api = _FlowApi();
      final tasmota = _TasmotaFake();
      // The phone cannot reach the backend for the whole local window, but the
      // local LAN is up from attempt 2 on: the loop must keep using the
      // claimed lastIp (no discovery needed) and succeed.
      final setup = _ScriptedLocalSetup(1,
          onCall: (calls) {
            if (calls >= 2) api.getDevicesDown = true;
          });
      final read = await _launcher(tester, api, tasmota,
          localSetup: setup.run);

      await _tapContinue(tester);
      await _fillAndProvision(tester);

      expect(read(), isTrue,
          reason: 'the device list being down must not stop local setup');
      expect(api.provisionCalls, 1);
      expect(api.unclaimCalls, 0);
      expect(api.deleteCalls, 0);
      expect(setup.lastIps, everyElement('192.168.1.10'),
          reason: 'the claimed IP is reused while the cloud list is unreachable');
      // The down refresh is expected and swallowed — the loop never terminated.
      expect(find.text('Local control not ready'), findsNothing);
      expect(find.text('Close'), findsNothing);

      await _unmount(tester);
    });

    testWidgets(
        'exhaustion -> Retry on the recoverable screen completes the SAME '
        'claim: no second provision, no config command, no rollback',
        (tester) async {
      _mockSecureStorage(tester);
      final api = _FlowApi();
      final tasmota = _TasmotaFake();
      // 5 failures = the whole auto window (immediate attempt + the 4 gaps in
      // kLocalSetupBackoff); the next call comes from the manual Retry.
      final setup = _ScriptedLocalSetup(5);
      final read = await _launcher(tester, api, tasmota,
          localSetup: setup.run);

      await _tapContinue(tester);
      await _fillAndProvision(tester);

      expect(find.text('Local control not ready'), findsOneWidget);
      expect(api.provisionCalls, 1);
      expect(api.unclaimCalls, 0);
      expect(api.deleteCalls, 0);
      expect(setup.calls, 5,
          reason: 'the bounded window is the immediate attempt plus exactly '
              'the 4 gaps in kLocalSetupBackoff');
      // Retry must not touch the device at all: it is local-setup only. Capture
      // the provisioning-phase command stream, tap Retry, and prove it is
      // byte-for-byte unchanged (no new config/Wi-Fi command).
      final commandsBeforeRetry = List<String>.of(tasmota.commands);
      final status5BeforeRetry =
          tasmota.commands.where((c) => c.startsWith('Status 5')).length;

      await tester.ensureVisible(find.text('Retry Local Control'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry Local Control'));
      await tester.pumpAndSettle();

      expect(read(), isTrue,
          reason: 'Retry completes the SAME claim without re-provisioning');
      expect(api.provisionCalls, 1,
          reason: 'Retry never issues a second provision/claim');
      expect(api.unclaimCalls, 0);
      expect(api.deleteCalls, 0);
      expect(tasmota.commands, commandsBeforeRetry,
          reason: 'Retry sends NO provisioning/config/Wi-Fi command — the '
              'device command stream is unchanged after it ran');
      expect(tasmota.commands.where((c) => c.startsWith('Status 5')).length,
          status5BeforeRetry,
          reason: 'Retry performs no extra identity read either');

      await _unmount(tester);
    });

    testWidgets(
        'network still down on Retry: the wizard stays recoverable with the '
        'claim intact; Close still pops true without rolling anything back',
        (tester) async {
      _mockSecureStorage(tester);
      final api = _FlowApi();
      final tasmota = _TasmotaFake();
      final setup = _ScriptedLocalSetup(1 << 30); // never succeeds
      final read = await _launcher(tester, api, tasmota,
          localSetup: setup.run);

      await _tapContinue(tester);
      await _fillAndProvision(tester);
      expect(find.text('Local control not ready'), findsOneWidget);

      await tester.ensureVisible(find.text('Retry Local Control'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry Local Control'));
      await tester.pumpAndSettle();

      // Retry ran the whole bounded loop again and returned to recoverable.
      expect(setup.calls, 10,
          reason: 'a Retry is a fresh bounded loop (immediate + gap backoff)');
      expect(find.text('Local control not ready'), findsOneWidget);
      expect(api.provisionCalls, 1);
      expect(api.unclaimCalls, 0);
      expect(api.deleteCalls, 0);

      await tester.ensureVisible(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(read(), isTrue,
          reason: 'Close accepts the device while it stays claimed');
      expect(api.provisionCalls, 1);
      expect(api.unclaimCalls, 0);
      expect(api.deleteCalls, 0);

      await _unmount(tester);
    });

    testWidgets(
        'Continue in background accepts the device (claim intact) and finishes '
        'local setup off the critical path', (tester) async {
      _mockSecureStorage(tester);
      final api = _FlowApi();
      final tasmota = _TasmotaFake();
      // The auto window (5 attempts) always fails; the background continuation
      // adds exactly 2 more (immediate + one bounded gap) then stops.
      final setup = _ScriptedLocalSetup(1 << 30);
      final read = await _launcher(tester, api, tasmota,
          localSetup: setup.run);

      await _tapContinue(tester);
      await _fillAndProvision(tester);

      expect(find.text('Local control not ready'), findsOneWidget);
      expect(find.text('Continue in background'), findsOneWidget);
      expect(setup.calls, 5,
          reason: 'the auto window exhausted exactly as with Close/Retry');

      await tester.ensureVisible(find.text('Continue in background'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue in background'));
      await tester.pumpAndSettle();

      // Accepted immediately, the committed claim untouched, wizard retired —
      // identical ownership semantics to Close.
      expect(read(), isTrue,
          reason: 'Continue pops true like Close — the wizard never blocks');
      expect(api.provisionCalls, 1);
      expect(api.unclaimCalls, 0);
      expect(api.deleteCalls, 0);

      // The bounded background continuation keeps working after the pop and
      // uses the known claimed IP (no provisioning commands, ever).
      expect(setup.calls, 6,
          reason: 'the first background attempt runs immediately off the '
              'critical path');
      await tester.pump(kLocalSetupBackoff[0]);
      await tester.pump(const Duration(milliseconds: 50));
      expect(setup.calls, 7,
          reason: 'the second (last) background attempt ran after the bounded '
              'gap and stopped');
      expect(api.provisionCalls, 1,
          reason: 'background continuation never re-provisions');

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
        'Gate B authority: even with an EMPTY session snapshot and a silent '
        'backend pre-flight, an existing MAC is stopped at the provisioning '
        'boundary before ANY config command', (tester) async {
      _mockSecureStorage(tester);
      // Models the bypass scenario: the wizard-start snapshot did not capture
      // the MAC (load failed/raced on a reopen) and the backend pre-flight
      // silently passed (no internet on the Tasmota AP). The authoritative
      // boundary gate (Gate B) must still stop the device at _provision, before
      // a single provisioning/configuration command is sent.
      final api = _FlowApi(); // registeredAtStart=false -> empty snapshot; preflightStatus=notFound
      final tasmota = _TasmotaFake();
      final read = await _launcher(tester, api, tasmota,
          isRegistered: (canonical) async => canonical == _canonicalDeviceId);

      // Gate A and the backend pre-flight both passed -> the wizard reached the
      // Configure form (proving this test targets the boundary gate in _provision).
      await _tapContinue(tester);
      expect(find.text('Test Wi-Fi & Continue'), findsOneWidget);

      await _fillAndProvision(tester);

      // Gate B froze the wizard at the provisioning boundary.
      expect(find.textContaining('delete it before claiming it again'),
          findsOneWidget);
      expect(api.provisionCalls, 0, reason: 'no claim: the boundary gate stopped it');
      expect(api.preflightCalls, 1,
          reason: 'the legacy backend pre-flight ran at AP detection and passed '
              '— it must NOT be the last line of defense');
      // Only the two read-only Status 5 identity reads happened.
      expect(tasmota.commands.where((c) => c.startsWith('Status 5')).length, 2,
          reason: 'identity read at AP detection and again at Apply');
      expect(tasmota.commands.where((c) => !c.startsWith('Status 5')), isEmpty,
          reason: 'an existing MAC must NEVER receive a config/Wi-Fi command, '
              'even when every earlier best-effort gate was fooled');
      expect(tasmota.provisioned, isFalse);
      expect(read(), isNot(true));

      await _unmount(tester);
    });

    testWidgets(
        'reopening Add Device after Close re-blocks the same existing device on '
        'every attempt (3x) — widget recreated each time', (tester) async {
      _mockSecureStorage(tester);
      // One account, one physical device, one shared Tasmota responder. Each
      // loop iteration launches a BRAND-NEW wizard widget tree (= widget
      // recreation), exactly like the user closing Add Device and reopening it.
      final api = _FlowApi()..registeredAtStart = true;
      final tasmota = _TasmotaFake();
      for (var attempt = 1; attempt <= 3; attempt++) {
        final read = await _launcher(tester, api, tasmota);
        await _tapContinue(tester);

        expect(find.textContaining('delete it before claiming it again'),
            findsOneWidget,
            reason: 'attempt $attempt must freeze into the duplicate terminal');
        expect(find.text('Test Wi-Fi & Continue'), findsNothing,
            reason: 'attempt $attempt must never reach the Configure form');
        expect(find.text('Remove Device'), findsNothing,
            reason: 'the wizard never offers a delete/re-claim path');
        expect(find.text('Delete'), findsNothing);
        expect(api.provisionCalls, 0,
            reason: 'attempt $attempt must never claim the device');
        expect(read(), isNot(true),
            reason: 'attempt $attempt must never pop success');

        await _unmount(tester);
      }
      expect(api.preflightCalls, 0,
          reason: 'every stop happened fully offline at the snapshot/boundary '
              'gate with NO backend round-trip');
      expect(api.unclaimCalls, 0,
          reason: 'nothing was ever claimed, so nothing is ever unclaimed');
      expect(tasmota.provisioned, isFalse,
          reason: 'Close is NOT a transition to claimable — the MAC stays '
              'blocked until it is deleted from the Devices page');
      expect(tasmota.commands.every((c) => c == 'Status 5'), isTrue,
          reason: 'across all 3 attempts only the read-only identity probe '
              'touched the device — zero provisioning commands');
      expect(tasmota.commands.length, 3 * 1,
          reason: 'exactly one identity read per attempt');
    });

    testWidgets(
        'reopen on the OFFLINE Tasmota AP: the PERSISTED account snapshot '
        '(empty display mirror) still blocks the same MAC — zero provisioning '
        'commands', (tester) async {
      _mockSecureStorage(tester);
      // Phone B logged into the same account. Its display mirror is EMPTY (the
      // device was claimed from Phone A), but a successful GET /api/devices
      // refresh while online captured the MAC into the persisted account
      // snapshot. Now the phone is on the offline Tasmota AP.
      final cache = LocalDeviceCache();
      await cache.saveAccountSnapshot(const [
        {'deviceId': _canonicalDeviceId, 'name': 'Controller', 'channels': 4},
      ]);
      expect(await cache.cachedDevices(), isEmpty,
          reason: 'display mirror is empty — only the account snapshot knows '
              'the device (the cross-client case)');

      final api = _FlowApi()..offline = true;
      final tasmota = _TasmotaFake();
      final read = await _launcher(tester, api, tasmota,
          useRealBoundaryCheck: true, repo: _offlineRepo());

      await _tapContinue(tester);

      // The persisted snapshot certifies the duplicate fully offline.
      expect(find.textContaining('delete it before claiming it again'),
          findsOneWidget);
      expect(find.text('Test Wi-Fi & Continue'), findsNothing,
          reason: 'the reopened wizard must never reach the Configure form');
      expect(api.preflightCalls, 0,
          reason: 'the persisted snapshot certifies offline — no backend '
              'pre-flight round-trip is needed');
      expect(api.provisionCalls, 0);
      expect(tasmota.commands, ['Status 5'],
          reason: 'only the read-only identity probe touched the device');
      expect(tasmota.provisioned, isFalse);
      expect(read(), isNot(true));

      await _unmount(tester);
    });

    testWidgets(
        'repeated recreation (3x) offline with a fresh repository each time: '
        'the persisted snapshot keeps blocking the registered MAC', (tester) async {
      _mockSecureStorage(tester);
      final cache = LocalDeviceCache();
      await cache.saveAccountSnapshot(const [
        {'deviceId': _canonicalDeviceId, 'name': 'Controller', 'channels': 4},
        {'deviceId': 'AAAAAAAAAAAA', 'name': 'Gate', 'channels': 4},
      ]);
      final api = _FlowApi()..offline = true;
      final tasmota = _TasmotaFake();
      for (var attempt = 1; attempt <= 3; attempt++) {
        final read = await _launcher(tester, api, tasmota,
            useRealBoundaryCheck: true, repo: _offlineRepo());
        await _tapContinue(tester);

        expect(find.textContaining('delete it before claiming it again'),
            findsOneWidget,
            reason: 'attempt $attempt must freeze into the duplicate terminal');
        expect(find.text('Test Wi-Fi & Continue'), findsNothing,
            reason: 'attempt $attempt must never reach the Configure form');
        expect(api.provisionCalls, 0,
            reason: 'attempt $attempt must never claim the device');
        expect(tasmota.commands.where((c) => c.startsWith('Status 5')).length,
            attempt,
            reason: 'one identity read per attempt, nothing else');
        expect(tasmota.commands.where((c) => !c.startsWith('Status 5')), isEmpty,
            reason: 'across all attempts the registered MAC never receives a '
                'config/Wi-Fi command');
        expect(tasmota.provisioned, isFalse);
        expect(read(), isNot(true));

        await _unmount(tester);
      }
      expect(api.preflightCalls, 0,
          reason: 'every stop happened fully offline at the snapshot gate');
      expect(api.unclaimCalls, 0);
    });

    testWidgets(
        'network failure never erases the persisted account snapshot', (tester) async {
      _mockSecureStorage(tester);
      final cache = LocalDeviceCache();
      await cache.saveAccountSnapshot(const [
        {'deviceId': _canonicalDeviceId, 'name': 'Controller', 'channels': 4},
      ]);
      final api = _FlowApi()..offline = true;
      final tasmota = _TasmotaFake();
      final read = await _launcher(tester, api, tasmota,
          useRealBoundaryCheck: true, repo: _offlineRepo());

      await _tapContinue(tester);

      expect(find.textContaining('delete it before claiming it again'),
          findsOneWidget);
      // The failed GET /api/devices must NOT have erased the stored knowledge.
      expect(await cache.loadAccountSnapshotMacs(), contains(_canonicalDeviceId),
          reason: 'a network failure is not evidence of absence — the persisted '
              'snapshot must survive a failed refresh');
      expect(api.provisionCalls, 0);
      expect(read(), isNot(true));

      await _unmount(tester);
    });

    testWidgets(
        'first-time offline new device with NO persisted snapshot: provisioning '
        'still proceeds (real Gate B path, backend remains the net)', (tester) async {
      _mockSecureStorage(tester);
      // Brand-new account, never refreshed, straight onto the offline AP.
      final api = _FlowApi()..offline = true;
      final tasmota = _TasmotaFake();
      final read = await _launcher(tester, api, tasmota,
          useRealBoundaryCheck: true, repo: _offlineRepo());

      await _tapContinue(tester);
      // No knowledge exists -> the wizard reaches Configure.
      expect(find.text('Test Wi-Fi & Continue'), findsOneWidget);
      await _fillAndProvision(tester);

      // The genuinely unknown state must not fail closed: a new device claims.
      expect(read(), isTrue, reason: 'unknown is not a false duplicate');
      expect(api.provisionCalls, 1);
      expect(tasmota.provisioned, isTrue);

      await _unmount(tester);
    });

    testWidgets(
        'delete then reclaim: the persisted snapshot drops the MAC, so an '
        'offline reopen no longer blocks the same device', (tester) async {
      _mockSecureStorage(tester);
      // The account's persisted snapshot contains the device.
      final cache = LocalDeviceCache();
      await cache.saveAccountSnapshot(const [
        {'deviceId': _canonicalDeviceId, 'name': 'Controller', 'channels': 4},
      ]);

      // Delete it from the Devices page (the real authenticated delete flow).
      final api = _StatefulApi()..preflightStatus = DeviceDuplicateStatus.mine;
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
      // The delete removed the MAC from the persisted account snapshot.
      expect(await cache.loadAccountSnapshotMacs(),
          isNot(contains(_canonicalDeviceId)),
          reason: 'reopening Add Device after deletion must not falsely block');
      await _unmount(tester);

      // Re-claim the SAME device while offline: with the MAC dropped from the
      // snapshot and the backend confirming the deletion, the device claims.
      final tasmota = _TasmotaFake();
      final read = await _launcher(tester, api, tasmota,
          useRealBoundaryCheck: true, repo: _offlineRepo());

      await _tapContinue(tester);
      // Offline + snapshot without M: unknown is not a false duplicate.
      expect(find.text('Test Wi-Fi & Continue'), findsOneWidget);
      await _fillAndProvision(tester);

      expect(read(), isTrue,
          reason: 'after a successful DELETE the same device claims afresh, '
              'even offline');
      expect(api.provisionCalls, 1);
      expect(tasmota.provisioned, isTrue);

      await _unmount(tester);
    });

    testWidgets(
        'Add Device entry refreshes and persists the account snapshot while '
        'still on the normal network', (tester) async {
      _mockSecureStorage(tester);
      // The cloud list contains the account's device before the wizard opens.
      final api = _FlowApi()..registeredAtStart = true;
      expect(await LocalDeviceCache().loadAccountSnapshotMacs(), isNull,
          reason: 'no snapshot yet until Add Device is entered');

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
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      // The pre-AP refresh ran on the normal network and persisted the MAC.
      expect(await LocalDeviceCache().loadAccountSnapshotMacs(),
          contains(_canonicalDeviceId),
          reason: 'the snapshot is captured BEFORE the wizard can enter the '
              'offline Tasmota AP, so a later offline duplicate check is '
              'decided from persisted knowledge');
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
      // Topic+FullTopic are batched into a single Backlog (one write-triggered
      // reboot instead of two), so the identity is asserted through it.
      expect(
          tasmota.commands,
          contains('Backlog Topic $_canonicalDeviceId; '
              'FullTopic %prefix%/%topic%/'));
      expect(tasmota.commands.where((c) => c.startsWith('Topic ')), isEmpty,
          reason: 'the identity is written through the batch, not a standalone '
              'Topic write');
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

    testWidgets(
        'broker-info pre-fetch failure BLOCKS the wizard at Connect: no AP '
        'probe, no probe timer, no device commands, no claim', (tester) async {
      _mockSecureStorage(tester);
      // The phone is offline / the backend is unreachable at wizard start, so
      // the broker address can NEVER be learned. Provisioning to Tasmota's
      // factory broker is the bug this regression guards against — the wizard
      // must hard-stop BEFORE the user is sent to the offline setup AP.
      final api = _FlowApi()..brokerInfoDown = true;
      final tasmota = _TasmotaFake();
      final read = await _launcher(tester, api, tasmota);

      expect(find.textContaining('Could not load the MQTT broker'),
          findsOneWidget,
          reason: 'the blocking broker error renders on the Connect step');

      await _tapContinue(tester);

      expect(find.text('Test Wi-Fi & Continue'), findsNothing,
          reason: 'broker-down must never reach the Configure form');
      expect(find.textContaining('Could not load the MQTT broker'),
          findsOneWidget,
          reason: 'the blocking error survives the Continue attempt');
      expect(api.provisionCalls, 0, reason: 'nothing is ever claimed');
      expect(tasmota.provisioned, isFalse);
      expect(tasmota.commands, isEmpty,
          reason: 'no AP probe and therefore zero device touches: _startSearch '
              'returned before _startApDetection armed its probe timer');
      expect(read(), isNot(true));

      await tester.pump(const Duration(seconds: 30));
      expect(tasmota.commands, isEmpty,
          reason: 'even after the AP probe grace elapses the wizard never '
              'probed — the probe timer was never armed');

      await _unmount(tester);
    });

    testWidgets(
        'device stuck on TASMOTA\u2019S FACTORY broker (broker.emqx.io) is '
        'halted by the read-back verify: even a device that never got the MQTT '
        'write is not certified or claimed', (tester) async {
      _mockSecureStorage(tester);
      // Real-hardware regression: write "MqttHost mqtt.stees.test" but the
      // device still reports broker.emqx.io on read-back (e.g. it ignored the
      // command, rebooted, or the Backlog write was dropped). The per-key
      // read-back verify MUST catch the mismatch and abort before Restart 1.
      final api = _FlowApi(); // broker served is mqtt.stees.test
      final tasmota = _TasmotaFake()..stuckOnFactoryBroker = true;
      final read = await _launcher(tester, api, tasmota);

      await _tapContinue(tester);
      expect(find.text('Test Wi-Fi & Continue'), findsOneWidget);
      await _fillAndProvision(tester);

      expect(read(), isNot(true), reason: 'must never pop success');
      expect(api.provisionCalls, 0,
          reason: 'a device on the wrong broker must never be claimed');
      expect(find.textContaining('didn\u2019t accept a setting'),
          findsWidgets,
          reason: 'the read-back (MqttHost/MqttPort) failure is surfaced');
      expect(tasmota.commands.any((c) => c == 'Restart 1'), isFalse,
          reason: 'the verify halt happens BEFORE the final Restart 1');
      expect(tasmota.commands.any((c) => c.startsWith('Backlog')),
          isTrue,
          reason: 'the config sweep ran (broker/identity wrote) but the read '
              'verify stopped the flow before restart');

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