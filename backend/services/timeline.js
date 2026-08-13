// Debug-safe end-to-end command timeline for the backend. Monotonic absolute
// (process-anchored) so a physical test can align the Flutter and backend logs
// for the same opId.
//
// Emits:
//   [CONTROL TIMELINE] device=<id> channel=<ch> op=<opId> <label> abs=<Ams>ms
//
// Never logs payloads, credentials, headers, or tokens. Disable wholesale with
// DISABLE_CONTROL_TIMELINE=1. Logging is the ONLY effect: no behavior change.

const base = process.hrtime.bigint();

function absMs() {
  return Number(process.hrtime.bigint() - base) / 1e6;
}

function timeline(deviceId, channel, opId, label) {
  if (process.env.DISABLE_CONTROL_TIMELINE === '1') return;
  if (!deviceId || opId == null || opId === '') return;
  console.log(
    `[CONTROL TIMELINE] device=${deviceId} channel=${channel ?? '-'} op=${opId} ${label} abs=${absMs().toFixed(0)}ms`,
  );
}

module.exports = { timeline, absMs };
