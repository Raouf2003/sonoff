const { test } = require('node:test');
const assert = require('node:assert');
const { TasmotaConfigClient } = require('../services/tasmotaConfigClient');

function makeClient() {
  const handlers = new Map();
  const published = [];
  const client = {
    connected: true,
    subscribe: () => {},
    on(type, cb) {
      handlers.set(type, cb);
    },
    emit(type, ...args) {
      const cb = handlers.get(type);
      if (cb) cb(...args);
    },
    publish(topic, payload, opts, cb) {
      published.push({ topic, payload: String(payload) });
      if (typeof cb === 'function') cb(null);
    },
    published,
  };
  return client;
}

function configClient() {
  const client = makeClient();
  const cfg = new TasmotaConfigClient({ mqttClient: client });
  return { cfg, client };
}

async function delay(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

test('request resolves with the payload containing the expectedResponseKey', async () => {
  const { cfg, client } = configClient();
  const p = cfg.requestTasmotaConfig('34987AC30304', 'Timer1', '', {
    expectedResponseKey: 'Timer1',
  });
  client.emit('message', 'stat/34987AC30304/RESULT', JSON.stringify({ Timer1: { Enable: 0 } }));
  const res = await p;
  assert.deepStrictEqual(res, { Timer1: { Enable: 0 } });
  assert.deepStrictEqual(client.published.map((m) => m.topic), ['cmnd/34987AC30304/Timer1']);
});

test('a POWER report never resolves a config request', async () => {
  const { cfg, client } = configClient();
  const p = cfg.requestTasmotaConfig('dev-x', 'Timer2', '', { expectedResponseKey: 'Timer2' });
  client.emit('message', 'stat/dev-x/RESULT', JSON.stringify({ POWER1: 'ON' }));
  let settled = false;
  p.then(() => (settled = true), () => (settled = true));
  await delay(10);
  assert.strictEqual(settled, false, 'POWER payload must not settle the config request');
  client.emit('message', 'stat/dev-x/RESULT', JSON.stringify({ Timer2: { Enable: 1 } }));
  const res = await p;
  assert.deepStrictEqual(res, { Timer2: { Enable: 1 } });
});

test('a config reply with a different key never settles the request', async () => {
  const { cfg, client } = configClient();
  const p = cfg.requestTasmotaConfig('dev-x', 'Rule1', '', { expectedResponseKey: 'Rule1' });
  client.emit('message', 'stat/dev-x/RESULT', JSON.stringify({ Timer1: { Enable: 0 } }));
  let settled = false;
  p.then(() => (settled = true), () => (settled = true));
  await delay(10);
  assert.strictEqual(settled, false, 'Timer1 reply must not settle a Rule1 request');
  client.emit('message', 'stat/dev-x/RESULT', JSON.stringify({ Rule1: { State: 'OFF' } }));
  const res = await p;
  assert.deepStrictEqual(res, { Rule1: { State: 'OFF' } });
});

test('timeout rejects with CFG_TIMEOUT and cleans up the pending entry', async () => {
  const { cfg, client } = configClient();
  const p = cfg.requestTasmotaConfig('dev-x', 'Timer3', '', {
    expectedResponseKey: 'Timer3',
    timeoutMs: 10,
  });
  await assert.rejects(() => p, (err) => err.code === 'CFG_TIMEOUT');
  assert.strictEqual(cfg.inflight.has('dev-x'), false, 'inflight entry must be removed after timeout');
  assert.strictEqual(cfg.queues.has('dev-x'), false, 'queue must be cleaned after timeout');
});

test('publish callback error rejects with CFG_PUBLISH_FAILED', async () => {
  const client = makeClient();
  client.publish = (topic, payload, opts, cb) => cb(new Error('boom'));
  const cfg = new TasmotaConfigClient({ mqttClient: client });
  await assert.rejects(
    () => cfg.requestTasmotaConfig('dev-x', 'Timer4', '', { expectedResponseKey: 'Timer4' }),
    (err) => err.code === 'CFG_PUBLISH_FAILED',
  );
});

test('rejects with MQTT_DISCONNECTED when the client is not connected', async () => {
  const { cfg, client } = configClient();
  client.connected = false;
  await assert.rejects(
    () => cfg.requestTasmotaConfig('dev-x', 'Timer5', '', { expectedResponseKey: 'Timer5' }),
    (err) => err.code === 'MQTT_DISCONNECTED',
  );
});

test('a disconnect while pending rejects the outstanding request with MQTT_DISCONNECTED', async () => {
  const { cfg, client } = configClient();
  const p = cfg.requestTasmotaConfig('dev-x', 'Timer6', '', { expectedResponseKey: 'Timer6' });
  client.emit('close');
  await assert.rejects(() => p, (err) => err.code === 'MQTT_DISCONNECTED');
});

test('concurrent config requests for the same device resolve independently (serialized queue)', async () => {
  const { cfg, client } = configClient();
  const p1 = cfg.requestTasmotaConfig('dev-x', 'Timer7', '', { expectedResponseKey: 'Timer7' });
  const p2 = cfg.requestTasmotaConfig('dev-x', 'Timer8', '', { expectedResponseKey: 'Timer8' });
  // Serialized: only Timer7 is published first; Timer8 queued.
  assert.deepStrictEqual(client.published.map((m) => m.topic), ['cmnd/dev-x/Timer7']);
  client.emit('message', 'stat/dev-x/RESULT', JSON.stringify({ Timer7: { Enable: 1 } }));
  assert.deepStrictEqual(await p1, { Timer7: { Enable: 1 } });
  // Now Timer8 is pumped.
  assert.deepStrictEqual(client.published.map((m) => m.topic), ['cmnd/dev-x/Timer7', 'cmnd/dev-x/Timer8']);
  client.emit('message', 'stat/dev-x/RESULT', JSON.stringify({ Timer8: { Enable: 0 } }));
  assert.deepStrictEqual(await p2, { Timer8: { Enable: 0 } });
});

test('a reply for one device never settles a request for another device', async () => {
  const { cfg, client } = configClient();
  const p1 = cfg.requestTasmotaConfig('dev-a', 'Timer1', '', { expectedResponseKey: 'Timer1' });
  const p2 = cfg.requestTasmotaConfig('dev-b', 'Timer1', '', { expectedResponseKey: 'Timer1' });
  client.emit('message', 'stat/dev-a/RESULT', JSON.stringify({ Timer1: { Enable: 1 } }));
  const res1 = await p1;
  assert.deepStrictEqual(res1, { Timer1: { Enable: 1 } });
  let settled = false;
  p2.then(() => (settled = true), () => (settled = true));
  await delay(10);
  assert.strictEqual(settled, false, 'dev-a reply must not settle dev-b request');
  client.emit('message', 'stat/dev-b/RESULT', JSON.stringify({ Timer1: { Enable: 0 } }));
  assert.deepStrictEqual(await p2, { Timer1: { Enable: 0 } });
});

test('ignores messages on topics other than stat/<dev>/RESULT', async () => {
  const { cfg, client } = configClient();
  const p = cfg.requestTasmotaConfig('dev-x', 'Timer9', '', { expectedResponseKey: 'Timer9' });
  client.emit('message', 'tele/dev-x/STATE', JSON.stringify({ POWER1: 'ON' }));
  client.emit('message', 'stat/dev-x/STATE', JSON.stringify({ Timer9: { Enable: 1 } }));
  let settled = false;
  p.then(() => (settled = true), () => (settled = true));
  await delay(10);
  assert.strictEqual(settled, false, 'non-RESULT topics must be ignored');
  client.emit('message', 'stat/dev-x/RESULT', JSON.stringify({ Timer9: { Enable: 1 } }));
  assert.deepStrictEqual(await p, { Timer9: { Enable: 1 } });
});

test('a write command is published with its JSON payload on the config command topic', async () => {
  const { cfg, client } = configClient();
  const p = cfg.requestTasmotaConfig(
    'dev-x',
    'Timer1',
    JSON.stringify({ Enable: 1, Time: '07:00' }),
    { expectedResponseKey: 'Timer1' },
  );
  assert.deepStrictEqual(client.published.map((m) => m.payload), ['{"Enable":1,"Time":"07:00"}']);
  client.emit('message', 'stat/dev-x/RESULT', JSON.stringify({ Timer1: { Enable: 1 } }));
  await p;
});