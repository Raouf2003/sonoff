const Rule = require('../models/Rule');
const detectedSensors = require('./detectedSensors');

const CHECK_INTERVAL_MS = 10000;

class RuleEngine {
  constructor() {
    this.mqttGateway = null;
    this.timer = null;
    // ruleId -> whether the condition was true on the last tick. A rule fires
    // only once when its condition flips from false to true, never on every tick.
    this.prev = new Map();
  }

  init({ mqttGateway }) {
    this.mqttGateway = mqttGateway;
    this.timer = setInterval(() => this.evaluate(), CHECK_INTERVAL_MS);
  }

  async evaluate() {
    let rules;
    try {
      rules = await Rule.find({ enabled: true });
    } catch (err) {
      console.error('RuleEngine query error:', err);
      return;
    }

    for (const rule of rules) {
      const reading = detectedSensors.get(rule.sensorId);
      if (!reading) {
        this.prev.delete(String(rule._id));
        continue;
      }

      const value = reading.lastValue;
      const conditionTrue =
        rule.condition === 'above' ? value > rule.threshold : value < rule.threshold;

      const id = String(rule._id);
      const wasTrue = this.prev.get(id) || false;
      this.prev.set(id, conditionTrue);

      if (conditionTrue && !wasTrue) {
        this.mqttGateway
          .publishCommandNoWait(rule.deviceId, rule.channel, rule.action)
          .catch((err) => console.error(`Rule "${rule.name}" fire error:`, err.message));
        console.log(`Rule fired: ${rule.name} -> ${rule.deviceId} POWER${rule.channel} ${rule.action}`);
      }
    }
  }
}

module.exports = new RuleEngine();
