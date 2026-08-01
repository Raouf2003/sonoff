class RuntimeState {
  constructor() {
    this.deviceStates = new Map();
    this.sensorValues = new Map();
    this.sensorBaselines = new Map();
    this.sensorObservations = new Map();
    this.ruleActive = new Map();
    this.cooldowns = new Map();
    this.emergencyStops = new Set();
  }

  ensureDeviceState(deviceId, channels) {
    let state = this.deviceStates.get(deviceId);
    if (!state) {
      const chans = {};
      for (let i = 1; i <= channels; i++) chans[i] = 'OFF';
      state = { channels: chans, lastSeen: null };
      this.deviceStates.set(deviceId, state);
    }
    return state.channels;
  }

  touchDevice(deviceId) {
    const state = this.deviceStates.get(deviceId);
    if (state) state.lastSeen = Date.now();
  }

  getDeviceState(deviceId) {
    return this.deviceStates.get(deviceId) || null;
  }

  setSensorValue(ownerId, sensorId, value, ts) {
    this.sensorValues.set(`${ownerId}:${sensorId}`, { value, lastSeen: ts });
  }

  getSensorValue(ownerId, sensorId) {
    return this.sensorValues.get(`${ownerId}:${sensorId}`) || null;
  }

  getBaseline(ownerId, sensorId) {
    return this.sensorBaselines.get(`${ownerId}:${sensorId}`) || null;
  }

  setBaseline(ownerId, sensorId, value, ts) {
    this.sensorBaselines.set(`${ownerId}:${sensorId}`, { value, ts });
  }

  clearSensorRuntime(ownerId, sensorId) {
    this.sensorValues.delete(`${ownerId}:${sensorId}`);
    this.sensorBaselines.delete(`${ownerId}:${sensorId}`);
  }

  observeSensor(ownerId, sensorId, value, ts, deviceId) {
    const key = `${ownerId}:${sensorId}`;
    const prev = this.sensorObservations.get(key);
    const count = prev ? prev.count + 1 : 1;
    this.sensorObservations.set(key, { value, ts, deviceId, count, firstSeen: prev ? prev.firstSeen : ts });
  }

  getSensorObservations(ownerId) {
    const out = [];
    for (const [key, obs] of this.sensorObservations) {
      if (key.startsWith(`${ownerId}:`)) {
        out.push({ ...obs, sensorId: key.slice(ownerId.length + 1) });
      }
    }
    return out;
  }

  isRuleActive(ruleId) {
    return !!this.ruleActive.get(ruleId);
  }

  setRuleActive(ruleId, active) {
    this.ruleActive.set(ruleId, active);
  }

  claimCooldown(ruleId, ts, cooldownS) {
    if (cooldownS > 0) {
      const last = this.cooldowns.get(ruleId) || 0;
      if (ts - last < cooldownS * 1000) return false;
    }
    this.cooldowns.set(ruleId, ts);
    return true;
  }

  isEmergencyStop(ownerId) {
    return this.emergencyStops.has(ownerId);
  }

  setEmergencyStop(ownerId, on) {
    if (on) this.emergencyStops.add(ownerId);
    else this.emergencyStops.delete(ownerId);
  }

  reset() {
    this.ruleActive.clear();
    this.cooldowns.clear();
  }
}

module.exports = new RuntimeState();
