import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:url_launcher/url_launcher.dart';

import '../models/device_type.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/provisioning_service.dart';
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';
import '../widgets/device_type_picker.dart';

enum _Step { connect, provision, waiting }

/// Result of the full Tasmota configuration sweep. [wifiTestFailed] is a
/// distinct outcome so a failed Wi-Fi pre-flight test stays on Configure with a
/// Wi-Fi-specific message (never a generic power-cycle/factory-reset error).
enum _ConfigOutcome { ok, wifiTestFailed, configFailed }

/// STEES provisioning wizard. Replaces the workflow of typing MQTT/Wi-Fi
/// settings into the raw Tasmota web page, using STEES-styled screens and the
/// existing backend claim endpoint.
class ProvisionDeviceScreen extends StatefulWidget {
  const ProvisionDeviceScreen({super.key});

  @override
  State<ProvisionDeviceScreen> createState() => _ProvisionDeviceScreenState();
}

class _ProvisionDeviceScreenState extends State<ProvisionDeviceScreen>
    with WidgetsBindingObserver {
  static const String _deviceUrl = 'http://192.168.4.1';

  // Expected Tasmota AP SSID used only for the Wi-Fi binding sanity check.
  // The trailing XXXX acts as a tasmota- prefix wildcard in MainActivity.
  static const String _tasmotaApSsid = 'tasmota-XXXX';

  // Give up waiting for the device to appear on the backend after this long.
  // Must comfortably exceed the backend's recentDevices window so a device that
  // was briefly seen is not missed, but not spin forever on a lost network.
  static const Duration _waitDeadline = Duration(minutes: 6);

  // Cosmetic pacing of the WAIT stage labels: the device reboots and joins
  // home Wi-Fi during this window, before it can reach the MQTT broker.
  static const Duration _stageAdvance = Duration(seconds: 25);

  // Absolute bound for the whole Tasmota configuration sweep (broker, topic,
  // fulltopic, device name, Wi-Fi, verify, restart). Each command already has
  // its own HTTP timeout and retry loop; this is a coarse backstop so a device
  // that wedges mid-sweep cannot pin the UI forever. On expiry the wizard shows
  // a bounded recovery (power-cycle + retry), never blind auto-retries.
  static const Duration _configStepDeadline = Duration(minutes: 3);

  // WifiTest3 pre-flight validation (AP mode only, mode 3 = test credentials
  // WITHOUT persisting them or restarting). The start HTTP call returns
  // {"WifiTest3":"Testing"} immediately; the firmware runs the test in the
  // background (~9-10s on 15.5.0) and we poll the data-less WifiTest command
  // until the status settles. These bounds keep a stuck/slow device from
  // blocking provisioning forever, while still allowing the test to complete.
  static const Duration _wifiTestHttpTimeout = Duration(seconds: 4);
  static const Duration _wifiTestPollInterval = Duration(seconds: 1);
  static const Duration _wifiTestTotalDeadline = Duration(seconds: 20);

  static const MethodChannel _wifiBindChannel =
      MethodChannel('stees/wifi_binding');

  bool _wifiBound = false;

  final _api = ApiService();

  final _ssidCtl = TextEditingController();
  final _wifiPassCtl = TextEditingController();
  final _mqttBrokerCtl = TextEditingController(text: 'broker.emqx.io');
  final _mqttPortCtl = TextEditingController(text: '1883');
  final _mqttUserCtl = TextEditingController();
  final _mqttPassCtl = TextEditingController();
  final _deviceNameCtl = TextEditingController();

  final FocusNode _wifiPassFocus = FocusNode();

  bool _manualWifi = false;
  DeviceType _deviceType = DeviceType.fourRelay;

  _Step _step = _Step.connect;
  // Explicit state machine. The UI renders only [provisionUserLabel]; the log
  // emits a measured trace for every phase (see provisioning_service.dart).
  ProvisionState _state = ProvisionState.idle;
  final ProvisionTrace _trace = ProvisionTrace();
  bool _searching = false;
  bool _provisioning = false;
  String? _error;
  Timer? _reachTimer;
  Timer? _waitTimer;
  DateTime? _waitStart;

  // Backend-issued provisioning session. The deviceId (== MQTT topic) is
  // issued by the backend and serves as the possession secret; the one-time
  // claim token is returned at session creation and must be replayed to claim.
  String? _sessionId;
  String? _claimToken;
  String _issuedDeviceId = '';
  String? _hardwareId;
  io.Socket? _provisionSocket;
  bool _watchAcked = false;
  bool _creating = false;
  bool _claimed = false;
  int? _sessionCreateStatus;
  // Whether the terminal failure was a wait-deadline (device never seen) - the
  // only case where "Wait a bit longer" makes sense. Claim conflicts and other
  // terminal errors get a Close-only recovery instead of a pointless re-arm.
  bool _allowWaitRetry = false;
  // Set when the wizard enters the Reconfigure-Wi-Fi recovery flow. Reuses the
  // existing provisioning session / deviceId / claim token - a Wi-Fi correction
  // is never a new session. Drives the recovery-aware connect screen.
  bool _recoveryMode = false;
  // Paces the WAIT stage labels: Wi-Fi for the early device-reboot window, then
  // MQTT. Labels are cosmetic pacing, never a functional timeout.
  Timer? _waitStageTimer;

  // Pre-flight Wi-Fi validation (Tasmota WifiTest3) is a local device operation
  // that runs while the phone is still bound to the Tasmota AP. Keeps the
  // testing state and the classifier result so the Configure screen can render
  // a specific error and stay put (no Restart, no session change).
  WifiTestResult _wifiTestResult = WifiTestResult.unknown;

  String get _phaseLabel {
    switch (_step) {
      case _Step.connect:
        return 'AP_CONNECT';
      case _Step.provision:
        return 'CONFIGURING';
      case _Step.waiting:
        return 'WAITING_FOR_DEVICE';
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // PHASE 0 (ONLINE): create the backend provisioning session NOW, while the
    // phone is still on normal Internet - before the user switches to the
    // Tasmota SoftAP, which provides no WAN. This is the only guaranteed-online
    // moment in the wizard. Everything after this must never need the backend.
    unawaited(_ensureSessionSilent());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Phase-dependent resume handling. The AP probe / Wi-Fi binding must run
    // ONLY during the initial "connect phone to Tasmota AP" phase. After the
    // Tasmota Restart command succeeds, the AP is EXPECTED to disappear, so we
    // must never re-probe 192.168.4.1 or show an AP connection error again.
    if (state != AppLifecycleState.resumed) {
      // Leaving the app (e.g. jumping into Wi-Fi Settings) halts the probing
      // timer. Detection is restarted from a clean slate on resume.
      if (_step == _Step.connect) {
        _reachTimer?.cancel();
        // Bump the generation so any in-flight probe cannot commit stale state.
        _apProbeGen++;
      }
      return;
    }
    if (!mounted) return;
    switch (_step) {
      case _Step.connect:
        debugPrint('[PROVISION] phase=$_phaseLabel lifecycle resumed - rechecking Tasmota AP');
        // Re-prepare the backend session in the background while the phone
        // still has internet (best-effort; `_startSearch` gates on it later).
        unawaited(_ensureSessionSilent());
        _startApDetection();
      case _Step.provision:
        debugPrint('[PROVISION] phase=$_phaseLabel lifecycle resumed - AP probe skipped (configuring)');
      case _Step.waiting:
        debugPrint('[PROVISION] phase=$_phaseLabel lifecycle resumed - AP probe skipped: provisioning already completed');
        _waitTimer?.cancel();
        _pollSessionStatus();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_releaseWifiBinding());
    _reachTimer?.cancel();
    _waitTimer?.cancel();
    _waitStageTimer?.cancel();
    _closeProvisionSocket();
    _ssidCtl.dispose();
    _wifiPassCtl.dispose();
    _mqttBrokerCtl.dispose();
    _mqttPortCtl.dispose();
    _mqttUserCtl.dispose();
    _mqttPassCtl.dispose();
    _deviceNameCtl.dispose();
    _wifiPassFocus.dispose();
    super.dispose();
  }

  void _closeProvisionSocket() {
    _watchAcked = false;
    _provisionSocket?.disconnect();
    _provisionSocket?.dispose();
    _provisionSocket = null;
  }

  // ──────────────────────────────────────────────────────────
  // Step 1 - connect to device Wi-Fi + reachability
  // ──────────────────────────────────────────────────────────

  static const MethodChannel _wifiSettingsChannel =
      MethodChannel('stees/wifi_settings');

  Future<void> _openWifiSettings() async {
    try {
      if (Theme.of(context).platform == TargetPlatform.iOS) {
        await launchUrl(
          Uri.parse('App-Prefs:root=WIFI'),
          mode: LaunchMode.externalApplication,
        );
      } else {
        await _wifiSettingsChannel.invokeMethod<void>('openWifiSettings');
      }
    } catch (_) {
      _setError('Could not open Wi-Fi settings.');
    }
  }

  Future<void> _startSearch() async {
    debugPrint('[PROVISION] phase=$_phaseLabel start search');
    // PHASE 1 (OFFLINE-AP): the phone is already on the Tasmota AP now (the
    // user picked it in Wi-Fi Settings and returned here). No backend call is
    // allowed from this point. The session MUST have been created during
    // PHASE 0 (initState/resume while online).
    if (_sessionId == null || _issuedDeviceId.isEmpty) {
      debugPrint('[PROVISION] OFFLINE_AP_PHASE_START');
      debugPrint('[PROVISION] CLOUD_CALL_BLOCKED_DURING_AP session missing');
      if (mounted) {
        setState(() {
          _searching = false;
          _error = _sessionErrorFor(_sessionCreateStatus);
        });
      }
      return;
    }
    debugPrint('[PROVISION] OFFLINE_AP_PHASE_START session=$_sessionId');
    debugPrint('[PROVISION] AP_CONNECT_START');
    _startApDetection();
  }

  // Bind this process's sockets to the CURRENTLY ACTIVE Wi-Fi network (the one
  // the user manually selected in Android Wi-Fi settings). Unlike the old
  // requestNetwork() approach this never lets Android pick a different network
  // (e.g. the router) — getActiveNetwork() returns exactly the user's choice.
  Future<void> _ensureBoundToWifi() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) return;
    if (_wifiBound) return;
    final expected = _tasmotaApSsid;
    try {
      final info = await _wifiBindChannel.invokeMethod<Map<dynamic, dynamic>>(
        'ensureBoundToActiveWifi',
        {'expectedSsid': expected},
      );
      final activeSsid = info?['activeSsid']?.toString() ?? '<unknown>';
      debugPrint('[PROVISION] expected SSID: $expected');
      debugPrint('[PROVISION] active SSID: $activeSsid');
      final matched = info?['matched'] == true;
      _wifiBound = info?['bound'] == true;
      if (_wifiBound) {
        debugPrint('[PROVISION] active Wi-Fi network matched');
        debugPrint('[PROVISION] process bound to active Wi-Fi');
        await _logNetworkInfo('after bind');
      } else if (!matched) {
        // Wrong SSID is treated as a transient condition here — the AP probe on
        // 192.168.4.1 is the authority, so we keep retrying inside the grace
        // window and let the loop surface an error only after it is exhausted.
        debugPrint('[PROVISION] wrong Wi-Fi network');
      } else {
        debugPrint('[PROVISION] could not bind to active Wi-Fi');
      }
    } catch (e) {
      debugPrint('[PROVISION] wifi bind failed: $e');
    }
  }

  Future<void> _releaseWifiBinding() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) return;
    try {
      await _wifiBindChannel.invokeMethod<void>('releaseWifiBinding');
      debugPrint('[PROVISION] wifi binding released');
    } catch (_) {}
    _wifiBound = false;
  }

  Future<bool> _isReachable() async {
    try {
      debugPrint('[PROVISION] probing $_deviceUrl');
      final res =
          await http.get(Uri.parse(_deviceUrl)).timeout(const Duration(seconds: 3));
      // Any HTTP response counts as reachable, regardless of status code.
      debugPrint('[PROVISION] probe status=${res.statusCode}');
      return true;
    } catch (_) {
      debugPrint('[PROVISION] probe unreachable (connection failed or timeout)');
      _wifiBound = false;
      await _logNetworkInfo('probe failed');
      return false;
    }
  }

  // Confirms the setup AP is actually responding on 192.168.4.1 before any
  // cmnd is sent. If the phone is on the home router (device already left its
  // AP), commands would just time out and the user would see "nothing happen".
  Future<bool> _ensureSetupApReachable() async {
    await _ensureBoundToWifi();
    for (var attempt = 1; attempt <= 5; attempt++) {
      if (await _isReachable()) return true;
      debugPrint('[PROVISION] setup AP probe attempt $attempt failed, retrying');
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    debugPrint('[PROVISION] setup AP not reachable on 192.168.4.1');
    return false;
  }

  // After a restart-triggering write (Topic/FullTopic) the device reboots and
  // returns to AP mode while home Wi-Fi is not yet configured. Wait (with
  // re-binding) until it is reachable again, then let the caller read settings
  // back. The device only leaves the AP for good once Restart 1 fires with the
  // home SSID present.
  Future<bool> _waitForDeviceOnAp() async {
    for (var attempt = 1; attempt <= 20; attempt++) {
      await _ensureBoundToWifi();
      if (await _isReachable()) {
        debugPrint('[PROVISION] device back on setup AP after write-triggered reboot');
        return true;
      }
      if (attempt == 20) {
        debugPrint('[PROVISION] device did not return to setup AP after reboot');
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    return false;
  }

  Future<bool> _logNetworkInfo(String tag) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) return false;
    try {
      final info = await _wifiBindChannel
          .invokeMethod<Map<dynamic, dynamic>>('getNetworkInfo');
      debugPrint(
          '[PROVISION] $tag: bound=${info?['bound']} wifi=${info?['wifi']} '
          'internet=${info?['internet']} validated=${info?['validated']}');
      return info?['internet'] == true;
    } catch (e) {
      debugPrint('[PROVISION] $tag: could not read network info: $e');
      return false;
    }
  }

  // ──────────────────────────────────────────────────────────
  // Step 1 - AP detection (retry loop, phase-gated)
  // ──────────────────────────────────────────────────────────

  // Android needs a moment after returning from Wi-Fi Settings before the
  // active network, the process binding and routing to 192.168.4.1 are usable.
  // A single failed probe is a TRANSIENT condition — never an error.
  static const Duration _stabilizeDelay = Duration(milliseconds: 1200);
  static const Duration _probeRetryInterval = Duration(milliseconds: 2500);
  static const Duration _apProbeGrace = Duration(seconds: 20);

  // Generation counter used to guarantee only ONE detection process is ever
  // running. Every new detection cycle (resume / Continue / retry) bumps this
  // and re-arms a single Timer; stale attempts bail out early.
  int _apProbeGen = 0;
  DateTime? _apProbeStart;
  int _apAttempt = 0;

  void _startApDetection() {
    if (_step != _Step.connect) return;
    _reachTimer?.cancel();
    _apProbeGen++;
    final gen = _apProbeGen;
    _apProbeStart = DateTime.now();
    _apAttempt = 0;
    _wifiBound = false;
    debugPrint('[PROVISION] phase=$_phaseLabel app resumed/restarting detection, waiting for network stabilization');
    if (mounted) {
      setState(() {
        _searching = true;
        _error = null;
      });
    }
    // Small stabilization delay BEFORE the first probe (not after a failure).
    _reachTimer = Timer(_stabilizeDelay, () => _runApProbe(gen));
  }

  Future<void> _runApProbe(int gen) async {
    if (!mounted || _step != _Step.connect || gen != _apProbeGen) return;
    _apAttempt++;
    debugPrint('[PROVISION] AP detection attempt=$_apAttempt');
    // Best-effort bind to the active Wi-Fi network. Binding can also fail
    // transiently right after the network transition — not fatal, probe next.
    await _ensureBoundToWifi();
    if (!mounted || _step != _Step.connect || gen != _apProbeGen) return;

    if (await _isReachable()) {
      _reachTimer?.cancel();
      _waitStageTimer?.cancel();
      debugPrint('[PROVISION] device AP reachable');
      if (!mounted || _step != _Step.connect) return;
      _trace.enter(ProvisionPhase.ap, 'AP_DETECTED');
      debugPrint('[PROVISION] AP_CONNECTED');
      if (_recoveryMode) {
        traceLog('RECOVERY', 'AP_FOUND total=${_trace.elapsedMs}ms');
        traceLog('RECONFIGURE',
            'START total=${_trace.elapsedMs}ms session=$_sessionId');
      }
      setState(() {
        _searching = false;
        _error = null;
        _step = _Step.provision;
        _state = ProvisionState.apConnected;
      });
      debugPrint('[PROVISION] AP detected, entering configuration');
      return;
    }
    if (!mounted || _step != _Step.connect || gen != _apProbeGen) return;

    // Not reachable YET. Keep the neutral state and retry within the grace
    // window. No error is shown during this phase.
    final elapsed = DateTime.now().difference(_apProbeStart!);
    if (elapsed < _apProbeGrace) {
      _reachTimer?.cancel();
      _reachTimer = Timer(_probeRetryInterval, () => _runApProbe(gen));
      return;
    }

    // Grace period exhausted — only now is a failure surfaced to the user.
    if (_recoveryMode) {
      traceLog('RECOVERY', 'AP_NOT_FOUND total=${_trace.elapsedMs}ms');
    }
    debugPrint('[PROVISION] AP detection grace ${_apProbeGrace.inSeconds}s elapsed, giving up');
    if (!mounted || _step != _Step.connect) return;
    setState(() {
      _searching = false;
      _error =
          "Could not find the device. Make sure you're connected to the Tasmota Wi-Fi and try again.";
    });
    debugPrint('[PROVISION] grace period exhausted, showing final error');
  }

  // The device identity is NO LONGER derived from the display name. It is
  // issued by the backend when the provisioning session is created
  // ([[_issuedDeviceId]]) and is immutable for the life of the device. Renaming
  // the device later only edits the display name on the Device record - it
  // never changes the MQTT topic or identity.

  // ──────────────────────────────────────────────────────────
  // Step 3 - provision via Tasmota HTTP + restart
  // ──────────────────────────────────────────────────────────

  Future<void> _provision() async {
    final name = _deviceNameCtl.text.trim();
    final ssid = _ssidCtl.text.trim();
    if (name.isEmpty) {
      _setError('Enter a Device Name.');
      return;
    }
    if (ssid.isEmpty) {
      _setError('Select or enter your home Wi-Fi network.');
      return;
    }
    setState(() {
      _provisioning = true;
      _error = null;
    });
    // The backend-issued deviceId MUST already exist (created in PHASE 0 while
    // online). No `_createSession()` call is made here: we are now in the
    // OFFLINE-AP phase and the backend is unreachable by design.
    if (_sessionId == null || _issuedDeviceId.isEmpty) {
      debugPrint('[PROVISION] CLOUD_CALL_BLOCKED_DURING_AP session missing');
      if (mounted) {
        setState(() {
          _provisioning = false;
          _error = _sessionErrorFor(_sessionCreateStatus);
        });
      }
      return;
    }

    if (!await _ensureSetupApReachable()) {
      if (!mounted) return;
      setState(() {
        _provisioning = false;
        _error = 'The device is not reachable on its setup Wi-Fi anymore. '
            'It likely already connected to your home network; power-cycle it '
            'and, if it reconnects instead of showing the tasmota-XXXX AP, '
            'factory-reset it (hold its button ~10s), then try again.';
      });
      return;
    }
    setState(() {
      _state = ProvisionState.configuringBroker;
    });

    // Anchor the claim to the physical hardware. Status 5 is a read-only query
    // (no reboot) so it is safe to add on the setup AP. The MAC is carried in
    // memory and sent with the claim - NEVER uploaded here (no backend during
    // the AP phase); the backend joins it to the session on claim.
    final mac = await _readDeviceMac();
    if (mac != null && mac.isNotEmpty) {
      _hardwareId = mac;
      debugPrint('[PROVISION] device MAC read locally (sent on claim): $mac');
    }

    final outcome = await _sendTasmotaConfig().timeout(
      _configStepDeadline,
      onTimeout: () {
        debugPrint(
            '[PROVISION] config step exceeded ${_configStepDeadline.inMinutes}m deadline');
        return _ConfigOutcome.configFailed;
      },
    );
    if (!mounted) return;
    if (outcome == _ConfigOutcome.wifiTestFailed) {
      // Wi-Fi pre-flight failed: the device is still on the setup AP. STAY on
      // Configure (step already is _Step.provision), preserve the session /
      // deviceId / claim token, surface the specific Wi-Fi message and let the
      // user correct the credentials and test again. Nothing was persisted and
      // no Restart was sent.
      debugPrint('[PROVISION] Wi-Fi validation failed, staying on Configure');
      traceLog('WIFI_TEST',
          'STAY_ON_CONFIGURE result=${_wifiTestResult.name}');
      setState(() {
        _provisioning = false;
        _error = wifiTestMessage(_wifiTestResult);
      });
      return;
    }
    if (outcome != _ConfigOutcome.ok) {
      setState(() {
        _provisioning = false;
        _error = 'The device did not accept all settings. Power-cycle it (hold '
            'its button ~10s to factory-reset if it no longer shows the '
            'tasmota-XXXX access point), then try again.';
      });
      return;
    }
    debugPrint('[PROVISION] restart succeeded');
    // Post-provision / waiting phase. The Tasmota AP is expected to disappear
    // now — stop AP probing and do NOT re-run Wi-Fi binding. The phone must go
    // back to normal routing and we wait for the device on the backend.
    _reachTimer?.cancel();
    _trace.enter(ProvisionPhase.reboot, 'RESTART_SENT');
    debugPrint('[PROVISION] FINAL_RESTART');
    debugPrint('[PROVISION] phase=WAITING_FOR_DEVICE');
    await _releaseWifiBinding();
    debugPrint('[PROVISION] AP_RELEASED');
    debugPrint('[PROVISION] HOME_NETWORK_RESTORED');
    if (!mounted) return;
    setState(() {
      _provisioning = false;
      _step = _Step.waiting;
      _state = ProvisionState.waitingForMqtt;
      _error = null;
    });
    _waitForDeviceOnline();
  }

  // Creates the backend provisioning session. PHASE 0 (ONLINE) ONLY - this must
// run before the phone switches to the Tasmota AP (which has no WAN). Logs
// only; user-facing feedback happens in `_startSearch` via _sessionCreateStatus.
Future<bool> _createSession() async {
  try {
    _trace.enter(ProvisionPhase.config, 'SESSION_CREATE_START');
    debugPrint('[PROVISION] SESSION_CREATE_START');
    final session = await _api.createProvisioningSession();
    final sessionId = session['sessionId'] as String?;
    final token = session['claimToken'] as String?;
    final deviceId = session['deviceId'] as String? ?? '';
    if (sessionId == null || token == null || deviceId.isEmpty) {
      debugPrint('[PROVISION] SESSION_CREATE_FAILED partial payload');
      return false;
    }
    _sessionId = sessionId;
    _claimToken = token;
    _issuedDeviceId = deviceId;
    _sessionCreateStatus = null;
    debugPrint('[PROVISION] SESSION_CREATE_SUCCESS session=$sessionId '
        'deviceId=$deviceId');
    if (mounted) setState(() {});
    return true;
  } on ApiException catch (e) {
    _sessionCreateStatus = e.statusCode;
    debugPrint('[PROVISION] SESSION_CREATE_FAILED status=${e.statusCode} '
        'msg=${e.message}');
    return false;
  } catch (e) {
    _sessionCreateStatus = null;
    debugPrint('[PROVISION] SESSION_CREATE_FAILED network: $e');
    return false;
  }
}

// Maps a session-creation failure to a PHASE-APPROPRIATE user message.
String _sessionErrorFor(int? status) {
  switch (status) {
    case 401:
      return 'You appear to be signed out. Please sign in again and try again.';
    case 403:
      return 'Access was denied. Please sign in again and try again.';
    case 404:
    case 409:
      return 'STEES rejected this provisioning request. Please try again.';
    case 500:
      return 'STEES is having trouble right now. Please try again in a moment.';
    default:
      return 'STEES could not prepare this device before you switched to the '
          'device Wi-Fi. Reconnect to normal Internet and reopen this screen '
          'to start over.';
  }
}

  // Best-effort session creation for the connect phase (created in the
  // background while the phone is still online so the AP phase stays offline).
  Future<void> _ensureSessionSilent() async {
    if (_sessionId != null) return;
    if (_creating) return;
    _creating = true;
    try {
      await _createSession();
    } finally {
      _creating = false;
    }
  }

  // Reads the immutable Tasmota MAC via the read-only `Status 5` query.
  Future<String?> _readDeviceMac() async {
    try {
      final uri = Uri.parse('$_deviceUrl/cm').replace(
        queryParameters: {'cmnd': 'Status 5'},
      );
      debugPrint('[PROVISION] reading device MAC (Status 5)');
      final res = await http.get(uri).timeout(const Duration(seconds: 4));
      final body = res.body.trim();
      if (res.statusCode != 200) {
        debugPrint('[PROVISION] Status 5 HTTP ${res.statusCode}');
        return null;
      }
      final mac = _findMac(jsonDecode(body));
      debugPrint('[PROVISION] device MAC: $mac');
      return mac;
    } catch (e) {
      debugPrint('[PROVISION] Status 5 read failed (non-fatal): $e');
      return null;
    }
  }

  String? _findMac(dynamic node) {
    if (node is Map) {
      final direct = node['Mac'];
      if (direct is String && direct.trim().isNotEmpty &&
          RegExp(r'^[0-9A-Fa-f:]{1,64}$').hasMatch(direct.trim())) {
        return direct.trim();
      }
      for (final v in node.values) {
        final found = _findMac(v);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final v in node) {
        final found = _findMac(v);
        if (found != null) return found;
      }
    }
    return null;
  }

  // Provision the device.
//
// Tasmota semantics verified on real hardware (firmware 15.5.0):
//
//  * `Topic`, `FullTopic`, `MqttClient`, `GroupTopic<x>`, `SSId<x>` and
//    `Password<x>` are documented as "<set> ... and restart" commands.
//  * Sending `Topic`/`FullTopic` INSIDE a single `Backlog` DROPS them: the
//    observed `Backlog MqttHost..; MqttPort..; Topic ..; FullTopic ..;
//    DeviceName ..` returned `{}` and read-back still showed the factory topic
//    `tasmota_%06X`, while `MqttHost`/`MqttPort` (non-restart commands) in the
//    same Backlog persisted. So restart-prone commands must NEVER be bundled
//    into one Backlog with the broker/identity block.
//  * `MqttHost`/`MqttPort`/`MqttUser`/`MqttPassword` are NOT restart commands
//    and persist reliably, so they stay together in one Backlog.
//
//  Strategy:
//  1) Broker + credentials in ONE Backlog (no restart) -> read-back verify.
//  2) `Topic` and `FullTopic` EACH standalone; a standalone write persists
//     (proven), but may reboot the device, so after each write we wait for the
//     device to return on the setup AP and then read the value back.
//  3) `DeviceName` standalone (no restart).
//  4) PRE-FLIGHT Wi-Fi validation: `WifiTest3 <ssid>+<password>` (AP mode,
//     non-persisting, non-restarting) proves the entered home credentials work
//     BEFORE they are persisted. On failure the wizard STAYS on Configure,
//     keeps the same session/deviceId/claim token, and never writes SSID/
//     password or sends Restart.
//  5) Home Wi-Fi credentials LAST (SSId1/Password1) so the device stays on the
//     setup AP during identity configuration and only leaves it on the final
//     `Restart 1`, i.e. once it can reach the home router + broker.
//  6) Every persisted setting is read back and compared BEFORE `Restart 1`, so
//     a silently-dropped write fails loudly instead of a device that never
//     comes online under the expected topic.
Future<_ConfigOutcome> _sendTasmotaConfig() async {
  await _ensureBoundToWifi();
  _trace.enter(ProvisionPhase.config, 'BROKER_BACKLOG');

  debugPrint('[PROVISION] configuring MQTT broker...');
  final brokerParts = <String>[
    if (_mqttUserCtl.text.trim().isNotEmpty)
      'MqttUser ${_mqttUserCtl.text.trim()}',
    if (_mqttPassCtl.text.isNotEmpty) 'MqttPassword ${_mqttPassCtl.text}',
    'MqttHost ${_mqttBrokerCtl.text.trim()}',
    'MqttPort ${_mqttPortCtl.text.trim()}',
  ];
  final brokerOk = await _sendCommand('Backlog ${brokerParts.join('; ')}');
  debugPrint('[PROVISION] MQTT broker response=${brokerOk ? 'OK' : 'FAILED'}');
  if (!brokerOk) return _ConfigOutcome.configFailed;
  _trace.debugTrace(ProvisionPhase.config, label: 'BROKER_VERIFY');

  debugPrint('[PROVISION] configuring MQTT identity...');
  final topic = _issuedDeviceId;
  if (topic.isEmpty) {
    debugPrint('[PROVISION] VERIFY FAILED: no deviceId issued by backend');
    return _ConfigOutcome.configFailed;
  }
  // Pin the topic layout to the default "%prefix%/%topic%/" so the device
  // ALWAYS publishes on tele/<topic>/STATE (and stat/<topic>/...). A leftover
  // custom FullTopic on the device would shift the deviceId to a different
  // topic segment and the wizard would never match it.
  if (!await _setDeviceSetting('Topic', topic)) {
    return _ConfigOutcome.configFailed;
  }
  _trace.debugTrace(ProvisionPhase.config, label: 'TOPIC_VERIFIED');
  if (!await _setDeviceSetting('FullTopic', '%prefix%/%topic%/')) {
    return _ConfigOutcome.configFailed;
  }
  _trace.debugTrace(ProvisionPhase.config, label: 'FULLTOPIC_VERIFIED');

  final nameOk = await _sendCommand('DeviceName ${_deviceNameCtl.text.trim()}');
  debugPrint('[PROVISION] DeviceName response=${nameOk ? 'OK' : 'FAILED'}');
  if (!nameOk) return _ConfigOutcome.configFailed;

  // Pre-flight Wi-Fi credential validation. The device is still on the setup
  // AP; WifiTest3 runs locally against the network and proves the credentials
  // BEFORE SSID1/Password1 are written. A failure stays on Configure with a
  // Wi-Fi-specific message - no persist, no Restart, same session/identity.
debugPrint('[PROVISION] running WifiTest3 pre-flight validation...');
    if (mounted) {
      setState(() => _state = ProvisionState.configuringWifiTest);
    }
    _wifiTestResult = await _runWifiTest(_ssidCtl.text.trim(),
        _wifiPassCtl.text);
    if (_wifiTestResult != WifiTestResult.success) {
      debugPrint('[PROVISION][WIFI_TEST] FAILED '
          'result=${_wifiTestResult.name}');
      _trace.debugTrace(ProvisionPhase.wifi,
          label: 'WIFI_TEST_FAILED_${_wifiTestResult.name}');
      if (mounted) {
        setState(() => _state = ProvisionState.wifiTestFailed);
      }
      return _ConfigOutcome.wifiTestFailed;
    }
    debugPrint('[PROVISION][WIFI_TEST] SUCCESS - persisting credentials');
    _trace.debugTrace(ProvisionPhase.wifi, label: 'WIFI_TEST_OK');
    if (mounted) {
      setState(() => _state = ProvisionState.wifiTestSucceeded);
    }

    debugPrint('[PROVISION] configuring WiFi...');
  final wifiSsid = await _sendCommand('SSId1 ${_ssidCtl.text.trim()}');
  debugPrint(
      '[PROVISION] WiFi configuration response(SSId1)=${wifiSsid ? 'OK' : 'FAILED'}');
  if (!wifiSsid) return _ConfigOutcome.configFailed;
  final wifiPass = await _sendCommand('Password1 ${_wifiPassCtl.text}');
  debugPrint(
      '[PROVISION] WiFi configuration response(Password1)=${wifiPass ? 'OK' : 'FAILED'}');
  if (!wifiPass) return _ConfigOutcome.configFailed;

  // Read back the exact settings the device claims to have before restarting.
  debugPrint('[PROVISION] verifying persisted settings...');
  final checks = <String, String>{
    'Topic': topic,
    'FullTopic': '%prefix%/%topic%/',
    'MqttHost': _mqttBrokerCtl.text.trim(),
    'MqttPort': _mqttPortCtl.text.trim(),
    'SSId1': _ssidCtl.text.trim(),
  };
  for (final entry in checks.entries) {
    if (!await _verifySetting(entry.key, entry.value)) {
      return _ConfigOutcome.configFailed;
    }
  }
  debugPrint('[PROVISION] persisted settings verified');
  _trace.debugTrace(ProvisionPhase.config, label: 'ALL_VERIFIED');

  debugPrint('[PROVISION] sending restart command: Restart 1');
  final restartOk = await _sendCommand('Restart 1');
  _trace.debugTrace(ProvisionPhase.config, label: 'RESTART_SENT_TO_DEVICE');
  return restartOk ? _ConfigOutcome.ok : _ConfigOutcome.configFailed;
}

  // Writes one setting that Tasmota may react to with a reboot (Topic,
  // FullTopic, ...). The write itself is verified by waiting for the device to
  // come back on the setup AP (it reboots to AP mode while home Wi-Fi is not
  // yet configured) and then reading the stored value back.
  Future<bool> _setDeviceSetting(String key, String value) async {
    final ok = await _sendCommand('$key $value');
    debugPrint('[PROVISION] $key write response=${ok ? 'OK' : 'FAILED'}');
    if (!ok) return false;
    await _waitForDeviceOnAp();
    return _verifySetting(key, value);
  }

  // Sends one cmnd command (write or action). A plain HTTP 200 is NOT enough -
  // Tasmota can wrap a rejected command in 200. Treat any {"Command":{"Error"...}}
  // body as a hard failure and log everything for diagnostics.
  Future<bool> _sendCommand(String command) async {
    try {
      final uri = Uri.parse('$_deviceUrl/cm').replace(
        queryParameters: {'cmnd': command},
      );
      debugPrint('[PROVISION] HTTP GET $uri');
      final res = await http.get(uri).timeout(const Duration(seconds: 4));
      final body = res.body.trim();
      debugPrint('[PROVISION] response status=${res.statusCode} body=$body');
      if (res.statusCode != 200) return false;
      if (body.isEmpty) return true;
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map) {
          final cmd = decoded['Command'];
          if (cmd is Map && cmd['Error'] is int && cmd['Error'] != 0) {
            debugPrint('[PROVISION] COMMAND REJECTED: "$command" -> $body');
            return false;
          }
        }
      } catch (_) {}
      return true;
    } catch (e) {
      debugPrint('[PROVISION] exception sending "$command": $e');
      return false;
    }
  }

  // Queries a setting (cmnd with no argument) and requires the stored value to
  // equal the expected value. The device may be momentarily rebooting after a
  // config write, so a short retry loop absorbs the gap before declaring the
  // write did not persist.
  Future<bool> _verifySetting(String key, String expected) async {
    for (var attempt = 1; attempt <= 6; attempt++) {
      try {
        final uri = Uri.parse('$_deviceUrl/cm').replace(
          queryParameters: {'cmnd': key},
        );
        debugPrint('[PROVISION] read-back GET $uri (attempt $attempt)');
        final res = await http.get(uri).timeout(const Duration(seconds: 3));
        final body = res.body.trim();
        if (res.statusCode != 200) {
          debugPrint('[PROVISION] read-back $key HTTP ${res.statusCode}');
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }
        final decoded = jsonDecode(body);
        final got = decoded is Map ? decoded[key] : decoded;
        final gotStr = got?.toString().trim() ?? '';
        if (got == null || gotStr.isEmpty) {
          debugPrint('[PROVISION] VERIFY FAILED: $key missing in response ($body)');
          return false;
        }
        final want = expected.trim();
        if (gotStr != want) {
          debugPrint('[PROVISION] DEVICE ID MISMATCH: $key=$gotStr expected=$want');
          debugPrint('[PROVISION] VERIFY FAILED: $key=$gotStr expected=$want');
          return false;
        }
        debugPrint('[PROVISION] verification OK: $key=$gotStr');
        return true;
      } catch (e) {
        debugPrint('[PROVISION] read-back $key exception (attempt $attempt): $e');
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    debugPrint('[PROVISION] VERIFY FAILED: $key unreachable after retries');
    return false;
  }

  // ──────────────────────────────────────────────────────────
  // Pre-flight Wi-Fi credential validation (WifiTest3)
  // ──────────────────────────────────────────────────────────

  // Validates the ENTERED home Wi-Fi credentials against the physical network
  // BEFORE SSID1/Password1 are persisted and BEFORE Restart 1. Uses Tasmota
  // `WifiTest3` (mode 3): only available in AP mode, tests the given
  // `ssid+password` against the network WITHOUT storing anything and WITHOUT
  // restarting. Entirely local (192.168.4.1) - no backend/cloud call.
  //
  // Sequence on firmware 15.5.0:
  //   1. `WifiTest3 <ssid>+<password>`      -> {"WifiTest3":"Testing"} (start)
  //   2. poll `WifiTest` (data-less) until status settles:
  //        {"WifiTest":"Successful"}                              -> success
  //        {"WifiTest":"Connect failed..."} (localized variants)  -> failure
  //        anything else ("Testing"/"Not Started"/malformed)      -> keep polling
  //
  // The verdict is latched on the device until the next test starts, so a
  // single poll loop reading the settled value is authoritative. The entered
  // credentials are NEVER logged (SSID/password go into the URL only).
  Future<WifiTestResult> _runWifiTest(String ssid, String password) async {
    debugPrint('[PROVISION][WIFI_TEST] START');
    _trace.enter(ProvisionPhase.wifi, 'WIFI_TEST_START');

    // WifiTest3 uses `+` as the ssid/password separator, so a `+` inside either
    // value would corrupt the request. Such networks are simply not testable —
    // surface it locally instead of falsifying the result.
    if (ssid.contains('+') || password.contains('+')) {
      debugPrint(
          '[PROVISION][WIFI_TEST] SKIP cannot test "+" in ssid/password');
      return WifiTestResult.unknown;
    }

    final startUri = Uri.parse('$_deviceUrl/cm').replace(
      queryParameters: {'cmnd': 'WifiTest3 $ssid+$password'},
    );
    try {
      final res = await http.get(startUri).timeout(_wifiTestHttpTimeout);
      final body = res.body.trim();
      // The trigger response never echoes the credentials; it is either
      // `{"WifiTest3":"Testing"}` or an error — safe to log raw for diagnosis.
      debugPrint('[PROVISION][WIFI_TEST] TRIGGER_RESPONSE '
          'status=${res.statusCode} body=$body');
      if (res.statusCode != 200) {
        debugPrint('[PROVISION][WIFI_TEST] HTTP_ERROR (non-200)');
        return WifiTestResult.localError;
      }
    } catch (e) {
      debugPrint('[PROVISION][WIFI_TEST] HTTP_ERROR $e');
      return WifiTestResult.localError;
    }

    // Poll the verdict. The test runs in the background (~9-10s), so keep
    // polling until the status leaves the transient "Testing" state or the
    // deadline expires. A transient HTTP failure mid-test is a LOCAL AP
    // communication problem, not a Wi-Fi verdict - retry the loop, and only
    // classify if we exhaust the deadline.
    final pollUri = Uri.parse('$_deviceUrl/cm').replace(
      queryParameters: {'cmnd': 'WifiTest'},
    );
    final deadline = DateTime.now().add(_wifiTestTotalDeadline);
    bool sawTransientException = false;
    var pollNumber = 0;
    while (DateTime.now().isBefore(deadline)) {
      pollNumber++;
      try {
        final res = await http.get(pollUri).timeout(_wifiTestHttpTimeout);
        final body = res.body.trim();
        // Log the RAW poll body: it is decisive for diagnosing whether the
        // firmware returns a flat/wrapped/nested `WifiTest` verdict (or a
        // localized string) — none of which contain credentials.
        // ignore: lines_longer_than_80_chars
        debugPrint('[PROVISION][WIFI_TEST] POLL #$pollNumber '
            'status=${res.statusCode} body=$body '
            'extracted=${extractWifiTestValue(body)} '
            'pending=${isWifiTestPending(body)}');
        if (res.statusCode != 200 || body.isEmpty) {
          sawTransientException = true;
          await Future<void>.delayed(_wifiTestPollInterval);
          continue;
        }
        if (isWifiTestPending(body)) {
          // Firmware still running the background test - keep polling.
          await Future<void>.delayed(_wifiTestPollInterval);
          continue;
        }
        final result = classifyWifiTest(body);
        debugPrint('[PROVISION][WIFI_TEST] FINAL #$pollNumber '
            'verdict=${result.name}');
        _trace.debugTrace(ProvisionPhase.wifi, label: 'WIFI_TEST_VERDICT');
        return result;
      } catch (e) {
        sawTransientException = true;
        debugPrint(
            '[PROVISION][WIFI_TEST] poll HTTP exception $e (transient, retrying)');
        await Future<void>.delayed(_wifiTestPollInterval);
      }
    }
    debugPrint(
        '[PROVISION][WIFI_TEST] TIMEOUT '
        'transientError=$sawTransientException');
    _trace.debugTrace(ProvisionPhase.wifi, label: 'WIFI_TEST_TIMEOUT');
    return sawTransientException
        ? WifiTestResult.localError
        : WifiTestResult.unknown;
  }

  // ──────────────────────────────────────────────────────────
  // Wait for the device to come online, then auto-claim
  // ──────────────────────────────────────────────────────────

  void _waitForDeviceOnline() {
    debugPrint('[PROVISION] BACKEND_WAIT_START');
    debugPrint('[PROVISION] waiting for device online: deviceId=$_issuedDeviceId');
    _trace.enter(ProvisionPhase.mqtt, 'WAIT_MQTT_DEVICE');
    _waitStart = DateTime.now();
    _claimed = false;
    // Stage label pacing: "Connecting device to Wi-Fi…" for the boot window,
    // then "Connecting device to MQTT…". Pure UX - the deadline and polling
    // cadence are untouched by it.
    _state = ProvisionState.waitingForWifi;
    _waitStageTimer?.cancel();
    _waitStageTimer = Timer(_stageAdvance, () {
      if (!mounted || _step != _Step.waiting) return;
      setState(() {
        _state = ProvisionState.waitingForMqtt;
      });
    });
    // Authoritative fallback: scoped, authenticated polling (source of truth).
    _pollSessionStatus();
    // Optional fast path: Socket.IO wake-up for this session's device only.
    unawaited(_startDeviceWatch());
  }

  // Socket.IO fast path. Notification only - never the source of truth. The
  // server emits device_seen to the provision:<deviceId> room when this exact
  // device announces on MQTT and only the session owner may join the room.
  Future<void> _startDeviceWatch() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    _closeProvisionSocket();
    final token = await AuthService().getToken();
    if (!mounted || token == null) {
      debugPrint('[PROVISION] no token, skipping socket fast path');
      return;
    }
    final socket = io.io(kBaseUrl, <String, dynamic>{
      'transports': ['websocket'],
      'secure': true,
      'autoConnect': false,
      'reconnection': true,
      'reconnectionDelay': 1500,
      'auth': <String, dynamic>{'token': token},
    });
    _provisionSocket = socket;

    socket.onConnect((_) {
      debugPrint('[PROVISION] socket connected, watching session $sessionId');
      socket.emit('provision_watch', <String, dynamic>{
        'sessionId': sessionId,
      });
    });
    socket.on('device_seen', (data) {
      if (!mounted) return;
      debugPrint('[PROVISION] device_seen fast-path received: $data');
      _onDeviceDetected();
    });
    socket.on('connect_error', (_) {
      debugPrint('[PROVISION] socket connect error - falling back to polling');
    });
    socket.on('disconnect', (_) {
      debugPrint('[PROVISION] socket disconnected - falling back to polling');
    });
    socket.connect();
  }

  Future<void> _pollSessionStatus() async {
    _waitTimer?.cancel();
    if (_step != _Step.waiting) return;
    // Bound the wait: the device must appear within the window or it is not
    // coming (wrong home Wi-Fi, wrong password, broker unreachable). Surface a
    // precise failure instead of polling forever.
    final started = _waitStart;
    if (started != null &&
        DateTime.now().difference(started) > _waitDeadline) {
      debugPrint(
          '[PROVISION] wait deadline of ${_waitDeadline.inMinutes}m elapsed, giving up');
      _finishWaitFailed();
      return;
    }
    final sessionId = _sessionId;
    if (sessionId == null) return;
    bool seen = false;
    try {
      final status = await _api.getProvisioningSession(sessionId);
      seen = status['deviceSeen'] == true;
      debugPrint(
          '[PROVISION] session poll: deviceId=$_issuedDeviceId deviceSeen=$seen');
      if (!seen) {
        debugPrint('[PROVISION] DEVICE ID MISMATCH expected=$_issuedDeviceId '
            'received=<no recent MQTT packet on that topic>');
      }
    } catch (e) {
      debugPrint('[PROVISION] session poll failed: $e');
      seen = false;
    }
    if (!mounted || _step != _Step.waiting) return;
    if (seen) {
      await _onDeviceDetected();
      return;
    }
    _waitTimer = Timer(const Duration(seconds: 3), () => _pollSessionStatus());
  }

  // Terminal stop of the wait loop. The device never appeared before the
  // deadline (or its session could not be reached). This is a RECOVERY state,
  // not a dead-end: the wizard keeps its identity and offers Reconfigure Wi-Fi
  // (re-acquire the Tasmota AP, correct credentials, reuse the same session),
  // Try again (fresh deadline - the device may still be slow to reboot) and
  // Close (leave with the session still valid so the user can continue later).
  // The cause is deliberately non-specific: the backend cannot distinguish a
  // wrong password from a wrong network, 5 GHz-only Wi-Fi, an unavailable
  // network, a device power loss or an MQTT/backend hiccup - recovery for all
  // of them is the same, so the wording stays evidence-based.
  void _finishWaitFailed() {
    _waitTimer?.cancel();
    _waitStageTimer?.cancel();
    _closeProvisionSocket();
    _allowWaitRetry = true;
    traceLog('WAIT',
        'TIMEOUT total=${_trace.elapsedMs}ms deviceId=$_issuedDeviceId');
    if (!mounted) return;
    setState(() {
      _state = ProvisionState.failed;
      _error =
          "The device didn't connect to the Wi-Fi network it was configured for.";
    });
  }

  Future<void> _onDeviceDetected() async {
    if (!mounted || _step != _Step.waiting) return;
    if (_claimed) return;
    _claimed = true;
    _waitTimer?.cancel();
    _closeProvisionSocket();
    _trace.enter(ProvisionPhase.backend, 'DEVICE_DETECTED');
    debugPrint('[PROVISION] DEVICE_SEEN via ${_watchAcked ? 'socket' : 'poll'}');
    if (mounted) {
      setState(() {
        _state = ProvisionState.deviceDetected;
      });
    }
    await _runClaim();
  }

  Future<void> _runClaim() async {
    final sessionId = _sessionId;
    final claimToken = _claimToken;
    if (sessionId == null || claimToken == null) {
      _setError('Provisioning session lost. Please try again.');
      return;
    }
    final name = _deviceNameCtl.text.trim();
    if (!mounted) return;
    setState(() {
      _state = ProvisionState.claiming;
    });
    try {
      _trace.enter(ProvisionPhase.claim, 'CLAIMING');
      await _api.claimDeviceWithSession(
        sessionId: sessionId,
        claimToken: claimToken,
        name: name,
        channels: _deviceType.channelCount,
        hardwareId: _hardwareId,
      );
      _trace.enter(ProvisionPhase.claim, 'CLAIMED');
      _recoveryMode = false;
      debugPrint('[PROVISION] CLAIM_SUCCESS deviceId=$_issuedDeviceId');
      debugPrint('[PROVISION] total provisioning elapsed ${_trace.elapsedMs}ms');
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      _claimed = false;
      debugPrint('[PROVISION] CLAIM_FAILED status=${e.statusCode} '
          'code=${e.code} msg=${e.message}');
      if (_isTerminalClaimError(e)) {
        // Graded, phase-appropriate recovery. Terminal errors are NOT retried
        // (they would re-fail forever). The wizard shows a recovery screen
        // with a resumable session instead of looping.
        _allowWaitRetry = false;
        traceLog('CLAIM', 'TERMINAL total=${_trace.elapsedMs}ms');
        setState(() {
          _state = ProvisionState.failed;
          _error = _claimFailureMessage(e);
        });
        return;
      }
      // Recoverable (device not on MQTT yet, transient 5xx/429/network):
      // keep waiting so a slow MQTT connect still completes - never leave
      // the device silently orphaned.
      _setError(_claimRecoveryMessage(e));
      setState(() {
        _state = ProvisionState.waitingForMqtt;
      });
      _waitTimer = Timer(const Duration(seconds: 3), () => _pollSessionStatus());
    } catch (e) {
      if (!mounted) return;
      _claimed = false;
      debugPrint('[PROVISION] CLAIM_FAILED network: $e');
      // Network / timeout: recoverable. Fall back to polling for the device.
      _setError('Could not reach STEES. Waiting and retrying…');
      setState(() {
        _state = ProvisionState.waitingForMqtt;
      });
      _waitTimer = Timer(const Duration(seconds: 3), () => _pollSessionStatus());
    }
  }

  // Distinguishes terminal claim failures (never worth retrying) from
  // transient ones (device not seen, rate-limited, server hiccup, network).
  bool _isTerminalClaimError(ApiException e) {
    final code = e.code;
    if (code != null) {
      switch (code) {
        case 'BAD_HARDWARE':
        case 'BAD_CHANNELS':
        case 'BAD_NAME':
        case 'BAD_DEVICE_ID':
        case 'ALREADY_CLAIMED':
        case 'SESSION_USED':
        case 'SESSION_NOT_PENDING':
        case 'SESSION_EXPIRED':
        case 'SESSION_NOT_FOUND':
        case 'INVALID_TOKEN':
          return true;
        case 'DEVICE_NOT_SEEN':
        case 'SESSION_BUSY':
        case 'RATE_LIMITED':
        default:
          return false;
      }
    }
    // Fall back to status codes when the body had no machine-readable code.
    final status = e.statusCode;
    return status == 401 || status == 403 || status == 404 || status == 400 ||
        status == 409 || status == 410;
  }

  // User-facing, non-technical wording for a TERMINAL claim failure.
  String _claimFailureMessage(ApiException e) {
    switch (e.code) {
      case 'ALREADY_CLAIMED':
        return 'This device is already linked to an account. If you own it, '
            'unlink it from that account first, then provision it again.';
      case 'SESSION_EXPIRED':
        return 'This provisioning attempt has expired. Close and start over.';
      case 'INVALID_TOKEN':
        return 'This provisioning attempt is no longer valid. Close and start over.';
      case 'SESSION_USED':
      case 'SESSION_NOT_PENDING':
      case 'SESSION_NOT_FOUND':
        return 'This provisioning attempt has already been used. Close and start over.';
      case 'BAD_NAME':
      case 'BAD_CHANNELS':
      case 'BAD_DEVICE_ID':
      case 'BAD_HARDWARE':
        return 'This device could not be registered with STEES. Close and try again.';
      default:
        if (e.statusCode == 401) {
          return 'You appear to be signed out. Sign in again and retry.';
        }
        if (e.statusCode == 403) {
          return 'Access was denied. Sign in again and retry.';
        }
        return 'STEES rejected this device. Close and try again.';
    }
  }

  // Wording for a RECOVERABLE claim failure (the wizard keeps waiting).
  String _claimRecoveryMessage(ApiException e) {
    switch (e.code) {
      case 'DEVICE_NOT_SEEN':
        return 'The device is not on the cloud yet. Waiting and retrying…';
      case 'RATE_LIMITED':
        return 'Too many requests to STEES. Waiting a moment and retrying…';
      case 'SESSION_BUSY':
        return 'Registration is still in progress. Continuing…';
      default:
        return 'STEES was busy. Waiting and retrying…';
    }
  }

  // ──────────────────────────────────────────────────────────
  // Helpers
  // ──────────────────────────────────────────────────────────

  void _setError(String msg) {
    if (!mounted) return;
    final colors = context.steesColors;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        backgroundColor: colors.danger,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        margin: const EdgeInsets.all(AppSpacing.lg),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Provision Device',
          style: GoogleFonts.sora(fontSize: 18, fontWeight: FontWeight.w600, color: colors.foam),
        ),
        backgroundColor: colors.well,
        iconTheme: IconThemeData(color: colors.mist),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colors.well, Theme.of(context).colorScheme.surfaceContainerHighest, colors.well],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: _buildStep(colors),
          ),
        ),
      ),
    );
  }

  Widget _buildStep(SteesColors colors) {
    switch (_step) {
      case _Step.connect:
        return _buildConnect(colors);
      case _Step.provision:
        return _buildConfig(colors);
      case _Step.waiting:
        return _buildWaiting(colors);
    }
  }

  Widget _buildConnect(SteesColors colors) {
    final recovering = _recoveryMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.xl),
        _PhaseProgress(active: 0, colors: colors),
        const SizedBox(height: AppSpacing.xl),
        Container(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          decoration: BoxDecoration(
            color: colors.submerged,
            borderRadius: BorderRadius.circular(AppRadius.xl),
          ),
          child: Column(
            children: [
              Icon(
                recovering ? Icons.wifi_tethering : Icons.wifi_outlined,
                size: 40,
                color: colors.stream.withValues(alpha: 0.5),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                recovering
                    ? 'Reconnect to your device Wi-Fi.\n\n'
                        'Your device ID is kept - this is a Wi-Fi correction, not a '
                        'new registration.\n\n'
                        'Power-cycle the device, pick its access point '
                        '(tasmota-XXXX) in Wi-Fi Settings, then return here.'
                    : 'Connect your phone to the device Wi-Fi.\n\n'
                        "Tap below, pick the device's access point (tasmota-XXXX), "
                        'then return here.',
                style: GoogleFonts.inter(fontSize: 13, color: colors.mist, height: 1.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xl),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  onPressed: _openWifiSettings,
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: const Text('Open Wi-Fi Settings'),
                  style: _filledStyle(colors),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  onPressed: _searching ? null : _startSearch,
                  style: _filledStyle(colors),
                  child: _searching
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: colors.well),
                        )
                      : Text('Continue', style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              ),
              if (_searching) ...[
                const SizedBox(height: AppSpacing.md),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: colors.stream),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      'Checking device connection…',
                      style: GoogleFonts.inter(fontSize: 12, color: colors.mist),
                    ),
                  ],
                ),
              ],
              if (!_searching && _error != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(fontSize: 12, color: colors.danger),
                ),
                if (recovering) ...[
                  const SizedBox(height: AppSpacing.xl),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 46,
                          child: OutlinedButton(
                            onPressed: _startSearch,
                            style: _outlinedStyle(colors),
                            child: Text(
                              'Search Again',
                              style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: SizedBox(
                          height: 46,
                          child: OutlinedButton(
                            onPressed: _openWifiSettings,
                            style: _outlinedStyle(colors),
                            child: Text(
                              'Open Wi-Fi Settings',
                              style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: OutlinedButton(
                      onPressed: _showRecoveryInstructions,
                      style: _outlinedStyle(colors),
                      child: const Text(
                        'Recovery Instructions',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextButton(
                    onPressed: _leaveWizard,
                    child: Text(
                      'Close',
                      style: GoogleFonts.inter(fontSize: 13, color: colors.mist),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  // Dialog with concrete recovery steps, shown from the recovery flow. Stays
  // open until dismissed - the phone has no internet while on the Tasmota AP,
  // so everything here must be actionable without backend calls.
  void _showRecoveryInstructions() {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Recovery steps'),
        content: const Text(
          '1. Power-cycle the device and wait 30 seconds for its setup AP '
          '(tasmota-XXXX) to appear.\n\n'
          '2. Open Wi-Fi Settings and connect to the tasmota-XXXX network.\n\n'
          '3. Return here and tap Continue.\n\n'
          '4. Make sure the home Wi-Fi name and password are correct, then tap '
          'Provision Device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _buildConfig(SteesColors colors) {
    final subLabel = _provisioning
        ? provisionUserLabel(_state)
        : (_state == ProvisionState.wifiTestFailed
            ? provisionUserLabel(ProvisionState.wifiTestFailed)
            : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.xl),
        _PhaseProgress(
          active: 1,
          colors: colors,
          subLabel: subLabel,
        ),
        const SizedBox(height: AppSpacing.xl),
        _section(colors, 'HOME WI-FI'),
        _buildWifiSelector(colors),
        const SizedBox(height: AppSpacing.md),
        if (_manualWifi) ...[
          _Field(
            controller: _ssidCtl,
            hint: 'Network name (SSID)',
            icon: Icons.router_outlined,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        _Field(
          controller: _wifiPassCtl,
          hint: 'Wi-Fi Password',
          icon: Icons.lock_outline,
          obscure: true,
          focusNode: _wifiPassFocus,
        ),
        const SizedBox(height: AppSpacing.xl),
        _section(colors, 'DEVICE'),
        _Field(
          controller: _deviceNameCtl,
          hint: 'Device Name',
          icon: Icons.label_outline,
        ),
        const SizedBox(height: AppSpacing.md),
        DeviceTypePicker(
          value: _deviceType,
          onChanged: (t) => setState(() => _deviceType = t),
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          decoration: BoxDecoration(
            color: colors.well,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Row(
            children: [
              Icon(Icons.alternate_email, size: 18, color: colors.mist),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Device ID',
                      style: GoogleFonts.inter(fontSize: 11, color: colors.mist.withValues(alpha: 0.75)),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _issuedDeviceId.isEmpty
                          ? 'generated when provisioning starts'
                          : _issuedDeviceId,
                      style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Assigned by STEES',
                style: GoogleFonts.inter(fontSize: 10, color: colors.mist.withValues(alpha: 0.6)),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),
        if (_state == ProvisionState.wifiTestFailed) ...[
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: colors.danger.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: colors.danger.withValues(alpha: 0.25)),
            ),
            child: Column(
              children: [
                Icon(Icons.wifi_off_outlined,
                    size: 28, color: colors.danger),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Wi-Fi connection failed',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.sora(
                      fontSize: 15, fontWeight: FontWeight.w600, color: colors.danger),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _error ??
                      "The device couldn't connect to this Wi-Fi network. "
                          'Check the Wi-Fi name and password and try again.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 12, color: colors.mist.withValues(alpha: 0.85), height: 1.4),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Your device is still connected to the setup Wi-Fi, so you '
                  'can correct the credentials and test again.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 11, color: colors.mist.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: FilledButton(
                    onPressed: _provisioning ? null : _provision,
                    style: _filledStyle(colors),
                    child: Text('Try Again',
                        style: GoogleFonts.sora(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: OutlinedButton(
                    onPressed: _focusWifiPassword,
                    style: _outlinedStyle(colors),
                    child: Text('Change Wi-Fi',
                        style: GoogleFonts.sora(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ],
          ),
        ] else if (_error != null) ...[
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 12, color: colors.danger, height: 1.4),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton(
            onPressed: _provisioning ? null : _provision,
            style: _filledStyle(colors),
            child: _provisioning
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: colors.well),
                  )
                : Text('Test Wi-Fi & Continue',
                    style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        ),
        if (_provisioning && _state == ProvisionState.configuringWifiTest) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            'Testing Wi-Fi connection…\nPlease keep your phone connected to '
            'the device.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 12, color: colors.mist.withValues(alpha: 0.85), height: 1.5),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }

  // Moves focus to the Wi-Fi password field after a failed connectivity test so
  // the user can immediately correct the most common mistake. Keeps the wizard
  // on the Configure step - no session or identity change.
  void _focusWifiPassword() {
    FocusScope.of(context).requestFocus(_wifiPassFocus);
  }

  // Dropdown-style selector for the HOME Wi-Fi network. Opening it scans for
  // nearby networks (without disconnecting from the Tasmota AP) and offers a
  // manual entry fallback for hidden/unlisted networks.
  Widget _buildWifiSelector(SteesColors colors) {
    final selected = _ssidCtl.text.trim();
    return InkWell(
      onTap: _openWifiPicker,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.well,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Row(
          children: [
            Icon(Icons.wifi, size: 18, color: colors.mist),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Wi-Fi Network',
                    style: GoogleFonts.inter(fontSize: 11, color: colors.mist.withValues(alpha: 0.75)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    selected.isEmpty ? 'Select Wi-Fi network' : selected,
                    style: GoogleFonts.inter(fontSize: 14, color: selected.isEmpty ? colors.mist : colors.foam),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 22, color: colors.mist),
          ],
        ),
      ),
    );
  }

  Future<void> _openWifiPicker() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (ctx) => _WifiPickerSheet(
        currentSsid: _ssidCtl.text.trim(),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (picked == '_manual') {
        _manualWifi = true;
      } else {
        _manualWifi = false;
        _ssidCtl.text = picked;
      }
    });
  }

  Widget _buildWaiting(SteesColors colors) {
    final failed = _state == ProvisionState.failed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.xl),
        _PhaseProgress(active: 2, colors: colors),
        const SizedBox(height: AppSpacing.xxxl),
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: failed
                  ? colors.danger.withValues(alpha: 0.06)
                  : colors.stream.withValues(alpha: 0.06),
              border: Border.all(
                color: (failed ? colors.danger : colors.stream).withValues(alpha: 0.12),
              ),
            ),
            child: Icon(
              failed
                  ? Icons.error_outline
                  : Icons.cloud_done_outlined,
              size: 32,
              color: (failed ? colors.danger : colors.stream).withValues(alpha: 0.5),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Text(
          failed
              ? 'Device is not connected yet'
              : provisionUserLabel(_state),
          textAlign: TextAlign.center,
          style: GoogleFonts.sora(fontSize: 17, fontWeight: FontWeight.w600, color: colors.foam),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          failed
              ? _error ?? 'Something went wrong. Please try again.'
              : 'The device will join your Wi-Fi and connect to the cloud automatically.',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(fontSize: 13, height: 1.5, color: colors.mist.withValues(alpha: 0.7)),
        ),
        if (!failed) ...[
          const SizedBox(height: AppSpacing.xxl),
          Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ),
        ],
        if (failed) ...[
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              onPressed: _startRecovery,
              icon: const Icon(Icons.wifi_tethering, size: 18),
              label: const Text('Reconfigure Wi-Fi'),
              style: _filledStyle(colors),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (_allowWaitRetry) ...[
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton(
                onPressed: _retryWait,
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.foam,
                  side: BorderSide(color: colors.stream.withValues(alpha: 0.4)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.xl),
                  ),
                ),
                child: Text('Wait a bit longer',
                    style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'You can also power-cycle the device so it reconnects, then '
              'continue waiting here.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 12, color: colors.mist.withValues(alpha: 0.6)),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          SizedBox(
            width: double.infinity,
            height: 50,
            child: OutlinedButton(
              onPressed: _leaveWizard,
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.mist,
                side: BorderSide(color: colors.mist.withValues(alpha: 0.35)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                ),
              ),
              child: Text('Close',
                  style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
        if (_error != null && !failed) ...[
          const SizedBox(height: AppSpacing.xl),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 13, color: colors.danger),
          ),
        ],
      ],
    );
  }

  // Re-arms the device wait for a fresh deadline window. The session, deviceId
  // and claim token are all still valid - this is a continuation, not a restart.
  void _retryWait() {
    _waitTimer?.cancel();
    _waitStageTimer?.cancel();
    _closeProvisionSocket();
    if (!mounted) return;
    setState(() {
      _error = null;
      _state = ProvisionState.waitingForMqtt;
      _waitStart = DateTime.now();
    });
    debugPrint('[PROVISION] wait re-armed for a fresh deadline');
    traceLog('WAIT', 'RETRY total=${_trace.elapsedMs}ms');
    _waitForDeviceOnline();
  }

  // Recovery from a failed WAIT. Returns to the CONNECT step to re-acquire the
  // Tasmota AP WITHOUT creating a new session/deviceId: the currently valid
  // session, one-time claim token and backend-issued identity are all kept, so
  // a Wi-Fi correction is a continuation, never a fresh (possibly duplicate)
  // provisioning attempt.
  void _startRecovery() {
    _waitTimer?.cancel();
    _waitStageTimer?.cancel();
    _closeProvisionSocket();
    _recoveryMode = true;
    traceLog('RECOVERY',
        'REQUIRED total=${_trace.elapsedMs}ms session=$_sessionId');
    debugPrint('[PROVISION] phase=RECOVERY_AP session preserved=$_sessionId '
        'deviceId=$_issuedDeviceId');
    if (!mounted) return;
    setState(() {
      _recoveryMode = true;
      _step = _Step.connect;
      _state = ProvisionState.recoveryRequired;
      _searching = false;
      _error = null;
    });
    _startApDetection();
  }

  // Leaves the wizard. The backend provisioning session stays valid for its
  // TTL window, so the user can power-cycle the device and start over without
  // losing the issued identity.
  void _leaveWizard() {
    _waitTimer?.cancel();
    _waitStageTimer?.cancel();
    _closeProvisionSocket();
    traceLog('EXIT', 'CANCELLED total=${_trace.elapsedMs}ms');
    if (mounted) Navigator.of(context).pop(false);
  }

  Widget _section(SteesColors colors, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.xs, bottom: AppSpacing.sm),
      child: Text(
        title,
        style: GoogleFonts.sora(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.6, color: colors.mist),
      ),
    );
  }

  ButtonStyle _filledStyle(SteesColors colors) {
    return FilledButton.styleFrom(
      backgroundColor: colors.stream,
      foregroundColor: colors.well,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
    );
  }

  ButtonStyle _outlinedStyle(SteesColors colors) {
    return OutlinedButton.styleFrom(
      foregroundColor: colors.foam,
      side: BorderSide(color: colors.stream.withValues(alpha: 0.4)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
    );
  }
}

class _PhaseProgress extends StatelessWidget {
  /// Which wizard step is active: 0 = connect, 1 = configure, 2 = wait.
  final int active;
  final SteesColors colors;
  final String? subLabel;

  const _PhaseProgress({
    required this.active,
    required this.colors,
    this.subLabel,
  });

  @override
  Widget build(BuildContext context) {
    const labels = ['Connect', 'Configure', 'Wait'];
    return Column(
      children: [
        Row(
          children: List.generate(labels.length, (i) {
            final state = i < active
                ? _PhaseDone.done
                : (i == active ? _PhaseDone.current : _PhaseDone.todo);
            return Expanded(
              child: _PhaseItem(
                label: labels[i],
                step: i + 1,
                state: state,
                colors: colors,
              ),
            );
          }),
        ),
        if (subLabel != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            subLabel!,
            style: GoogleFonts.inter(fontSize: 12, color: colors.mist),
          ),
        ],
      ],
    );
  }
}

enum _PhaseDone { done, current, todo }

class _PhaseItem extends StatelessWidget {
  final String label;
  final int step;
  final _PhaseDone state;
  final SteesColors colors;

  const _PhaseItem({
    required this.label,
    required this.step,
    required this.state,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor =
        state == _PhaseDone.done ? colors.stream : colors.mist.withValues(alpha: 0.55);
    final activeFont =
        state == _PhaseDone.todo ? colors.mist.withValues(alpha: 0.45) : colors.foam;
    return Column(
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: state == _PhaseDone.done
                ? colors.stream.withValues(alpha: 0.15)
                : colors.well,
            border: Border.all(
              color: state == _PhaseDone.todo
                  ? colors.mist.withValues(alpha: 0.25)
                  : activeColor,
              width: state == _PhaseDone.current ? 2 : 1,
            ),
          ),
          child: state == _PhaseDone.done
              ? Icon(Icons.check, size: 15, color: colors.stream)
              : Text(
                  '$step',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.sora(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: state == _PhaseDone.todo
                        ? colors.mist.withValues(alpha: 0.5)
                        : colors.foam,
                  ),
                ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          label,
          style: GoogleFonts.inter(fontSize: 11, color: activeFont),
        ),
      ],
    );
  }
}

class _WifiPickerSheet extends StatefulWidget {
  final String currentSsid;
  const _WifiPickerSheet({required this.currentSsid});

  @override
  State<_WifiPickerSheet> createState() => _WifiPickerSheetState();
}

class _WifiPickerSheetState extends State<_WifiPickerSheet> {
  static const _scanChannel = MethodChannel('stees/wifi_settings');

  List<String> _networks = const [];
  bool _scanning = false;
  String? _scanMessage;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _scanMessage = null;
      _networks = const [];
    });
    try {
      final Map<dynamic, dynamic>? result = await _scanChannel
          .invokeMethod<Map<dynamic, dynamic>>('scanWifi')
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      final available = result?['available'] == true;
      final raw = result?['networks'] as List<dynamic>? ?? const [];
      final ssids = raw
          .whereType<String>()
          .where((s) => s.trim().isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      setState(() {
        _scanning = false;
        _networks = ssids;
        _scanMessage = !available
            ? 'Wi-Fi scan unavailable. Enter your network manually.'
            : (ssids.isEmpty ? 'No Wi-Fi networks found.' : null);
      });
    } on TimeoutException {
      debugPrint('[PROVISION] wifi scan timed out after 10s');
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanMessage = 'Wi-Fi scan timed out. Tap refresh to try again.';
      });
    } catch (e) {
      debugPrint('[PROVISION] wifi scan failed: $e');
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanMessage = 'Wi-Fi scan unavailable. Enter your network manually.';
      });
    }
  }

  void _selectNetwork(String ssid) {
    Navigator.of(context).pop(ssid);
  }

  void _selectManual() {
    Navigator.of(context).pop('_manual');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'Select Wi-Fi Network',
                  style: GoogleFonts.sora(fontSize: 15, fontWeight: FontWeight.w600, color: colors.foam),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Rescan',
                  onPressed: _scanning ? null : _scan,
                  icon: _scanning
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: colors.stream),
                        )
                      : const Icon(Icons.refresh, size: 20, color: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_scanMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(
                  _scanMessage!,
                  style: GoogleFonts.inter(fontSize: 12, color: colors.mist.withValues(alpha: 0.8)),
                ),
              ),
            if (_scanning)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: colors.stream),
                  ),
                ),
              )
            else if (_networks.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _networks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (ctx, i) {
                    final ssid = _networks[i];
                    final isCurrent = ssid == widget.currentSsid;
                    return Material(
                      color: isCurrent ? colors.stream.withValues(alpha: 0.12) : colors.submerged,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      child: ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                        leading: Icon(Icons.wifi, size: 20, color: colors.mist),
                        title: Text(
                          ssid,
                          style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: isCurrent
                            ? Icon(Icons.check_circle, size: 18, color: colors.stream)
                            : null,
                        onTap: () => _selectNetwork(ssid),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: AppSpacing.xl),
            ListTile(
              dense: true,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
              leading: Icon(Icons.keyboard_outlined, size: 20, color: colors.mist),
              title: Text(
                'Enter network manually',
                style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
              ),
              onTap: _selectManual,
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final FocusNode? focusNode;

  const _Field({
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscure,
      style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon, size: 18, color: colors.mist),
        filled: true,
        fillColor: colors.well,
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide(color: colors.stream, width: 1.5),
        ),
      ),
    );
  }
}