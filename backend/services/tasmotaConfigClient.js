const mqtt = require('mqtt');

const DEFAULT_TIMEOUT_MS = 5000;
const CONFIG_RESULT_TOPIC = (deviceId) => `stat/${deviceId}/RESULT`;
// Topic parts are strictly limited to unreserved MQTT characters so only the
// exact device identity and command ever reach the wire. Labels, descriptions
// ("Payload: (empty)"), pipes, spaces, slashes or any other text can never be
// smuggled into a topic part.
const SAFE_TOPIC_PART = /^[A-Za-z0-9_-]+$/;
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
  constructor({ mqttClient, brokerUrl, username, password, logger } = {}) {
    this.client = mqttClient || null;
    this.brokerUrl = brokerUrl || process.env.MQTT_BROKER_URL;
    this.username = username !== undefined ? username : process.env.MQTT_USERNAME;
    this.password = password !== undefined ? password : process.env.MQTT_PASSWORD;
    // Diagnostic trace channel (observability only). When a request carries a
    // traceId the publish and its matched RESULT are logged so the Tasmota
    // console timeline can be correlated to a single sync invocation.
    this.logger = logger || console;
    // deviceId -> Set of topics already subscribed (idempotent subscribe)
    this.subscribed = new Set();
    // deviceId -> queue of pending ops (FIFO), one pumped at a time
    this.queues = new Map();
    // deviceId -> currently in-flight op
    this.inflight = new Map();
    // deviceId -> op waiting for the shared connection attempt to come up
    this.connecting = new Map();
    // deviceIds waiting on the current shared connect attempt (single attempt
    // for every concurrent waiter; one 'connect' resume for all of them)
    this.connectAttempt = [];
  }

  isConnected() {
    return !!(this.client && this.client.connected);
  }

  // Reject any deviceId/command that could turn the published topic into
  // anything other than the exact `cmnd/<deviceId>/<command>`. This is the
  // guarantee that a debug label like "Payload: (empty)" or a
  // "cmnd/... | Payload: ..." description can never become part of the topic.
  _validateTopicParts(deviceId, command) {
    if (!deviceId || !SAFE_TOPIC_PART.test(deviceId)) {
      const err = new Error('deviceId must contain only A-Za-z0-9_-');
      err.code = 'BAD_TOPIC_PART';
      return err;
    }
    if (!command || !SAFE_TOPIC_PART.test(command)) {
      const err = new Error('command must contain only A-Za-z0-9_-');
      err.code = 'BAD_TOPIC_PART';
      return err;
    }
    return null;
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
    // Lazily-created connection: every request that arrives before the 'connect'
    // event is parked on this._connectAttempt and resumed here in one pass. A
    // single client therefore serves any number of concurrent early requests.
    this.client.on('connect', () => {
      this._resumeConnecting();
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
  requestTasmotaConfig(deviceId, command, payload = '', { timeoutMs = DEFAULT_TIMEOUT_MS, expectedResponseKey, traceId } = {}) {
    return new Promise((resolve, reject) => {
      const partErr = this._validateTopicParts(deviceId, command);
      if (partErr) {
        reject(partErr);
        return;
      }
      const op = {
        deviceId,
        command,
        payload: String(payload),
        expectedResponseKey,
        traceId,
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
    if (this.inflight.has(deviceId) || this.connecting.has(deviceId)) return;
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

    if (!this.client || !this.client.connected) {
      // Lazy connection not established yet. Park this op on the shared
      // connect attempt instead of failing: the single 'connect' handler
      // resumes every parked op, and the wait is bounded by op.timeoutMs.
      this._parkForConnect(deviceId, op);
      return;
    }

    this._publishOp(deviceId, op);
  }

  // Park an op that arrived before the lazy connection was ready. All parked
  // ops share ONE connection attempt (this.connectAttempt); a single 'connect'
  // event resumes all of them, so concurrent early requests never create
  // multiple MQTT clients/connections.
  _parkForConnect(deviceId, op) {
    if (this.connecting.has(deviceId)) return;
    this.connecting.set(deviceId, op);
    this.connectAttempt.push(deviceId);
    op.connectTimer = setTimeout(() => {
      const err = new Error(`MQTT connect timeout for Tasmota config channel (${deviceId} ${op.command})`);
      err.code = 'CFG_CONNECT_TIMEOUT';
      this._fail(deviceId, op, err);
    }, op.timeoutMs);
  }

  // Invoked once per 'connect'. Every op parked while the connection was
  // coming up is moved into the normal publish path in a single pass.
  _resumeConnecting() {
    const waiters = this.connectAttempt;
    this.connectAttempt = [];
    for (const deviceId of waiters) {
      const op = this.connecting.get(deviceId);
      if (!op) continue;
      this.connecting.delete(deviceId);
      if (op.connectTimer) {
        clearTimeout(op.connectTimer);
        op.connectTimer = null;
      }
      this._publishOp(deviceId, op);
    }
  }

  _publishOp(deviceId, op) {
    if (!this.client || !this.client.connected) {
      // Connection dropped between resume and publish: park again rather than
      // publish on a dead connection. A later 'connect' or the bounded timeout
      // will settle the op.
      this._parkForConnect(deviceId, op);
      return;
    }

    // Defense in depth: even if an op somehow reached the pump with a labeled
    // command, never publish a topic that is not exactly cmnd/<dev>/<command>.
    const partErr = this._validateTopicParts(op.deviceId, op.command);
    if (partErr) {
      this._fail(deviceId, op, partErr);
      return;
    }

    this.inflight.set(deviceId, op);
    this._subscribe(deviceId);

    op.timer = setTimeout(() => {
      const err = new Error(`Tasmota config timeout for ${deviceId} ${op.command}`);
      err.code = 'CFG_TIMEOUT';
      this._fail(deviceId, op, err);
    }, op.timeoutMs);

    const topic = CONFIG_CMD_TOPIC(op.deviceId, op.command);
    if (op.traceId) {
      this.logger.log(`[SYNC MQTT COMMAND] traceId=${op.traceId} command=${op.command} payload=${op.payload}`);
    }
    this.client.publish(topic, op.payload, { qos: 1, retain: false }, (err) => {
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
    if (op.traceId) {
      this.logger.log(`[SYNC MQTT RESULT] traceId=${op.traceId} command=${op.command} payload=${message}`);
    }
    this._settle(deviceId, op, parsed);
  }

  _settle(deviceId, op, value) {
    if (this.inflight.get(deviceId) === op) this.inflight.delete(deviceId);
    if (op.connectTimer) clearTimeout(op.connectTimer);
    if (op.timer) clearTimeout(op.timer);
    op.resolve(value);
    this._pump(deviceId);
  }

  _fail(deviceId, op, err) {
    if (this.inflight.get(deviceId) === op) this.inflight.delete(deviceId);
    if (this.connecting.get(deviceId) === op) {
      this.connecting.delete(deviceId);
      const idx = this.connectAttempt.indexOf(deviceId);
      if (idx !== -1) this.connectAttempt.splice(idx, 1);
    }
    if (op.connectTimer) clearTimeout(op.connectTimer);
    if (op.timer) clearTimeout(op.timer);
    op.reject(err);
    this._pump(deviceId);
  }

  _failAll(err) {
    const errCopy = new Error(err.message);
    errCopy.code = 'MQTT_DISCONNECTED';
    for (const [deviceId, op] of this.inflight) {
      if (op.connectTimer) clearTimeout(op.connectTimer);
      if (op.timer) clearTimeout(op.timer);
      op.reject(errCopy);
    }
    this.inflight.clear();
    for (const [deviceId, op] of this.connecting) {
      if (op.connectTimer) clearTimeout(op.connectTimer);
      op.reject(errCopy);
    }
    this.connecting.clear();
    this.connectAttempt = [];
    for (const [deviceId, queue] of this.queues) {
      for (const op of queue) {
        if (op.connectTimer) clearTimeout(op.connectTimer);
        if (op.timer) clearTimeout(op.timer);
        op.reject(errCopy);
      }
    }
    this.queues.clear();
  }
}

module.exports = new TasmotaConfigClient();
module.exports.TasmotaConfigClient = TasmotaConfigClient;