const mqtt = require('mqtt');
const Sensor = require('../models/Sensor');

const ACK_TIMEOUT_MS = 5000;
// How long a device stays visible in recentDevices after its last MQTT packet.
// Tasmota only publishes tele/<topic>/STATE at boot and then every TelePeriod
// (default 300s), so the window must cover the idle silence between telemetry
// bursts, otherwise the wizard can miss a freshly-provisioned device.
const RECENT_WINDOW_MS = 320000;
// How often the transient in-memory lookups are pruned so a busy public broker
// never grows them without bound.
const PRUNE_INTERVAL_MS = 5 * 60 * 1000;
const SENSOR_CACHE_TTL_MS = 10 * 60 * 1000;
const SEEN_LOG_TTL_MS = 24 * 60 * 60 * 1000;

function powerUpdatesFrom(parsed, channelCount) {
  const updates = {};
  if (!parsed || typeof parsed !== 'object') return updates;
  // Multi-relay devices report POWER1..POWERn.
  let found = false;
  for (let i = 1; i <= channelCount; i++) {
    const v = parsed[`POWER${i}`];
    if (v === 'ON' || v === 'OFF') {
      updates[i] = v;
      found = true;
    }
  }
  // Single-relay devices report a bare POWER key (no number). Map it to
  // channel 1 whenever present and no numbered keys were found, so reverse
  // effect works regardless of the stored channel count.
  if (!found && (parsed.POWER === 'ON' || parsed.POWER === 'OFF')) {
    updates[1] = parsed.POWER;
  }
  return updates;
}

class MqttGateway {
  constructor() {
    this.client = null;
    this.io = null;
    this.deviceRegistry = null;
    this.runtimeState = null;
    this.pending = new Map();
    // sensorId -> { value, lastSeen } latest live MQTT reading. Transient,
    // never persisted. Used to verify a sensor exists before saving it.
    this.sensorCache = new Map();
    // sensorId -> ownerId (string) resolved lazily and cached in memory to
    // avoid a DB lookup on every incoming sensor reading. Never trusted from
    // the client; always derived from the Sensor document.
    this.sensorOwnerCache = new Map();
    // deviceId/sensorId -> { lastSeen } entities observed on the broker, used
    // to log first-boots without spamming every message.
    this.seenLog = new Map();
    // deviceId -> timestamp (ms) of the most recent MQTT packet for that
    // device, used to expose devices observed on the broker in the last
    // RECENT_WINDOW_MS regardless of claim status.
    this.recentDevices = new Map();
  }

  init({ io, deviceRegistry, runtimeState }) {
    this.io = io;
    this.deviceRegistry = deviceRegistry;
    this.runtimeState = runtimeState;
    this._connect();
    this.pruneTimer = setInterval(() => this._prune(), PRUNE_INTERVAL_MS);
    if (this.pruneTimer.unref) this.pruneTimer.unref();
  }

  // Drops stale transient entries so the per-process maps stay bounded even
  // under noise from a shared public broker. Clients re-populate transparently:
  // recentDevices re-announce, sensor readings re-cache, owners re-resolve.
  _prune() {
    const now = Date.now();
    for (const [id, ts] of this.recentDevices) {
      if (now - ts >= RECENT_WINDOW_MS) this.recentDevices.delete(id);
    }
    for (const [id, entry] of this.sensorCache) {
      if (now - entry.lastSeen >= SENSOR_CACHE_TTL_MS) {
        this.sensorCache.delete(id);
        this.sensorOwnerCache.delete(id);
      }
    }
    for (const [id, ts] of this.seenLog) {
      if (now - ts >= SEEN_LOG_TTL_MS) this.seenLog.delete(id);
    }
  }

  isConnected() {
    return !!(this.client && this.client.connected);
  }

  _connect() {
    const url = process.env.MQTT_BROKER_URL;
    if (!url || !url.startsWith('mqtt')) {
      console.log('MQTT broker not configured. Set MQTT_BROKER_URL env var.');
      return;
    }

    this.client = mqtt.connect(url, {
      username: process.env.MQTT_USERNAME,
      password: process.env.MQTT_PASSWORD,
    });

    this.client.on('connect', () => {
      console.log(`Backend connected to MQTT broker at ${url}`);
      this._subscribe();
      this._failPending('connection reset');
      // Fast state recovery: ask every claimed device to report its current
      // STATE right now instead of waiting up to a TelePeriod. `State` is a
      // read-only query, never a control command.
      this.requestStateSync();
    });

    this.client.on('reconnect', () => {
      console.log('MQTT reconnecting...');
    });

    this.client.on('error', (err) => {
      console.error('MQTT error:', err.message);
    });

    this.client.on('close', () => {
      this._failPending('connection closed');
    });

    this.client.on('message', (topic, message) => {
      try {
        this._handle(topic.toString(), message.toString());
      } catch (err) {
        // A malformed/hostile payload from the (shared, public) broker must
        // never take down the backend. Log and drop the message.
        console.error(`[mqtt] ignored unhandled message on ${topic}:`, err.message);
      }
    });
  }

