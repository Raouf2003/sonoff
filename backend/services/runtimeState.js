class RuntimeState {
  constructor() {
    this.deviceStates = new Map();
    this.sensorValues = new Map();
    this.sensorBaselines = new Map();
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

  setSensorValue(sensorId, value, ts) {
    this.sensorValues.set(sensorId, { value, lastSeen: ts });
  }

  getSensorValue(sensorId) {
    return this.sensorValues.get(sensorId) || null;
  }

  getBaseline(sensorId) {
    return this.sensorBaselines.get(sensorId) || null;
  }

  setBaseline(sensorId, value, ts) {
    this.sensorBaselines.set(sensorId, { value, ts });
  }

  clearSensorRuntime(sensorId) {
    this.sensorValues.delete(sensorId);
    this.sensorBaselines.delete(sensorId);
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
