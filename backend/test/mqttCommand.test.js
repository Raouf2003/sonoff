const { test } = require('node:test');
const assert = require('node:assert');
const { MqttGateway } = require('../services/mqttGateway');

function makeClient() {
  const published = [];
  return {
    connected: true,
    publish(topic, payload, opts, cb) {
      published.push({ topic, payload: String(payload) });
      if (typeof cb === 'function') cb(null);
    },
    published,
  };
}

function gateway() {
  const gw = new MqttGateway();
  gw.client = makeClient();
  gw.runtimeState = { ensureDeviceState() {}, touchDevice() {} };
  gw.deviceRegistry = { get: () => null, all: () => [], isOwned: () => false };
  return gw;
}

test('publishCommand rejects with MQTT_DISCONNECTED when the broker is down', async () => {
  const gw = gateway();
  gw.client.connected = false;
  await assert.rejects(
    () => gw.publishCommand('dev-a', 1, 'ON'),
    (err) => err.code === 'MQTT_DISCONNECTED',
  );
});

test('a concurrent command for the same device+channel SUPERSEDES the previous pending', async () => {
  const gw = gateway();
  const first = gw.publishCommand('dev-a', 1, 'ON');
  const second = gw.publishCommand('dev-a', 1, 'OFF');

  await assert.rejects(
    () => first,
    (err) => err.code === 'SUPERSEDED',
  );

  // The superseding command must still be pending (not settled) until an ack.
  let settled = false;
  second.then(() => { settled = true; }, () => { settled = true; });
  await new Promise((r) => setTimeout(r, 20));
  assert.strictEqual(settled, false, 'superseding command stays pending awaiting ACK');

  // Cleanup the outstanding timer so the test process can exit promptly.
  const pend = gw.pending.get('dev-a:1');
  if (pend) {
    clearTimeout(pend.timer);
    gw.pending.delete('dev-a:1');
  }
});

test('a device report resolves the pending command with acked/observed', async () => {
  const gw = gateway();
  const cmd = gw.publishCommand('dev-a', 1, 'ON');
  gw._resolvePending('dev-a', 1, 'OFF');
  const outcome = await cmd;
  assert.deepStrictEqual(outcome, { acked: false, observed: 'OFF' });
});

test('a matching report resolves with acked true', async () => {
  const gw = gateway();
  const cmd = gw.publishCommand('dev-a', 1, 'ON');
  gw._resolvePending('dev-a', 1, 'ON');
  const outcome = await cmd;
  assert.deepStrictEqual(outcome, { acked: true, observed: 'ON' });
});

test('a raw stat/POWERn payload resolves the pending ACK and feeds runtimeState', async () => {
  const gw = gateway();
  const applied = [];
  gw.runtimeState = {
    ensureDeviceState() {},
    touchDevice() {},
    applyChannelState(deviceId, ch, st) {
      applied.push({ deviceId, ch, st });
      return { state: st, updatedAt: Date.now() };
    },
  };
  const cmd = gw.publishCommand('dev-a', 1, 'ON');
  gw._handle('stat/dev-a/POWER1', 'ON');
  const outcome = await cmd;
  assert.deepStrictEqual(outcome, { acked: true, observed: 'ON' });
  assert.deepStrictEqual(applied, [{ deviceId: 'dev-a', ch: 1, st: 'ON' }]);
});
