const { DateTime } = require('luxon');
const Schedule = require('../models/Schedule');
const runtimeState = require('./runtimeState');

// Schedules control physical relays, so the cadence only needs to be tight
// enough to react to a range boundary without hammering MQTT or MongoDB.
// Rule-engine precision isn't required here (rules react to live sensor
// values); 30s keeps boundary transitions within half a minute while using a
// fraction of the writes a 10s tick would.
const SCHEDULE_CHECK_INTERVAL_MS = 30000;

// "Now" in the app's timezone (Render runs in UTC by default). Fallback is
// the author's timezone; override via APP_TIMEZONE env var.
const APP_TIMEZONE = process.env.APP_TIMEZONE || 'Africa/Algiers';

class ScheduleEngine {
  constructor() {
    this.mqttGateway = null;
    this.timer = null;
    // scheduleId -> Map<channel -> lastAppliedState> read-through cache,
    // primed from the DB on startup and updated on every successful change.
    this.stateCache = new Map();
  }

  init({ mqttGateway }) {
    this.mqttGateway = mqttGateway;
    if (this.timer) clearInterval(this.timer);
    this.timer = setInterval(() => this.evaluate(), SCHEDULE_CHECK_INTERVAL_MS);
    console.log(
      `[scheduleEngine] Started, checking every ${SCHEDULE_CHECK_INTERVAL_MS}ms in zone ${APP_TIMEZONE}`,
    );
  }

  _primeCache(schedules) {
    for (const schedule of schedules) {
      const id = String(schedule._id);
      if (!this.stateCache.has(id)) {
        const map = new Map();
        if (schedule.lastAppliedState) {
          for (const [ch, state] of schedule.lastAppliedState.entries()) {
            map.set(ch, state);
          }
        }
        this.stateCache.set(id, map);
      }
    }
  }

  // Push the new state for one channel to memory + MongoDB together.
  async _setChannelState(scheduleId, channel, state) {
    const id = String(scheduleId);
    const map = this.stateCache.get(id);
    if (!map) return;
    map.set(String(channel), state);
    try {
      await Schedule.updateOne(
        { _id: scheduleId },
        { $set: { [`lastAppliedState.${channel}`]: state } },
      );
      console.log(
        `[scheduleEngine] Persisted channel ${channel} state=${state} for schedule ${id}`,
      );
    } catch (err) {
      console.error(`[scheduleEngine] DB update error for schedule ${id}:`, err.message);
    }
  }

  // Desired state for the whole schedule at the current time. Returns 'ON' if
  // today matches the recurrence AND now falls inside any time range, else
  // 'OFF' (schedules never hold channels on outside their windows).
  _desiredState(schedule, now) {
    const rec = schedule.recurrence || {};
    if (rec.type === 'custom') {
      const days = rec.daysOfWeek || [];
      if (!days.includes(now.weekday % 7)) return 'OFF';
    }
    const hhmm = now.toFormat('HH:mm');
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

  // Revert any channels a schedule left ON so they don't stay stuck after the
// schedule is deleted. Only channels recorded as ON in lastAppliedState are
// reset, so channels the schedule never touched are left alone.
async release(schedule) {
    const deviceId = schedule.deviceId;
    const applied = schedule.lastAppliedState;
    const onChannels = [];
    if (applied instanceof Map) {
      for (const [ch, state] of applied.entries()) {
        if (String(state).toUpperCase() === 'ON') onChannels.push(ch);
      }
    } else if (applied) {
      for (const [ch, state] of Object.entries(applied)) {
        if (String(state).toUpperCase() === 'ON') onChannels.push(ch);
      }
    }
    if (!onChannels.length) return;
    if (!runtimeState.isOnline(deviceId)) {
      console.warn(
        `[scheduleEngine] Skip release "${schedule.name}" — device ${deviceId} is offline`,
      );
      return;
    }
    for (const channel of onChannels) {
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

  async evaluate() {
    let schedules;
    try {
      schedules = await Schedule.find({ enabled: true });
    } catch (err) {
      console.error('[scheduleEngine] Query error:', err);
      return;
    }

    this._primeCache(schedules);

    const now = DateTime.now().setZone(APP_TIMEZONE);

    for (const schedule of schedules) {
      const desired = this._desiredState(schedule, now);
      const name = schedule.name;
      const deviceId = schedule.deviceId;
      const id = String(schedule._id);

      for (const channel of schedule.channels || []) {
        const cache = this.stateCache.get(id);
        const lastState = cache.get(String(channel)) || 'OFF';

        if (desired === lastState) continue;

        if (!runtimeState.isOnline(deviceId)) {
          console.warn(
            `[scheduleEngine] Skipped schedule "${name}" channel ${channel} — device ${deviceId} is offline`,
          );
          continue;
        }

        try {
          await this.mqttGateway.publishCommandNoWait(deviceId, channel, desired);
          console.log(
            `[scheduleEngine] Applied schedule "${name}" -> ${deviceId} POWER${channel} ${desired}`,
          );
          await this._setChannelState(schedule._id, channel, desired);
        } catch (err) {
          console.error(
            `[scheduleEngine] Schedule "${name}" apply error on ${deviceId} channel ${channel}: ${err.message}`,
          );
        }
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