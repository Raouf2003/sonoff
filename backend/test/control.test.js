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

// Scriptable lastIp so tests can verify the discovery-hint field.
let deviceIp = null;
Device.findOne = async (query) => {
  if (query.deviceId === DEVICE.deviceId) return { ...DEVICE, lastIp: deviceIp };
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

test('POST /control returns 202 pending after PUBACK (fast-ack)', async () => {
  mqttGateway.publishCommand = async () => ({ acked: false, pending: true, opId: 'op1', expected: 'ON' });
  runtimeState.getDeviceState = () => ({
    channels: { 1: { state: 'ON', updatedAt: Date.now() } },
  });

  const { base, close } = await start();
  try {
    const res = await fetch(`${base}/control`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: DEVICE.deviceId, channel: 1, state: 'ON', opId: 'op1' }),
    });
    const body = await res.json();
    assert.strictEqual(res.status, 202);
    assert.strictEqual(body.status, 'pending');
    assert.strictEqual(body.pending, true);
    assert.strictEqual(body.acked, false);
    assert.strictEqual(body.opId, 'op1');
    assert.strictEqual(body.expected, 'ON');
    assert.strictEqual(body.deviceId, DEVICE.deviceId);
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
    assert.strictEqual(body.lastIp, null);
  } finally {
    await close();
  }
});

test('GET /status and POST /control expose the device lastIp for the app', async () => {
  deviceIp = '192.168.1.9';
  mqttGateway.publishCommand = async () => ({ acked: false, pending: true, opId: null, expected: 'ON' });
  runtimeState.getDeviceState = () => ({
    channels: { 1: { state: 'ON', updatedAt: Date.now() } },
  });
  runtimeState.getDeviceStatus = () => ({ online: true, channels: {} });

  const { base, close } = await start();
  try {
    const sres = await fetch(`${base}/status?deviceId=${DEVICE.deviceId}`);
    const sbody = await sres.json();
    assert.strictEqual(sres.status, 200);
    assert.strictEqual(sbody.lastIp, '192.168.1.9');

    const cres = await fetch(`${base}/control`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: DEVICE.deviceId, channel: 1, state: 'ON' }),
    });
    const cbody = await cres.json();
    assert.strictEqual(cres.status, 202);
    assert.strictEqual(cbody.lastIp, '192.168.1.9');
    assert.strictEqual(cbody.status, 'pending');
  } finally {
    deviceIp = null;
    await close();
  }
});
