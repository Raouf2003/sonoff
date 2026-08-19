import 'dart:convert';

/// Canonical device identity: the physical Tasmota MAC IS the deviceId.
///
/// Normalizes any common MAC spelling to a single canonical form that is also
/// the MQTT topic burned into the firmware (Tasmota topics allow
/// [A-Za-z0-9_-]):
///
///   34:98:7A:C3:03:04  →  34987AC30304
///   34-98-7A-C3-03-04  →  34987AC30304
///   34987AC30304       →  34987AC30304
///
/// Normalization is deterministic (same MAC always yields the same deviceId),
/// case-insensitive, and rejection is strict: after stripping `:`, `-` and
/// whitespace the remainder must be exactly 12 hex digits, else null.
final RegExp _canonicalMacRe = RegExp(r'^[0-9A-F]{12}$');

String? normalizeMac(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final cleaned = raw
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(':', '')
      .replaceAll('-', '')
      .toUpperCase();
  if (!_canonicalMacRe.hasMatch(cleaned)) return null;
  return cleaned;
}

/// True when [value] is a strict canonical deviceId (12 uppercase hex digits).
bool isCanonicalDeviceId(String value) {
  return _canonicalMacRe.hasMatch(value);
}

/// Immutable in-memory snapshot of the user's registered device MACs, taken
/// once when the provisioning wizard opens (the phone is still on its home
/// network, so the backend is reachable — on the Tasmota setup AP it never is).
///
/// Feeds the RAM-only EARLY duplicate gate at AP detection / Apply: a canonical
/// MAC read off the setup AP that is already in this set stops the flow BEFORE
/// any provisioning command, with no backend round-trip at all. The set is
/// deliberately never refreshed mid-wizard — a device claimed after this
/// snapshot is the backend pre-flight + provision check's job (the unchanged
/// authoritative net).
class ClaimDeviceSnapshot {
  ClaimDeviceSnapshot._(this.macs);

  /// MACs already registered to the current user, canonical ([normalizeMac])
  /// form only.
  final Set<String> macs;

  /// Builds the snapshot from the backend device list (`GET /api/devices`).
  /// Entries without a parseable MAC are skipped, never an error.
  factory ClaimDeviceSnapshot.fromDevices(List<dynamic> devices) {
    final normalized = <String>{};
    for (final device in devices) {
      if (device is! Map) continue;
      final mac = device['deviceId'];
      if (mac is String) {
        final canonical = normalizeMac(mac);
        if (canonical != null) normalized.add(canonical);
      }
    }
    return ClaimDeviceSnapshot._(Set.unmodifiable(normalized));
  }

  /// Builds the snapshot from a collection of (possibly non-canonical) MACs,
  /// e.g. a test seam. Unparseable entries are skipped.
  factory ClaimDeviceSnapshot.fromMacs(Iterable<String> macs) {
    final normalized = <String>{};
    for (final mac in macs) {
      final canonical = normalizeMac(mac);
      if (canonical != null) normalized.add(canonical);
    }
    return ClaimDeviceSnapshot._(Set.unmodifiable(normalized));
  }

  /// Empty snapshot: the account held no devices when the wizard opened (or the
  /// snapshot could not be loaded). The backend gates remain the authority.
  factory ClaimDeviceSnapshot.empty() => ClaimDeviceSnapshot._(const {});

  /// True when the (possibly non-canonical) [mac] read off the setup AP is one
  /// of the registered MACs. A MAC that cannot be canonicalized is NEVER
  /// treated as a duplicate — an unreadable identity falls back to the existing
  /// gates instead of blocking.
  bool containsMac(String? mac) {
    final canonical = normalizeMac(mac);
    return canonical != null && macs.contains(canonical);
  }
}

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
      return 'Registering device…';
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
/// (`cm?cmnd=WifiTest`). The values are firmware states that vary slightly by
/// version (older ESP8266 builds use exact sentences like "Connect failed with
/// AP timeout"), so the matching is tolerant:
///
///   "Successful"                          -> success
///   "Connect failed as no IP address received"     -> noIp
///   "Connect failed as AP cannot be reached"       -> ssidNotFound
///   "Connect failed" / "Connect failed with AP
///     timeout" / any other "Connect failed..."
///     / "Connection rejected due to invalid
///     password"                             -> wrongPassword
///   anything else / empty / malformed       -> unknown
///
/// A still-running status ("Testing"/"Not Started") is not a final verdict, so
/// it maps to [WifiTestResult.unknown] here; the caller keeps polling until the
/// status settles or its own deadline expires.
/// [WifiTestResult] verdicts never guess: only the documented firmware failure
/// states are surfaced (or a generic "couldn't connect"), and the entered
/// credentials are never echoed.
WifiTestResult classifyWifiTest(String rawJson) {
  final body = rawJson.trim();
  if (body.isEmpty) return WifiTestResult.unknown;
  // The poll response may be wrapped or contain the key we care about.
  final value = extractWifiTestValue(body);
  if (value == null) return WifiTestResult.unknown;
  final v = value.replaceAll('\n', ' ').trim().toLowerCase();

  if (v == 'successful') return WifiTestResult.success;
  if (v.contains('no ip address')) return WifiTestResult.noIp;
  if (v.contains('ap cannot be reached')) return WifiTestResult.ssidNotFound;
  if (v.startsWith('connect failed') || v.contains('invalid password')) {
    return WifiTestResult.wrongPassword;
  }
  return WifiTestResult.unknown;
}

