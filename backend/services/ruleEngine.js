const Sensor = require('../models/Sensor');
const Rule = require('../models/Rule');

class RuleEngine {
  constructor() {
    this.sensorsByKey = new Map();
    this.rulesByKey = new Map();
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
    this.sensorsByKey.clear();
    this.rulesByKey.clear();
    this.byId.clear();
    this.runtimeState.reset();
    for (const s of sensors) this._indexSensor(s);
    for (const r of rules) this._indexRule(r);
    console.log(`RuleEngine: indexed ${sensors.length} sensor(s), ${rules.length} rule(s)`);
  }

  getSensor(ownerId, sensorId) {
    return this.sensorsByKey.get(`${ownerId}:${sensorId}`) || null;
  }

  _key(ownerId, sensorId) {
    return `${ownerId}:${sensorId}`;
  }

  _indexSensor(s) {
    this.sensorsByKey.set(this._key(s.ownerId.toString(), s.sensorId), s);
  }

  _dropSensor(s) {
    this.sensorsByKey.delete(this._key(s.ownerId.toString(), s.sensorId));
  }

  _indexRule(r) {
    const rid = r._id.toString();
    this.byId.set(rid, r);

    const key = this._key(r.ownerId.toString(), r.sensorId);
    if (!this.rulesByKey.has(key)) this.rulesByKey.set(key, []);
    const arr = this.rulesByKey.get(key);
    if (!arr.some((x) => x._id.toString() === rid)) arr.push(r);
    arr.sort((a, b) => (b.priority || 0) - (a.priority || 0));
  }

  _dropRule(r) {
    const rid = r._id.toString();
    this.byId.delete(rid);
    const key = this._key(r.ownerId.toString(), r.sensorId);
    const arr = this.rulesByKey.get(key);
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
    this.runtimeState.clearSensorRuntime(s.ownerId.toString(), s.sensorId);
  }

  async onRuleChanged(r) {
    this._indexRule(r);
  }

  async onRuleDeleted(r) {
    this._dropRule(r);
  }

  handleReading(ownerId, sensorId, value, ts) {
    const rt = this.runtimeState;
    const key = this._key(ownerId, sensorId);
    const prev = rt.getSensorValue(ownerId, sensorId);
    rt.setSensorValue(ownerId, sensorId, value, ts);

    const rules = this.rulesByKey.get(key) || [];
    for (const rule of rules) {
      if (!rule.enabled) continue;
      if (rt.isEmergencyStop(ownerId)) continue;
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
