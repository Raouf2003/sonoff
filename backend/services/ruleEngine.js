const Sensor = require('../models/Sensor');
const Rule = require('../models/Rule');

class RuleEngine {
  constructor() {
    this.sensorsByDevice = new Map();
    this.rulesBySensor = new Map();
    this.byId = new Map();
    this.runtimeState = null;
    this.commandRouter = null;
  }

  init({ runtimeState, commandRouter }) {
    this.runtimeState = runtimeState;
    this.commandRouter = commandRouter;
  }

  async rebuildAll() {
    const [sensors, rules] = await Promise.all([Sensor.find({}), Rule.find({})]);
    this.sensorsByDevice.clear();
    this.rulesBySensor.clear();
    this.byId.clear();
    this.runtimeState.reset();
    for (const s of sensors) this._indexSensor(s);
    for (const r of rules) this._indexRule(r);
    console.log(`RuleEngine: indexed ${sensors.length} sensor(s), ${rules.length} rule(s)`);
  }

  getSensorsForDevice(deviceId) {
    return this.sensorsByDevice.get(deviceId) || null;
  }

  _indexSensor(s) {
    if (!s.deviceId) return;
    if (!this.sensorsByDevice.has(s.deviceId)) {
      this.sensorsByDevice.set(s.deviceId, new Map());
    }
    this.sensorsByDevice.get(s.deviceId).set(s.sensorId, s);
  }

  _dropSensor(s) {
    const m = this.sensorsByDevice.get(s.deviceId);
    if (m) m.delete(s.sensorId);
  }

  _indexRule(r) {
    const rid = r._id.toString();
    this.byId.set(rid, r);

    if (!this.rulesBySensor.has(r.sensorId)) this.rulesBySensor.set(r.sensorId, []);
    const arr = this.rulesBySensor.get(r.sensorId);
    if (!arr.some((x) => x._id.toString() === rid)) arr.push(r);
    arr.sort((a, b) => (b.priority || 0) - (a.priority || 0));
  }

  _dropRule(r) {
    const rid = r._id.toString();
    this.byId.delete(rid);
    const arr = this.rulesBySensor.get(r.sensorId);
    if (arr) {
      const i = arr.findIndex((x) => x._id.toString() === rid);
      if (i >= 0) arr.splice(i, 1);
    }
    this.runtimeState.setRuleActive(rid, false);
  }

  async onSensorChanged(s) {
    this._dropSensor(s);
    this._indexSensor(s);
  }

  async onSensorDeleted(s) {
    this._dropSensor(s);
    this.runtimeState.clearSensorRuntime(s.sensorId);
  }

  async onRuleChanged(r) {
    this._indexRule(r);
  }

  async onRuleDeleted(r) {
    this._dropRule(r);
  }

  async onDeviceUnclaimed(deviceId) {
    const sensors = this.sensorsByDevice.get(deviceId);
    if (!sensors) return;
    for (const s of sensors.values()) {
      this.runtimeState.clearSensorRuntime(s.sensorId);
      for (const r of this.rulesBySensor.get(s.sensorId) || []) {
        if (r.enabled) {
          r.enabled = false;
          this.runtimeState.setRuleActive(r._id.toString(), false);
        }
      }
    }
    this.sensorsByDevice.delete(deviceId);
  }

  handleReading(sensorId, value, ts) {
    const rt = this.runtimeState;
    const prev = rt.getSensorValue(sensorId);
    rt.setSensorValue(sensorId, value, ts);

    const rules = this.rulesBySensor.get(sensorId) || [];
    for (const rule of rules) {
      if (!rule.enabled) continue;
      if (rt.isEmergencyStop(rule.ownerId.toString())) continue;
      const rid = rule._id.toString();
      const lastSeen = prev ? prev.lastSeen : ts;
      if (rule.freshnessS > 0 && ts - lastSeen > rule.freshnessS * 1000) {
        continue;
      }
      if (!this._bandHit(rule, value)) {
        rt.setRuleActive(rid, false);
        continue;
      }
      if (rt.isRuleActive(rid)) continue;
      if (!rt.claimCooldown(rid, ts, rule.cooldownS)) continue;
      rt.setRuleActive(rid, true);
      this.commandRouter.execute(rule, value, ts);
    }
  }

  _bandHit(rule, value) {
    const band = rule.condition && rule.condition.band;
    if (!band) return false;
    if (typeof value !== 'number' || Number.isNaN(value)) return false;
    const h = band.hysteresis || 0;
    const active = this.runtimeState.isRuleActive(rule._id.toString());
    const min = band.min != null ? band.min - (active ? h : 0) : -Infinity;
    const max = band.max != null ? band.max + (active ? h : 0) : Infinity;
    return value >= min && value <= max;
  }
}

module.exports = new RuleEngine();
