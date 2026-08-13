const { test } = require('node:test');
const assert = require('node:assert');
const { MqttGateway } = require('../services/mqttGateway');
const runtimeState = require('../services/runtimeState');

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

// LWT Offline must be authoritative even when telemetry is fresh, and a later
// positive report (tele/STATE) must restore ONLINE — and both emissions must
// carry the RESOLVED runtimeState verdict so no consumer sees two truths.
test('LWT Offline emits authoritative offline; a later tele/STATE restores online', () => {
  const gw = new MqttGateway();
  gw.client = makeClient();
  gw.runtimeState = runtimeState;
  gw.deviceRegistry = {
    get: () => ({ deviceId: 'dev-lwt', ownerId: 'owner-x', channels: 2 }),
    all: () => [],
    isOwned: () => true,
  };
  const emitted = [];
  gw.io = {
    to: (room) => ({
      emit: (ev, payload) => emitted.push({ room, ev, payload }),
    }),
  };

  runtimeState.ensureDeviceState('dev-lwt', 2);
  // Fresh telemetry immediately before the LWT Offline — the flicker scenario.
  runtimeState.touchDevice('dev-lwt');
  assert.strictEqual(runtimeState.isOnline('dev-lwt'), true);

  gw._handle('tele/dev-lwt/LWT', 'Offline');
  const offlineEvent = emitted[emitted.length - 1];
  assert.strictEqual(offlineEvent.ev, 'device_status');
  assert.strictEqual(offlineEvent.payload.online, false,
    'LWT Offline is authoritative even with fresh lastSeen');
  assert.strictEqual(runtimeState.isOnline('dev-lwt'), false);

  gw._handle('tele/dev-lwt/STATE', JSON.stringify({ POWER1: 'ON' }));
  const onlineEvent = emitted[emitted.length - 1];
  assert.strictEqual(onlineEvent.ev, 'device_status');
  assert.strictEqual(onlineEvent.payload.online, true,
    'a positive device report restores ONLINE');
  assert.strictEqual(runtimeState.isOnline('dev-lwt'), true);
});

function ipStateGateway({ lastIp }) {
  const gw = new MqttGateway();
  gw.client = makeClient();
  const applied = [];
  gw.runtimeState = {
    ensureDeviceState() {},
    touchDevice() {},
    applyChannelState(deviceId, ch, st) {
      applied.push({ deviceId, ch, st });
      return { state: st, updatedAt: Date.now() };
    },
  };
  gw.deviceRegistry = {
    get: () => ({ deviceId: 'dev-a', lastIp }),
    all: () => [],
    isOwned: () => true,
  };
  return gw;
}

test('tele/STATE with a changed IPAddress records the device lastIp', () => {
  const gw = ipStateGateway({ lastIp: '192.168.1.8' });
  const ipUpdates = [];
  gw.deviceRegistry.updateIp = (deviceId, ip) => ipUpdates.push({ deviceId, ip });
  const saved = [];
  gw.deviceModel = {
    updateOne(filter, update) {
      saved.push({ filter, update });
      return { catch() {} };
    },
  };

  gw._handle('tele/dev-a/STATE', JSON.stringify({ IPAddress: '192.168.1.42', POWER1: 'ON' }));

  assert.deepStrictEqual(ipUpdates, [{ deviceId: 'dev-a', ip: '192.168.1.42' }]);
  assert.deepStrictEqual(saved, [
    { filter: { deviceId: 'dev-a' }, update: { $set: { lastIp: '192.168.1.42' } } },
  ]);
});

test('tele/STATE with an unchanged IPAddress does not re-persist', () => {
  const gw = ipStateGateway({ lastIp: '192.168.1.8' });
  gw.deviceRegistry.updateIp = () => {
    throw new Error('updateIp must not be called for an unchanged IP');
  };
  let writes = 0;
  gw.deviceModel = {
    updateOne() {
      writes++;
      return { catch() {} };
    },
  };

  gw._handle('tele/dev-a/STATE', JSON.stringify({ IPAddress: '192.168.1.8', POWER1: 'ON' }));

  assert.strictEqual(writes, 0);
});

test('tele/STATE with no IPAddress leaves lastIp untouched', () => {
  const gw = ipStateGateway({ lastIp: null });
  gw.deviceRegistry.updateIp = () => {
    throw new Error('updateIp must not be called without an IP');
  };
  let writes = 0;
  gw.deviceModel = {
    updateOne() {
      writes++;
      return { catch() {} };
    },
  };

  gw._handle('tele/dev-a/STATE', JSON.stringify({ POWER1: 'ON' }));

  assert.strictEqual(writes, 0);
});

// A rejected telemetry IP must neither touch the in-memory registry nor write
// to the DB: the previous valid lastIp survives untouched.
function assertTelemetryIpRejected(ip, { lastIp = '192.168.1.8' } = {}) {
  const gw = ipStateGateway({ lastIp });
  let ipUpdates = 0;
  gw.deviceRegistry.updateIp = () => {
    ipUpdates++;
  };
  let writes = 0;
  gw.deviceModel = {
    updateOne() {
      writes++;
      return { catch() {} };
    },
  };

  gw._handle('tele/dev-a/STATE', JSON.stringify({ IPAddress: ip, POWER1: 'ON' }));

  assert.strictEqual(ipUpdates, 0, `updateIp must not run for ${ip}`);
  assert.strictEqual(writes, 0, `deviceModel.updateOne must not run for ${ip}`);
  assert.strictEqual(gw.deviceRegistry.get('dev-a').lastIp, lastIp,
    `a valid lastIp must survive a later invalid payload (${ip})`);
}

test('tele/STATE with IPAddress 0.0.0.0 is rejected and lastIp is preserved', () => {
  assertTelemetryIpRejected('0.0.0.0');
});

test('tele/STATE with unspecified IPv6 :: is rejected and lastIp is preserved', () => {
  assertTelemetryIpRejected('::');
});

test('tele/STATE with loopback is rejected and lastIp is preserved', () => {
  assertTelemetryIpRejected('127.0.0.1');
});

test('tele/STATE with a multicast address is rejected and lastIp is preserved', () => {
  assertTelemetryIpRejected('239.255.255.250');
});

test('tele/STATE with a malformed IP is rejected and lastIp is preserved', () => {
  assertTelemetryIpRejected('not-an-ip');
});

test('a valid IP overrides a previous invalid lastIp', () => {
  const gw = ipStateGateway({ lastIp: '0.0.0.0' });
  const ipUpdates = [];
  gw.deviceRegistry.updateIp = (deviceId, ip) => ipUpdates.push({ deviceId, ip });
  const saved = [];
  gw.deviceModel = {
    updateOne(filter, update) {
      saved.push({ filter, update });
      return { catch() {} };
    },
  };

  gw._handle('tele/dev-a/STATE', JSON.stringify({ IPAddress: '192.168.1.42' }));

  assert.deepStrictEqual(ipUpdates, [{ deviceId: 'dev-a', ip: '192.168.1.42' }]);
  assert.deepStrictEqual(saved, [
    { filter: { deviceId: 'dev-a' }, update: { $set: { lastIp: '192.168.1.42' } } },
  ]);
});
