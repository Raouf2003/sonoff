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

test('a first request while the lazy connection is down waits for connect and succeeds', async () => {
  const { cfg, client } = configClient();
  client.connected = false;
  const p = cfg.requestTasmotaConfig('dev-x', 'Timer5', '', {
    expectedResponseKey: 'Timer5',
    timeoutMs: 1000,
  });
  // Not connected: nothing may be published until 'connect'.
  assert.deepStrictEqual(client.published, []);
  client.connected = true;
  client.emit('connect');
  assert.deepStrictEqual(client.published.map((m) => m.topic), ['cmnd/dev-x/Timer5']);
  client.emit('message', 'stat/dev-x/RESULT', JSON.stringify({ Timer5: { Enable: 1 } }));
  assert.deepStrictEqual(await p, { Timer5: { Enable: 1 } });
  assert.strictEqual(cfg.inflight.has('dev-x'), false);
});

test('multiple concurrent requests while connecting share ONE connect attempt', async () => {
  const { cfg, client } = configClient();
  client.connected = false;
  const p1 = cfg.requestTasmotaConfig('dev-a', 'Timer1', '', { expectedResponseKey: 'Timer1', timeoutMs: 1000 });
  const p2 = cfg.requestTasmotaConfig('dev-b', 'Timer1', '', { expectedResponseKey: 'Timer1', timeoutMs: 1000 });
  // Both parked on the same shared connectAttempt; single client instance.
  assert.strictEqual(cfg.connecting.has('dev-a'), true);
  assert.strictEqual(cfg.connecting.has('dev-b'), true);
  assert.strictEqual(cfg.connectAttempt.length, 2);
  assert.deepStrictEqual(client.published, [], 'no publish before connect');
  client.connected = true;
  client.emit('connect');
  assert.deepStrictEqual(new Set(client.published.map((m) => m.topic)), new Set(['cmnd/dev-a/Timer1', 'cmnd/dev-b/Timer1']));
  client.emit('message', 'stat/dev-a/RESULT', JSON.stringify({ Timer1: { Enable: 1 } }));
  client.emit('message', 'stat/dev-b/RESULT', JSON.stringify({ Timer1: { Enable: 0 } }));
  assert.deepStrictEqual(await p1, { Timer1: { Enable: 1 } });
  assert.deepStrictEqual(await p2, { Timer1: { Enable: 0 } });
  assert.strictEqual(cfg.connectAttempt.length, 0);
});

test('a connection that never comes up times out cleanly with CFG_CONNECT_TIMEOUT', async () => {
  const { cfg, client } = configClient();
  client.connected = false;
  const p = cfg.requestTasmotaConfig('dev-x', 'Timer6', '', {
    expectedResponseKey: 'Timer6',
    timeoutMs: 10,
  });
  await assert.rejects(() => p, (err) => err.code === 'CFG_CONNECT_TIMEOUT');
  assert.deepStrictEqual(client.published, [], 'timeout must not publish anything');
  assert.strictEqual(cfg.connecting.has('dev-x'), false);
  assert.strictEqual(cfg.connectAttempt.length, 0);
  assert.strictEqual(cfg.inflight.has('dev-x'), false);
  assert.strictEqual(cfg.queues.has('dev-x'), false);
});

test('a failed connection cleans up and a later request can connect again', async () => {
  const { cfg, client } = configClient();
  client.connected = false;
  const p1 = cfg.requestTasmotaConfig('dev-x', 'Timer7', '', { expectedResponseKey: 'Timer7', timeoutMs: 200 });
  // Simulate a genuine connection failure: broker rejects the connect.
  client.emit('close');
  await assert.rejects(() => p1, (err) => err.code === 'MQTT_DISCONNECTED');
  assert.deepStrictEqual(client.published, []);
  assert.strictEqual(cfg.connectAttempt.length, 0);
  // Later request: a fresh connection is allowed (a NEW client object would be
  // created for a real broker; here the injected client comes back up).
  const p2 = cfg.requestTasmotaConfig('dev-x', 'Timer8', '', { expectedResponseKey: 'Timer8', timeoutMs: 1000 });
  client.connected = true;
  client.emit('connect');
  assert.deepStrictEqual(client.published.map((m) => m.topic), ['cmnd/dev-x/Timer8']);
  client.emit('message', 'stat/dev-x/RESULT', JSON.stringify({ Timer8: { Enable: 0 } }));
  assert.deepStrictEqual(await p2, { Timer8: { Enable: 0 } });
});

