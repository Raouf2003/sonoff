const mqtt = require('mqtt');
const Device = require('../models/Device');
const Sensor = require('../models/Sensor');
const { classifyIp } = require('./ipValidation');
const { timeline } = require('./timeline');

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
    // deviceId -> { ip, ts } the most recent VALID LAN IP a device reported
    // through tele/STATE while it was still UNCLAIMED. Tasmota only publishes
    // tele/STATE at boot and then every TelePeriod (default 300s), so the boot
    // STATE — which carries the IP the device just obtained after being
    // provisioned — arrives BEFORE the claim and is the only reliable record of
    // the address at claim time. The provisioning service seeds a fresh claim's
    // lastIp from this hint so the app's local-setup bootstrap can reach the
    // device immediately instead of depending on a fragile post-claim STATE
    // sync. Still just a hint: the app re-verifies identity via Status 5.
    this.unclaimedIpHints = new Map();
    // Injectable Device model so unit tests can capture lastIp persistence
    // without a Mongo connection.
    this.deviceModel = Device;
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
    for (const [id, hint] of this.unclaimedIpHints) {
      if (now - hint.ts >= RECENT_WINDOW_MS) this.unclaimedIpHints.delete(id);
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

  // Bounded state recovery for a SINGLE device right after it is claimed. The
  // runtime is already warmed synchronously by the provisioning service so the
  // control route accepts it immediately; this asks the firmware for its
  // current STATE now so real channel values arrive instead of waiting up to a
  // TelePeriod. One pass, no timer, read-only (never a control command). If the
  // broker is down it is safely skipped - the connect handler runs
  // requestStateSync() over the whole registry anyway.
  requestStateSyncFor(deviceId) {
    if (!deviceId || !this.isConnected()) return;
    const topic = `cmnd/${deviceId}/State`;
    console.log(`[mqtt] requesting state sync for ${deviceId}`);
    this.client.publish(topic, '', { qos: 1, retain: false }, (err) => {
      if (err) {
        console.error(
          `[mqtt] state sync publish failed for ${deviceId}: ${err.message}`,
        );
      }
    });
  }

  // ACK-based command. Publishes to MQTT, registers a pending command, and
  // resolves only when the matching stat/.../RESULT (or tele/STATE) ack
  // arrives. Rejects on timeout, publish failure, or disconnect so callers
  // never mistake a silent device for success.
  //
  // A concurrent command for the SAME device+channel explicitly SUPERSEDES the
  // previous one (deterministic last-writer-wins) and rejects the older
  // promise with `SUPERSEDED` — no caller is ever left hanging forever.
  //
  // [opId] is the per-tap correlation id threaded from the app for the
  // end-to-end timing timeline; it is echoed on the device_update socket event
  // so the app can correlate the MQTT RESULT to its tap.
  publishCommand(deviceId, channel, state, opId) {
    return new Promise((ackResolve, ackReject) => {
      const c = this.client;
      timeline(deviceId, channel, opId, 'MQTT publish start');
      if (!c || !c.connected) {
        const err = new Error('MQTT not connected');
        err.code = 'MQTT_DISCONNECTED';
        return ackReject(err);
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
        if (prev.ackReject) prev.ackReject(err);
        if (prev.reject) prev.reject(err);
      }

      const timer = setTimeout(() => {
        this.pending.delete(key);
        console.log(`ACK timeout: ${deviceId} POWER${channel} (pending: ${this.pending.size})`);
        timeline(deviceId, channel, opId, 'ACK_TIMEOUT');
      }, ACK_TIMEOUT_MS);

      this.pending.set(key, {
        deviceId,
        channel,
        state: expected,
        timestamp: Date.now(),
        timer,
        opId,
        ackResolve,
        ackReject,
      });

      console.log(`[ACK DEBUG] publishCommand: deviceId=${deviceId} channel=${channel} expected=${expected} opId=${opId} key=${key} pendingSize=${this.pending.size}`);
      console.log(`MQTT command published: cmnd/${deviceId}/POWER${channel} = ${expected}`);
      console.log(`Waiting for ACK... (pending: ${this.pending.size})`);

      c.publish(topic, expected, { qos: 1, retain: false }, (err) => {
        if (err) {
          clearTimeout(timer);
          this.pending.delete(key);
          console.error(`MQTT publish failed: ${deviceId} POWER${channel}: ${err.message}`);
          ackReject(err);
        } else {
          timeline(deviceId, channel, opId, 'MQTT publish completed');
          timeline(deviceId, channel, opId, 'HTTP 202 sent');
          ackResolve({ acked: false, pending: true, opId, expected });
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

  // Publish arbitrary Tasmota command (e.g., SetOption128, Restart) via MQTT.
  // Uses the main gateway connection (QoS 1). Does not wait for RESULT ack.
  publishTasmotaCommand(deviceId, command) {
    return new Promise((resolve, reject) => {
      const c = this.client;
      if (!c || !c.connected) {
        return reject(new Error('MQTT not connected'));
      }
      const topic = `cmnd/${deviceId}/${command}`;
      c.publish(topic, '', { qos: 1, retain: false }, (err) => {
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
  // Only logs claimed devices by default to reduce noise from shared broker.
  _logSeen(kind, id) {
    const now = Date.now();
    const last = this.seenLog.get(id);
    // Increase dedup window to 10 minutes to reduce log volume from shared broker
    if (last && now - last < 10 * 60 * 1000) return;
    this.seenLog.set(id, now);
    const owned = kind === 'device' && this.deviceRegistry.isOwned(id);
    // Only log claimed devices and sensors to reduce noise
    if (owned) {
      console.log(`[mqtt] ${kind} seen on broker: ${id} (claimed)`);
    }
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

  // Returns the freshest VALID LAN IP this device reported WHILE UNCLAIMED
  // (within RECENT_WINDOW_MS), or null. Used only to seed a brand-new claim's
  // lastIp so local control does not wait on a post-claim telemetry round.
  unclaimedIpHint(deviceId) {
    const hint = this.unclaimedIpHints.get(deviceId);
    if (!hint) return null;
    if (Date.now() - hint.ts >= RECENT_WINDOW_MS) {
      this.unclaimedIpHints.delete(deviceId);
      return null;
    }
    return hint.ip;
  }

  _resolvePending(deviceId, channel, observed, topic = 'unknown') {
    const key = `${deviceId}:${channel}`;
    const p = this.pending.get(key);
    if (!p) return null;
    const observedUpper = String(observed).toUpperCase();
    const expectedUpper = p.state;
    const isToggle = expectedUpper === 'TOGGLE';
    const matches = isToggle ? (observedUpper === 'ON' || observedUpper === 'OFF') : (observedUpper === expectedUpper);
    if (!matches) {
      console.log(`[ACK DEBUG] opId=${p.opId} channel=${channel} observed=${observedUpper} expected=${expectedUpper} -> no match, keep waiting`);
      return null;
    }
    clearTimeout(p.timer);
    this.pending.delete(key);
    timeline(deviceId, channel, p.opId, 'Device RESULT received');
    console.log(`[ACK DEBUG] opId=${p.opId} elapsed=${Date.now() - p.timestamp}ms topic=${topic} payload=${JSON.stringify({ observed: observedUpper, expected: expectedUpper })} channel=${channel} pendingExisted=true resolvePending=true acked=true`);
    return p.opId;
  }

  _failPending(reason) {
    const err = new Error(`MQTT ${reason}`);
    err.code = 'MQTT_DISCONNECTED';
    for (const [key, p] of this.pending) {
      clearTimeout(p.timer);
      this.pending.delete(key);
      if (p.ackReject) p.ackReject(err);
      if (p.reject) p.reject(err);
    }
    console.log(`Pending commands cleared (${reason}): ${this.pending.size}`);
  }

  // Remembers the LAN IP a device reports through tele/STATE while UNCLAIMED.
  // Same validity rules as _recordDeviceIp, but never persists and never
  // requires the device to be in the registry — that is the whole point: the
  // boot STATE of a freshly-provisioned device arrives before its claim.
  _recordUnclaimedIpHint(deviceId, ip) {
    if (!ip || typeof ip !== 'string') return;
    ip = ip.trim();
    if (!ip) return;
    if (classifyIp(ip) !== 'valid') {
      console.log(`[mqtt] rejected invalid unclaimed telemetry IP for ${deviceId}: ${ip}`);
      return;
    }
    this.unclaimedIpHints.set(deviceId, { ip, ts: Date.now() });
  }

  // Remembers the LAN IP a claimed device reported via tele/STATE. Only
  // touched when the value actually changes, so a device announcing every
  // TelePeriod does not hammer the DB. The IP is just a hint: the app
  // re-verifies identity via `Status 5` before ever using it.
  //
  // Tasmota transiently reports "0.0.0.0" during boot / STA reconnect /
  // pre-DHCP, which is syntactically valid but never a reachable device
  // address. Such values (and loopback/multicast/malformed) are REJECTED: the
  // previous valid lastIp is preserved and nothing is written.
  _recordDeviceIp(deviceId, ip) {
    if (!ip || typeof ip !== 'string') return;
    ip = ip.trim();
    if (!ip) return;
    const current = this.deviceRegistry.get(deviceId);
    if (!current) return; // not a claimed device — nothing to record
    if (classifyIp(ip) !== 'valid') {
      console.log(`[mqtt] rejected invalid telemetry IP for ${deviceId}: ${ip}`);
      return;
    }
    if (current.lastIp === ip) return;
    this.deviceRegistry.updateIp(deviceId, ip);
    this.deviceModel
      .updateOne({ deviceId }, { $set: { lastIp: ip } })
      .catch((err) =>
        console.error(`Device lastIp update error for ${deviceId}:`, err.message),
      );
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
    // LWT Offline is authoritative (setOnline latches `offline`); the emitted
    // value is the resolved runtimeState verdict so every consumer reads ONE
    // consistent truth instead of raw LWT vs telemetry disagreeing.
    if (parts[0] === 'tele' && parts[2] === 'LWT') {
      const up = payload.trim().toLowerCase() === 'online';
      this.runtimeState.ensureDeviceState(deviceId, channelCount);
      const prevOnline = this.runtimeState.isOnline(deviceId);
      this.runtimeState.setOnline(deviceId, up);
      const newOnline = this.runtimeState.isOnline(deviceId);
      if (this.io && ownerId && prevOnline !== newOnline) {
        this.io.to(`user:${ownerId}`).emit('device_status', {
          deviceId,
          online: newOnline,
        });
      }
      // Device came back: nudge the schedule-sync retry layer so any deferred
      // Timer/Rule work (pendingDelete removals, failed syncs) converges now.
      if (newOnline && !prevOnline) {
        try {
          require('./scheduleSyncRetry').nudge(deviceId);
        } catch (_) {
          /* retry layer is best-effort; never break the MQTT handler */
        }
      }
      return;
    }

    let parsed = null;
    try {
      parsed = JSON.parse(payload);
    } catch {
      parsed = null;
    }

    const isState = parts[0] === 'tele' && parts[2] === 'STATE';
    const isResult = parts[0] === 'stat' && parts[2] === 'RESULT';

    // Gate: skip processing for unrelated shared-broker devices
    // Only process if we have a claimed device OR a pending command for this deviceId
    const hasPending = this._hasPendingFor(deviceId);
    if (!device && !hasPending) {
      // Record the boot/reboot STATE IP as a claim-time hint even while the
      // device is unclaimed: a fresh claim must be able to seed lastIp from
      // precisely this telemetry, which arrives minutes before any
      // post-claim STATE. Invalid values (0.0.0.0 etc.) are rejected here too.
      if (isState && parsed && parsed.IPAddress) {
        this._recordUnclaimedIpHint(deviceId, parsed.IPAddress);
      }
      return;
    }

    // Passive STATE handling: update runtimeState, emit only on actual change
    if (isState && parsed) {
      // Record LAN IP from telemetry
      this._recordDeviceIp(deviceId, parsed.IPAddress);
      const prevOnline = this.runtimeState.isOnline(deviceId);
      const updates = powerUpdatesFrom(parsed, channelCount);
      if (Object.keys(updates).length) {
        this.runtimeState.ensureDeviceState(deviceId, channelCount);
        this.runtimeState.touchDevice(deviceId);
        for (const [ch, st] of Object.entries(updates)) {
          const entry = this.runtimeState.applyChannelState(deviceId, Number(ch), st);
          // Only emit if state actually changed
          if (entry && entry.state === st) {
            this._emitDeviceUpdate(deviceId, Number(ch), st, null, 'state', ownerId);
          }
        }
      }
      // Emit device_status if online state changed (touchDevice may have restored it)
      const newOnline = this.runtimeState.isOnline(deviceId);
      if (this.io && ownerId && prevOnline !== newOnline) {
        this.io.to(`user:${ownerId}`).emit('device_status', {
          deviceId,
          online: newOnline,
        });
        // Telemetry restored liveness: same convergence nudge as LWT Online.
        if (newOnline) {
          try {
            require('./scheduleSyncRetry').nudge(deviceId);
          } catch (_) {
            /* best-effort */
          }
        }
      }
      return;
    }

    // RESULT handling: resolve pending commands AND update state
    if (isResult && parsed) {
      const updates = powerUpdatesFrom(parsed, channelCount);
      const resolvedOps = {};
      for (const [ch, st] of Object.entries(updates)) {
        const opId = this._resolvePending(deviceId, Number(ch), st, topic);
        if (opId) resolvedOps[ch] = opId;
      }
      // Update runtimeState for all channels in RESULT (whether or not they resolved a pending)
      if (Object.keys(updates).length) {
        this.runtimeState.ensureDeviceState(deviceId, channelCount);
        this.runtimeState.touchDevice(deviceId);
        for (const [ch, st] of Object.entries(updates)) {
          const entry = this.runtimeState.applyChannelState(deviceId, Number(ch), st);
          const opId = resolvedOps[ch] || null;
          this._emitDeviceUpdate(deviceId, Number(ch), st, opId, 'result', ownerId);
        }
      }
      return;
    }
  }

  _hasPendingFor(deviceId) {
    for (const key of this.pending.keys()) {
      if (key.startsWith(deviceId + ':')) return true;
    }
    return false;
  }

  _emitDeviceUpdate(deviceId, channel, state, opId, source, ownerId) {
    if (!this.io || !ownerId) return;
    const room = `user:${ownerId}`;
    timeline(deviceId, channel, opId, 'Socket.IO emitted');
    this.io.to(room).emit('device_update', {
      deviceId,
      channel,
      state,
      updatedAt: new Date().toISOString(),
      opId,
    });
    console.log(`[SOCKET DEBUG] device_update emitted: deviceId=${deviceId} channel=${channel} state=${state} opId=${opId} source=${source}`);
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
