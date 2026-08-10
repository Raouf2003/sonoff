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
  creatingSession,
  configuringBroker,
  configuringIdentity,
  verifyingIdentity,
  configuringWifi,
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
    case ProvisionState.readyToRestart:
      return 'Configuring device';
    case ProvisionState.restarting:
      return 'Connecting to Wi-Fi';
    case ProvisionState.waitingForWifi:
      return 'Connecting to Wi-Fi';
    case ProvisionState.waitingForMqtt:
      return 'Connecting to cloud…';
    case ProvisionState.deviceDetected:
      return 'Registering device';
    case ProvisionState.verifyingPossession:
      return 'Registering device';
    case ProvisionState.claiming:
      return 'Registering device';
    case ProvisionState.completed:
      return 'Device ready';
    case ProvisionState.failed:
      return 'Provisioning failed';
    case ProvisionState.cancelled:
      return 'Cancelled';
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