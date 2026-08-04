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
    // ruleId -> whether the condition was true on the last tick.
    this.prev = new Map();
    // ruleId -> the action string last published ("ON" / "OFF"). Used to avoid
    // re-publishing the same action every tick; we only publish when the
    // desired action changes.
    this._lastSent = new Map();
  }

  init({ mqttGateway }) {
    this.mqttGateway = mqttGateway;
    if (this.timer) clearInterval(this.timer);
    this.timer = setInterval(() => this.evaluate(), CHECK_INTERVAL_MS);
    console.log(`[ruleEngine] Started, checking every ${CHECK_INTERVAL_MS}ms`);
  }

  invalidate(ruleId) {
    this.prev.delete(String(ruleId));
    this._lastSent.delete(String(ruleId));
  }

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

  _primeCache(rules) {
    for (const rule of rules) {
      const id = String(rule._id);
      if (!this.prev.has(id)) {
        this.prev.set(id, rule.lastConditionState === true);
      }
    }
  }

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

  async _publishToChannels(deviceId, channels, action) {
    for (const ch of channels) {
      try {
        await this.mqttGateway.publishCommandNoWait(deviceId, ch, action);
      } catch (err) {
        console.error(`[ruleEngine] Publish error on ${deviceId} CH${ch} ${action}: ${err.message}`);
        throw err;
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

    if (!this._startupLogged) {
      this._startupLogged = true;
      this._logStuckCandidates(rules);
    }

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

      const channels = rule.channels && rule.channels.length > 0
        ? rule.channels
        : (typeof rule.channel === 'number' ? [rule.channel] : []);

      if (channels.length === 0) {
        console.warn(`[ruleEngine] Rule "${rule.name}" has no channels, skipping`);
        continue;
      }

      if (!sensor || typeof sensor.lastValue !== 'number') {
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

      // The action we want the channels to be in right now.
      const desiredAction = conditionTrue ? rule.action : oppositeAction(rule.action);

      // Only publish when the desired action changes from what we last sent.
      const lastAction = this._lastSent.get(id);
      if (lastAction === desiredAction) {
        // State already enforced — skip.
        this.prev.set(id, conditionTrue);
        continue;
      }

      // ---- Desired action changed (or first tick) ----

      // Only fire against an online device. If offline, do NOT change the
      // edge state, so the rule retries once the device returns.
      if (!runtimeState.isOnline(rule.deviceId)) {
        console.warn(
          `[ruleEngine] Skipped rule "${rule.name}" — device ${rule.deviceId} is offline (channels [${channels}])`,
        );
        this.prev.set(id, this.prev.get(id) || false);
        continue;
      }

      try {
        await this._publishToChannels(rule.deviceId, channels, desiredAction);
        const chStr = channels.join(',');
        console.log(
          `[ruleEngine] Rule "${rule.name}": ${rule.condition} ${value}${conditionTrue ? '' : ' (else)'} -> ${rule.deviceId} CH[${chStr}] ${desiredAction}`,
        );
        this._lastSent.set(id, desiredAction);
        await this._setConditionState(rule._id, conditionTrue);
      } catch (err) {
        console.error(
          `[ruleEngine] Rule "${rule.name}" fire error on ${rule.deviceId} channels [${channels}]: ${err.message}`,
        );
        // Do not flip the edge state; allow a retry on the next tick.
      }
    }
  }
}

module.exports = new RuleEngine();
