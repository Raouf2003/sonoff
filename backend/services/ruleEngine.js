const Rule = require('../models/Rule');
const Sensor = require('../models/Sensor');
const runtimeState = require('./runtimeState');

const CHECK_INTERVAL_MS = 10000;

class RuleEngine {
  constructor() {
    this.mqttGateway = null;
    this.timer = null;
    // ruleId -> whether the condition was true on the last tick. A rule fires
    // only once when its condition flips from false to true, never on every tick.
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

  // Persist the edge-trigger state to memory + MongoDB together.
  async _setConditionState(ruleId, state) {
    this.prev.set(ruleId, state);
    const ruleStr = String(ruleId);
    try {
      await Rule.updateOne(
        { _id: ruleId },
        { $set: { lastConditionState: state } },
      );
      console.log(`[ruleEngine] Persisted lastConditionState=${state} for rule ${ruleStr}`);
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

  async evaluate() {
    let rules;
    try {
      rules = await Rule.find({ enabled: true });
    } catch (err) {
      console.error('[ruleEngine] Query error:', err);
      return;
    }

    this._primeCache(rules);

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
      if (!sensor || typeof sensor.lastValue !== 'number') {
        // No usable reading: reset edge state so a later true reading is a
        // fresh edge. Only write to DB if it actually changed.
        const id = String(rule._id);
        if (this.prev.get(id)) {
          await this._setConditionState(rule._id, false);
        } else {
          this.prev.set(id, false);
        }
        continue;
      }

      const value = sensor.lastValue;
      const conditionTrue =
        rule.condition === 'above' ? value > rule.threshold : value < rule.threshold;

      const id = String(rule._id);
      const wasTrue = this.prev.get(id) || false;

      if (!conditionTrue) {
        // Reset edge state so the next true reading is detected as a fresh edge.
        if (wasTrue) {
          await this._setConditionState(rule._id, false);
        } else {
          this.prev.set(id, false);
        }
        continue;
      }

      // condition is now true.
      if (wasTrue) {
        // Already fired while the condition has remained true - do nothing.
        this.prev.set(id, true);
        continue;
      }

      // ---- false -> true edge ----
      // Only fire against an online device. If offline, do NOT change the
      // edge state, so the rule can still fire once the device returns.
      if (!runtimeState.isOnline(rule.deviceId)) {
        console.warn(
          `[ruleEngine] Skipped rule "${rule.name}" — device ${rule.deviceId} is offline (channel ${rule.channel})`,
        );
        this.prev.set(id, false);
        continue;
      }

      try {
        await this.mqttGateway.publishCommandNoWait(rule.deviceId, rule.channel, rule.action);
        console.log(
          `[ruleEngine] Rule fired: ${rule.name} -> ${rule.deviceId} POWER${rule.channel} ${rule.action}`,
        );
        await this._setConditionState(rule._id, true);
      } catch (err) {
        console.error(
          `[ruleEngine] Rule "${rule.name}" fire error on ${rule.deviceId} channel ${rule.channel}: ${err.message}`,
        );
        // Do not flip the edge state; allow a retry on the next tick.
        this.prev.set(id, false);
      }
    }
  }
}

module.exports = new RuleEngine();