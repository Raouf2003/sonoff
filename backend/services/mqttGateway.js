const mqtt = require('mqtt');
const Sensor = require('../models/Sensor');

const ACK_TIMEOUT_MS = 5000;

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
  }

  init({ io, deviceRegistry, runtimeState }) {
    this.io = io;
    this.deviceRegistry = deviceRegistry;
    this.runtimeState = runtimeState;
    this._connect();
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

    this.client.on('message', (topic, message) => this._handle(topic.toString(), message.toString()));
  }

  _subscribe() {
    this.client.subscribe('stat/+/RESULT');
    this.client.subscribe('stat/+/POWER+');
    this.client.subscribe('tele/+/STATE');
    this.client.subscribe('tele/+/LWT');
    this.client.subscribe('tele/+/SENSOR');
    console.log('MQTT subscriptions (re)registered');
  }

  // ACK-based command. Publishes to MQTT, registers a pending command, and
  // resolves only when the matching stat/.../RESULT (or tele/STATE) ack
  // arrives. Rejects on timeout, publish failure, or disconnect so callers
  // never mistake a silent device for success.
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
      if (prev) clearTimeout(prev.timer);

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

  _resolvePending(deviceId, channel, observed) {
    const key = `${deviceId}:${channel}`;
    const p = this.pending.get(key);
    if (!p) return;
    clearTimeout(p.timer);
    this.pending.delete(key);
    const acked = String(observed).toUpperCase() === p.state;
    console.log(`ACK received: ${deviceId} POWER${channel} = ${observed} (expected ${p.state}, acked: ${acked})`);
    console.log(`Pending commands: ${this.pending.size}`);
    if (p.resolve) p.resolve(acked);
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
      const m = topic.match(/POWER(\d*)$/);
      if (m) {
        const ch = channelCount === 1 ? 1 : parseInt(m[1], 10) || 1;
        const st = payload.trim().toUpperCase();
        if (st === 'ON' || st === 'OFF') channelUpdates[ch] = st;
      }
    }

    if (Object.keys(channelUpdates).length) {
      const chans = this.runtimeState.ensureDeviceState(deviceId, channelCount);
      for (const [ch, st] of Object.entries(channelUpdates)) {
        chans[Number(ch)] = st;
      }
      this.runtimeState.touchDevice(deviceId);
      if (this.io && ownerId) {
        const room = `user:${ownerId}`;
        for (const [ch, st] of Object.entries(channelUpdates)) {
          this.io.to(room).emit('device_update', { deviceId, channel: Number(ch), state: st });
        }
        this.io.to(room).emit('device_status', { deviceId, online: true });
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
    this._routeSensorUpdate(sensorId, value, new Date(now).toISOString());
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
