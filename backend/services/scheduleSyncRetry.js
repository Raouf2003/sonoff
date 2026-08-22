const Schedule = require('../models/Schedule');
const Device = require('../models/Device');
const runtimeState = require('./runtimeState');
const scheduleSyncService = require('./scheduleSyncService');
const scheduleSyncTrigger = require('./scheduleSyncTrigger');

// Retry + backfill layer for the Tasmota-native ownership model.
//
// The sync trigger (scheduleSyncTrigger) fires only on schedule CRUD. That
// leaves two gaps this module closes:
//
//   1. FAILED/OFFLINE SYNC — a create/update/delete whose device-sync failed
//      (device offline, timeouts) previously stayed failed forever: the device
//      kept running stale or deleted schedules silently. The periodic sweep
//      re-runs syncDevice for every device whose last outcome was 'failed' or
//      that still has pendingDelete rows, as soon as the device is back online
//      (LWT Online nudges it immediately; the interval is the fallback).
//   2. STARTUP BACKFILL — devices whose schedules predate the cutover have no
//      onboard timers at all. On startup every device with schedules and
//      without a confirmed 'synced' outcome gets one trigger through the
//      existing per-device serialized queue.
//
// Graceful degradation: when TASMOTA_SCHEDULE_SYNC_ENABLED is false there is
// no device copy to converge with — the sweep is a no-op and pendingDelete
// rows are finalized by the delete route's legacy path instead.

const SWEEP_INTERVAL_MS = 60 * 1000;
const NUDGE_DEBOUNCE_MS = 10 * 1000;

class ScheduleSyncRetry {
  constructor() {
    this.timer = null;
    this._sweeping = false;
    // deviceId -> last nudge ts (debounce so an LWT burst fires one retry)
    this._nudgedAt = new Map();
    // Injectable for tests.
    this.syncFn = (deviceId, options) => scheduleSyncService.syncDevice(deviceId, options);
    this.isOnlineFn = (deviceId) => runtimeState.isOnline(deviceId);
    this.logger = console;
  }

  init({ intervalMs = SWEEP_INTERVAL_MS } = {}) {
    if (this.timer) clearInterval(this.timer);
    this.timer = setInterval(() => {
      this.sweep().catch((err) =>
        this.logger.error(`[scheduleSyncRetry] sweep error: ${err.message}`),
      );
    }, intervalMs);
    if (this.timer.unref) this.timer.unref();
    console.log(`[scheduleSyncRetry] sweep started (every ${intervalMs}ms)`);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  // Startup: initialize the sweep AND backfill every not-yet-synced device.
  startup() {
    this.init();
    return this.backfill();
  }

  // Immediate, debounced retry for one device (called on LWT Online).
  nudge(deviceId) {
    const id = String(deviceId || '');
    if (!id) return;
    const now = Date.now();
    const last = this._nudgedAt.get(id);
    if (last && now - last < NUDGE_DEBOUNCE_MS) return;
    this._nudgedAt.set(id, now);
    this._retryDevice(id, 'online-nudge').catch((err) =>
      this.logger.error(`[scheduleSyncRetry] nudge error for ${id}: ${err.message}`),
    );
  }

  _candidateDeviceIds() {
    return (async () => {
      const ids = new Set();
      // No .select()/.lean() chaining: keeps the queries stub-friendly and
      // whole-document reads are tiny here.
      const pending = await Schedule.find({ pendingDelete: true });
      for (const s of pending) if (s.deviceId) ids.add(s.deviceId);
      // 'failed' = apply/verify failed; 'unsupported' = plan could not be
      // applied at all (slot exhaustion, occupied Rule2...). Both are retried:
      // an unsupported plan becomes supportable the moment the user fixes or
      // removes the offending schedules, and only the sweep converges it then.
      const failed = await Device.find({
        'scheduleSyncInfo.status': { $in: ['failed', 'unsupported'] },
      });
      for (const d of failed) if (d.deviceId) ids.add(d.deviceId);
      return Array.from(ids);
    })();
  }

  // One pass: retry every online candidate; finalize pendingDelete rows of any
  // device whose sync just confirmed.
  async sweep() {
    if (this._sweeping) return { status: 'skipped-busy' };
    if (!scheduleSyncService.syncEnabled()) {
      return { status: 'skipped-flag-off' };
    }
    this._sweeping = true;
    try {
      const ids = await this._candidateDeviceIds();
      let retried = 0;
      let finalized = 0;
      for (const id of ids) {
        if (!this.isOnlineFn(id)) continue;
        retried++;
        const res = await this._retryDevice(id, 'retry-sweep');
        if (res && res.status === 'synced') {
          const r = await Schedule.deleteMany({ deviceId: id, pendingDelete: true });
          finalized += r.deletedCount || 0;
        }
      }
      if (retried || finalized) {
        this.logger.log(
          `[scheduleSyncRetry] sweep: retried=${retried} finalizedPendingDeletes=${finalized}`,
        );
      }
      return { status: 'done', retried, finalized };
    } finally {
      this._sweeping = false;
    }
  }

  async _retryDevice(deviceId, source) {
    try {
      const res = await this.syncFn(deviceId, { source });
      if (res && res.status !== 'synced') {
        this.logger.warn(
          `[scheduleSyncRetry] ${source} for ${deviceId}: status=${res.status}${res.error ? ` (${res.error})` : ''}`,
        );
      }
      return res;
    } catch (err) {
      this.logger.error(`[scheduleSyncRetry] ${source} for ${deviceId} threw: ${err.message}`);
      return { status: 'failed', deviceId, error: err.message };
    }
  }

  // One-time pass at boot: trigger a sync for every device that has schedules
  // but no confirmed synced outcome yet. Goes through the normal per-device
  // serialized trigger queue (coalescing included), so it can never collide
  // with a CRUD-triggered sync for the same device.
  async backfill() {
    if (!scheduleSyncService.syncEnabled()) {
      this.logger.log('[scheduleSyncRetry] backfill skipped — native sync disabled');
      return { status: 'skipped-flag-off', triggered: [] };
    }
    let devices;
    try {
      devices = await Device.find({
        scheduleSyncInfo: { $ne: null },
      });
    } catch (err) {
      // Older documents may lack the field entirely; fall back to "every
      // device that has schedules" — the trigger is idempotent (diff-based).
      try {
        devices = await Device.find({});
      } catch (err2) {
        this.logger.error(`[scheduleSyncRetry] backfill query error: ${err2.message}`);
        return { status: 'failed', triggered: [] };
      }
    }

    const scheduledRows = await Schedule.find({ pendingDelete: { $ne: true } });
    const scheduledIds = new Set(scheduledRows.map((s) => s.deviceId));

    const triggered = [];
    for (const d of devices) {
      const id = d.deviceId;
      if (!id || !scheduledIds.has(id)) continue;
      const status = d.scheduleSyncInfo && d.scheduleSyncInfo.status;
      if (status === 'synced') continue; // already converged — never duplicate-sync
      scheduleSyncTrigger.trigger(id, { source: 'startup-backfill' });
      triggered.push(id);
    }
    if (triggered.length) {
      this.logger.log(
        `[scheduleSyncRetry] backfill triggered for ${triggered.length} device(s): ${triggered.join(', ')}`,
      );
    }
    return { status: 'done', triggered };
  }
}

module.exports = new ScheduleSyncRetry();
module.exports.ScheduleSyncRetry = ScheduleSyncRetry;
