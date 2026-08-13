class RuntimeState {
  constructor() {
    this.deviceStates = new Map();
    // Treat a device as online if its last MQTT activity is within this
    // window. Overridable via DEVICE_FRESH_MS. The default (5 min) is far
    // more forgiving than the old 60s so real devices with a long Tasmota
    // TelePeriod don't flicker offline between telemetry publishes.
    this.freshMs = parseInt(process.env.DEVICE_FRESH_MS || '300000', 10);
  }

  // Channels are seeded UNKNOWN (never OFF): a channel that has not been
  // observed reporting a real state must never be presented as a confident
  // "OFF". Only device reports (MQTT STATE/RESULT/POWERn) can turn a channel
  // into ON/OFF, and each report is timestamped.
    ensureDeviceState(deviceId, channels) {
    let state = this.deviceStates.get(deviceId);
    if (!state) {
      const chans = {};
      for (let i = 1; i <= channels; i++) {
        chans[i] = { state: 'UNKNOWN', updatedAt: null };
      }
      // `online` mirrors the latest LWT/heartbeat intent; `offline` latches an
      // explicit LWT Offline and is only cleared by a positive device report
      // (tele/STATE, stat/RESULT, POWERn, LWT Online). `lastSeen` records when
      // the device last produced ANY MQTT packet and must NEVER override an
      // explicit `offline` (see isOnline).
      state = { channels: chans, lastSeen: null, online: false, offline: false };
      this.deviceStates.set(deviceId, state);
    }
    return state.channels;
  }

  // Records a device-reported channel state and stamps it with the current
  // server time. Returns the updated channel entry so callers can emit its
  // timestamp. A state other than ON/OFF is recorded as UNKNOWN.
  applyChannelState(deviceId, channel, state) {
    const st = this.deviceStates.get(deviceId);
    const chans = st ? st.channels : this.ensureDeviceState(deviceId, channel);
    if (!chans[channel]) chans[channel] = { state: 'UNKNOWN', updatedAt: null };
    const normalized = state === 'ON' || state === 'OFF' ? state : 'UNKNOWN';
    chans[channel].state = normalized;
    chans[channel].updatedAt = Date.now();
    return chans[channel];
  }

  // Any positive device report (tele/STATE, stat/RESULT, raw POWERn) is
  // liveness evidence: it restores ONLINE and clears an explicit LWT Offline.
  touchDevice(deviceId) {
    const state = this.deviceStates.get(deviceId);
    if (state) {
      state.lastSeen = Date.now();
      state.online = true;
      state.offline = false;
    }
  }

  // LWT-driven connectivity. `setOnline(false)` (LWT Offline) is AUTHORITATIVE
  // device-offline evidence: it latches `offline` so stale `lastSeen` cannot
  // keep the device online. Only a positive report (touchDevice / LWT Online)
  // clears it.
  setOnline(deviceId, online) {
    const state = this.deviceStates.get(deviceId);
    if (!state) return;
    state.online = online;
    state.offline = !online;
    if (online) state.lastSeen = Date.now();
  }

  isOnline(deviceId) {
    const state = this.deviceStates.get(deviceId);
    if (!state) return false;
    // An explicit LWT Offline is authoritative and beats any telemetry age.
    if (state.offline) return false;
    if (state.online) return true;
    // Fallback: recent telemetry counts as alive even without an LWT event.
    // Uses the same freshMs window as `touchDevice` so devices don't flicker
    // offline between telemetry bursts (Tasmota TelePeriod default 300s).
    return !!state.lastSeen && Date.now() - state.lastSeen < this.freshMs;
  }

  getDeviceState(deviceId) {
    return this.deviceStates.get(deviceId) || null;
  }

  // Read-model for the status API: per-channel `{ state, updatedAt }` with
  // UNKNOWN (not OFF) for anything never observed, plus liveness. Never
  // fabricates an OFF for an unobserved channel.
  getDeviceStatus(deviceId) {
    const state = this.deviceStates.get(deviceId);
    const channels = {};
    if (state) {
      for (const [ch, c] of Object.entries(state.channels)) {
        channels[ch] = {
          state: c.state || 'UNKNOWN',
          updatedAt: c.updatedAt
            ? new Date(c.updatedAt).toISOString()
            : null,
        };
      }
    }
    return { online: this.isOnline(deviceId), channels };
  }
}

module.exports = new RuntimeState();
