import 'dart:convert';

/// Explicit provisioning state machine.
///
/// The wizard drives through these states in a strictly sequential order. Only
/// one async operation is ever in flight per state; the UI just renders the
/// current state's user-facing label. Phases are also emitted to the debug log
/// with millisecond timing via [ProvisionTrace] so the actual dominant latency
/// (device reboot -> Wi-Fi -> MQTT CONNECT) is MEASURED, never guessed.
enum ProvisionState {
  idle,
  connectingToAp,
  apConnected,
  recoveryRequired,
  creatingSession,
  configuringBroker,
  configuringIdentity,
  verifyingIdentity,
  configuringWifi,
  configuringWifiTest,
  wifiTestFailed,
  wifiTestSucceeded,
  readyToRestart,
  restarting,
  waitingForWifi,
  waitingForMqtt,
  deviceDetected,
  verifyingPossession,
  claiming,
  completed,
  failed,
  cancelled,
}

/// Human-readable, non-technical label for the user interface.
String provisionUserLabel(ProvisionState state) {
  switch (state) {
    case ProvisionState.idle:
      return 'Getting ready…';
    case ProvisionState.connectingToAp:
      return 'Connecting to device';
    case ProvisionState.apConnected:
      return 'Connecting to device';
    case ProvisionState.recoveryRequired:
      return 'Reconnecting to device';
    case ProvisionState.creatingSession:
      return 'Preparing device';
    case ProvisionState.configuringBroker:
      return 'Configuring device';
    case ProvisionState.configuringIdentity:
      return 'Configuring device';
    case ProvisionState.verifyingIdentity:
      return 'Configuring device';
    case ProvisionState.configuringWifi:
      return 'Configuring device';
    case ProvisionState.configuringWifiTest:
      return 'Testing Wi-Fi connection…';
    case ProvisionState.wifiTestFailed:
      return 'Wi-Fi connection failed';
    case ProvisionState.wifiTestSucceeded:
      return 'Wi-Fi verified';
    case ProvisionState.readyToRestart:
      return 'Configuring device';
    case ProvisionState.restarting:
      return 'Connecting device to Wi-Fi…';
    case ProvisionState.waitingForWifi:
      return 'Connecting device to Wi-Fi…';
    case ProvisionState.waitingForMqtt:
      return 'Connecting device to MQTT…';
    case ProvisionState.deviceDetected:
      return 'Registering device…';
    case ProvisionState.verifyingPossession:
      return 'Registering device…';
    case ProvisionState.claiming:
      return 'Claiming device…';
    case ProvisionState.completed:
      return 'Device ready';
    case ProvisionState.failed:
      return 'Provisioning failed';
    case ProvisionState.cancelled:
      return 'Cancelled';
  }
}

/// Outcome of the Tasmota `WifiTest3` pre-flight Wi-Fi credential validation.
///
/// Only [direct] evidence from the Tasmota result string is used: the wizard
/// never guesses a wrong password — it surfaces the documented firmware states
/// (or a generic "couldn't connect") and stays on the Configure step to retry.
enum WifiTestResult {
  /// The device reported `{"WifiTest":"Successful"}` after the test window.
  success,

  /// The device connected to the network but never received an IP lease.
  noIp,

  /// WL_NO_SSID_AVAIL — the SSID could not be found (offline / misspelled).
  ssidNotFound,

  /// WL_CONNECT_FAILED — authentication was rejected (wrong password/cipher).
  wrongPassword,

  /// The test ran to completion but the device never reached a verdict, or the
  /// verdict string was not one of the documented firmware states.
  unknown,

  /// The start/poll HTTP call failed (phone left the AP, request timed out) —
  /// a LOCAL AP communication problem, distinct from a Wi-Fi verdict.
  localError,
}

/// Classifies the JSON value Tasmota returns for a data-less `WifiTest` poll
/// (`cm?cmnd=WifiTest`). The values are documented firmware states (localized):
///
///   "Successful"                       -> success
///   "Connect failed as no IP address received"     -> noIp
///   "Connect failed as AP cannot be reached"       -> ssidNotFound
///   "Connect failed"                               -> wrongPassword
///   anything else / empty / malformed              -> unknown
///
/// A still-running status ("Testing"/"Not Started") is not a final verdict, so
/// it maps to [WifiTestResult.unknown] here; the caller keeps polling until the
/// status settles or its own deadline expires.
WifiTestResult classifyWifiTest(String rawJson) {
  final body = rawJson.trim();
  if (body.isEmpty) return WifiTestResult.unknown;
  // The poll response may be wrapped or contain the key we care about.
  final value = _extractWifiTestValue(body);
  if (value == null) return WifiTestResult.unknown;
  final v = value.replaceAll('\n', ' ').trim();

  switch (v) {
    case 'Successful':
      return WifiTestResult.success;
    case 'Connect failed as no IP address received':
      return WifiTestResult.noIp;
    case 'Connect failed as AP cannot be reached':
      return WifiTestResult.ssidNotFound;
    case 'Connect failed':
      return WifiTestResult.wrongPassword;
    default:
      return WifiTestResult.unknown;
  }
}

