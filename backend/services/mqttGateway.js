const mqtt = require('mqtt');
const Telemetry = require('../models/Telemetry');

const ACK_TIMEOUT_MS = 5000;
const SENSOR_META_KEYS = new Set(['Time', 'Epoch', 'Uptime', 'UptimeSec', 'Heap', 'LoadAvg']);

function coerceValue(v) {
  if (typeof v === 'number') return v;
  if (typeof v === 'boolean') return v;
  const s = String(v).trim();
  if (s === '') return undefined;
  const num = Number(s);
  return Number.isNaN(num) ? s.toUpperCase() : num;
}

function powerUpdatesFrom(parsed, channelCount) {
  const updates = {};
  if (!parsed || typeof parsed !== 'object') return updates;
  for (let i = 1; i <= channelCount; i++) {
    const v = parsed[`POWER${i}`];
    if (v === 'ON' || v === 'OFF') updates[i] = v;
  }
  return updates;
}

class MqttGateway {
  constructor() {
    this.client = null;
    this.io = null;
    this.deviceRegistry = null;
    this.runtimeState = null;
    this.engine = null;
    this.pending = new Map();
  }

  init({ io, deviceRegistry, runtimeState, engine }) {
    this.io = io;
    this.deviceRegistry = deviceRegistry;
    this.runtimeState = runtimeState;
    this.engine = engine;
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
    this.client.subscribe('tele/+/SENSOR');
    console.log('MQTT subscriptions (re)registered');
  }

  publishCommand(deviceId, channel, state) {
    return new Promise((resolve, reject) => {
      const c = this.client;
      if (!c || !c.connected) {
        return reject(new Error('MQTT not connected'));
      }
      const topic = `cmnd/${deviceId}/POWER${channel}`;
      const key = `${deviceId}:${channel}`;
      const prev = this.pending.get(key);
      if (prev) clearTimeout(prev.timer);

      const timer = setTimeout(() => {
        this.pending.delete(key);
        resolve(false);
      }, ACK_TIMEOUT_MS);
      this.pending.set(key, { state: String(state).toUpperCase(), timer, resolve, reject });

      c.publish(topic, String(state).toUpperCase(), { qos: 1, retain: false }, (err) => {
        if (err) {
          clearTimeout(timer);
          this.pending.delete(key);
          reject(err);
        }
      });
    });
  }

  _resolvePending(deviceId, channel, observed) {
    const key = `${deviceId}:${channel}`;
    const p = this.pending.get(key);
    if (!p) return;
    clearTimeout(p.timer);
    this.pending.delete(key);
    const acked = String(observed).toUpperCase() === p.state;
    if (p.resolve) p.resolve(acked);
  }

  _failPending(reason) {
    for (const [key, p] of this.pending) {
      clearTimeout(p.timer);
      this.pending.delete(key);
      if (p.reject) p.reject(new Error(`MQTT ${reason}`));
    }
  }

  _handle(topic, payload) {
    const parts = topic.split('/');
    const deviceId = parts[1];
    if (!deviceId) return;

    const device = this.deviceRegistry.get(deviceId);
    const owned = !!(device && device.ownerId);
    const channelCount = device ? device.channels : 4;

    let parsed = null;
    try {
      parsed = JSON.parse(payload);
    } catch {
      parsed = null;
    }

    const channelUpdates = {};
    const isState = parts[0] === 'tele' && parts[2] === 'STATE';
    const isSensor = parts[0] === 'tele' && parts[2] === 'SENSOR';
    const isResult = parts[0] === 'stat' && (parts[2] === 'RESULT' || /^POWER\d+$/.test(parts[2]));

    if (isSensor && owned && parsed && typeof parsed === 'object') {
      this._ingestSensorPayload(deviceId, device.ownerId, parsed);
    } else if (isState && parsed) {
      Object.assign(channelUpdates, powerUpdatesFrom(parsed, channelCount));
      this._resolveAcks(deviceId, parsed);
    } else if (isResult && parsed) {
      Object.assign(channelUpdates, powerUpdatesFrom(parsed, channelCount));
      this._resolveAcks(deviceId, parsed);
    } else if (isResult) {
      const m = topic.match(/POWER(\d+)$/);
      if (m) {
        const ch = parseInt(m[1], 10);
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
      if (owned && this.io) {
        for (const [ch, st] of Object.entries(channelUpdates)) {
          this.io.emit('device_update', { deviceId, channel: Number(ch), state: st });
        }
      }
    }
  }

  _ingestSensorPayload(deviceId, ownerId, parsed) {
    const ts = Date.now();
    for (const [sensorId, raw] of Object.entries(parsed)) {
      if (SENSOR_META_KEYS.has(sensorId)) continue;
      const value = coerceValue(raw);
      if (value === undefined) continue;
      this.runtimeState.observeSensor(ownerId, sensorId, value, ts, deviceId);
      const sensor = this.engine.getSensor(ownerId, sensorId);
      if (!sensor) continue;
      this._ingestReading(sensor, value, ts, deviceId);
    }
  }

  _resolveAcks(deviceId, parsed) {
    if (!parsed || typeof parsed !== 'object') return;
    for (const key of Object.keys(parsed)) {
      const m = key.match(/^POWER(\d+)$/);
      if (m && (parsed[key] === 'ON' || parsed[key] === 'OFF')) {
        this._resolvePending(deviceId, parseInt(m[1], 10), parsed[key]);
      }
    }
  }

  _ingestReading(sensor, value, ts, deviceId) {
    const ownerId = sensor.ownerId.toString();
    this.engine.handleReading(ownerId, sensor.sensorId, value, ts);
    if (this._shouldPersist(sensor, value, ts)) {
      Telemetry.create({
        ownerId: sensor.ownerId,
        sensorId: sensor.sensorId,
        deviceId: deviceId || null,
        value,
        ts: new Date(ts),
      }).catch((err) => console.error('Telemetry write error:', err.message));
      this.runtimeState.setBaseline(ownerId, sensor.sensorId, value, ts);
    }
  }

  _shouldPersist(sensor, value, ts) {
    const ownerId = sensor.ownerId.toString();
    const p = sensor.persistence || {};
    const mode = p.mode || 'change_or_interval';
    const intervalMs = (p.intervalSeconds && p.intervalSeconds > 0 ? p.intervalSeconds : 300) * 1000;
    const epsilon = p.epsilon || 0;
    const baseline = this.runtimeState.getBaseline(ownerId, sensor.sensorId);
    if (!baseline) return true;

    const intervalElapsed = ts - baseline.ts >= intervalMs;
    if (mode === 'interval_only') return intervalElapsed;

    const numeric = typeof baseline.value === 'number' && typeof value === 'number';
    const changed = numeric
      ? Math.abs(value - baseline.value) >= epsilon
      : value !== baseline.value;
    if (mode === 'change_only') return changed;
    return changed || intervalElapsed;
  }
}

module.exports = new MqttGateway();
