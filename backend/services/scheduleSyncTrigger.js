const scheduleSyncService = require('./scheduleSyncService');

// Phase 7A integration layer: turns "a schedule changed" into a safe, per-device
// serialized call to the EXISTING schedule sync service.
//
// Design rules:
//  - It NEVER touches the compiler, allocation, protection, MQTT config logic or
//    verification; it only delegates to scheduleSyncService.syncDevice.
//  - The TASMOTA_SCHEDULE_SYNC_ENABLED flag is honored entirely inside
//    syncDevice (dry-run vs real writes). This layer never bypasses it and never
//    creates another flag.
//  - Syncs are serialized PER DEVICE and coalesced: rapid schedule changes for
//    one device collapse into (at most) the currently-running sync plus ONE
//    follow-up that re-reads the latest DB state. Different devices run fully
//    independently (no global queue).
//  - trigger() is fire-and-forget from the CRUD handler's point of view: it never
//    blocks the schedule save response, and an MQTT/device failure can never
//    roll back or fail an already-saved schedule.
class ScheduleSyncTrigger {
  constructor({ syncFn, logger } = {}) {
    this.syncFn = syncFn || ((deviceId) => scheduleSyncService.syncDevice(deviceId));
    this.logger = logger || console;
    // deviceId -> { running, pending, tail, resolveTail, lastResult }
    this.states = new Map();
  }

  // Fire-and-forget trigger. Synchronously returns a queued indication so the
  // schedule CRUD response is never delayed; the actual sync happens on the
  // per-device serialized queue in the background.
  trigger(deviceId) {
    const id = String(deviceId || '').trim();
    if (!id) {
      this.logger.error(`[scheduleSyncTrigger] trigger skipped: invalid deviceId=${JSON.stringify(deviceId)}`);
      return { status: 'unsupported', deviceId: null, error: 'invalid deviceId' };
    }
    let st = this.states.get(id);
    if (!st) {
      st = { running: false, pending: false, tail: null, resolveTail: null, lastResult: null };
      this.states.set(id, st);
    }
    if (st.running) {
      // A sync is already executing for this device: mark that a fresh run is
      // required after it finishes (coalescing), and report queued.
      st.pending = true;
      return { status: 'queued', deviceId: id };
    }
    st.running = true;
    st.tail = new Promise((resolve) => {
      st.resolveTail = resolve;
    });
    // Fire-and-forget, BUT never allow an unhandled rejection to escape the
    // drain: the do/while body already isolates syncFn failures, and this
    // backstop swallows anything else (e.g. a crashed logger) so the CRUD
    // caller and the process are never affected.
    this._drain(id, st).catch((err) => {
      try {
        this.logger.error(`[scheduleSyncTrigger] drain crashed for ${id}: ${err && err.message ? err.message : err}`);
      } catch (logErr) {
        // A broken logger must not create a second rejection.
      }
    });
    return { status: 'queued', deviceId: id };
  }

  async _drain(deviceId, st) {
    try {
      do {
        st.pending = false;
        let result;
        try {
          result = await this.syncFn(deviceId);
        } catch (err) {
          // A sync failure must never propagate into the CRUD caller. Capture
          // and log it, and let a pending follow-up still run.
          st.lastResult = { status: 'failed', deviceId, error: err.message };
          try {
            this.logger.error(`[scheduleSyncTrigger] sync failed for ${deviceId}: ${err.message}`);
          } catch (logErr) {
            // A broken logger must not abort the drain loop: the pending
            // follow-up still needs to run and read the latest DB state.
          }
        }
        if (result) {
          st.lastResult = result;
          if (result.status !== 'synced' && result.error) {
            this.logger.warn(
              `[scheduleSyncTrigger] sync for ${deviceId}: status=${result.status}${result.error ? ` (${result.error})` : ''}`,
            );
          }
        }
      } while (st.pending);
    } finally {
      st.running = false;
      if (st.resolveTail) {
        st.resolveTail();
        st.resolveTail = null;
      }
      st.tail = null;
    }
  }

  // Resolves when the device's current serialized queue has fully drained.
  // Used by tests and any tooling that needs to observe completion.
  whenIdle(deviceId) {
    const st = this.states.get(String(deviceId || ''));
    return st && st.tail ? st.tail : Promise.resolve();
  }

  // Last sync report recorded for a device (after drain completes).
  lastResult(deviceId) {
    const st = this.states.get(String(deviceId || ''));
    return st ? st.lastResult : null;
  }

  _stateCount() {
    return this.states.size;
  }
}

module.exports = new ScheduleSyncTrigger();
module.exports.ScheduleSyncTrigger = ScheduleSyncTrigger;