  _subscribe() {
    // qos1 for the topics that carry relay state and command ACKs so a
    // transient broker gap is less likely to lose a state report; SENSOR
    // telemetry stays qos0 to bound the load from a shared public broker.
    this.client.subscribe('stat/+/RESULT', { qos: 1 });
    this.client.subscribe('stat/+/POWER+', { qos: 1 });
    this.client.subscribe('tele/+/STATE', { qos: 1 });
    this.client.subscribe('tele/+/LWT', { qos: 1 });
    this.client.subscribe('tele/+/SENSOR', { qos: 0 });
    console.log('MQTT subscriptions (re)registered');
  }

  // Bounded, idempotent read-only state recovery. Publishes an empty
  // `cmnd/<deviceId>/State` for every claimed device so runtimeState is
  // repopulated quickly after a backend restart or MQTT reconnect instead of
  // waiting up to TelePeriod. Never sends control commands and never retries
  // on a timer — one pass per (re)connect, plus one pass after the registry
  // has loaded the claimed devices from the database.
  requestStateSync() {
    if (this._stateSyncTimer) {
      clearTimeout(this._stateSyncTimer);
    }
    this._stateSyncTimer = setTimeout(() => {
      this._stateSyncTimer = null;
      if (!this.isConnected()) return;
      for (const device of this.deviceRegistry.all()) {
        const topic = `cmnd/${device.deviceId}/State`;
        console.log(`[mqtt] requesting state sync for ${device.deviceId}`);
        this.client.publish(topic, '', { qos: 1, retain: false }, (err) => {
          if (err) {
            console.error(
              `[mqtt] state sync publish failed for ${device.deviceId}: ${err.message}`,
            );
          }
        });
      }
    }, 500);
  }

  // ACK-based command. Publishes to MQTT, registers a pending command, and
  // resolves only when the matching stat/.../RESULT (or tele/STATE) ack
  // arrives. Rejects on timeout, publish failure, or disconnect so callers
  // never mistake a silent device for success.
  //
  // A concurrent command for the SAME device+channel explicitly SUPERSEDES the
  // previous one (deterministic last-writer-wins) and rejects the older
  // promise with `SUPERSEDED` — no caller is ever left hanging forever.
  publishCommand(deviceId, channel, state) {
    return new Promise((resolve, reject) => {
      const c = this.client;
      if (!c || !c.connected) {
        const err = new Error('MQTT not connected');
        err.code = 'MQTT_DISCONNECTED';
        return reject(err);
      }
      const topic = `cmnd/${deviceId}/POWER${channel}`;
      const key = `${deviceId}:${channel}`;
      const expected = String(state).toUpperCase();
      const prev = this.pending.get(key);
      if (prev) {
        clearTimeout(prev.timer);
        const err = new Error(
          `Command superseded for ${deviceId} channel ${channel}`,
        );
        err.code = 'SUPERSEDED';
        if (prev.reject) prev.reject(err);
      }

      const timer = setTimeout(() => {
        this.pending.delete(key);
        const err = new Error(`ACK timeout waiting for ${deviceId} channel ${channel}`);
        err.code = 'ACK_TIMEOUT';
        console.log(`ACK timeout: ${deviceId} POWER${channel} (pending: ${this.pending.size})`);
        reject(err);
      }, ACK_TIMEOUT_MS);

      this.pending.set(key, {
        deviceId,
        channel,
        state: expected,
        timestamp: Date.now(),
        timer,
        resolve,
        reject,
      });

      console.log(`MQTT command published: cmnd/${deviceId}/POWER${channel} = ${expected}`);
      console.log(`Waiting for ACK... (pending: ${this.pending.size})`);

      c.publish(topic, expected, { qos: 1, retain: false }, (err) => {
        if (err) {
          clearTimeout(timer);
          this.pending.delete(key);
          console.error(`MQTT publish failed: ${deviceId} POWER${channel}: ${err.message}`);
          reject(err);
        }
      });
    });
  }

  publishCommandNoWait(deviceId, channel, state) {
    return new Promise((resolve, reject) => {
      const c = this.client;
      if (!c || !c.connected) {
        return reject(new Error('MQTT not connected'));
      }
      const topic = `cmnd/${deviceId}/POWER${channel}`;
      c.publish(topic, String(state).toUpperCase(), { qos: 1, retain: false }, (err) => {
        if (err) {
          reject(err);
        } else {
          resolve();
        }
      });
    });
  }

