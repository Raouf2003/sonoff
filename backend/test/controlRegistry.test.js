const { test, beforeEach, after } = require('node:test');
const assert = require('node:assert');
const express = require('express');
const controlRouter = require('../routes/control');
const Device = require('../models/Device');
const deviceRegistry = require('../services/deviceRegistry');
const mqttGateway = require('../services/mqttGateway');
const runtimeState = require('../services/runtimeState');

const DEVICE = { deviceId: 'REGISTRY01', ownerId: 'owner1', channels: 2, lastIp: '192.168.1.10' };

const originals = {
  findOne: Device.findOne,
  isConnected: mqttGateway.isConnected,
  isOnline: runtimeState.isOnline,
  publishCommand: mqttGateway.publishCommand,
  getDeviceState: runtimeState.getDeviceState,
};

Device.findOne = async (query) => {
  if (query.deviceId === DEVICE.deviceId) return { ...DEVICE, lastIp: DEVICE.lastIp };
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
  deviceRegistry.devices.clear();
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

test('P3: ownership check succeeds via registry without DB call when device is in registry', async () => {
  // Seed registry
  deviceRegistry.devices.set(DEVICE.deviceId, { ...DEVICE, ownerId: DEVICE.ownerId });
  let dbCalled = false;
  const origFindOne = Device.findOne;
  Device.findOne = async () => {
    dbCalled = true;
    return null;
  };
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
    assert.strictEqual(res.status, 200);
    assert.strictEqual(dbCalled, false, 'DB should not be called when registry hit');
  } finally {
    Device.findOne = origFindOne;
    deviceRegistry.devices.clear();
    await close();
  }
});

test('P3: falls back to DB correctly on registry miss', async () => {
  deviceRegistry.devices.clear();
  let dbCalled = false;
  const origFindOne = Device.findOne;
  Device.findOne = async (query) => {
    dbCalled = true;
    if (query.deviceId === DEVICE.deviceId) return { ...DEVICE };
    return null;
  };
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
    assert.strictEqual(res.status, 200);
    assert.strictEqual(dbCalled, true, 'DB should be called on registry miss');
  } finally {
    Device.findOne = origFindOne;
    await close();
  }
});

test('P3: unauthorized/ownership-mismatch still correctly rejected via registry path', async () => {
  deviceRegistry.devices.set(DEVICE.deviceId, { ...DEVICE, ownerId: 'owner1' });
  mqttGateway.publishCommand = async () => ({ acked: true, observed: 'ON' });

  const { base, close } = await start();
  // Make app with different userId
  const app2 = express();
  app2.use(express.json());
  app2.use((req, res, next) => {
    req.userId = 'intruder';
    next();
  });
  app2.use(controlRouter);
  const server2 = app2.listen(0);
  await new Promise((r) => server2.once('listening', r));
  const port2 = server2.address().port;
  const base2 = `http://127.0.0.1:${port2}`;
  try {
    const res = await fetch(`${base2}/control`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: DEVICE.deviceId, channel: 1, state: 'ON' }),
    });
    assert.strictEqual(res.status, 403);
  } finally {
    deviceRegistry.devices.clear();
    await new Promise((r) => server2.close(r));
    await close();
  }
});

test('P3: registry miss + DB 404 still returns 404', async () => {
  deviceRegistry.devices.clear();
  const origFindOne = Device.findOne;
  Device.findOne = async () => null;
  const { base, close } = await start();
  try {
    const res = await fetch(`${base}/control`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: 'UNKNOWN123', channel: 1, state: 'ON' }),
    });
    assert.strictEqual(res.status, 404);
  } finally {
    Device.findOne = origFindOne;
    await close();
  }
});