test('no publish ever occurs while the connection is not ready after a failed attempt', async () => {
  const { cfg, client } = configClient();
  client.connected = false;
  const p = cfg.requestTasmotaConfig('dev-x', 'Timer9', '', { expectedResponseKey: 'Timer9', timeoutMs: 10 });
  // Close while parked: rejects and still nothing was published.
  client.emit('close');
  await assert.rejects(() => p, (err) => err.code === 'MQTT_DISCONNECTED');
  assert.deepStrictEqual(client.published, []);
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

test('empty read publish uses EXACT topic and empty payload', async () => {
  const { cfg, client } = configClient();
  const p = cfg.requestTasmotaConfig('34987AC30304', 'Timer1', '', { expectedResponseKey: 'Timer1' });
  const { topic, payload } = client.published[0];
  assert.strictEqual(topic, 'cmnd/34987AC30304/Timer1');
  assert.strictEqual(payload, '');
  client.emit('message', 'stat/34987AC30304/RESULT', JSON.stringify({ Timer1: { Enable: 0 } }));
  await p;
});

test('timer write publish uses EXACT topic and EXACT payload', async () => {
  const { cfg, client } = configClient();
  const config = '{"Enable":1,"Mode":0,"Time":"23:30","Window":0,"Days":"1111111","Repeat":1,"Output":1,"Action":1}';
  const p = cfg.requestTasmotaConfig('34987AC30304', 'Timer2', config, { expectedResponseKey: 'Timer2' });
  const { topic, payload } = client.published[0];
  assert.strictEqual(topic, 'cmnd/34987AC30304/Timer2');
  assert.strictEqual(payload, config);
  client.emit('message', 'stat/34987AC30304/RESULT', JSON.stringify({ Timer2: JSON.parse(config) }));
  await p;
});

test('rule read publish uses EXACT topic and empty payload', async () => {
  const { cfg, client } = configClient();
  const p = cfg.requestTasmotaConfig('34987AC30304', 'Rule1', '', { expectedResponseKey: 'Rule1' });
  const { topic, payload } = client.published[0];
  assert.strictEqual(topic, 'cmnd/34987AC30304/Rule1');
  assert.strictEqual(payload, '');
  client.emit('message', 'stat/34987AC30304/RESULT', JSON.stringify({ Rule1: { State: 'OFF' } }));
  await p;
});

test('verbose timer read publish uses EXACT topic and empty payload', async () => {
  const { cfg, client } = configClient();
  const p = cfg.requestTasmotaConfig('34987AC30304', 'Timer5', '', { expectedResponseKey: 'Timer5' });
  const { topic, payload } = client.published[0];
  assert.strictEqual(topic, 'cmnd/34987AC30304/Timer5');
  assert.strictEqual(payload, '');
  client.emit('message', 'stat/34987AC30304/RESULT', JSON.stringify({ Timer5: { Enable: 0 } }));
  await p;
});

test('no debug label or payload description can ever become part of the topic', async () => {
  const { cfg, client } = configClient();
  const labelStrings = [
    'Timer1 | Payload: (empty)',
    'cmnd/34987AC30304/Timer1 | Payload: (empty)',
    'Timer1 Payload: (empty)',
    'Timer1 | Payload',
    'Rule2 Payload: (empty)',
    'Timer1 | |\n',
    'Timer1 | Payload: {"Enable":1}',
  ];
  for (const labeled of labelStrings) {
    await assert.rejects(
      () => cfg.requestTasmotaConfig('34987AC30304', labeled, '', { expectedResponseKey: labeled }),
      (err) => err.code === 'BAD_TOPIC_PART',
      `labeled command ${JSON.stringify(labeled)} must be rejected`,
    );
  }
  // Every actual publish must consist of exactly two clean parts under cmnd/.
  for (const m of client.published) {
    assert.match(m.topic, /^cmnd\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+$/);
    assert.ok(!m.topic.includes('Payload'), 'topic must never contain the Payload label');
    assert.ok(!m.topic.includes('|'), 'topic must never contain a pipe');
    assert.ok(!m.topic.includes('(') && !m.topic.includes(')'), 'topic must never contain parens');
    assert.ok(!m.topic.includes('cmnd/34987AC30304/cmnd'), 'topic must never double-nest cmnd/');
    assert.strictEqual(m.topic.split('/').length, 3, 'topic must be exactly cmnd/<dev>/<command>');
  }
});

test('labeled deviceId is also rejected before any publish', async () => {
  const { cfg, client } = configClient();
  await assert.rejects(
    () =>
      cfg.requestTasmotaConfig('34987AC30304 | Payload: (empty)', 'Timer1', '', {
        expectedResponseKey: 'Timer1',
      }),
    (err) => err.code === 'BAD_TOPIC_PART',
  );
  assert.deepStrictEqual(client.published, []);
});

test('a queued op whose command becomes labeled is rejected before ever being published', async () => {
  const { cfg, client } = configClient();
  const p1 = cfg.requestTasmotaConfig('dev-x', 'Timer10', '', { expectedResponseKey: 'Timer10' });
  assert.deepStrictEqual(client.published.map((m) => m.topic), ['cmnd/dev-x/Timer10']);
  // Timer3 is queued behind Timer10; corrupt its queued command to mimic a
  // label leaking into the op after it was accepted.
  const p3 = cfg.requestTasmotaConfig('dev-x', 'Timer3', '', { expectedResponseKey: 'Timer3' });
  const queued = cfg.queues.get('dev-x').find((op) => op.command === 'Timer3');
  queued.command = 'Timer3 | Payload: (empty)';
  // Settle Timer10 so the pump moves to the corrupted queued op.
  client.emit('message', 'stat/dev-x/RESULT', JSON.stringify({ Timer10: { Enable: 1 } }));
  await p1;
  await assert.rejects(() => p3, (err) => err.code === 'BAD_TOPIC_PART');
  // The corrupted op was rejected at the pump and never reached the wire.
  assert.deepStrictEqual(client.published.map((m) => m.topic), ['cmnd/dev-x/Timer10']);
});