String? _extractWifiTestValue(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final v = decoded['WifiTest'];
      if (v is String) return v;
      // Tasmota may respond with a per-index key.
      for (final e in decoded.entries) {
        if (e.key is String &&
            e.key.toString().contains(RegExp(r'WifiTest\d?')) &&
            e.value is String) {
          return e.value as String;
        }
      }
    }
  } catch (_) {
    // Not JSON at all (e.g. an HTTP error page) — cannot parse a verdict.
    return null;
  }
  return null;
}

/// True while the firmware's background Wi-Fi test is still running (i.e. the
/// poll returned `"Testing"`/`"Not Started"`). False for any settled verdict.
///
/// Strings are localized; the English defaults are assumed because the wizard
/// provisions fresh firmwares whose language is English unless explicitly
/// changed. An unrecognized (translated) settled string therefore reads as a
/// terminal unknown failure rather than being mistaken for "still running" —
/// safe by construction: an unrecognized verdict can never cause a Restart.
bool isWifiTestPending(String rawJson) {
  final value = _extractWifiTestValue(rawJson);
  switch (value) {
    case 'Testing':
    case 'Not Started':
      return true;
    default:
      return false;
  }
}

/// User-facing message for a failed Wi-Fi pre-flight test. Stays generic for
/// indeterminate results — only the documented firmware states claim a specific
/// cause. Never reveals the entered credentials.
String wifiTestMessage(WifiTestResult result) {
  switch (result) {
    case WifiTestResult.noIp:
      return 'The device connected to the network but did not receive an '
          'IP address. The Wi-Fi name and password are correct; check that the '
          'network allows new devices.';
    case WifiTestResult.ssidNotFound:
      return 'The device could not find this Wi-Fi network. Check the Wi-Fi '
          'name and try again.';
    case WifiTestResult.wrongPassword:
      return 'The device could not connect to this Wi-Fi network. The Wi-Fi '
          'password may be incorrect.';
    case WifiTestResult.localError:
      return "The device didn't respond to the Wi-Fi test. Make sure your "
          'phone is still connected to the device Wi-Fi and try again.';
    case WifiTestResult.success:
      return 'Wi-Fi connection verified.';
    case WifiTestResult.unknown:
      return "The device couldn't connect to this Wi-Fi network. Check the "
          'Wi-Fi name and password and try again.';
  }
}

/// Coarse phase tag used in [PROVISION] log lines (kept stable on purpose so
/// scripts can parse timings).
enum ProvisionPhase {
  ap('AP'),
  config('CONFIG'),
  reboot('REBOOT'),
  wifi('WIFI'),
  mqtt('MQTT'),
  backend('BACKEND'),
  claim('CLAIM');

  const ProvisionPhase(this.tag);
  final String tag;
}

/// Per-step timing instrument. Every transition logs
/// `[PROVISION][<CP>] <label> +<elapsedMs>ms (total +<totalMs>ms)` with a
/// coarse phase tag and a fine-grained phase label.
class ProvisionTrace {
  final Stopwatch _sw = Stopwatch()..start();

  String? _subPhase;
  int _last = 0;

  void enter(ProvisionPhase phase, String label) {
    final nowMs = _sw.elapsedMilliseconds;
    debugTrace(
      phase,
      label: label,
      elapsedMs: nowMs - _last,
      totalMs: nowMs,
      stateChanged: true,
    );
    _subPhase = label;
    _last = nowMs;
  }

  void debugTrace(
    ProvisionPhase phase, {
    String? label,
    int? elapsedMs,
    int? totalMs,
    bool stateChanged = false,
  }) {
    final nowMs = _sw.elapsedMilliseconds;
    final labelStr = label ?? _subPhase ?? 'step';
    final el = (elapsedMs ?? nowMs - _last).toString();
    final tot = (totalMs ?? nowMs).toString();
    // ignore: avoid_print
    print(
      '[PROVISION][${phase.tag}] $labelStr '
      '+${el}ms total+${tot}ms'
      '${stateChanged ? '' : ' (sub-step)'}',
    );
  }

  int get elapsedMs => _sw.elapsedMilliseconds;
}

/// Standalone logger so service code keeps working without importing the
/// screen.
void traceLog(String tag, String message) {
  // ignore: avoid_print
  print('[PROVISION][$tag] $message');
}