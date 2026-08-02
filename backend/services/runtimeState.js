class RuntimeState {
  constructor() {
    this.deviceStates = new Map();
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
}

module.exports = new RuntimeState();
