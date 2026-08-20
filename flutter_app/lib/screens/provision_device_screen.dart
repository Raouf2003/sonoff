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
import '../services/device_repository_service.dart';
import '../services/local_device_cache.dart';
import '../services/local_ip.dart';
import '../services/provisioning_service.dart';
import '../theme/app_theme.dart';
import '../theme/stees_colors.dart';
import '../widgets/device_type_picker.dart';

enum _Step { connect, provision, waiting, localControl }

/// Graded terminal-failure kind for the WAIT step's recovery UI.
enum _TerminalKind {
  /// Default: wait-deadline / generic backend rejection. Keeps the full
  /// recovery set (Reconfigure Wi-Fi / Wait a bit longer / Close).
  generic,

  /// The MAC could not be read/invalidated on the device. Nothing to retry.
  identityUnreadable,

  /// The MAC is already a device in THIS account. Close-only.
  alreadyAdded,

  /// The MAC is already a device in ANOTHER account. Close-only.
  alreadyRegistered,
}

/// Result of the full Tasmota configuration sweep. [wifiTestFailed] is a
/// distinct outcome so a failed Wi-Fi pre-flight test stays on Configure with a
/// Wi-Fi-specific message (never a generic power-cycle/factory-reset error).
enum _ConfigOutcome { ok, wifiTestFailed, configFailed }

/// Post-claim Local HTTP enable+verify bounded retry/backoff for the
/// AP → home-Wi-Fi transition. The backend claim has ALREADY committed before
/// this loop runs, so a miss is a LOCAL-READINESS problem, never an ownership
/// one. The first attempt runs immediately (the phone already reached the
/// backend for the device-seen poll, so it is back on the home network); each
/// following gap lets the phone/router/device settle. Deliberately SMALL and
/// bounded (~12s window) — never the ever-growing 5,10,20,30… style of retry.
/// Public so widget tests can pump through it deterministically.
const List<Duration> kLocalSetupBackoff = [
  Duration(seconds: 2),
  Duration(seconds: 2),
  Duration(seconds: 3),
  Duration(seconds: 5),
];

/// Fallback diagnostic for the recoverable local-control screen when the
/// repository produced no more specific reason.
const String kLocalSetupFallbackMessage =
    'Local HTTP control could not be enabled and verified on the device. '
    'Make sure this phone is on the same Wi-Fi as the device, then try again.';

/// STEES provisioning wizard. Replaces the workflow of typing MQTT/Wi-Fi
/// settings into the raw Tasmota web page, using STEES-styled screens and the
/// MAC-based device registration endpoint.
class ProvisionDeviceScreen extends StatefulWidget {
  const ProvisionDeviceScreen({super.key})
      : testApi = null,
        testDeviceId = null,
        testFailureCode = null,
        testWarmUp = null,
        testLocalSetup = null,
        testHttpClient = null,
        testIsDeviceRegistered = null,
        testRepository = null;

  /// Test-only constructor: seeds the wizard directly into a terminal (duplicate)
  /// failure state and injects an [ApiService] so widget tests can exercise the
  /// "Remove Device" flow without driving the real hardware AP/MQTT steps.
  /// [testFailureCode] is a provision error code (e.g. DEVICE_ALREADY_EXISTS);
  /// [testDeviceId] is the canonical MAC used for the DELETE call.
  // ignore: prefer_const_constructors_in_immutables
  ProvisionDeviceScreen.forTest({
    super.key,
    this.testApi,
    this.testDeviceId,
    this.testFailureCode,
    this.testWarmUp,
    this.testLocalSetup,
    this.testHttpClient,
    this.testIsDeviceRegistered,
    this.testRepository,
  });

  @visibleForTesting
  final ApiService? testApi;

  @visibleForTesting
  final String? testDeviceId;

  @visibleForTesting
  final String? testFailureCode;

  /// Test seam: replaces the real background discovery warm-up (which opens
  /// mDNS browsers and holds fake-time timers) with a no-op in widget tests.
  @visibleForTesting
  final Future<void> Function(List<Map<String, dynamic>> devices)? testWarmUp;

  /// Test seam: replaces the BLOCKING post-claim Local HTTP enable + verify
  /// hard gate (SetOption128 + HTTP_API verification). Widget tests inject it so
  /// no real mDNS browser or LAN request is created on the claim-success path,
  /// and so both the success and the failure branch can be exercised. Returning
  /// `false` must make the wizard fail provisioning (terminal diagnostic, no
  /// success pop).
  @visibleForTesting
  final Future<bool> Function(String deviceId, {String? lastIp})? testLocalSetup;

  /// Test seam: injects an [http.Client] that answers the Tasmota setup-AP
  /// HTTP calls (reachability probe, Status 5 MAC read, config commands,
  /// WifiTest3) so widget tests can drive the full wizard flow without a real
  /// device / network. When null the wizard uses the default client (top-level
  /// [http.get]).
  @visibleForTesting
  final http.Client? testHttpClient;

  /// Test seam: replaces the AUTHORITATIVE provisioning-boundary duplicate
  /// check (Gate B), which in production consults the repository's
  /// registered-device authority (`DeviceRepositoryService.isDeviceRegistered`:
  /// cloud list + persisted local mirror). Widget tests inject a controlled
  /// verdict so no real network / LocalDeviceCache is touched while the
  /// boundary-gate-before-any-config-command behavior is exercised.
  @visibleForTesting
  final Future<bool> Function(String canonical)? testIsDeviceRegistered;

  /// Test seam: replaces the repository consulted by Gate B (the authoritative
  /// provisioning-boundary duplicate check). Lets widget tests drive the REAL
  /// persisted snapshot / cloud-failure path deterministically with no network.
  @visibleForTesting
  final DeviceRepositoryService? testRepository;

  @override
  State<ProvisionDeviceScreen> createState() => _ProvisionDeviceScreenState();
}

