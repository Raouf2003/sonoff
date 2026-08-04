const Rule = require('../models/Rule');
const Sensor = require('../models/Sensor');
const runtimeState = require('./runtimeState');

const CHECK_INTERVAL_MS = 10000;

function oppositeAction(action) {
  return action === 'ON' ? 'OFF' : 'ON';
}

class RuleEngine {
  constructor() {
    this.mqttGateway = null;
    this.timer = null;
    // ruleId -> whether the condition was true on the last tick. A rule fires
    // only once when its condition flips, never on every tick.
    // false -> true: publish the configured action to every channel.
    // true  -> false: publish the opposite action to every channel.
    // This is a read-through cache: on restart it is initialized from each
    // rule's persisted lastConditionState (never from a fresh `false`).
    this.prev = new Map();
  }

  init({ mqttGateway }) {
    this.mqttGateway = mqttGateway;
    if (this.timer) clearInterval(this.timer);
    this.timer = setInterval(() => this.evaluate(), CHECK_INTERVAL_MS);
    console.log(`[ruleEngine] Started, checking every ${CHECK_INTERVAL_MS}ms`);
  }

  // Drop a rule's in-memory edge-state cache so the next tick re-reads the
  // persisted lastConditionState from DB before evaluating. Used after edits
  // or enable/disable toggles where the in-memory cache would otherwise
  // suppress the next intended state change.
  invalidate(ruleId) {
    this.prev.delete(String(ruleId));
  }

  // Persist the edge-trigger state to memory + MongoDB together.
  async _setConditionState(ruleId, state) {
    this.prev.set(ruleId, state);
    const ruleStr = String(ruleId);
    try {
      await Rule.updateOne(
        { _id: ruleId },
        { $set: { lastConditionState: state } },
      );
    } catch (err) {
      console.error(`[ruleEngine] DB update error for rule ${ruleStr}:`, err.message);
    }
  }

  // Hydrate the memory cache for any rules not yet known. Reads the persisted
  // value from DB so a restart resumes from the last correct state.
  _primeCache(rules) {
    for (const rule of rules) {
      const id = String(rule._id);
      if (!this.prev.has(id)) {
        this.prev.set(id, rule.lastConditionState === true);
      }
    }
  }

  // Log any enabled rules whose in-memory cache says condition=true — these
  // are candidates for being stuck (won't re-fire until condition flips false
  // then true again). Called once after the first tick to surface the current
  // state without spamming every 10s.
  _logStuckCandidates(rules) {
    const stuck = [];
    for (const rule of rules) {
      const id = String(rule._id);
      if (this.prev.get(id)) {
        const chs = (rule.channels || []).join(',');
        stuck.push(`rule=${id.slice(-6)} "${rule.name}" sensor=${rule.sensorId} CH[${chs}]`);
      }
    }
    if (stuck.length) {
      console.log(
        `[ruleEngine] ${stuck.length} rule(s) have lastConditionState=true (will NOT re-fire ` +
        `until condition flips false then true): ${stuck.join('; ')}`,
      );
    } else {
      console.log('[ruleEngine] No stuck rules detected on startup');
    }
  }

  // Publish an action to every channel in the list. Returns true if all
  // publishes succeeded.
  async _publishToChannels(deviceId, channels, action) {
    let allOk = true;
    for (const ch of channels) {
      try {
        await this.mqttGateway.publishCommandNoWait(deviceId, ch, action);
      } catch (err) {
        console.error(`[ruleEngine] Publish error on ${deviceId} CH${ch} ${action}: ${err.message}`);
        allOk = false;
      }
    }
    return allOk;
  }

  async evaluate() {
    let rules;
    try {
      rules = await Rule.find({ enabled: true });
    } catch (err) {
      console.error('[ruleEngine] Query error:', err);
      return;
    }

    this._primeCache(rules);

    // Log stuck candidates once on the very first tick after startup.
    if (!this._startupLogged) {
      this._startupLogged = true;
      this._logStuckCandidates(rules);
    }

    // Latest live value for every sensor referenced by an enabled rule.
    const sensorMap = new Map();
    if (rules.length > 0) {
      try {
        const sensors = await Sensor.find({ sensorId: { $in: rules.map((r) => r.sensorId) } });
        for (const s of sensors) sensorMap.set(s.sensorId, s);
      } catch (err) {
        console.error('[ruleEngine] Sensor query error:', err);
        return;
      }
    }

    for (const rule of rules) {
      const sensor = sensorMap.get(rule.sensorId);
      const id = String(rule._id);

      // Backward compat: ensure channels is populated.
      const channels = rule.channels && rule.channels.length > 0
        ? rule.channels
        : (typeof rule.channel === 'number' ? [rule.channel] : []);

      if (channels.length === 0) {
        console.warn(`[ruleEngine] Rule "${rule.name}" has no channels, skipping`);
        continue;
      }

      if (!sensor || typeof sensor.lastValue !== 'number') {
        // No usable reading: reset edge state so a later true reading is a
        // fresh edge. Only write to DB if it actually changed.
        const wasTrue = this.prev.get(id) || false;
        if (wasTrue) {
          await this._setConditionState(rule._id, false);
        } else {
          this.prev.set(id, false);
        }
        continue;
      }

      const value = sensor.lastValue;
      const conditionTrue =
        rule.condition === 'above' ? value > rule.threshold : value < rule.threshold;

      const wasTrue = this.prev.get(id) || false;

      // No state change — do nothing.
      if (conditionTrue === wasTrue) {
        this.prev.set(id, conditionTrue);
        continue;
      }

      // ---- State transition detected ----

      // Only fire against an online device. If offline, do NOT change the
      // edge state, so the rule can still fire once the device returns.
      if (!runtimeState.isOnline(rule.deviceId)) {
        console.warn(
          `[ruleEngine] Skipped rule "${rule.name}" — device ${rule.deviceId} is offline (channels [${channels}])`,
        );
        this.prev.set(id, wasTrue);
        continue;
      }

      // Determine which action to send based on the new condition state.
      const actionToSend = conditionTrue ? rule.action : oppositeAction(rule.action);

      try {
        await this._publishToChannels(rule.deviceId, channels, actionToSend);
        const chStr = channels.join(',');
        console.log(
          `[ruleEngine] Rule "${rule.name}": condition=${conditionTrue} -> ${rule.deviceId} CH[${chStr}] ${actionToSend}`,
        );
        await this._setConditionState(rule._id, conditionTrue);
      } catch (err) {
        console.error(
          `[ruleEngine] Rule "${rule.name}" fire error on ${rule.deviceId} channels [${channels}]: ${err.message}`,
        );
        // Do not flip the edge state; allow a retry on the next tick.
        this.prev.set(id, wasTrue);
      }
    }
  }
}

module.exports = new RuleEngine();
