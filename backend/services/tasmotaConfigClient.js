const mqtt = require('mqtt');

const DEFAULT_TIMEOUT_MS = 5000;
const CONFIG_RESULT_TOPIC = (deviceId) => `stat/${deviceId}/RESULT`;
const CONFIG_CMD_TOPIC = (deviceId, command) => `cmnd/${deviceId}/${command}`;

// Isolated request/response channel for Tasmota *configuration* commands
// (Timer<n>, Rule<n>, later Time/Timezone). Completely separate from
// mqttGateway.publishCommand()/pending:
//
//   - it uses its OWN MQTT connection and its OWN `stat/<deviceId>/RESULT`
//     subscription, so it never shares a message handler with the gateway;
//   - it correlates replies by the expected top-level JSON key (e.g. "Timer1",
//     "Rule2"), never by a POWER channel;
//   - it never resolves or touches the gateway's `deviceId:channel` POWER ACK
//     registry, and it ignores any POWER-key RESULT that happens to arrive on
//     the same topic;
//   - requests are serialized PER DEVICE (one in-flight config command per
//     device) so ambiguous concurrent Timer/Rule replies cannot cross-resolve;
//     different devices are independent queues.
//
// Each request has a bounded timeout; on timeout/error/disconnect every
// pending entry is cleaned up (no orphan promises, no leaked timers).
class TasmotaConfigClient {
  constructor({ mqttClient, brokerUrl, username, password } = {}) {
    this.client = mqttClient || null;
    this.brokerUrl = brokerUrl || process.env.MQTT_BROKER_URL;
    this.username = username !== undefined ? username : process.env.MQTT_USERNAME;
    this.password = password !== undefined ? password : process.env.MQTT_PASSWORD;
    // deviceId -> Set of topics already subscribed (idempotent subscribe)
    this.subscribed = new Set();
    // deviceId -> queue of pending ops (FIFO), one pumped at a time
    this.queues = new Map();
    // deviceId -> currently in-flight op
    this.inflight = new Map();
  }

  isConnected() {
    return !!(this.client && this.client.connected);
  }

  // Lazily create the dedicated connection on first use so requiring this
  // module has zero side effects (no broker handshake until a config command
  // is actually issued). When a client is injected (tests / shared broker),
  // the handlers are bound here exactly once as well.
  _ensureClient() {
    if (!this.client) {
      if (!this.brokerUrl || !this.brokerUrl.startsWith('mqtt')) {
        throw new Error('MQTT broker not configured for Tasmota config channel');
      }
      this.client = mqtt.connect(this.brokerUrl, {
        username: this.username,
        password: this.password,
      });
    }
    if (this._bound) return;
    this._bound = true;
    this.client.on('message', (topic, message) => {
      try {
        this._onMessage(topic.toString(), message.toString());
      } catch (err) {
        console.error(`[tasmotaConfig] ignored message on ${topic}:`, err.message);
      }
    });
    this.client.on('close', () => this._failAll(new Error('MQTT connection closed')));
    this.client.on('error', (err) => console.error('[tasmotaConfig] MQTT error:', err.message));
  }

  _subscribe(deviceId) {
    if (this.subscribed.has(deviceId)) return;
    const topic = CONFIG_RESULT_TOPIC(deviceId);
    if (this.client && this.client.subscribe) {
      this.client.subscribe(topic, { qos: 1 });
    }
    this.subscribed.add(deviceId);
  }

  // Public API: issue one Tasmota configuration command and resolve with the
  // parsed `stat/<deviceId>/RESULT` payload once the expectedResponseKey is
  // present. Rejects on timeout / publish failure / disconnect.
  requestTasmotaConfig(deviceId, command, payload = '', { timeoutMs = DEFAULT_TIMEOUT_MS, expectedResponseKey } = {}) {
    return new Promise((resolve, reject) => {
      if (!deviceId || !command) {
        reject(new Error('deviceId and command are required'));
        return;
      }
      const op = {
        deviceId,
        command,
        payload: String(payload),
        expectedResponseKey,
        timeoutMs,
        resolve,
        reject,
        timer: null,
      };
      if (!this.queues.has(deviceId)) this.queues.set(deviceId, []);
      this.queues.get(deviceId).push(op);
      this._pump(deviceId);
    });
  }

  _pump(deviceId) {
    if (this.inflight.has(deviceId)) return;
    const queue = this.queues.get(deviceId);
    const op = queue && queue.shift();
    if (!op) {
      if (queue && queue.length === 0) this.queues.delete(deviceId);
      return;
    }

    try {
      this._ensureClient();
    } catch (err) {
      op.reject(err);
      this._pump(deviceId);
      return;
    }

    const client = this.client;
    if (!client || !client.connected) {
      const err = new Error('MQTT not connected for Tasmota config channel');
      err.code = 'MQTT_DISCONNECTED';
      op.reject(err);
      this._pump(deviceId);
      return;
    }

    this.inflight.set(deviceId, op);
    this._subscribe(deviceId);

    op.timer = setTimeout(() => {
      const err = new Error(`Tasmota config timeout for ${deviceId} ${op.command}`);
      err.code = 'CFG_TIMEOUT';
      this._fail(deviceId, op, err);
    }, op.timeoutMs);

    client.publish(CONFIG_CMD_TOPIC(deviceId, op.command), op.payload, { qos: 1, retain: false }, (err) => {
      if (err) {
        const e = new Error(`Tasmota config publish failed for ${deviceId} ${op.command}: ${err.message}`);
        e.code = 'CFG_PUBLISH_FAILED';
        this._fail(deviceId, op, e);
      }
    });
  }

  // Correlate an incoming stat/<deviceId>/RESULT to the in-flight config
  // request for that device by top-level key. A POWER-key RESULT (or any
  // other unrelated payload) never resolves the config request.
  _onMessage(topic, message) {
    const parts = String(topic).split('/');
    if (parts[0] !== 'stat' || parts[2] !== 'RESULT') return;
    const deviceId = parts[1];
    const op = this.inflight.get(deviceId);
    if (!op) return;

    let parsed = null;
    try {
      parsed = JSON.parse(message);
    } catch {
      parsed = null;
    }
    if (!parsed || typeof parsed !== 'object') return;

    const expected = op.expectedResponseKey;
    if (expected) {
      if (!Object.prototype.hasOwnProperty.call(parsed, expected)) return;
    } else if (!Object.keys(parsed).some((k) => k.startsWith('Timer') || k.startsWith('Rule'))) {
      return;
    }
    this._settle(deviceId, op, parsed);
  }

  _settle(deviceId, op, value) {
    if (this.inflight.get(deviceId) === op) this.inflight.delete(deviceId);
    if (op.timer) clearTimeout(op.timer);
    op.resolve(value);
    this._pump(deviceId);
  }

  _fail(deviceId, op, err) {
    if (this.inflight.get(deviceId) === op) this.inflight.delete(deviceId);
    if (op.timer) clearTimeout(op.timer);
    op.reject(err);
    this._pump(deviceId);
  }

  _failAll(err) {
    const errCopy = new Error(err.message);
    errCopy.code = 'MQTT_DISCONNECTED';
    for (const [deviceId, op] of this.inflight) {
      if (op.timer) clearTimeout(op.timer);
      op.reject(errCopy);
    }
    this.inflight.clear();
    for (const [deviceId, queue] of this.queues) {
      for (const op of queue) {
        if (op.timer) clearTimeout(op.timer);
        op.reject(errCopy);
      }
    }
    this.queues.clear();
  }
}

module.exports = new TasmotaConfigClient();
module.exports.TasmotaConfigClient = TasmotaConfigClient;