class _ProvisionDeviceScreenState extends State<ProvisionDeviceScreen>
    with WidgetsBindingObserver {
  static const String _deviceUrl = 'http://192.168.4.1';

  // Expected Tasmota AP SSID used only for the Wi-Fi binding sanity check.
  // The trailing XXXX acts as a tasmota- prefix wildcard in MainActivity.
  static const String _tasmotaApSsid = 'tasmota-XXXX';

  // Closed-loop duplicate message for a device already registered. Re-claiming
  // inside the wizard is intentionally unsupported: the existing device must be
  // deleted from the Devices page first.
  static const String _alreadyExistsMessage =
      'The device already exists. You must delete it before claiming it again.';

  // Give up waiting for the device to appear on the backend after this long.
  // Must comfortably exceed the backend's recentDevices window so a device that
  // was briefly seen is not missed, but not spin forever on a lost network.
  static const Duration _waitDeadline = Duration(minutes: 6);

  // Cosmetic pacing of the WAIT stage labels: the device reboots and joins
  // home Wi-Fi during this window, before it can reach the MQTT broker.
  static const Duration _stageAdvance = Duration(seconds: 25);

  // Staged label pacing during the reboot wait. PURE UX: the deadline and the
  // polling cadence are untouched by these offsets. The device reboots, re-runs
  // DHCP and joins the broker, so the labels tell the user what stage the wait
  // is in instead of a single generic spinner.
  static const Duration _stageRebootAdvance = Duration(seconds: 8);

  // Backend device-seen poll cadence. The Socket.IO `device_seen` fast-path
  // wakes the flow in (near) real time; this bounded poll is the authoritative
  // fallback and also bounds recovery when the socket stalls.
  static const Duration _seenPollInterval = Duration(milliseconds: 1500);

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

  // Short, best-effort bound for the pre-flight backend duplicate check. The
  // phone may have no internet while on the Tasmota AP, so this must fail fast
  // and silently - it must never block provisioning.
  static const Duration _preflightTimeout = Duration(seconds: 4);

  // Bound for the account snapshot refresh in `_loadClaimedMacsAtStart`. The
  // phone is usually on its home network at wizard open; this just keeps a
  // slow/unreachable backend from delaying the Connect step.
  static const Duration _snapshotRefreshTimeout = Duration(seconds: 5);

  // Bound for the broker-info pre-fetch in `_loadBrokerInfo`. Runs at the same
  // moment over the same home-network link as the snapshot refresh; a
  // slow/unreachable backend must not hang the Connect step (the failure
  // surfaces as a blocking error either way).
  static const Duration _brokerInfoTimeout = Duration(seconds: 5);

  static const MethodChannel _wifiBindChannel =
      MethodChannel('stees/wifi_binding');

  // Programmatic soft-AP connect (Android, API 29+): WifiNetworkSpecifier +
  // bindProcessToNetwork exposed as `stees/ap_connect`. Kept separate from the
  // manual `stees/wifi_settings` / `stees/wifi_binding` channels: the
  // specifier's `onAvailable` bind is the ONLY bind in programmatic mode, and
  // reachability is still decided by the wizard's own 192.168.4.1 probe.
  static const MethodChannel _apConnectChannel =
      MethodChannel('stees/ap_connect');

  /// Android SDK int reported by the native side (null until known). Programmatic
  /// connect is only attempted when this is >= 29 AND the API-33+ NEARBY_WIFI_DEVICES
  /// runtime permission was not denied this session.
  int? _apConnectSdkInt;

  /// True after NEARBY_WIFI_DEVICES was denied (or the channel rejected the
  /// request): the wizard falls back to the manual Wi-Fi-settings flow for the
  /// rest of this session instead of re-requesting the permission.
  bool _apConnectDisabled = false;

  /// True while a programmatic specifier connect is live and bound. While set,
  /// [_ensureBoundToWifi] is a no-op (the specifier already bound the process)
  /// and [_releaseWifiBinding] cancels through the specifier channel instead.
  bool _apConnectMode = false;

  int _apConnectAttempts = 0;

  /// Optional staged label shown during the automatic connect (SSID discovery,
  /// awaiting the system specifier dialog) so the spinner is self-explanatory.
  String? _apConnectPending;

  /// True after the user-selected programmatic connect exhausted its bounded
  /// retries without binding. Drives the "Open Wi-Fi Settings" fallback button
  /// in the Connect step's error state so the user can still proceed manually.
  bool _programmaticConnectFailed = false;

  bool get _apConnectSupported =>
      defaultTargetPlatform == TargetPlatform.android &&
      (_apConnectSdkInt ?? -1) >= 29 &&
      !_apConnectDisabled;

  // Max specifier requests per [.. _runProgrammaticConnect]: the system can
  // answer onUnavailable (no matching AP found / request rejected) even when
  // the AP is in range, so a handful of bounded retries come first.
  static const int _apConnectMaxAttempts = 3;
  static const Duration _apConnectStateDeadline = Duration(seconds: 20);

  bool _wifiBound = false;

  late final ApiService _api;

  /// Local mirror of registered devices. Updated when the (authoritative) cloud
  /// registration/removal succeeds so Local Mode still knows the device when
  /// the cloud is temporarily unreachable. Best-effort only — a cache write
  /// failure never fails provisioning.
  final LocalDeviceCache _deviceCache = LocalDeviceCache();

  /// Used after a successful provisioning to kick off background local
  /// discovery warm-up so the device's first relay tap uses a verified LAN IP
  /// instead of waiting on mDNS. Best-effort only. Also the Gate B authority
  /// (see [_stopIfRegisteredAtBoundary]); a test seam may inject a controlled
  /// repository so the real persisted-snapshot path runs without network.
  late final DeviceRepositoryService _repository;

  final _ssidCtl = TextEditingController();
  final _wifiPassCtl = TextEditingController();
  // Broker host/port are NOT hardcoded: they are fetched once at wizard start
  // (before the phone joins the offline Tasmota soft-AP, which has no route to
  // the backend) and populated from the backend's own broker-info endpoint. A
  // hardcoded default would silently reproduce Tasmota's factory broker.
  // The controllers stay `final`; `_loadBrokerInfo()` fills their text.
  final _mqttBrokerCtl = TextEditingController();
  final _mqttPortCtl = TextEditingController();
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

  // The device identity IS the canonical physical MAC, derived locally the
  // moment the setup AP is reached (see _readDeviceMac / normalizeMac). It is
  // never issued by the backend and never needs a session or claim token.
  String _issuedDeviceId = '';
  io.Socket? _provisionSocket;
  bool _watchAcked = false;
  bool _claimed = false;
  // Graded terminal-failure kind for the WAIT screen. Duplicates and
  // identity-unreadable get a Close-only recovery; everything else keeps the
  // existing recovery buttons.
  _TerminalKind _terminalKind = _TerminalKind.generic;
  // Explicit terminal-state guard. Once a closed-loop terminal failure
  // (duplicate identity, other-account registration, unreadable identity) is
  // shown, this becomes true and FREEZES the state machine: all polling timers,
  // the stage-advance timer, lifecycle-resume re-polling and Socket.IO wake-ups
  // are ignored until the user exits. A plain widget rebuild can never clear it;
  // it is only reset when the wizard exits.
  bool _terminal = false;
  // Whether the terminal failure was a wait-deadline (device never seen) - the
  // only case where "Wait a bit longer" makes sense. Provision conflicts and
  // other terminal errors get a Close-only recovery instead of a pointless
  // re-arm.
  bool _allowWaitRetry = false;
  // Set when the wizard enters the Reconfigure-Wi-Fi recovery flow. The
  // deviceId stays the same - a Wi-Fi correction is never a new registration.
  // Drives the recovery-aware connect screen.
  bool _recoveryMode = false;
  // Paces the WAIT stage labels: Wi-Fi for the early device-reboot window, then
  // MQTT. Labels are cosmetic pacing, never a functional timeout.
  Timer? _waitStageTimer;
  Timer? _stageRebootTimer;

  // Pre-flight Wi-Fi validation (Tasmota WifiTest3) is a local device operation
  // that runs while the phone is still bound to the Tasmota AP. Keeps the
  // testing state and the classifier result so the Configure screen can render
  // a specific error and stay put (no Restart, no identity change).
  WifiTestResult _wifiTestResult = WifiTestResult.unknown;

  // The canonical identity most recently submitted to the backend duplicate
  // gate (`GET /api/devices/check`). The gate runs at AP detection and again
  // in _provision() before the first config command; both calls are over the
  // phone's link to the backend, which is a best-effort UX check that can cost
  // seconds on the offline Tasmota AP (its own short timeout). Skipping the
  // second round-trip when the SAME identity was already checked is safe: the
  // gate outcome is never authoritative (see PART 4) and the backend still
  // enforces the real duplicate/ownership check in
  // POST /api/devices/provision. The second gate stays for the one case it
  // exists for — the MAC was NOT readable at AP detection, so no gate ran yet.
  // Note the RAM-only wizard-start snapshot ([_claimedMacsAtStart]) is checked
  // FIRST, before any backend round-trip: it never touches this bookkeeping.
  String _preflightCheckedFor = '';

  // The user's already-registered device MACs, snapshotted ONCE at wizard start
  // (while the phone is on its home network and the backend is reachable — the
  // Tasmota setup AP has no internet). Gate A: the fastest duplicate check,
  // fully offline, runs the moment the canonical MAC is first derived. Deliber-
  // ately never refreshed mid-wizard, so it must NOT be the only protection:
  // Gate B (see _stopIfRegisteredAtBoundary) re-verifies at the authoritative
  // provisioning boundary against the repository's registered-device authority.
  ClaimDeviceSnapshot _claimedMacsAtStart = ClaimDeviceSnapshot.empty();

  /// Broker endpoint the device must be provisioned to, fetched ONCE at wizard
  /// start while the phone is on its home network (the Tasmota setup AP has no
  /// internet route back to the backend). A `null` value after loading means the
  /// fetch FAILED — this is a hard blocker, never a silent default: without a
  /// known broker the wizard must not hand the device off to Tasmota's factory
  /// `broker.emqx.io`. Backend-served (backend/.env MQTT_BROKER_URL), so the
  /// address can never drift between the app and the broker in use.
  MqttBrokerInfo? _brokerInfo;
  String? _brokerInfoError;

  /// In-flight load of [_brokerInfo]. Blocking the Connect step on it makes a
  /// fast reopen wait the same way Gate A waits on the account snapshot.
  Future<void>? _brokerInfoLoad;

  /// In-flight registration of the once-at-start snapshot load. Gate B awaits
  /// it (it is normally already complete) so a fast reopen cannot race the
  /// snapshot and accidentally skip Gate A.
  Future<void>? _claimedMacsAtStartLoad;

  /// Post-claim Local HTTP readiness — deliberately DECOUPLED from the cloud
  /// claim. The claim commits on the backend first ([_registerDevice]); only
  /// these fields track whether direct LAN control has been enabled+verified.
  /// A failure here is a local-readiness problem and must never roll back
  /// ownership.
  bool _localSetupInProgress = false;
  bool _localSetupReady = false;
  String? _localSetupError;

  /// The most recent usable LAN IP (MQTT-learned or claim-carried) driving the
  /// local bootstrap; retained so Retry resumes from the last known address.
  String? _lastKnownIp;

  String get _phaseLabel {
    switch (_step) {
      case _Step.connect:
        return 'AP_CONNECT';
      case _Step.provision:
        return 'CONFIGURING';
      case _Step.waiting:
        return 'WAITING_FOR_DEVICE';
      case _Step.localControl:
        return 'LOCAL_CONTROL';
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _api = widget.testApi ?? ApiService();
    _repository = widget.testRepository ?? DeviceRepositoryService();
    // Test-only seeding: jump straight into a graded terminal failure (e.g. a
    // duplicate) so the "Remove Device" flow can be exercised in widget tests
    // without the offline AP / MQTT hardware steps.
    final code = widget.testFailureCode;
    if (code != null) {
      final deviceId = widget.testDeviceId ?? '';
      _issuedDeviceId = deviceId;
      _step = _Step.waiting;
      _state = ProvisionState.failed;
      _claimed = false;
      _allowWaitRetry = false;
      final kind = _terminalKindFor(
        ApiException(code, statusCode: 409, code: code),
      );
      _terminalKind = kind;
      // Seed the terminal freeze so the seeded duplicate state is stable (as it
      // would be after a real terminal result).
      _terminal = true;
      _error = code == 'DEVICE_ALREADY_EXISTS'
          ? _alreadyExistsMessage
          : 'This device is already registered to another account and cannot '
              'be added to this one.';
    }
    // Snapshot the user's registered devices once, at flow start. Loaded on the
    // home network, where the backend is reachable; on the Tasmota AP it never
    // is. Best-effort: any failure leaves the empty snapshot and the flow falls
    // back to the existing backend duplicate gates (also authoritative).
    if (code == null) {
      _claimedMacsAtStartLoad = _loadClaimedMacsAtStart();
      // Broker host/port for the device's MQTT config MUST be fetched now, on
      // the home network, before the user is allowed to proceed to the offline
      // Tasmota AP. Unlike the snapshot, a failure is a HARD blocker (see
      // _loadBrokerInfo): proceeding without a real broker would silently
      // reconfigure the device onto Tasmota's factory broker.
      _brokerInfoLoad = _loadBrokerInfo();
      unawaited(_probeApConnectSupport());
    }
    // The Connect phase is fully offline from the start - no backend session is
    // ever created. MAC read, Wi-Fi configuration and WifiTest3 all run against
    // the Tasmota AP (192.168.4.1); the backend is only contacted AFTER the
    // device restarts and rejoins the network, to register the device.
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Phase-dependent resume handling. The AP probe / Wi-Fi binding must run
    // ONLY during the initial "connect phone to Tasmota AP" phase. After the
    // Tasmota Restart command succeeds, the AP is EXPECTED to disappear, so we
    // must never re-probe 192.168.4.1 or show an AP connection error again.
    final bool resumed = state == AppLifecycleState.resumed;
    debugPrint('[PROVISION][LIFECYCLE] '
        '${resumed ? 'RESUME' : 'PAUSE'} phase=$_phaseLabel');
    if (!resumed) {
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
        // Returning from Wi-Fi Settings (or the foreground) restarts AP
        // detection from a clean slate. No session exists to recreate - the
        // Connect phase is offline by design.
        debugPrint(
            '[PROVISION] phase=$_phaseLabel lifecycle resumed - rechecking Tasmota AP');
        _startApDetection();
      case _Step.provision:
        debugPrint('[PROVISION] phase=$_phaseLabel lifecycle resumed - AP probe skipped (configuring)');
      case _Step.waiting:
        debugPrint('[PROVISION] phase=$_phaseLabel lifecycle resumed - AP probe skipped: provisioning already completed');
        if (_isTerminal) {
          // A closed-loop terminal state (duplicate etc.) must survive lifecycle
          // resume: never restart polling or re-trigger provisioning.
          debugPrint('[PROVISION] lifecycle resumed in terminal state - polling skipped');
          return;
        }
        _waitTimer?.cancel();
        _pollDeviceSeen();
      case _Step.localControl:
        debugPrint(
            '[PROVISION] phase=$_phaseLabel lifecycle resumed - local setup persists');
        if (_isTerminal) return;
        if (!_localSetupInProgress && !_localSetupReady) {
          // The retry loop died with the process paused: resume the LOCAL-
          // READINESS work only — the claim is still committed, so this is
          // never a new provisioning attempt.
          _startLocalSetup(_issuedDeviceId, _lastKnownIp);
        }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_releaseWifiBinding());
    _reachTimer?.cancel();
    _waitTimer?.cancel();
    _waitStageTimer?.cancel();
    _stageRebootTimer?.cancel();
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

  // Sends the user to Android/iOS Wi-Fi Settings to pick the device's setup AP.
  // Available from the very start - no backend session is required for the
  // offline Connect phase.
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

  // Reads the Android SDK int from `stees/ap_connect` once, at wizard start,
  // so the Connect step knows whether programmatic soft-AP connect is usable.
  // Any failure (MissingPlugin on iOS / in widget tests, etc.) disables it.
  Future<void> _probeApConnectSupport() async {
    try {
      final info = await _apConnectChannel
          .invokeMethod<Map<dynamic, dynamic>>('sdkInfo');
      _apConnectSdkInt = info?['sdkInt'] as int?;
      debugPrint('[PROVISION] ap_connect SDK support: ${_apConnectSdkInt ?? -1}');
    } catch (e) {
      debugPrint('[PROVISION] ap_connect support probe failed: $e');
      _apConnectSdkInt = null;
    }
  }

  // Smart connect entry: on Android API 29+ (when not disabled) it opens the
  // in-app Wi-Fi scan list so the user picks the device's setup AP explicitly,
  // then joins it programmatically via WifiNetworkSpecifier — no Wi-Fi Settings
  // jump, no captive-portal prompt. On API 24-28 / iOS / after a permission
  // denial it falls back to the original manual [.. _openWifiSettings] unchanged.
  Future<void> _connectToDeviceWifi() async {
    if (_step != _Step.connect) return;
    if (_apConnectSupported && !_apConnectMode) {
      final ok = await _connectToApViaPicker();
      if (!mounted || _step != _Step.connect) return;
      if (!ok) return; // error surfaced, or manual fallback in progress
      _startApDetection();
      return;
    }
    await _openWifiSettings();
  }

  // Opens the device-AP picker sheet, which scans for Wi-Fi networks in-app and
  // returns either the user's chosen SSID (→ programmatic join) or a fallback
  // sentinel. Returns true once the programmatic join bound (the caller should
  // run AP detection); false for a dismissed sheet, a manual fallback (the
  // session was flipped to manual and Wi-Fi Settings opened), or a failed
  // connect (the error UI was surfaced).
  Future<bool> _connectToApViaPicker() async {
    if (_step != _Step.connect) return false;
    if (mounted) {
      setState(() {
        _error = null;
        _programmaticConnectFailed = false;
      });
    }
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _DeviceApPickerSheet(),
    );
    if (!mounted || _step != _Step.connect) return false;
    if (selected == null) return false; // dismissed
    if (selected == '_manual') {
      // A permission denial or the user choosing the manual path: flip the
      // session to manual mode (no further specifier requests) and send them to
      // Wi-Fi Settings. Never an error.
      _apConnectDisabled = true;
      _apConnectMode = false;
      if (mounted) {
        setState(() {
          _searching = false;
          _apConnectPending = null;
        });
      }
      await _openWifiSettings();
      return false;
    }
    return _connectToApSsid(selected);
  }

  // Programmatic connect to an EXPLICIT user-selected SSID: request it via
  // WifiNetworkSpecifier, retry on onUnavailable. Returns true once the system
  // reports the network as available (the 192.168.4.1 probe runs afterwards,
  // unmodified, in _startApDetection).
  Future<bool> _connectToApSsid(String ssid) async {
    if (_step != _Step.connect) return false;
    if (mounted) {
      setState(() {
        _searching = true;
        _error = null;
        _apConnectPending = 'Connecting to $ssid…';
      });
    }
    _apConnectAttempts = 0;
    while (_apConnectAttempts < _apConnectMaxAttempts) {
      _apConnectAttempts++;
      if (mounted) {
        setState(() => _apConnectPending = 'Connecting to $ssid automatically…');
      }
      final stage = await _requestApConnect(ssid);
      if (stage == null) return false; // permission denied / channel fatal → manual fallback
      if (stage == 'available') {
        _apConnectMode = true;
        _wifiBound = true;
        _apConnectPending = null;
        debugPrint('[PROVISION] programmatic AP connect bound; probing next');
        return true;
      }
      // unavailable / lost / failed → short backoff, then a fresh request.
      if (mounted) {
        setState(() => _apConnectPending = 'Retrying connection to $ssid…');
      }
      await Future<void>.delayed(_apConnectBackoff(_apConnectAttempts));
    }
    _failProgrammatic(
      'Could not connect to the device setup network $ssid. Make sure the '
      'device is powered on and in setup mode, then try again or use Open '
      'Wi-Fi Settings.',
    );
    return false;
  }

  Duration _apConnectBackoff(int attempt) {
    switch (attempt) {
      case 1:
        return const Duration(milliseconds: 1200);
      case 2:
        return const Duration(milliseconds: 2000);
      default:
        return const Duration(milliseconds: 3000);
    }
  }

  // Issues one specifier request and waits for it to settle. Returns:
  //   'available'  → bound, proceed to the probe
  //   other stage  → terminal specifier outcome (unavailable/lost/failed) → retry
  //   null         → a hard fallback already happened (permission denied etc.)
  Future<String?> _requestApConnect(String ssid) async {
    try {
      await _apConnectChannel.invokeMethod<void>('connectToAp', {'ssid': ssid});
    } on PlatformException catch (e) {
      debugPrint('[PROVISION] connectToAp PlatformException: ${e.code} ${e.message}');
      if (e.code == 'PERMISSION_DENIED') {
        // NEARBY_WIFI_DEVICES denied on API 33+: never hard-block. The user is
        // sent to the (fully manual) Wi-Fi Settings flow for this session.
        _apConnectDisabled = true;
        _apConnectMode = false;
        if (mounted) {
          setState(() {
            _searching = false;
            _apConnectPending = null;
          });
        }
        await _openWifiSettings();
        return null;
      }
      if (e.code == 'UNSUPPORTED' || e.code == 'BAD_SSID') {
        _apConnectDisabled = true;
        if (mounted) {
          setState(() {
            _searching = false;
            _apConnectPending = null;
          });
        }
        await _openWifiSettings();
        return null;
      }
      return 'failed';
    } catch (e) {
      debugPrint('[PROVISION] connectToAp threw: $e');
      return 'failed';
    }
    final deadline = DateTime.now().add(_apConnectStateDeadline);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted || _step != _Step.connect) return null;
      Map<dynamic, dynamic>? st;
      try {
        st =
            await _apConnectChannel.invokeMethod<Map<dynamic, dynamic>>('getState');
      } catch (e) {
        debugPrint('[PROVISION] getState threw: $e');
        return 'failed';
      }
      final stage = st?['stage'] as String?;
      if (stage == 'available') return 'available';
      if (stage == 'unavailable' || stage == 'lost' || stage == 'failed') {
        debugPrint('[PROVISION] specifier stage=$stage; retrying');
        return stage!;
      }
      // requesting / awaiting_system / idle → keep waiting inside the poll.
    }
    debugPrint('[PROVISION] specifier state deadline exceeded');
    return 'failed';
  }

  void _failProgrammatic(String message) {
    debugPrint('[PROVISION] programmatic connect failed: $message');
    if (!mounted) return;
    setState(() {
      _searching = false;
      _apConnectPending = null;
      _apConnectMode = false;
      _programmaticConnectFailed = true;
      _error = message;
    });
  }

  Future<void> _startSearch() async {
    debugPrint('[PROVISION] phase=$_phaseLabel start search');
    // Broker info is fetched at wizard start on the home network (the Tasmota
    // setup AP has no route to the backend). Proceeding to the AP without it
    // would silently leave the device on Tasmota's factory broker later, so a
    // missing broker config is a HARD blocker: wait for the in-flight fetch,
    // then either proceed or show the blocking error.
    if (_brokerInfo == null) {
      final load = _brokerInfoLoad;
      if (load != null) {
        await load;
        if (!mounted) return;
      }
    }
    if (_brokerInfo == null) {
      debugPrint('[PROVISION] blocked: broker info not available');
      if (mounted) {
        setState(() => _error = _brokerInfoError ??
            'Could not load the MQTT broker address. Reopen Add Device while '
                'you have an internet connection.');
      }
      return;
    }
    // PHASE 1 (OFFLINE-AP): the phone is already on the Tasmota AP now (the
    // user picked it in Wi-Fi Settings and returned here, or the programmatic
    // connect below bound it). No backend call is allowed from this point - the
    // MAC, Wi-Fi config and WifiTest3 are all local device operations.
    debugPrint('[PROVISION] OFFLINE_AP_PHASE_START');
    debugPrint('[PROVISION] AP_CONNECT_START');
    // API 29+ (Android): open the in-app device-AP picker and join the chosen
    // network via WifiNetworkSpecifier — no settings jump, no captive-portal
    // prompt. On API 24-28 / iOS / after a permission denial this is skipped and
    // detection runs exactly as before against the manually selected network.
    if (_apConnectSupported && !_apConnectMode) {
      final ok = await _connectToApViaPicker();
      if (!mounted) return;
      if (!ok) return; // error surfaced, or manual fallback in progress
    }
    _startApDetection();
  }

  // Bind this process's sockets to the CURRENTLY ACTIVE Wi-Fi network (the one
  // the user manually selected in Android Wi-Fi settings). Unlike the old
  // requestNetwork() approach this never lets Android pick a different network
  // (e.g. the router) — getActiveNetwork() returns exactly the user's choice.
  Future<void> _ensureBoundToWifi() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) return;
    // In programmatic mode the specifier's `onAvailable` bind is the ONLY bind;
    // the manual channel must never run concurrently (it could re-bind to the
    // router network while the process is supposed to be pinned to the AP).
    if (_apConnectMode) {
      _wifiBound = true;
      return;
    }
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
    if (_apConnectMode) {
      // Programmatic mode unbinds through the specifier channel (which also
      // unregisters the callback and unbinds the process network).
      try {
        await _apConnectChannel.invokeMethod<void>('cancel');
        debugPrint('[PROVISION] programmatic AP connect cancelled / binding released');
      } catch (_) {}
      _apConnectMode = false;
      _wifiBound = false;
      return;
    }
    try {
      await _wifiBindChannel.invokeMethod<void>('releaseWifiBinding');
      debugPrint('[PROVISION] wifi binding released');
    } catch (_) {}
    _wifiBound = false;
  }

  Future<bool> _isReachable() async {
    try {
      debugPrint('[PROVISION] probing $_deviceUrl');
      final res = await _httpGet(Uri.parse(_deviceUrl))
          .timeout(const Duration(seconds: 3));
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

  // Single HTTP fetch path for every Tasmota setup-AP request. Uses the
  // injected [widget.testHttpClient] in widget tests (so the flow can be driven
  // without a real device / network) and the default top-level [http.get]
  // otherwise. Never throws; call sites apply their own timeouts.
  Future<http.Response> _httpGet(Uri uri) async {
    final custom = widget.testHttpClient;
    if (custom != null) return custom.get(uri);
    final client = http.Client();
    try {
      return await client.get(uri);
    } finally {
      client.close();
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
    // The Connect step must not probe the Tasmota AP until the broker endpoint
    // is known (fetched at wizard start on the home network). A missing broker
    // would later write Tasmota's factory default into the device. Recovery
    // re-enters Connect after a broker info already loaded earlier, so this
    // only blocks the initial flow.
    if (_brokerInfo == null) {
      debugPrint('[PROVISION] blocked AP detection: broker info not available');
      if (mounted) {
        setState(() {
          _searching = false;
          _error = _brokerInfoError ??
              'Could not load the MQTT broker address. Reopen Add Device while '
                  'you have an internet connection.';
        });
      }
      return;
    }
    _reachTimer?.cancel();
    _apProbeGen++;
    final gen = _apProbeGen;
    _apProbeStart = DateTime.now();
    _apAttempt = 0;
    _wifiBound = false;
    _apConnectPending = null;
    _programmaticConnectFailed = false;
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
      _stageRebootTimer?.cancel();
      debugPrint('[PROVISION] device AP reachable');
      if (!mounted || _step != _Step.connect) return;
      // Derive the device identity as soon as the AP is reachable - offline
      // and harmless (Status 5 is read-only, no reboot). It feeds the Configure
      // screen header and is re-confirmed when Apply runs.
      final mac = await _readDeviceMac();
      if (!mounted || _step != _Step.connect) return;
      final canonical = mac == null ? null : normalizeMac(mac);
      if (canonical != null) {
        _issuedDeviceId = canonical;
        debugPrint('[PROVISION] device identity (canonical MAC): $canonical');
        // Pre-flight duplicate check at the EARLIEST point the canonical
        // identity exists - as soon as the setup AP is reachable, before the
        // Configure step. If the backend confirms the MAC is already
        // registered the wizard freezes into the right terminal state here,
        // so the user never reaches the provisioning form. An unreachable
        // backend (no internet on the Tasmota AP) silently continues and the
        // same gate re-runs in _provision() before any config command.
        if (await _stopIfAlreadyRegistered(canonical)) return;
      } else {
        debugPrint('[PROVISION] MAC not readable yet (retried on Apply)');
      }
      _trace.enter(ProvisionPhase.ap, 'AP_DETECTED');
      debugPrint('[PROVISION][AP] AP_DETECTED');
      debugPrint('[PROVISION] AP_CONNECTED');
      if (_recoveryMode) {
        traceLog('RECOVERY', 'AP_FOUND total=${_trace.elapsedMs}ms');
        traceLog('RECONFIGURE', 'START total=${_trace.elapsedMs}ms');
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

  // The device identity IS the physical Tasmota MAC (canonical form, see
  // [normalizeMac]) - it equals the MQTT topic burned into the firmware, is
  // immutable for the life of the device, and is derived locally the moment the
  // setup AP is reached. Renaming the device later only edits the display name
  // on the Device record - it never changes the MQTT topic or identity. The
  // backend stores this MAC verbatim as deviceId when the wizard registers the
  // device after it comes online.

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
    // We are in the OFFLINE-AP phase: no backend call is made or needed here.
    // The device identity is derived from the MAC read just below, locally.

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

    // THE device identity = the physical MAC. Status 5 is a read-only query
    // (no reboot) so it is safe on the setup AP. The MAC is derived to its
    // canonical deviceId LOCALLY and never sent anywhere while offline; the
    // backend learns it only in the first online step after the restart. If the
    // MAC cannot be read there is no identity to provision - fail cleanly
    // instead of guessing.
    final mac = await _readDeviceMac();
    var canonical = mac == null || mac.trim().isEmpty
        ? null
        : normalizeMac(mac);
    // The identity was already read when the AP was first detected - reuse it
    // if this fresh read failed transiently.
    if (canonical == null &&
        _issuedDeviceId.isNotEmpty &&
        isCanonicalDeviceId(_issuedDeviceId)) {
      canonical = _issuedDeviceId;
      debugPrint('[PROVISION] reused identity read at AP detection');
    }
    if (canonical == null) {
      if (!mounted) return;
      setState(() {
        _provisioning = false;
        _state = ProvisionState.failed;
        _terminalKind = _TerminalKind.identityUnreadable;
        _error = "The device's identity couldn't be read. Power-cycle the "
            'device and try again.';
      });
      return;
    }
    _issuedDeviceId = canonical;
    debugPrint('[PROVISION] device identity (canonical MAC): $canonical');

    // Gate A — hard duplicate check BEFORE any provisioning operation: even if
    // the MAC read failed at AP-detection time (so the Configure step was
    // entered without a check), the identity is guaranteed right now. The RAM
    // snapshot is checked first (fully offline), then the backend pre-flight.
    // An unreachable backend (no internet while on the Tasmota AP) silently
    // continues — which is why Gate B below, at the authoritative provision
    // boundary, re-verifies against the repository before ANY config command.
    if (await _stopIfAlreadyRegistered(canonical)) return;

    // Gate B — AUTHORITATIVE provisioning-boundary duplicate check. Runs
    // immediately before the first Tasmota configuration command and re-verifies
    // the MAC against the repository's registered-device authority (cloud list +
    // persisted local mirror), NOT transient wizard state. This is what makes
    // the duplicate rule a hard invariant: closing the wizard, reopening Add
    // Device, recreating the widget, an unloaded session snapshot, a stale UI
    // state, or another code path calling into provisioning can never let an
    // already-registered MAC reach the configuration phase.
    if (await _stopIfRegisteredAtBoundary(canonical)) return;

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
      // Configure (step already is _Step.provision), preserve the deviceId,
      // surface the specific Wi-Fi message and let the user correct the
      // credentials and test again. Nothing was persisted and no Restart was
      // sent.
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
    // First ONLINE action after the restart: the wait loop polls whether the
    // device has announced on MQTT and registers it once observed. Nothing
    // needs to be anchored or claimed - the MAC read offline IS the identity.
    if (!mounted) return;
    _waitForDeviceOnline();
  }

  // Reads the immutable Tasmota MAC via the read-only `Status 5` query.
  Future<String?> _readDeviceMac() async {    try {
      final uri = Uri.parse('$_deviceUrl/cm').replace(
        queryParameters: {'cmnd': 'Status 5'},
      );
      debugPrint('[PROVISION] reading device MAC (Status 5)');
      final res = await _httpGet(uri).timeout(const Duration(seconds: 4));
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
//     keeps the same deviceId, and never writes SSID/password or sends Restart.
//  5) Home Wi-Fi credentials LAST (SSId1/Password1) so the device stays on the
//     setup AP during identity configuration and only leaves it on the final
//     `Restart 1`, i.e. once it can reach the home router + broker.
//  6) Every persisted setting is read back and compared BEFORE `Restart 1`, so
//     a silently-dropped write fails loudly instead of a device that never
//     comes online under the expected topic.
Future<_ConfigOutcome> _sendTasmotaConfig() async {
  await _ensureBoundToWifi();
  _trace.enter(ProvisionPhase.config, 'BROKER_BACKLOG');

  // Defense in depth: the Connect step already blocks without broker info, but
  // never write an empty/default host if this is somehow reached - a device on
  // Tasmota's factory broker is exactly the bug this guard exists to prevent.
  final brokerHost = _mqttBrokerCtl.text.trim();
  final brokerPort = _mqttPortCtl.text.trim();
  if (brokerHost.isEmpty || brokerPort.isEmpty) {
    debugPrint(
        '[PROVISION] VERIFY FAILED: broker host/port not loaded - aborting');
    return _ConfigOutcome.configFailed;
  }
  debugPrint('[PROVISION] configuring MQTT broker $brokerHost:$brokerPort...');
  final brokerParts = <String>[
    if (_mqttUserCtl.text.trim().isNotEmpty)
      'MqttUser ${_mqttUserCtl.text.trim()}',
    if (_mqttPassCtl.text.isNotEmpty) 'MqttPassword ${_mqttPassCtl.text}',
    'MqttHost $brokerHost',
    'MqttPort $brokerPort',
  ];
  final brokerOk = await _sendCommand('Backlog ${brokerParts.join('; ')}');
  debugPrint('[PROVISION] MQTT broker response=${brokerOk ? 'OK' : 'FAILED'}');
  if (!brokerOk) return _ConfigOutcome.configFailed;
  _trace.debugTrace(ProvisionPhase.config, label: 'BROKER_VERIFY');

  debugPrint('[PROVISION] configuring MQTT identity...');
  final topic = _issuedDeviceId;
  if (topic.isEmpty) {
    debugPrint('[PROVISION] VERIFY FAILED: no deviceId (MAC not read)');
    return _ConfigOutcome.configFailed;
  }
  // Pin the topic layout to the default "%prefix%/%topic%/" so the device
  // ALWAYS publishes on tele/<topic>/STATE (and stat/<topic>/...). A leftover
  // custom FullTopic on the device would shift the deviceId to a different
  // topic segment and the wizard would never match it.
  //
  // Topic + FullTopic are written in a SINGLE Backlog: writing either setting
  // makes the device reboot back to the setup AP, so one Backlog collapses two
  // write -> reboot -> AP-return cycles into one (the dominant App-controlled
  // latency of the whole config sweep). Both values are read back and verified
  // BEFORE any home-Wi-Fi credential is persisted and BEFORE Restart 1. If the
  // device reboots mid-Backlog (Tasmota may restart on Topic) and a read-back
  // then mismatches, the proven sequential per-setting path below is used —
  // identical behavior to the pre-batch code, at worst one extra read-back.
  if (!await _applyIdentityBatched(topic)) {
    if (!await _setDeviceSetting('Topic', topic)) {
      return _ConfigOutcome.configFailed;
    }
    _trace.debugTrace(ProvisionPhase.config, label: 'TOPIC_VERIFIED');
    if (!await _setDeviceSetting('FullTopic', '%prefix%/%topic%/')) {
      return _ConfigOutcome.configFailed;
    }
    _trace.debugTrace(ProvisionPhase.config, label: 'FULLTOPIC_VERIFIED');
  }

  // Physical relay layout: pin the Tasmota module to one exposing exactly the
  // channels the user selected. Stock Tasmota starts on a SINGLE-relay module,
  // so picking "4 Relays" but never writing the module leaves a 4-channel
  // device reporting only POWER1 — exactly the bug this fixes. oneRelay writes
  // nothing (a stock Tasmota already exposes one relay).
  final module = _deviceType.tasmotaModule;
  if (module != null) {
    debugPrint(
        '[PROVISION] configuring module $module for ${_deviceType.name} '
        '(${_deviceType.channelCount} relay(s))...');
    if (!await _applyModule(module)) {
      return _ConfigOutcome.configFailed;
    }
    _trace.debugTrace(ProvisionPhase.config, label: 'MODULE_VERIFIED');
  }

  final nameOk = await _sendCommand('DeviceName ${_deviceNameCtl.text.trim()}');
  debugPrint('[PROVISION] DeviceName response=${nameOk ? 'OK' : 'FAILED'}');
  if (!nameOk) return _ConfigOutcome.configFailed;

  // Pre-flight Wi-Fi credential validation. The device is still on the setup
  // AP; WifiTest3 runs locally against the network and proves the credentials
  // BEFORE SSID1/Password1 are written. A failure stays on Configure with a
  // Wi-Fi-specific message - no persist, no Restart, same identity.
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
    'MqttHost': brokerHost,
    'MqttPort': brokerPort,
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

  // Writes the physical relay-layout module and verifies the device actually
  // switched to it. Reboot-prone like _setDeviceSetting (Tasmota restarts after
  // a module change), so we wait for the device to return on the setup AP too.
  // The bare `Module` command's read-back is NOT a plain scalar: firmware 15.x
  // answers {"Module":{"23":"Sonoff 4CH Pro"}} and older builds
  // {"Module":"23 (Sonoff 4CH Pro)"} — the generic _verifySetting string
  // compare would always fail, so this accepts any of those shapes.
  Future<bool> _applyModule(int module) async {
    final ok = await _sendCommand('Module $module');
    debugPrint('[PROVISION] Module write response=${ok ? 'OK' : 'FAILED'}');
    if (!ok) return false;
    await _waitForDeviceOnAp();
    return _verifyModule(module);
  }

  Future<bool> _verifyModule(int module) async {
    for (var attempt = 1; attempt <= 6; attempt++) {
      try {
        final uri = Uri.parse('$_deviceUrl/cm')
            .replace(queryParameters: {'cmnd': 'Module'});
        debugPrint('[PROVISION] read-back GET $uri (attempt $attempt)');
        final res = await _httpGet(uri).timeout(const Duration(seconds: 3));
        final body = res.body.trim();
        if (res.statusCode != 200) {
          debugPrint('[PROVISION] read-back Module HTTP ${res.statusCode}');
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }
        final decoded = jsonDecode(body);
        final got = decoded is Map ? decoded['Module'] : null;
        final wanted = '$module';
        final matched = got is int
            ? got == module
            : got is String
                ? got == wanted || got.startsWith('$wanted ')
                : got is Map
                    ? got.containsKey(wanted)
                    : false;
        if (!matched) {
          debugPrint('[PROVISION] VERIFY FAILED: Module=$got expected=$wanted');
          return false;
        }
        debugPrint('[PROVISION] verification OK: Module=$got');
        return true;
      } catch (e) {
        debugPrint('[PROVISION] read-back Module exception (attempt $attempt): $e');
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    debugPrint('[PROVISION] VERIFY FAILED: Module unreachable after retries');
    return false;
  }

  // Writes Topic + FullTopic in ONE `Backlog` so the write-triggered reboot
  // back to the setup AP happens exactly once instead of twice. Returns true
  // only when the Backlog was accepted AND both read-backs match (each
  // `_verifySetting` already retries across the transient reboot window). On
  // any failure the caller falls back to the sequential [_setDeviceSetting]
  // path, which is byte-for-byte the old behavior.
  Future<bool> _applyIdentityBatched(String topic) async {
    const fullTopic = '%prefix%/%topic%/';
    final batched = 'Backlog Topic $topic; FullTopic $fullTopic';
    final ok = await _sendCommand(batched);
    debugPrint('[PROVISION] identity Backlog response=${ok ? 'OK' : 'FAILED'}');
    if (!ok) return false;
    await _waitForDeviceOnAp();
    if (!await _verifySetting('Topic', topic)) return false;
    if (!await _verifySetting('FullTopic', fullTopic)) return false;
    _trace.debugTrace(ProvisionPhase.config, label: 'IDENTITY_BATCH_VERIFIED');
    return true;
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
      final res = await _httpGet(uri).timeout(const Duration(seconds: 4));
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
        final res = await _httpGet(uri).timeout(const Duration(seconds: 3));
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
      final res = await _httpGet(startUri).timeout(_wifiTestHttpTimeout);
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
        final res = await _httpGet(pollUri).timeout(_wifiTestHttpTimeout);
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
  // Wait for the device to come online, then register it directly.
  // ──────────────────────────────────────────────────────────

  void _waitForDeviceOnline() {
    debugPrint('[PROVISION] BACKEND_WAIT_START');
    debugPrint('[PROVISION] waiting for device online: deviceId=$_issuedDeviceId');
    _trace.enter(ProvisionPhase.mqtt, 'WAIT_MQTT_DEVICE');
    _waitStart = DateTime.now();
    _claimed = false;
    // Stage label pacing: "Rebooting device…" for the immediate boot window,
    // then "Connecting device to Wi-Fi…", then "Connecting device to MQTT…".
    // Pure UX - the deadline and polling cadence are untouched by it.
    _state = ProvisionState.waitingForReboot;
    _waitStageTimer?.cancel();
    _stageRebootTimer?.cancel();
    _waitStageTimer = Timer(_stageAdvance, () {
      if (!mounted || _step != _Step.waiting || _isTerminal) return;
      setState(() {
        _state = ProvisionState.waitingForMqtt;
      });
    });
    _stageRebootTimer = Timer(_stageRebootAdvance, () {
      if (!mounted || _step != _Step.waiting || _isTerminal) return;
      if (_state != ProvisionState.waitingForReboot) return;
      setState(() {
        _state = ProvisionState.waitingForWifi;
      });
    });
    // Authoritative polling: does this device announce on MQTT (source of truth).
    _pollDeviceSeen();
    // Optional fast path: Socket.IO wake-up for this deviceId only.
    unawaited(_startDeviceWatch());
  }

  // Socket.IO fast path. Notification only - never the source of truth. The
  // server emits device_seen to the provision:<deviceId> room when this exact
  // device announces on MQTT; only authenticated clients that verified they may
  // watch that MAC (server-side) may join, so it never leaks foreign devices.
  Future<void> _startDeviceWatch() async {
    final deviceId = _issuedDeviceId;
    if (deviceId.isEmpty || _isTerminal) return;
    _closeProvisionSocket();
    final token = await AuthService().getToken();
    if (!mounted || token == null || _isTerminal) {
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
      debugPrint('[PROVISION] socket connected, watching device $deviceId');
      socket.emitWithAck('provision_watch', <String, dynamic>{
        'deviceId': deviceId,
      }, ack: (data) {
        if (!mounted) return;
        final map = data is Map ? data : null;
        _watchAcked = map != null && map['ok'] == true;
        debugPrint('[PROVISION] provision_watch ack: $_watchAcked');
      });
    });
    socket.on('device_seen', (data) {
      if (!mounted || _isTerminal) return;
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

  Future<void> _pollDeviceSeen() async {
    _waitTimer?.cancel();
    if (_step != _Step.waiting || _isTerminal) return;
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
    final deviceId = _issuedDeviceId;
    if (deviceId.isEmpty) return;
    bool seen = false;
    try {
      final status = await _api.getDeviceSeen(deviceId);
      seen = status['seen'] == true;
      debugPrint('[PROVISION] device seen poll: deviceId=$deviceId seen=$seen');
      if (!seen) {
        debugPrint('[PROVISION] DEVICE ID MISMATCH expected=$deviceId '
            'received=<no recent MQTT packet on that topic>');
      }
    } catch (e) {
      debugPrint('[PROVISION] device seen poll failed: $e');
      seen = false;
    }
    if (!mounted || _step != _Step.waiting || _isTerminal) return;
    if (seen) {
      await _onDeviceDetected();
      return;
    }
    // Re-arm only if the terminal freeze did not happen while the poll was in
    // flight (e.g. a lifecycle resume racing with a duplicate result).
    if (_isTerminal) return;
    _waitTimer = Timer(_seenPollInterval, () => _pollDeviceSeen());
  }

  // Terminal stop of the wait loop. The device never appeared before the
  // deadline (or the backend could not be reached). This is a RECOVERY state,
  // not a dead-end: the wizard keeps its identity and offers Reconfigure Wi-Fi
  // (re-acquire the Tasmota AP, correct credentials, re-run the same flow),
  // Try again (fresh deadline - the device may still be slow to reboot) and
  // Close. The cause is deliberately non-specific: the backend cannot
  // distinguish a wrong password from a wrong network, 5 GHz-only Wi-Fi, an
  // unavailable network, a device power loss or an MQTT/backend hiccup -
  // recovery for all of them is the same, so the wording stays evidence-based.
  void _finishWaitFailed() {
    _waitTimer?.cancel();
    _waitStageTimer?.cancel();
    _stageRebootTimer?.cancel();
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
    if (!mounted || _step != _Step.waiting || _isTerminal) return;
    if (_claimed) return;
    // A terminal freeze must never be overwritten by an in-flight device-seen
    // callback that was racing with a duplicate result.
    if (_isTerminal) return;
    _claimed = true;
    _waitTimer?.cancel();
    _waitStageTimer?.cancel();
    _stageRebootTimer?.cancel();
    _closeProvisionSocket();
    _trace.enter(ProvisionPhase.backend, 'DEVICE_DETECTED');
    debugPrint('[PROVISION] DEVICE_SEEN via ${_watchAcked ? 'socket' : 'poll'}');
    if (mounted) {
      setState(() {
        _state = ProvisionState.deviceDetected;
      });
    }
    // Tactile confirmation that the device was seen and is being registered.
    unawaited(HapticFeedback.mediumImpact());
    await _registerDevice();
  }

  Future<void> _registerDevice() async {
    final deviceId = _issuedDeviceId;
    if (deviceId.isEmpty) {
      _setError('Device identity was lost. Please try again.');
      return;
    }
    // Never start an automatic provisioning attempt (or move back to a loading
    // state) while a closed-loop terminal state is active.
    if (_isTerminal) return;
    final rawName = _deviceNameCtl.text.trim();
    final name = rawName.isEmpty ? 'STEES Smart Device' : rawName;
    if (!mounted) return;
    setState(() {
      _state = ProvisionState.claiming;
    });
    try {
      _trace.enter(ProvisionPhase.claim, 'REGISTERING');
      final claimed = await _api.provisionDevice(
        deviceId: deviceId,
        name: name,
        channels: _deviceType.channelCount,
      );
      _trace.enter(ProvisionPhase.claim, 'REGISTERED');
      _recoveryMode = false;
      debugPrint('[PROVISION] REGISTER_SUCCESS deviceId=$deviceId');
      debugPrint('[PROVISION] total provisioning elapsed ${_trace.elapsedMs}ms');
      await _cacheUpsertDevice(deviceId, name);

      // A brand-new claim response carries NO lastIp: the backend learns the
      // LAN IP only from the device's first tele/STATE over MQTT (it is not part
      // of the claim row). The device just restarted onto home Wi-Fi and is
      // already connected to the broker (the seen/poll state confirmed it), so
      // its STATE — with IPAddress — lands within seconds. Poll the device list
      // briefly so the local-setup bootstrap below is driven by a real IP
      // instead of failing on a null hint.
      String? lastIp = claimed['lastIp'] as String?;
      if (!isValidLocalIp(lastIp)) {
        lastIp = null;
        traceLog('CLAIM', 'LAST_IP_WAIT total=${_trace.elapsedMs}ms');
        for (var i = 0; i < _lastIpWaitTries; i++) {
          await Future<void>.delayed(_lastIpWaitInterval);
          lastIp = await _awaitClaimLastIp(deviceId);
          if (isValidLocalIp(lastIp)) break;
        }
        traceLog('CLAIM', 'LAST_IP_WAIT_END ip=$lastIp total=${_trace.elapsedMs}ms');
      }

      // The backend claim has COMMITTED — ownership is final. Local HTTP
      // readiness is a SEPARATE concern from here on: a temporary LAN/network
      // miss (phone still transitioning off the Tasmota AP, device HTTP server
      // or router ARP still settling) must NEVER roll ownership back. No
      // unclaim, no delete, no re-provision — the device stays claimed and
      // cached; only the bounded local-setup loop below (plus its manual Retry
      // on the recoverable screen) marks local control ready.
      traceLog('CLAIM', 'PROVISION_OK total=${_trace.elapsedMs}ms '
          'deviceId=$deviceId');
      _lastKnownIp = lastIp;
      if (!mounted) return;
      setState(() {
        _step = _Step.localControl;
        _state = ProvisionState.settingUpLocalControl;
      });
      _startLocalSetup(deviceId, lastIp);
      return;
    } on ApiException catch (e) {
      if (!mounted) return;
      _claimed = false;
      debugPrint('[PROVISION] REGISTER_FAILED status=${e.statusCode} '
          'code=${e.code} msg=${e.message}');
      if (_isTerminalProvisionError(e)) {
        // Graded, phase-appropriate recovery. Terminal errors are NOT retried
        // (they would re-fail forever): the wizard freezes on a terminal screen
        // and every polling/socket/lifecycle callback is torn down so the
        // duplicate state can never flicker back to a loading state.
        traceLog('CLAIM', 'TERMINAL total=${_trace.elapsedMs}ms');
        _enterTerminalState(_terminalKindFor(e), _provisionFailureMessage(e));
        return;
      }
      // Recoverable (device not on MQTT yet, transient 5xx/429/network):
      // keep waiting so a slow MQTT connect still completes - never leave
      // the device silently orphaned.
      if (_isTerminal) return;
      _setError(_provisionRecoveryMessage(e));
      setState(() {
        _state = ProvisionState.waitingForMqtt;
      });
      _waitTimer = Timer(_seenPollInterval, () => _pollDeviceSeen());
    } catch (e) {
      if (!mounted) return;
      _claimed = false;
      debugPrint('[PROVISION] REGISTER_FAILED network: $e');
      // Network / timeout: recoverable. Fall back to polling for the device.
      if (_isTerminal) return;
      _setError('Could not reach STEES. Waiting and retrying…');
      setState(() {
        _state = ProvisionState.waitingForMqtt;
      });
      _waitTimer = Timer(_seenPollInterval, () => _pollDeviceSeen());
    }
  }

  // Loads the broker host/port once, at wizard start, from the backend's own
  // broker-info endpoint (which serves backend/.env MQTT_BROKER_URL). A failure
  // is a HARD blocker — never a silent fallback to a hardcoded default:
  // proceeding without a known broker would write Tasmota's factory
  // `broker.emqx.io` into every device. The Connect step stays disabled until
  // [_brokerInfo] is set, and a failed fetch is surfaced as a blocking error so
  // the user can fix connectivity and reopen instead of misconfiguring a device.
  Future<void> _loadBrokerInfo() async {
    try {
      final info = await _api
          .getMqttBrokerInfo()
          .timeout(_brokerInfoTimeout);
      if (!_isTerminal && mounted) {
        _mqttBrokerCtl.text = info.host;
        _mqttPortCtl.text = '${info.port}';
        setState(() {
          _brokerInfo = info;
          _brokerInfoError = null;
        });
        debugPrint('[PROVISION] broker info loaded: ${info.host}:${info.port}');
      }
    } catch (e) {
      debugPrint('[PROVISION] broker info load failed (blocking): $e');
      if (!_isTerminal && mounted) {
        setState(() {
          _brokerInfo = null;
          final msg = 'Could not load the MQTT broker address from the '
              'backend. Make sure you are online, then reopen Add Device.';
          _brokerInfoError = msg;
          // Surface immediately on the Connect screen so the blocker is visible
          // before the user even taps Continue, not only after the tap.
          _error = msg;
        });
      }
    }
  }

  // Loads the user's registered device MACs once, at wizard start, into the
  // immutable [_claimedMacsAtStart] snapshot that powers Gate A (the early
  // offline duplicate gate). Seeds from the PERSISTED account snapshot
  // (SharedPreferences) — so a reopen on the offline Tasmota AP still sees the
  // account's registered identities — then refreshes from the authoritative
  // cloud list and persists the fresh result. Best-effort and silent: a failed
  // refresh keeps the persisted snapshot; Gate B at the provisioning boundary
  // re-verifies against the repository authority, so a stale/empty snapshot can
  // NEVER let an existing MAC into provisioning.
  Future<void> _loadClaimedMacsAtStart() async {
    // 1. Seed from the PERSISTED account snapshot first (SharedPreferences):
    //    fast, fully offline, and it survives Close/reopen, wizard recreation
    //    and app restarts — the reopen duplicate block does not depend on the
    //    phone having internet on the Tasmota AP. A null store (never refreshed,
    //    or another account's snapshot) yields the empty set.
    _claimedMacsAtStart = ClaimDeviceSnapshot.fromMacs(
      await _deviceCache.loadAccountSnapshotMacs() ?? const <String>{},
    );
    // 2. Refresh from the authoritative cloud list (bounded). A success
    //    REPLACES both the in-memory snapshot and the persisted account
    //    snapshot. Any failure keeps the persisted knowledge — a network
    //    failure must never erase already-known registered identities.
    try {
      final devices = await _api
          .getDevices()
          .timeout(_snapshotRefreshTimeout);
      if (_isTerminal || !mounted) return;
      _claimedMacsAtStart = ClaimDeviceSnapshot.fromDevices(devices);
      await _deviceCache.saveAccountSnapshot(
        devices.whereType<Map<String, dynamic>>().toList(),
      );
      debugPrint('[PROVISION] wizard-start registered snapshot refreshed: '
          '${_claimedMacsAtStart.macs.length} device(s)');
    } catch (_) {
      debugPrint('[PROVISION] wizard-start registered snapshot unavailable — '
          'using persisted snapshot '
          '(${_claimedMacsAtStart.macs.length} device(s))');
    }
  }

  // Best-effort pre-flight duplicate check, run ONCE the canonical identity is
  // known, BEFORE any provisioning/configuration operation. Returns a terminal
  // kind to freeze on, or null to continue provisioning normally. Purely a UX
  // optimization - NOT authoritative (see PART 4): the backend still enforces
  // the real duplicate/ownership check in POST /api/devices/provision. A short
  // timeout and silent failure mean an unreachable backend (no internet on the
  // Tasmota AP) never blocks or errors the flow.
  Future<_TerminalKind?> _preflightDuplicateCheck(String mac) async {
    DeviceDuplicateStatus? status;
    try {
      status = await _api.preflightDeviceCheck(mac).timeout(_preflightTimeout);
    } catch (_) {
      // Unreachable backend, timeout or any failure: silently continue with the
      // normal provisioning flow. Never show a scary network error here.
      status = null;
    }
    switch (decidePreflight(status)) {
      case PreflightDecision.stopMine:
        return _TerminalKind.alreadyAdded;
      case PreflightDecision.stopOthers:
        return _TerminalKind.alreadyRegistered;
      case PreflightDecision.continueProvisioning:
        return null;
    }
  }

  // Duplicate gate. Runs whenever the canonical identity becomes available - at
  // AP detection (the earliest possible point) and again in _provision()
  // immediately before the first Tasmota config command, so an already-existing
  // device NEVER gets configured or connected to the user's Wi-Fi. Returns true
  // (and freezes the wizard into a terminal "already added / already registered"
  // state) when a duplicate is confirmed, false to continue provisioning.
  //
  // Layer 1 is the RAM-only wizard-start snapshot (fully offline, no backend
  // round-trip). Layer 2 is the backend pre-flight (GET /api/devices/check),
  // which catches a device claimed after the snapshot; it is best-effort — an
  // unreachable backend silently continues (see _preflightDuplicateCheck).
  //
  // The SAME canonical identity is only checked against the backend ONCE: the
  // second call site (the hard gate in _provision) is skipped when this
  // identity already passed the AP-detection gate. Both round-trips run over
  // the phone's link to the backend — seconds on the offline Tasmota AP — and
  // the gate is never authoritative, so a revisiting duplicate check buys
  // nothing but latency. The hard gate only spends its round-trip for the one
  // case it was added for: the MAC could not be read at AP detection, so no
  // gate ran for this identity yet.
  Future<bool> _stopIfAlreadyRegistered(String canonical) async {
    // RAM-only early gate, fully offline — the phone can be on the Tasmota AP
    // with no internet. The snapshot was taken at wizard start on the home
    // network, so a MAC found here certifies the duplicate WITHOUT any backend
    // round-trip (works even with no connectivity on the AP). A device claimed
    // AFTER the snapshot is still caught by the backend pre-flight below and by
    // POST /api/devices/provision itself.
    if (_claimedMacsAtStart.containsMac(canonical)) {
      debugPrint('[PROVISION] $canonical already registered (wizard-start '
          'snapshot) — stopping before any provisioning command');
      _enterTerminalState(_TerminalKind.alreadyAdded, _alreadyExistsMessage);
      return true;
    }
    if (_preflightCheckedFor == canonical) {
      debugPrint(
          '[PROVISION] duplicate gate already run for $canonical — skipping '
          'redundant round-trip');
      return false;
    }
    final duplicateKind = await _preflightDuplicateCheck(canonical);
    _preflightCheckedFor = canonical;
    if (!mounted) return true;
    if (duplicateKind != null) {
      final msg = duplicateKind == _TerminalKind.alreadyAdded
          ? _alreadyExistsMessage
          : 'This device is already registered to another account and cannot '
              'be added to this one.';
      _enterTerminalState(duplicateKind, msg);
      return true;
    }
    return false;
  }

  // Gate B — the AUTHORITATIVE duplicate check at the provisioning boundary.
  // Called in _provision() immediately before the first Tasmota configuration
  // command. Unlike Gate A / the backend pre-flight (UX best-effort, both able
  // to silently pass when the AP has no internet), this consults the
  // repository's registered-device authority, which does NOT depend on
  // transient wizard state:
  //
  //   1. the once-at-start session snapshot is awaited and re-checked (so a
  //      fast reopen can never race it);
  //   2. then `DeviceRepositoryService.isDeviceRegistered` — the cloud-authorised
  //      registered list (bounded) plus the PERSISTED local mirror — certifies
  //      the MAC against every source the app itself trusts, offline included.
  //
  // A MAC registered in ANY of those sources freezes the wizard into the
  // terminal duplicate state and NEVER sends a configuration command. Returns
  // true only when the flow must stop.
  Future<bool> _stopIfRegisteredAtBoundary(String canonical) async {
    final load = _claimedMacsAtStartLoad;
    if (load != null) await load;
    if (_claimedMacsAtStart.containsMac(canonical)) {
      debugPrint('[PROVISION] $canonical already registered (session snapshot) '
          '— stopping at the provisioning boundary');
      _enterTerminalState(_TerminalKind.alreadyAdded, _alreadyExistsMessage);
      return true;
    }
    final hook = widget.testIsDeviceRegistered;
    if (hook != null) {
      final registered = await hook(canonical);
      if (registered) {
        debugPrint('[PROVISION] $canonical already registered (test boundary '
            'verdict) — stopping before any provisioning command');
        _enterTerminalState(_TerminalKind.alreadyAdded, _alreadyExistsMessage);
      }
      return registered;
    }
    try {
      final state = await _repository
          .registrationState(canonical)
          .timeout(const Duration(seconds: 4));
      if (state == RegistrationState.registered) {
        debugPrint('[PROVISION] $canonical already registered (authoritative '
            'repository check) — stopping before any provisioning command');
        _enterTerminalState(_TerminalKind.alreadyAdded, _alreadyExistsMessage);
        return true;
      }
      // `notRegistered` = a valid source shows the MAC absent (evidence);
      // `unknown` = no source could establish anything (a network failure is
      // NOT evidence of absence). Both proceed: the backend pre-claim check and
      // POST /api/devices/provision remain the final authority, and the
      // persisted account snapshot guarantees the offline-reopen case was
      // decided by `registered` above, never by a failed request.
    } on Object catch (e) {
      // The authoritative sources are unreachable (deep offline). The session
      // snapshot (seeded from the persisted account snapshot) was already
      // checked above; the backend pre-claim check + POST /api/devices/provision
      // remain the net for a duplicate that only exists on another phone.
      debugPrint('[PROVISION] authoritative registered check unavailable: $e');
    }
    return false;
  }

  // Distinguishes terminal provision failures (never worth retrying) from
  // transient ones (device not seen, rate-limited, server hiccup, network).
  bool _isTerminalProvisionError(ApiException e) {
    final code = e.code;
    if (code != null) {
      switch (code) {
        case 'BAD_HARDWARE':
        case 'BAD_CHANNELS':
        case 'BAD_NAME':
        case 'DEVICE_ALREADY_EXISTS':
        case 'DEVICE_ALREADY_REGISTERED':
        case 'INVALID_MAC':
          return true;
        case 'DEVICE_NOT_SEEN':
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

  // Maps a terminal provision failure to its graded recovery kind. Only a
  // duplicate owned by the CURRENT user gets the "Remove Device" recovery; a
  // duplicate owned by someone else is a strict close-only state with no
  // deletion controls.
  _TerminalKind _terminalKindFor(ApiException e) {
    switch (e.code) {
      case 'DEVICE_ALREADY_EXISTS':
        return _TerminalKind.alreadyAdded;
      case 'DEVICE_ALREADY_REGISTERED':
        return _TerminalKind.alreadyRegistered;
      default:
        return _TerminalKind.generic;
    }
  }

  // True while the wizard is frozen in a closed-loop terminal failure. Every
  // asynchronous mutator (polling timers, stage-advance timer, lifecycle resume,
  // Socket.IO wake-ups, delayed futures, retry callbacks) MUST early-return when
  // this is true so the duplicate / registered UI can never flicker back to a
  // loading or "waitingForMqtt" state.
  bool get _isTerminal => _terminal;

  // Freezes the state machine into a closed-loop terminal failure. Cancels and
  // disposes every outstanding asynchronous resource (device-seen polling, the
  // stage-label timer, the AP probe timer and the Socket.IO watch) so no later
  // callback can overwrite the terminal state. The wizard only leaves this
  // state when the user explicitly acts (Remove Device / Close), or when a
  // successful removal explicitly re-opens provisioning.
  void _enterTerminalState(_TerminalKind kind, String message) {
    _allowWaitRetry = false;
    _recoveryMode = false;
    _reachTimer?.cancel();
    _waitTimer?.cancel();
    _waitStageTimer?.cancel();
    _stageRebootTimer?.cancel();
    _closeProvisionSocket();
    // Cleanly disconnect from the device's setup AP. A duplicate stop never
    // configured the device and never sent Restart, so there is no reboot to
    // wait for - the phone can return to its home network immediately (the
    // duplicate must be deleted from the Devices page, which needs internet).
    unawaited(_releaseWifiBinding());
    _terminal = true;
    _claimed = false;
    _provisioning = false;
    _terminalKind = kind;
    // The graded duplicate/registered terminal card is rendered on the WAIT
    // step, so a preflight duplicate found during the offline Connect phase also
    // lands there (and never advances to Configure).
    _step = _Step.waiting;
    if (mounted) {
      setState(() {
        _state = ProvisionState.failed;
        _error = message;
      });
    }
    debugPrint('[PROVISION] TERMINAL_STATE kind=${kind.name}');
  }

  // User-facing, non-technical wording for a TERMINAL provision failure.
  String _provisionFailureMessage(ApiException e) {
    switch (e.code) {
      case 'DEVICE_ALREADY_EXISTS':
        return _alreadyExistsMessage;
      case 'DEVICE_ALREADY_REGISTERED':
        return 'This device is already registered to another account and cannot '
            'be added to this one.';
      case 'INVALID_MAC':
        return "The device didn't report its identity correctly. Close this "
            'window and try again.';
      case 'BAD_NAME':
      case 'BAD_CHANNELS':
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

  // Wording for a RECOVERABLE provision failure (the wizard keeps waiting).
  String _provisionRecoveryMessage(ApiException e) {
    switch (e.code) {
      case 'DEVICE_NOT_SEEN':
        return 'The device is not on the cloud yet. Waiting and retrying…';
      case 'RATE_LIMITED':
        return 'Too many requests to STEES. Waiting a moment and retrying…';
      default:
        return 'STEES was busy. Waiting and retrying…';
    }
  }

  // Best-effort Local Mode cache writes. Cloud is always authoritative; the
  // cache is only a mirror so the devices page can keep working offline. A
  // failed OR hanging cache write must NEVER change the outcome of
  // provisioning — hence the tight timeout guard.
  static const Duration _cacheWriteBudget = Duration(seconds: 3);

  Future<void> _cacheUpsertDevice(String deviceId, String name) async {
    try {
      await _deviceCache
          .upsert({
            'deviceId': deviceId,
            'name': name,
            'channels': _deviceType.channelCount,
          })
          .timeout(_cacheWriteBudget);
      // A newly claimed device joins the persisted account snapshot too, so a
      // later offline reopen still certifies it as registered.
      await _deviceCache
          .upsertAccountSnapshot(deviceId)
          .timeout(_cacheWriteBudget);
    } on Object catch (e) {
      debugPrint('[LOCAL] cache upsert failed for $deviceId: $e');
    }
  }

  // How long the post-claim hard gate waits for the backend to learn the
  // device's LAN IP from its first MQTT tele/STATE before running the Local
  // HTTP enable+verify. The device is already confirmed on the broker at this
  // point, so STATE (with IPAddress) normally arrives within a second or two;
  // these bounds just keep a stuck device from pinning the wizard.
  static const Duration _lastIpWaitInterval = Duration(seconds: 1);
  static const int _lastIpWaitTries = 4;

  // Bounded background continuation after the user picks "Continue in
  // background" on the recoverable local-control screen. Runs fully off the
  // critical path (the wizard has already popped) and is deliberately tiny.
  static const int _backgroundLocalSetupAttempts = 2;

  // Reads the backend-learned `lastIp` for the just-claimed device from the
  // device list (the claim response itself never carries it). `null` when the
  // record is not there yet or the address is still the transient `0.0.0.0`.
  Future<String?> _awaitClaimLastIp(String deviceId) async {
    try {
      final devices = await _api.getDevices();
      for (final raw in devices) {
        if (raw is Map && raw['deviceId'] == deviceId) {
          final ip = raw['lastIp'];
          if (ip is String && isValidLocalIp(ip)) return ip;
          return null;
        }
      }
    } on Object catch (e) {
      debugPrint('[PROVISION] lastIp read failed: $e');
    }
    return null;
  }

  // Background discovery warm-up after a successful claim so the first relay
  // tap on the devices page uses a verified LAN IP. Test seam: widget tests
  // replace this with a no-op so no real mDNS browser/timer is created.
  Future<void> _warmUpDevice(Map<String, dynamic> device) async {
    final hook = widget.testWarmUp;
    if (hook != null) {
      await hook([device]);
      return;
    }
    await _repository.warmUp([device]);
  }

  // BLOCKING local HTTP enable + verify (SetOption128 1 + HTTP_API + real
  // referer-less round-trip) after a successful claim. Runs the automatic
  // bounded retry loop ([_startLocalSetup]) and the manual Retry. The cloud
  // claim is ALREADY committed when this runs, so returning false only marks
  // local control as NOT-YET-READY (recoverable) — it never unclaims or deletes
  // the device. Test seam: provision widget tests inject it so no real mDNS
  // browser / LAN request is created on the claim-success path, and so both the
  // success and the failure branch can be driven deterministically.
  Future<bool> _setupLocalControl(String deviceId, {String? lastIp}) async {
    debugPrint('[local-setup] claim success deviceId=$deviceId lastIp=$lastIp');
    final hook = widget.testLocalSetup;
    if (hook != null) {
      return hook(deviceId, lastIp: lastIp);
    }
    debugPrint('[local-setup] setup started');
    try {
      final ok = await _repository.enableLocalHttpApi(deviceId, lastIp: lastIp);
      if (!ok) {
        debugPrint(
            '[local-setup] failed: '
            '${_repository.lastLocalSetupError ?? 'no reachable LAN endpoint'}');
      }
      return ok;
    } on Object catch (e) {
      debugPrint('[local-setup] failed: $e');
      return false;
    }
  }

  /// Reads the CURRENT authoritative LAN IP for [deviceId] from the backend
  /// (the backend registry learns it from MQTT telemetry and may have updated
  /// it since the claim). Best-effort: any failure keeps the previously-known
  /// IP — the repository still has its persisted verified-IP cache and mDNS as
  /// lower-priority fallbacks.
  Future<String?> _refreshAuthoritativeIp(String deviceId) async {
    try {
      final devices = await _api.getDevices();
      for (final raw in devices) {
        if (raw is Map && raw['deviceId'] == deviceId) {
          final ip = raw['lastIp'];
          if (ip is String && isValidLocalIp(ip)) return ip;
          return null;
        }
      }
    } on Object catch (e) {
      debugPrint('[LOCAL HTTP] authoritative IP refresh unavailable ($e)');
    }
    return null;
  }

  /// Post-claim Local HTTP enable + verify with a SMALL bounded retry/backoff
  /// for the AP → home-Wi-Fi transition ([kLocalSetupBackoff]). The claim has
  /// ALREADY committed on the backend before this runs, so a failure here is a
  /// LOCAL-READINESS problem, never an ownership problem: the device stays
  /// claimed and cached. Each attempt re-reads the authoritative lastIp first,
  /// then runs the referer'd SetOption128 1 bootstrap + HTTP_API verify +
  /// real referer-less round-trip via [_setupLocalControl]. On exhaustion the
  /// wizard shows a recoverable "Local control not ready" screen with Retry
  /// (which re-runs ONLY this step — never provision, never config, never a
  /// factory reset).
  Future<void> _startLocalSetup(String deviceId, String? lastIp) async {
    if (_isTerminal || _localSetupInProgress || !mounted) return;
    traceLog('CLAIM',
        'LOCAL_HTTP_SETUP_START total=${_trace.elapsedMs}ms deviceId=$deviceId');
    debugPrint('[LOCAL HTTP] setup start deviceId=$deviceId lastIp=$lastIp');
    setState(() {
      _localSetupInProgress = true;
      _localSetupReady = false;
      _localSetupError = null;
      _state = ProvisionState.settingUpLocalControl;
    });
    var knownIp = lastIp;
    // Attempt count = gaps + 1: the first attempt runs immediately (the phone
    // already reached the backend for the seen-poll, so it is back on the home
    // network), then one bounded gap before each retry.
    for (var attempt = 0; attempt <= kLocalSetupBackoff.length; attempt++) {
      if (_isTerminal || !mounted) return;
      if (attempt > 0) {
        traceLog('LOCAL_HTTP',
            'WAIT gap=${kLocalSetupBackoff[attempt - 1].inSeconds}s '
            'total=${_trace.elapsedMs}ms');
        if (!mounted) return;
        setState(() => _state = ProvisionState.localSetupWaiting);
        await Future<void>.delayed(kLocalSetupBackoff[attempt - 1]);
        if (_isTerminal || !mounted) return;
      }
      // Authoritative IP first: the MQTT-learned / registry lastIp is the
      // preferred address after the claim. A refresh failure keeps the last
      // known IP; discovery/mDNS remains the repository's fallback.
      final refreshed = await _refreshAuthoritativeIp(deviceId);
      if (refreshed != null) knownIp = refreshed;
      bool ok = false;
      try {
        ok = await _setupLocalControl(deviceId, lastIp: knownIp);
      } on Object catch (e) {
        debugPrint('[LOCAL HTTP] setup exception on attempt ${attempt + 1}: $e');
      }
      _lastKnownIp = knownIp;
      traceLog('LOCAL_HTTP',
          'ATTEMPT ${attempt + 1} ip=$knownIp result=${ok ? 'OK' : 'FAILED'} '
          'total=${_trace.elapsedMs}ms');
      if (ok) {
        debugPrint(
            '[LOCAL HTTP] setup VERIFIED on attempt ${attempt + 1} ip=$knownIp');
        traceLog('CLAIM',
            'LOCAL_HTTP_VERIFIED total=${_trace.elapsedMs}ms deviceId=$deviceId');
        await _finishLocalControlReady(deviceId);
        return;
      }
      debugPrint('[LOCAL HTTP] setup attempt ${attempt + 1} failed '
          '(ip=$knownIp) — backing off');
    }
    if (!mounted || _isTerminal) return;
    debugPrint('[LOCAL HTTP] setup EXHAUSTED after '
        '${kLocalSetupBackoff.length + 1} attempts');
    traceLog('CLAIM',
        'LOCAL_HTTP_RECOVERABLE total=${_trace.elapsedMs}ms deviceId=$deviceId');
    setState(() {
      _localSetupInProgress = false;
      _localSetupError = _repository.lastLocalSetupError ??
          kLocalSetupFallbackMessage;
    });
  }

  Future<void> _finishLocalControlReady(String deviceId) async {
    if (!mounted || _isTerminal) return;
    setState(() {
      _localSetupInProgress = false;
      _localSetupReady = true;
      _state = ProvisionState.completed;
    });
    // Tactile confirmation that provisioning finished end-to-end.
    unawaited(HapticFeedback.heavyImpact());
    // Background local discovery warm-up: bounded, single-flight, never
    // blocks the flow or affects the local-setup outcome.
    final name = _deviceNameCtl.text.trim();
    unawaited(
      _warmUpDevice({
        'deviceId': deviceId,
        'name': name,
        'channels': _deviceType.channelCount,
      }),
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  /// Manual Retry from the recoverable "Local control not ready" screen.
  /// Re-runs ONLY the bounded local-setup loop — the device is already
  /// claimed and configured, so nothing about the claim, the Wi-Fi settings or
  /// the device identity is touched.
  void _retryLocalSetup() {
    if (_localSetupInProgress || _isTerminal) return;
    if (!mounted) return;
    setState(() {
      _localSetupError = null;
    });
    _startLocalSetup(_issuedDeviceId, _lastKnownIp);
  }

  /// Close from the recoverable "Local control not ready" screen. The device
  /// REMAINS claimed and cached (cloud control works); only local readiness is
  /// postponed. The wizard pops `true` so the Devices page shows the added
  /// device.
  void _closeLocalControlReady() {
    _waitTimer?.cancel();
    _waitStageTimer?.cancel();
    _stageRebootTimer?.cancel();
    _closeProvisionSocket();
    traceLog('CLAIM',
        'LOCAL_HTTP_POSTPONED total=${_trace.elapsedMs}ms deviceId=$_issuedDeviceId');
    if (mounted) Navigator.of(context).pop(true);
  }

  /// Accept the device NOW (the claim stays committed) and finish local HTTP
  /// readiness in the background. Unlike Close this does NOT just give up: a
  /// bounded, non-blocking loop keeps trying to enable + verify while the user
  /// already sees their Devices page. Failure there never touches the claim —
  /// the device simply stays cloud-only until a later tap re-discovers it.
  /// Pops `true` exactly like Close, so the wizard never blocks on readiness.
  void _continueLocalSetupInBackground() {
    if (_localSetupInProgress || _isTerminal) return;
    final deviceId = _issuedDeviceId;
    final lastIp = _lastKnownIp;
    traceLog('CLAIM',
        'LOCAL_HTTP_BACKGROUND total=${_trace.elapsedMs}ms deviceId=$deviceId');
    if (mounted) Navigator.of(context).pop(true);
    if (deviceId.isEmpty) return;
    unawaited(_backgroundLocalSetup(deviceId, lastIp));
  }

  /// Bounded continuation of [_startLocalSetup] for the "Continue in
  /// background" path. Deliberately never touches setState / Navigator (the
  /// wizard may already be popped) and never issues a claim, unclaim, delete
  /// or provisioning command — it only re-runs the Local HTTP enable+verify
  /// bootstrap, exactly like a manual Retry would.
  Future<void> _backgroundLocalSetup(String deviceId, String? lastIp) async {
    if (_isTerminal) return;
    var ip = lastIp;
    for (var attempt = 0; attempt < _backgroundLocalSetupAttempts; attempt++) {
      if (_isTerminal) return;
      try {
        final refreshed = await _refreshAuthoritativeIp(deviceId);
        if (refreshed != null) ip = refreshed;
      } on Object catch (e) {
        debugPrint('[LOCAL HTTP] background refresh unavailable ($e)');
      }
      var ok = false;
      try {
        ok = await _setupLocalControl(deviceId, lastIp: ip);
      } on Object catch (e) {
        debugPrint('[LOCAL HTTP] background attempt ${attempt + 1} error: $e');
      }
      traceLog('LOCAL_HTTP',
          'BACKGROUND_ATTEMPT ${attempt + 1} ip=$ip '
          'result=${ok ? 'OK' : 'FAILED'}');
      if (ok) return;
      if (attempt + 1 >= _backgroundLocalSetupAttempts) return;
      await Future<void>.delayed(kLocalSetupBackoff[attempt]);
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
      case _Step.localControl:
        return _buildLocalControl(colors);
    }
  }

  Widget _buildConnect(SteesColors colors) {
    final recovering = _recoveryMode;
    // On Android API 29+ the primary action joins the device AP programmatically
    // (no settings jump, no captive-portal prompt); everywhere else it is the
    // plain manual Wi-Fi-Settings open.
    final smartConnect = _apConnectSupported;
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
                        'Tap below, scan for the device\'s access point '
                        '(tasmota-XXXX) and pick it from the list.',
                style: GoogleFonts.inter(fontSize: 13, color: colors.mist, height: 1.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xl),
              // The Connect phase is fully offline: the Wi-Fi-Settings action
              // and Continue are available immediately. No backend session is
              // ever created before leaving for the offline SoftAP.
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  onPressed: _connectToDeviceWifi,
                  icon: Icon(
                    smartConnect ? Icons.wifi_tethering : Icons.settings_outlined,
                    size: 18,
                  ),
                  label: Text(
                    smartConnect ? 'Select Device Wi-Fi' : 'Open Wi-Fi Settings',
                  ),
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
                      _apConnectPending ?? 'Checking device connection…',
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
                if (!recovering && _programmaticConnectFailed) ...[
                  const SizedBox(height: AppSpacing.xl),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: OutlinedButton.icon(
                      onPressed: _openWifiSettings,
                      icon: const Icon(Icons.settings_outlined, size: 18),
                      style: _outlinedStyle(colors),
                      label: Text(
                        'Open Wi-Fi Settings',
                        style: GoogleFonts.sora(fontSize: 14, fontWeight: FontWeight.w700),
                      ),
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
    // Only the firmware's definitive "authentication rejected" verdict is
    // surfaced on the password field itself (inline red border + hint). Every
    // other failure keeps the general Wi-Fi banner below the form.
    final bool isWrongPassword = _state == ProvisionState.wifiTestFailed &&
        _wifiTestResult == WifiTestResult.wrongPassword;
    final subLabel = _provisioning
        ? provisionUserLabel(_state)
        : (_state == ProvisionState.wifiTestFailed && !isWrongPassword
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
          errorText:
              isWrongPassword ? 'Wrong password. Check it and try again.' : null,
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
                          ? 'read from the device when it connects'
                          : _issuedDeviceId,
                      style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Physical MAC',
                style: GoogleFonts.inter(fontSize: 10, color: colors.mist.withValues(alpha: 0.6)),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),
        if (_state == ProvisionState.wifiTestFailed && !isWrongPassword) ...[
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
        ] else if (_error != null && !isWrongPassword) ...[
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
  // on the Configure step - no identity change.
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
              ? _terminalTitle
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
          if (_terminalKind == _TerminalKind.alreadyAdded ||
              _terminalKind == _TerminalKind.alreadyRegistered ||
              _terminalKind == _TerminalKind.identityUnreadable) ...[
            // Closed-loop failure: nothing to reconfigure and no point waiting.
            // A duplicate identity cannot become addable - the existing device
            // must be deleted from the Devices page first - and an unreadable
            // identity has no recovery path. Close is the only action.
          ] else ...[
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

  // Recoverable post-claim screen: the device was provisioned and the backend
  // claim COMMITTED, but direct Local HTTP control could not be enabled and
  // verified yet. The device stays owned and cached (cloud control works);
  // Retry re-runs ONLY the local bootstrap, Close accepts the added device.
  // Never a terminal state and never a second claim.
  Widget _buildLocalControl(SteesColors colors) {
    final failed = !_localSetupInProgress && !_localSetupReady;
    // Smarter diagnostics: the repository records a precise reason when one is
    // known (`_localSetupError`); when it stayed empty, the recurring pattern
    // is that no address was ever known to the phone (null lastIp through the
    // whole loop) — call that out explicitly instead of a generic fallback.
    final localControlMessage = failed
        ? (_lastKnownIp == null && _localSetupError == null
            ? '${_localSetupError ?? kLocalSetupFallbackMessage}\n\n'
                'The device address is not known to this phone yet — make sure '
                'it is on the same Wi-Fi network as the device, then retry.'
            : _localSetupError ?? kLocalSetupFallbackMessage)
        : 'The device has been added to your account. Enabling direct '
            'local control…';
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
                color: (failed ? colors.danger : colors.stream)
                    .withValues(alpha: 0.12),
              ),
            ),
            child: failed
                ? Icon(Icons.warning_amber_outlined,
                    size: 32,
                    color: colors.danger.withValues(alpha: 0.6))
                : Icon(Icons.wifi_tethering,
                    size: 32,
                    color: colors.stream.withValues(alpha: 0.5)),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Text(
          failed ? 'Local control not ready' : 'Preparing local control…',
          textAlign: TextAlign.center,
          style: GoogleFonts.sora(
              fontSize: 17, fontWeight: FontWeight.w600, color: colors.foam),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          localControlMessage,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
              fontSize: 13, height: 1.5,
              color: colors.mist.withValues(alpha: 0.7)),
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
          const SizedBox(height: AppSpacing.xl),
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Text(
              'The device is already added to your account — you can control '
              'it through the cloud while local control is pending. Retry '
              'enables direct local control without claiming the device again.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 12, height: 1.4,
                  color: colors.mist.withValues(alpha: 0.8)),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton(
              onPressed: _retryLocalSetup,
              style: _filledStyle(colors),
              child: Text('Retry Local Control',
                  style: GoogleFonts.sora(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: OutlinedButton(
              onPressed: _continueLocalSetupInBackground,
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.stream,
                side: BorderSide(color: colors.stream.withValues(alpha: 0.35)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                ),
              ),
              child: Text('Continue in background',
                  style: GoogleFonts.sora(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: OutlinedButton(
              onPressed: _closeLocalControlReady,
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.mist,
                side: BorderSide(color: colors.mist.withValues(alpha: 0.35)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                ),
              ),
              child: Text('Close',
                  style: GoogleFonts.sora(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ],
    );
  }

  // Re-arms the device wait for a fresh deadline window. The canonical deviceId
  // is still valid - this is a continuation, not a restart.
  void _retryWait() {
    _waitTimer?.cancel();
    _waitStageTimer?.cancel();
    _stageRebootTimer?.cancel();
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
  // Tasmota AP WITHOUT creating a new identity: the canonical deviceId derived
  // from the physical MAC is kept, so a Wi-Fi correction is a continuation,
  // never a fresh (possibly duplicate) provisioning attempt.
  void _startRecovery() {
    _waitTimer?.cancel();
    _waitStageTimer?.cancel();
    _stageRebootTimer?.cancel();
    _closeProvisionSocket();
    _recoveryMode = true;
    traceLog('RECOVERY',
        'REQUIRED total=${_trace.elapsedMs}ms deviceId=$_issuedDeviceId');
    debugPrint('[PROVISION] phase=RECOVERY_AP deviceId preserved=$_issuedDeviceId');
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

  // Leaves the wizard. The canonical deviceId is still valid (it is the
  // physical MAC), so the user can power-cycle the device and start over
  // without losing the identity.
  void _leaveWizard() {
    _waitTimer?.cancel();
    _waitStageTimer?.cancel();
    _stageRebootTimer?.cancel();
    _closeProvisionSocket();
    traceLog('EXIT', 'CANCELLED total=${_trace.elapsedMs}ms');
    if (mounted) Navigator.of(context).pop(false);
  }

  // WAIT-step title for a terminal failure. Duplicate identities and an
  // unreadable identity get their own close-only wording; everything else keeps
  // the original, deliberately non-specific title.
  String get _terminalTitle {
    switch (_terminalKind) {
      case _TerminalKind.alreadyAdded:
        return 'Device Already Added';
      case _TerminalKind.alreadyRegistered:
        return 'Device Already Registered';
      case _TerminalKind.identityUnreadable:
        return 'Device identity not readable';
      case _TerminalKind.generic:
        return 'Device is not connected yet';
    }
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

/// Matches the SSID patterns the firmware uses for its setup access point, so
/// the picker can surface likely device networks first. Covers Tasmota's
/// `tasmota-XXXX` default plus the common ESP32 factory names.
bool _isDeviceApSsid(String ssid) {
  final s = ssid.trim().toLowerCase();
  return s.startsWith('tasmota-') ||
      s.startsWith('esp_') ||
      s.startsWith('esp32-');
}

/// In-app Wi-Fi scan list for the Connect step. Unlike the Configure step's
/// [_WifiPickerSheet], this one is about the DEVICE's setup AP: device-pattern
/// SSIDs (tasmota-XXXX …) are grouped and highlighted at the top, and a scan
/// permission denial degrades gracefully to the manual Wi-Fi Settings flow
/// (popping `'_manual'`) instead of hard-blocking.
class _DeviceApPickerSheet extends StatefulWidget {
  const _DeviceApPickerSheet();

  @override
  State<_DeviceApPickerSheet> createState() => _DeviceApPickerSheetState();
}

class _DeviceApPickerSheetState extends State<_DeviceApPickerSheet> {
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
      final reason = result?['reason']?.toString();
      final raw = result?['networks'] as List<dynamic>? ?? const [];
      final ssids = raw
          .whereType<String>()
          .where((s) => s.trim().isNotEmpty)
          .toSet()
          .toList();
      if (!available && reason == 'permission denied') {
        // The scan permission is a hard prerequisite for programmatic connect,
        // so this session degrades to the fully manual Wi-Fi Settings flow.
        Navigator.of(context).pop('_manual');
        return;
      }
      setState(() {
        _scanning = false;
        _networks = ssids;
        _scanMessage = ssids.isEmpty
            ? 'No Wi-Fi networks found. Make sure the device is powered on and '
                'in setup mode, then rescan or open Wi-Fi Settings.'
            : null;
      });
    } on TimeoutException {
      debugPrint('[PROVISION] device AP scan timed out after 10s');
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanMessage = 'Wi-Fi scan timed out. Tap refresh to try again or open '
            'Wi-Fi Settings.';
      });
    } catch (e) {
      debugPrint('[PROVISION] device AP scan failed: $e');
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanMessage = 'Wi-Fi scan unavailable. Open Wi-Fi Settings instead.';
      });
    }
  }

  void _selectNetwork(String ssid) {
    Navigator.of(context).pop(ssid);
  }

  void _manualFallback() {
    Navigator.of(context).pop('_manual');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    final deviceNetworks =
        _networks.where(_isDeviceApSsid).toList()..sort();
    final otherNetworks =
        _networks.where((s) => !_isDeviceApSsid(s)).toList()..sort();
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
                  'Select Device Wi-Fi',
                  style: GoogleFonts.sora(
                      fontSize: 15, fontWeight: FontWeight.w600, color: colors.foam),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Rescan',
                  onPressed: _scanning ? null : _scan,
                  icon: _scanning
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: colors.stream),
                        )
                      : const Icon(Icons.refresh, size: 20, color: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Pick the device\'s setup access point (tasmota-XXXX).',
              style: GoogleFonts.inter(
                  fontSize: 12, color: colors.mist.withValues(alpha: 0.8)),
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_scanMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(
                  _scanMessage!,
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      color: colors.mist.withValues(alpha: 0.8),
                      height: 1.4),
                ),
              ),
            if (_scanning)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: colors.stream),
                  ),
                ),
              )
            else if (_networks.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (deviceNetworks.isNotEmpty) ...[
                      Text(
                        'Likely your device',
                        style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: colors.stream.withValues(alpha: 0.9)),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      for (final ssid in deviceNetworks)
                        _networkTile(colors, ssid, highlighted: true),
                      if (otherNetworks.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.lg),
                        Text(
                          'Other networks',
                          style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: colors.mist.withValues(alpha: 0.8)),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                      ],
                    ],
                    for (final ssid in otherNetworks) _networkTile(colors, ssid),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.xl),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: OutlinedButton.icon(
                onPressed: _scanning ? null : _manualFallback,
                icon: const Icon(Icons.settings_outlined, size: 18),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: colors.stream.withValues(alpha: 0.5)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.lg)),
                ),
                label: Text(
                  'Open Wi-Fi Settings',
                  style: GoogleFonts.sora(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: colors.foam),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _networkTile(SteesColors colors, String ssid,
      {bool highlighted = false}) {
    return Material(
      color: highlighted
          ? colors.stream.withValues(alpha: 0.12)
          : colors.submerged,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: ListTile(
        dense: true,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md)),
        leading: Icon(
          highlighted ? Icons.wifi_tethering : Icons.wifi,
          size: 20,
          color: highlighted ? colors.stream : colors.mist,
        ),
        title: Text(
          ssid,
          style: GoogleFonts.inter(
              fontSize: 14,
              color: highlighted ? colors.stream : colors.foam),
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => _selectNetwork(ssid),
      ),
    );
  }
}

class _Field extends StatefulWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final FocusNode? focusNode;
  final String? errorText;

  const _Field({
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.focusNode,
    this.errorText,
  });

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  late bool _obscure;

  @override
  void initState() {
    super.initState();
    _obscure = widget.obscure;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.steesColors;
    return TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      obscureText: _obscure,
      style: GoogleFonts.inter(fontSize: 14, color: colors.foam),
      decoration: InputDecoration(
        hintText: widget.hint,
        prefixIcon: Icon(widget.icon, size: 18, color: colors.mist),
        suffixIcon: widget.obscure
            ? IconButton(
                icon: Icon(
                  _obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 18,
                  color: colors.mist,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
                tooltip: _obscure ? 'Show password' : 'Hide password',
              )
            : null,
        filled: true,
        fillColor: colors.well,
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        errorText: widget.errorText,
        errorMaxLines: 2,
        errorStyle: GoogleFonts.inter(fontSize: 12, color: colors.danger, height: 1.3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide(color: colors.stream, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide(color: colors.danger, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide(color: colors.danger, width: 1.5),
        ),
      ),
    );
  }
}