/// Extracts the `WifiTest` verdict string from a `/cm?cmnd=WifiTest` (or
/// `WifiTest3`) response, no matter how Tasmota wraps it.
///
/// Handles all documented shapes (keys compared case-insensitively — a real
/// 15.5.x device spells them `WiFiTest`/`WiFiTest3` with a capital `F`):
///   * flat:              `{"WiFiTest":"Successful"}` / `{"WifiTest":"Successful"}`
///   * per-index trigger: `{"WiFiTest3":"Testing"}`
///   * wrapped:           `{"Command":{"WiFiTest":"..."}}` — the `/cm` web layer
///                        may nest command results, so the whole tree is walked.
///
/// Only String values are accepted; a bare `42` under `WifiTest` is NOT a
/// verdict. Null-safe: empty / non-JSON / malformed bodies return null (never
/// throw), which the classifier maps to [WifiTestResult.unknown].
String? extractWifiTestValue(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;
  try {
    return _findWifiTestValue(jsonDecode(trimmed));
  } catch (_) {
    // Not JSON at all (e.g. an HTTP error page) — cannot extract a verdict.
    return null;
  }
}

/// Depth-first search for the first non-empty String under a `WifiTest`-ish
/// key. Container values (Maps/Lists) are recursed into to resolve `/cm`-wrapped
/// shapes.
///
/// Key comparison is CASE-INSENSITIVE and digitally verified against a real
/// Tasmota 15.5.x device: the `/cm` response keys are spelled `WiFiTest` /
/// `WiFiTest3` (capital `F`), while docs/comments historically say `WifiTest`.
/// Both spellings (and nested wrappers) must resolve for a successful poll body
/// like `{"WiFiTest":"Successful"}` to classify as [WifiTestResult.success].
String? _findWifiTestValue(Object? node) {
  if (node is Map) {
    for (final entry in node.entries) {
      if (entry.key is String && _isWifiTestKey(entry.key as String)) {
        final v = entry.value;
        if (v is String && v.trim().isNotEmpty) return v;
      }
    }
    for (final v in node.values) {
      final found = _findWifiTestValue(v);
      if (found != null) return found;
    }
    return null;
  }
  if (node is List) {
    for (final v in node) {
      final found = _findWifiTestValue(v);
      if (found != null) return found;
    }
  }
  return null;
}

/// True for the documented WifiTest response keys, case-insensitively:
/// `WifiTest`, `WiFiTest`, and their per-index trigger forms (`WifiTest3`,
/// `WiFiTest3`, `WifiTest4`). Anchored equality (not substring) so an unrelated
/// key like `WifiResult` can never match.
bool _isWifiTestKey(String key) {
  switch (key.toLowerCase()) {
    case 'wifitest':
    case 'wifitest3':
    case 'wifitest4':
      return true;
    default:
      return false;
  }
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
  final value = extractWifiTestValue(rawJson);
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

/// Classifies the outcome of the authenticated device DELETE used by the
/// Devices-page "Delete Device" action, so callers decide whether to treat the
/// removal as complete (and drop the device locally) or keep it and surface an
/// error.
///
/// * [succeeded] true (the DELETE returned the expected 200): the device was
///   removed.
/// * [statusCode] 404: the device is already gone (deleted elsewhere). Treated
///   as already removed.
/// * Anything else (network / timeout via [kApiTimeout], a 401 handled by the
///   shared auth gate, a 5xx): the deletion did NOT succeed - the device must
///   be kept in the account and a retryable error shown, never a false success.
enum DeleteOutcome {
  /// Deleted (200) or already gone (404): clear duplicate state, allow retry.
  cleared,

  /// Network / timeout / 401 / server / unexpected failure: the deletion did
  /// NOT complete - keep the device in the account.
  kept,
}

DeleteOutcome classifyDeleteOutcome({int? statusCode, bool succeeded = false}) {
  if (succeeded || statusCode == 200 || statusCode == 404) {
    return DeleteOutcome.cleared;
  }
  return DeleteOutcome.kept;
}