class RuntimeState {
  constructor() {
    this.deviceStates = new Map();
    // Treat a device as online if its last MQTT activity is within this
    // window. Overridable via DEVICE_FRESH_MS. The default (5 min) is far
    // more forgiving than the old 60s so real devices with a long Tasmota
    // TelePeriod don't flicker offline between telemetry publishes.
    this.freshMs = parseInt(process.env.DEVICE_FRESH_MS || '300000', 10);
  }

  ensureDeviceState(deviceId, channels) {
    let state = this.deviceStates.get(deviceId);
    if (!state) {
      const chans = {};
      for (let i = 1; i <= channels; i++) chans[i] = 'OFF';
      state = { channels: chans, lastSeen: null, online: false };
      this.deviceStates.set(deviceId, state);
    }
    return state.channels;
  }

  touchDevice(deviceId) {
    const state = this.deviceStates.get(deviceId);
    if (state) state.lastSeen = Date.now();
  }

  setOnline(deviceId, online) {
    const state = this.deviceStates.get(deviceId);
    if (!state) return;
    state.online = online;
    if (online) state.lastSeen = Date.now();
  }

  isOnline(deviceId) {
    const state = this.deviceStates.get(deviceId);
    if (!state) return false;
    if (state.online) return true;
    // Fallback: recent telemetry counts as alive even without an LWT event.
    const FRESH_MS = 60 * 1000;
    return !!state.lastSeen && Date.now() - state.lastSeen < FRESH_MS;
  }

  getDeviceState(deviceId) {
    return this.deviceStates.get(deviceId) || null;
  }
}

module.exports = new RuntimeState();