  // Latest known reading for a sensor, or null if never seen. The reading is
  // valid only if it arrived within `maxAgeMs`.
  getSensorReading(sensorId, maxAgeMs) {
    const entry = this.sensorCache.get(sensorId);
    if (!entry) return null;
    if (Date.now() - entry.lastSeen > maxAgeMs) return null;
    return { sensorId, value: entry.value, lastSeen: new Date(entry.lastSeen) };
  }

  // Logs a newly-seen entity (device or sensor) once, so the logs show every
  // thing currently talking to the broker without flooding per-message noise.
  _logSeen(kind, id) {
    const now = Date.now();
    const last = this.seenLog.get(id);
    if (last && now - last < 60 * 1000) return;
    this.seenLog.set(id, now);
    const owned = kind === 'device' && this.deviceRegistry.isOwned(id);
    console.log(`[mqtt] ${kind} seen on broker: ${id}${owned ? ' (claimed)' : ''}`);
  }

  snapshot() {
    return {
      sensors: Array.from(this.sensorCache, ([sensorId, e]) => ({
        sensorId,
        value: e.value,
        lastSeen: new Date(e.lastSeen),
      })),
      devices: Array.from(this.deviceRegistry.all(), (d) => ({
        deviceId: d.deviceId,
        name: d.name,
        channels: d.channels,
      })),
    };
  }

  // True if deviceId has announced itself on the broker within the recent
  // window. This is the possession gate for device provisioning and is always
  // checked against the caller-known deviceId, never broadcast.
  hasRecent(deviceId) {
    const ts = this.recentDevices.get(deviceId);
    return !!ts && Date.now() - ts < RECENT_WINDOW_MS;
  }

  _resolvePending(deviceId, channel, observed) {
    const key = `${deviceId}:${channel}`;
    const p = this.pending.get(key);
    if (!p) return;
    clearTimeout(p.timer);
    this.pending.delete(key);
    const acked = String(observed).toUpperCase() === p.state;
    console.log(`ACK received: ${deviceId} POWER${channel} = ${observed} (expected ${p.state}, acked: ${acked})`);
    console.log(`Pending commands: ${this.pending.size}`);
    if (p.resolve) p.resolve({ acked, observed: String(observed).toUpperCase() });
  }

  _failPending(reason) {
    const err = new Error(`MQTT ${reason}`);
    err.code = 'MQTT_DISCONNECTED';
    for (const [key, p] of this.pending) {
      clearTimeout(p.timer);
      this.pending.delete(key);
      if (p.reject) p.reject(err);
    }
    console.log(`Pending commands cleared (${reason}): ${this.pending.size}`);
  }

  _handle(topic, payload) {
    const parts = topic.split('/');
    const id = parts[1];
    if (!id) return;

    // Sensor nodes: tele/<SENSOR_ID>/SENSOR, payload {"value":42}. The sensor
    // id comes from the topic; the payload only carries the numeric value.
    if (parts[0] === 'tele' && parts[2] === 'SENSOR') {
      this._logSeen('sensor', id);
      this._ingestSensor(id, payload);
      return;
    }

    const deviceId = id;
    this._logSeen('device', deviceId);
    // Fast-path wake-up: when a device becomes visible on the broker for the
    // first time (or re-appears after leaving the window) emit a scoped event.
    // The room is keyed by the canonical MAC the client is provisioning; only
    // authenticated clients who verified they may watch that MAC are allowed to
    // join it (validated on connect), so this never leaks unowned or foreign
    // devices across users. It is a wake-up only - the app polling the /seen
    // endpoint remains the source of truth / fallback.
    const firstSeenInWindow = !this.hasRecent(deviceId);
    this.recentDevices.set(deviceId, Date.now());
    if (firstSeenInWindow && this.io) {
      this.io.to(`provision:${deviceId}`).emit('device_seen', { deviceId });
    }
    const device = this.deviceRegistry.get(deviceId);
    const ownerId = device ? device.ownerId : null;
    const channelCount = device ? device.channels : 4;

    // Tasmota LWT reports liveness: tele/<deviceId>/LWT = "Online"/"Offline".
    if (parts[0] === 'tele' && parts[2] === 'LWT') {
      const up = payload.trim().toLowerCase() === 'online';
      this.runtimeState.ensureDeviceState(deviceId, channelCount);
      this.runtimeState.setOnline(deviceId, up);
      if (this.io && ownerId) {
        this.io.to(`user:${ownerId}`).emit('device_status', { deviceId, online: up });
      }
      return;
    }

    let parsed = null;
    try {
      parsed = JSON.parse(payload);
    } catch {
      parsed = null;
    }

    const channelUpdates = {};
    const isState = parts[0] === 'tele' && parts[2] === 'STATE';
    const isResult = parts[0] === 'stat' && (parts[2] === 'RESULT' || /^POWER(\d*)$/.test(parts[2]));

    if (isState && parsed) {
      Object.assign(channelUpdates, powerUpdatesFrom(parsed, channelCount));
      this._resolveAcks(deviceId, parsed);
    } else if (isResult && parsed) {
      Object.assign(channelUpdates, powerUpdatesFrom(parsed, channelCount));
      this._resolveAcks(deviceId, parsed);
    } else if (isResult) {
      // Raw stat/<deviceId>/POWERn = "ON"/"OFF" (non-JSON payload). It is both
      // a device state report AND the direct reply to a command, so it updates
      // state and resolves any pending ACK for that channel.
      const m = topic.match(/POWER(\d*)$/);
      if (m) {
        const ch = channelCount === 1 ? 1 : parseInt(m[1], 10) || 1;
        const st = payload.trim().toUpperCase();
        if (st === 'ON' || st === 'OFF') {
          channelUpdates[ch] = st;
          this._resolvePending(deviceId, ch, st);
        }
      }
    }

    if (Object.keys(channelUpdates).length) {
      this.runtimeState.ensureDeviceState(deviceId, channelCount);
      this.runtimeState.touchDevice(deviceId);
      for (const [ch, st] of Object.entries(channelUpdates)) {
        const entry = this.runtimeState.applyChannelState(deviceId, Number(ch), st);
        if (this.io && ownerId) {
          const room = `user:${ownerId}`;
          this.io.to(room).emit('device_update', {
            deviceId,
            channel: Number(ch),
            state: st,
            updatedAt: entry.updatedAt
              ? new Date(entry.updatedAt).toISOString()
              : null,
          });
          this.io.to(room).emit('device_status', { deviceId, online: true });
        }
      }
    }
  }

