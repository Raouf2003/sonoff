import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

/// Monotonic stopwatch anchored at isolate start (not wall clock), so
/// `+Nms` deltas are immune to clock changes on the phone.
final Stopwatch _monotonic = Stopwatch()..start();

int _seq = 0;

/// opId -> monotonic ms of the tap that anchored the timeline.
final Map<String, int> _anchors = {};

int _monoMs() => _monotonic.elapsedMilliseconds;

/// Generates a per-tap operation id so events from the same command can be
/// followed end-to-end (Flutter tap -> backend -> MQTT -> RESULT -> socket ->
/// UI) even though they are produced by different processes.
String nextControlOpId() {
  _seq++;
  return '${DateTime.now().millisecondsSinceEpoch}-$_seq';
}

/// Debug-only end-to-end command timeline. `begin` anchors the tap; every
/// `mark` with the same opId emits:
///
/// `[CONTROL TIMELINE] device=<id> channel=<ch> op=<opId> <label> +<Nms> abs=<Ams>`
///
/// `+Nms` is the monotonic offset since the tap; `abs` is the monotonic
/// absolute (isolate-anchored) so logs from separate processes can be aligned.
/// Never logs payloads, credentials, headers, or tokens.
///
/// Everything is gated on [kDebugMode] and is a plain `debugPrint`: zero
/// behavioral impact in release builds.
class ControlTimeline {
  /// Anchors a new tap and logs `Tap received`. Returns the opId to thread
  /// through the command and release with [end].
  static String begin(String deviceId, int channel) {
    final opId = nextControlOpId();
    _anchors[opId] = _monoMs();
    mark(opId, deviceId, channel, 'Tap received');
    return opId;
  }

  static void mark(String opId, String deviceId, int channel, String label) {
    if (!kDebugMode) return;
    final anchor = _anchors[opId];
    if (anchor == null) return;
    final now = _monoMs();
    debugPrint(
      '[CONTROL TIMELINE] device=$deviceId channel=$channel '
      'op=$opId $label +${now - anchor}ms abs=$now',
    );
  }

  /// Releases the anchor so the registry never grows without bound.
  static void end(String opId) => _anchors.remove(opId);
}
