const { test, after } = require('node:test');
const assert = require('node:assert');
const express = require('express');
const controlRouter = require('../routes/control');
const Device = require('../models/Device');
const mqttGateway = require('../services/mqttGateway');
const runtimeState = require('../services/runtimeState');

const DEVICE = { deviceId: 'DEADBEEF', ownerId: 'owner1', channels: 2 };

const originals = {
  findOne: Device.findOne,
  isConnected: mqttGateway.isConnected,
  isOnline: runtimeState.isOnline,
  publishCommand: mqttGateway.publishCommand,
  getDeviceState: runtimeState.getDeviceState,
  getDeviceStatus: runtimeState.getDeviceStatus,
};

Device.findOne = async (query) => {
  if (query.deviceId === DEVICE.deviceId) return { ...DEVICE };
  return null;
};
runtimeState.isOnline = () => true;
mqttGateway.isConnected = () => true;

after(() => {
  Device.findOne = originals.findOne;
  mqttGateway.isConnected = originals.isConnected;
  runtimeState.isOnline = originals.isOnline;
  mqttGateway.publishCommand = originals.publishCommand;
  runtimeState.getDeviceState = originals.getDeviceState;
  runtimeState.getDeviceStatus = originals.getDeviceStatus;
});

function makeApp() {
  const app = express();
  app.use(express.json());
  app.use((req, res, next) => {
    req.userId = 'owner1';
    next();
  });
  app.use(controlRouter);
  return app.listen(0);
}

async function start() {
  const server = makeApp();
  await new Promise((r) => server.once('listening', r));
  const port = server.address().port;
  return {
    server,
    base: `http://127.0.0.1:${port}`,
    close: () => new Promise((r) => server.close(r)),
  };
}

test('POST /control returns the reported state plus the per-channel shape', async () => {
  mqttGateway.publishCommand = async () => ({ acked: true, observed: 'ON' });
  runtimeState.getDeviceState = () => ({
    channels: { 1: { state: 'ON', updatedAt: Date.now() } },
  });

  const { base, close } = await start();
  try {
    const res = await fetch(`${base}/control`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: DEVICE.deviceId, channel: 1, state: 'ON' }),
    });
    const body = await res.json();
    assert.strictEqual(res.status, 200);
    assert.strictEqual(body.POWER1, 'ON');
    assert.strictEqual(body.acked, true);
    assert.strictEqual(body.channels['1'].state, 'ON');
    assert.ok(typeof body.channels['1'].updatedAt === 'string');
  } finally {
    await close();
  }
});

test('POST /control maps a superseded pending command to 409 with code SUPERSEDED', async () => {
  mqttGateway.publishCommand = async () => {
    const err = new Error('Command superseded');
    err.code = 'SUPERSEDED';
    throw err;
  };

  const { base, close } = await start();
  try {
    const res = await fetch(`${base}/control`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: DEVICE.deviceId, channel: 1, state: 'ON' }),
    });
    const body = await res.json();
    assert.strictEqual(res.status, 409);
    assert.strictEqual(body.code, 'SUPERSEDED');
  } finally {
    await close();
  }
});

test('GET /status reports per-channel state, UNKNOWN default, and legacy flat keys', async () => {
  const iso = new Date(Date.now()).toISOString();
  runtimeState.getDeviceStatus = () => ({
    online: true,
    channels: {
      1: { state: 'ON', updatedAt: iso },
      2: { state: 'UNKNOWN', updatedAt: null },
    },
  });

  const { base, close } = await start();
  try {
    const res = await fetch(`${base}/status?deviceId=${DEVICE.deviceId}`);
    const body = await res.json();
    assert.strictEqual(res.status, 200);
    assert.strictEqual(body.online, true);
    assert.deepStrictEqual(body.channels['1'], { state: 'ON', updatedAt: iso });
    assert.deepStrictEqual(body.channels['2'], { state: 'UNKNOWN', updatedAt: null });
    assert.strictEqual(body.POWER1, 'ON');
    assert.strictEqual(body.POWER2, 'UNKNOWN');
  } finally {
    await close();
  }
});

test('GET /status defaults every channel to UNKNOWN when nothing was observed', async () => {
  runtimeState.getDeviceStatus = () => ({ online: false, channels: {} });

  const { base, close } = await start();
  try {
    const res = await fetch(`${base}/status?deviceId=${DEVICE.deviceId}`);
    const body = await res.json();
    assert.strictEqual(res.status, 200);
    assert.deepStrictEqual(body.channels['1'], { state: 'UNKNOWN', updatedAt: null });
    assert.deepStrictEqual(body.channels['2'], { state: 'UNKNOWN', updatedAt: null });
    assert.strictEqual(body.POWER1, 'UNKNOWN');
    assert.strictEqual(body.online, false);
  } finally {
    await close();
  }
});