  _resolveAcks(deviceId, parsed) {
    if (!parsed || typeof parsed !== 'object') return;
    for (const key of Object.keys(parsed)) {
      const m = key.match(/^POWER(\d*)$/);
      if (m && (parsed[key] === 'ON' || parsed[key] === 'OFF')) {
        const ch = m[1] ? parseInt(m[1], 10) : 1;
        this._resolvePending(deviceId, ch, parsed[key]);
      }
    }
  }

  _ingestSensor(sensorId, payload) {
    let parsed = null;
    try {
      parsed = JSON.parse(payload);
    } catch {
      parsed = null;
    }
    if (!parsed || typeof parsed !== 'object') return;

    const value = parsed.value;
    if (typeof value !== 'number') return;

    const now = Date.now();
    this.sensorCache.set(sensorId, { value, lastSeen: now });

    Sensor.updateOne(
      { sensorId },
      { $set: { lastValue: value, lastSeen: new Date(now) } },
    ).catch((err) => console.error('Sensor update error:', err));

    // Live push to the app, mirroring device_update. Emitted only to the
    // owning user's socket room; never broadcast globally.
    this._routeSensorUpdate(sensorId, value, new Date(now).toISOString())
      .catch((err) => console.error(`[mqtt] sensor_update failed for ${sensorId}:`, err.message));
  }

  // Deliver a sensor reading only to the sockets of the user who owns that
  // sensor. The owner is resolved from the Sensor document once and cached in
  // memory (sensorOwnerCache) so repeated MQTT readings don't hit the DB.
  // If the owner cannot be determined the update is safely skipped.
  async _routeSensorUpdate(sensorId, value, lastSeenIso) {
    if (!this.io) return;
    try {
      const ownerId = await this._sensorOwnerId(sensorId);
      if (!ownerId) {
        console.log(`[mqtt] Skipping sensor_update for ${sensorId}: owner unknown`);
        return;
      }
      this.io.to(`user:${ownerId}`).emit('sensor_update', { sensorId, value, lastSeen: lastSeenIso });
    } catch (err) {
      console.error(`[mqtt] Failed to route sensor_update for ${sensorId}:`, err.message);
    }
  }

  async _sensorOwnerId(sensorId) {
    const cached = this.sensorOwnerCache.get(sensorId);
    if (cached) return cached;
    const doc = await Sensor.findOne({ sensorId }).select('ownerId').lean();
    const ownerId = doc && doc.ownerId ? doc.ownerId.toString() : null;
    if (ownerId) {
      this.sensorOwnerCache.set(sensorId, ownerId);
    }
    return ownerId;
  }
}

module.exports = new MqttGateway();
module.exports.MqttGateway = MqttGateway;
module.exports.powerUpdatesFrom = powerUpdatesFrom;
