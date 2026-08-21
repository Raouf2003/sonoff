const { DateTime } = require('luxon');
const Schedule = require('../models/Schedule');
const runtimeState = require('./runtimeState');

// AUDIT-ONLY MODE (Tasmota-native cutover):
//
// Device-side Timer1-16/Rule2 execution (scheduleSyncService) is now the SOLE
// owner-of-record for schedule firing. This module no longer publishes relay
// commands on a timer. Its remaining roles:
//
//   1. AUDIT SAFETY NET — the periodic tick still runs, but instead of
//      publishing it only LOGS divergence between what the enabled schedules
//      want right now and what the device last reported, so an operator can
//      spot a device whose onboard timers are stale/missing. Never writes.
//   2. LIFECYCLE CLEANUP — release(schedule) is still invoked by schedule CRUD
//      (delete/disable) to revert channels the schedule is physically holding
//      ON at removal time. Under native ownership the "held ON" set is derived
//      from (desired==='ON' right now) AND (device reports ON), NOT from
//      lastAppliedState bookkeeping — the tick loop no longer maintains that.
//
// _desiredState stays exported/pure: scheduleDryRunService depends on it.

// Audit cadence: same 30s reaction window as before; divergence logs are
// throttled per device+channel so a legitimate manual override inside a window
// cannot flood the log.
const SCHEDULE_CHECK_INTERVAL_MS = 30000;
const AUDIT_LOG_THROTTLE_MS = 60 * 1000;

// "Now" in the app's timezone (Render runs in UTC by default). Fallback is
// the author's timezone; override via APP_TIMEZONE env var.
const APP_TIMEZONE = process.env.APP_TIMEZONE || 'Africa/Algiers';

class ScheduleEngine {
  constructor() {
    this.mqttGateway = null;
    this.timer = null;
    // `${deviceId}:${channel}` -> last divergence log ts (throttle).
    this._auditLog = new Map();
  }

  init({ mqttGateway }) {
    this.mqttGateway = mqttGateway;
    if (this.timer) clearInterval(this.timer);
    this.timer = setInterval(() => this.evaluate(), SCHEDULE_CHECK_INTERVAL_MS);
    console.log(
      `[scheduleEngine] AUDIT-ONLY mode started, checking every ${SCHEDULE_CHECK_INTERVAL_MS}ms in zone ${APP_TIMEZONE} ` +
        '(device-native timers are the sole executor; this loop never publishes)',
    );
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  // Compatibility no-op: routes previously cleared the executor's applied-state
  // cache after edits. There is no executor cache anymore.
  invalidate(_scheduleId) {}

  // Desired state for the whole schedule at the current time. Returns 'ON' if
  // today matches the recurrence AND now falls inside any time range, else
  // 'OFF' (schedules never hold channels on outside their windows).
  _desiredState(schedule, now) {
    const rec = schedule.recurrence || {};
    if (rec.type === 'custom') {
      const days = rec.daysOfWeek || [];
      // daysOfWeek is stored as 0=Mon..6=Sun (same convention the form uses).
      // luxon weekday is 1=Mon..7=Sun, so map to 0-based.
      const today = (now.weekday + 6) % 7;
      if (!days.includes(today)) return 'OFF';
    }
    const nowMin = now.hour * 60 + now.minute;
    for (const range of schedule.timeRanges || []) {
      const startMin = minutesFromHhmm(range.start);
      const endMin = minutesFromHhmm(range.end);
      if (startMin !== null && endMin !== null && nowMin >= startMin && nowMin < endMin) {
        return 'ON';
      }
    }
    return 'OFF';
  }

  // Revert any channels this schedule is physically holding ON right now so
  // they don't stay stuck after delete/disable. Under native ownership the
  // held-ON set is: desired==='ON' at this instant AND the device itself
  // reports the channel ON. Best-effort and skipped entirely when the device
  // is offline (the caller's pendingDelete/retry path owns that case).
  async release(schedule) {
    const deviceId = schedule.deviceId;
    if (!this.mqttGateway) return;
    if (!runtimeState.isOnline(deviceId)) {
      console.warn(
        `[scheduleEngine] Skip release "${schedule.name}" — device ${deviceId} is offline`,
      );
      return;
    }
    const now = DateTime.now().setZone(APP_TIMEZONE);
    if (this._desiredState(schedule, now) !== 'ON') return; // window closed: timer removal suffices

    const entry = runtimeState.getDeviceState(deviceId);
    const channels = entry ? entry.channels : {};
    for (const channel of schedule.channels || []) {
      const reported =
        channels[channel] !== undefined
          ? channels[channel]
          : channels[String(channel)];
      const state = reported && (reported.state || reported);
      if (String(state).toUpperCase() !== 'ON') continue;
      try {
        await this.mqttGateway.publishCommandNoWait(deviceId, channel, 'OFF');
        console.log(
          `[scheduleEngine] Released schedule "${schedule.name}" -> ${deviceId} POWER${channel} OFF`,
        );
      } catch (err) {
        console.error(
          `[scheduleEngine] release error on ${deviceId} channel ${channel}: ${err.message}`,
        );
      }
    }
  }

  // AUDIT pass: never publishes. Logs desired-vs-reported divergence so a
  // device with stale/missing onboard timers becomes visible in the logs.
  async evaluate() {
    let schedules;
    try {
      schedules = await Schedule.find({ enabled: true, pendingDelete: { $ne: true } });
    } catch (err) {
      console.error('[scheduleEngine] Query error:', err);
      return;
    }

    const now = DateTime.now().setZone(APP_TIMEZONE);
    const nowMs = Date.now();

    for (const schedule of schedules) {
      const desired = this._desiredState(schedule, now);
      const deviceId = schedule.deviceId;
      if (!runtimeState.isOnline(deviceId)) continue; // offline: nothing to audit against

      const entry = runtimeState.getDeviceState(deviceId);
      const channels = entry ? entry.channels : {};
      for (const channel of schedule.channels || []) {
        const reported =
          channels[channel] !== undefined
            ? channels[channel]
            : channels[String(channel)];
        const actual = reported ? String(reported.state ?? reported).toUpperCase() : null;
        if (actual === null || actual === desired) continue;

        const key = `${deviceId}:${channel}`;
        const last = this._auditLog.get(key);
        if (last && nowMs - last < AUDIT_LOG_THROTTLE_MS) continue;
        this._auditLog.set(key, nowMs);
        console.warn(
          `[scheduleEngine][AUDIT] divergence device=${deviceId} ch=${channel} ` +
            `desired=${desired} actual=${actual} (schedule "${schedule.name}") — ` +
            'device-native timers may be stale or missing',
        );
      }
    }
  }
}

function minutesFromHhmm(hhmm) {
  if (!hhmm || typeof hhmm !== 'string') return null;
  const m = hhmm.match(/^(\d{1,2}):(\d{2})$/);
  if (!m) return null;
  const h = parseInt(m[1], 10);
  const mi = parseInt(m[2], 10);
  if (h > 23 || mi > 59) return null;
  return h * 60 + mi;
}

module.exports = new ScheduleEngine();
