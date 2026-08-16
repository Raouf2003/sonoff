const { test, after } = require('node:test');
const assert = require('node:assert');
const express = require('express');
const devSyncRouter = require('../routes/devSync');
const Device = require('../models/Device');
const scheduleSyncService = require('../services/scheduleSyncService');

const DEVICE = { deviceId: '34987AC30304', ownerId: 'owner1', channels: 4 };

const originals = {
  findOne: Device.findOne,
};

Device.findOne = async (query) => {
  if (query.deviceId === DEVICE.deviceId) return { ...DEVICE };
  return null;
};

after(() => {
  Device.findOne = originals.findOne;
});

function makeApp({ production, enableSyncRoute } = {}) {
  const prevNodeEnv = process.env.NODE_ENV;
  const prevFlag = process.env.ENABLE_SCHEDULE_SYNC_ROUTE;
  if (production !== undefined) process.env.NODE_ENV = production;
  if (enableSyncRoute !== undefined) process.env.ENABLE_SCHEDULE_SYNC_ROUTE = enableSyncRoute;
  const app = express();
  app.use(express.json());
  app.use((req, res, next) => {
    req.userId = 'owner1';
    next();
  });
  app.use(devSyncRouter);
  return {
    server: app.listen(0),
    restoreEnv: () => {
      if (production !== undefined) process.env.NODE_ENV = prevNodeEnv;
      if (enableSyncRoute !== undefined) process.env.ENABLE_SCHEDULE_SYNC_ROUTE = prevFlag;
    },
  };
}

async function start(opts) {
  const { server, restoreEnv } = makeApp(opts);
  await new Promise((r) => server.once('listening', r));
  const port = server.address().port;
  return {
    server,
    base: `http://127.0.0.1:${port}`,
    close: async () => {
      await new Promise((r) => server.close(r));
      restoreEnv();
    },
  };
}

test('POST /api/dev/sync/:deviceId returns the full manual sync report', async () => {
  const manualSync = scheduleSyncService.manualSync;
  scheduleSyncService.manualSync = async (deviceId, options) => {
    assert.strictEqual(options.source, 'manual-sync', 'manual route must label the sync source');
    return {
      status: 'pending',
      deviceId,
      enabled: false,
      plan: { requiredTimerCount: 2, timers: [], rules: [] },
      allocation: [{ logical: 1, physical: 1 }, { logical: 2, physical: 2 }],
      protected: { timers: [{ index: 3, reason: 'user Rule1 trigger' }], rules: [{ index: 1, reason: 'user rule' }, { index: 3, reason: 'user rule' }] },
      intendedWrites: [{ kind: 'timer', index: 1, config: '{}' }, { kind: 'timer', index: 2, config: '{}' }],
      publishedWrites: [],
      verification: [],
    };
  };

  const { base, close } = await start();
  try {
    const res = await fetch(`${base}/sync/${DEVICE.deviceId}`, { method: 'POST' });
    const body = await res.json();
    assert.strictEqual(res.status, 200);
    assert.strictEqual(body.deviceId, DEVICE.deviceId);
    assert.strictEqual(body.enabled, false);
    assert.strictEqual(body.status, 'pending');
    assert.deepStrictEqual(body.allocation, [{ logical: 1, physical: 1 }, { logical: 2, physical: 2 }]);
    assert.deepStrictEqual(body.publishedWrites, []);
    assert.strictEqual(body.protected.timers.length, 1);
    assert.strictEqual(body.protected.timers[0].index, 3);
  } finally {
    await close();
    scheduleSyncService.manualSync = manualSync;
  }
});

test('POST /api/dev/sync/:deviceId returns 404 when the device is unknown', async () => {
  const { base, close } = await start();
  try {
    const res = await fetch(`${base}/sync/DEADBEEF`, { method: 'POST' });
    const body = await res.json();
    assert.strictEqual(res.status, 404);
    assert.ok(body.error);
  } finally {
    await close();
  }
});

test('POST /api/dev/sync/:deviceId returns 403 when the device is not owned by the caller', async () => {
  const app = express();
  app.use(express.json());
  app.use((req, res, next) => {
    req.userId = 'someone-else';
    next();
  });
  app.use(devSyncRouter);
  const server = app.listen(0);
  await new Promise((r) => server.once('listening', r));
  const port = server.address().port;
  try {
    const res = await fetch(`http://127.0.0.1:${port}/sync/${DEVICE.deviceId}`, { method: 'POST' });
    const body = await res.json();
    assert.strictEqual(res.status, 403);
    assert.ok(body.error);
  } finally {
    await new Promise((r) => server.close(r));
  }
});

test('POST /api/dev/sync/:deviceId returns 404 when NODE_ENV=production', async () => {
  const { base, close } = await start({ production: 'production' });
  try {
    const res = await fetch(`${base}/sync/${DEVICE.deviceId}`, { method: 'POST' });
    assert.strictEqual(res.status, 404);
  } finally {
    await close();
  }
});

test('POST /api/dev/sync/:deviceId reaches the handler when production but ENABLE_SCHEDULE_SYNC_ROUTE=true', async () => {
  const manualSync = scheduleSyncService.manualSync;
  scheduleSyncService.manualSync = async (deviceId) => ({
    status: 'pending',
    deviceId,
    enabled: false,
    plan: { requiredTimerCount: 2, timers: [], rules: [] },
    allocation: [],
    protected: { timers: [], rules: [] },
    intendedWrites: [],
    publishedWrites: [],
    verification: [],
  });
  const { base, close } = await start({ production: 'production', enableSyncRoute: 'true' });
  try {
    const res = await fetch(`${base}/sync/${DEVICE.deviceId}`, { method: 'POST' });
    const body = await res.json();
    assert.strictEqual(res.status, 200);
    assert.strictEqual(body.deviceId, DEVICE.deviceId);
    assert.deepStrictEqual(body.publishedWrites, []);
  } finally {
    await close();
    scheduleSyncService.manualSync = manualSync;
  }
});

test('POST /api/dev/sync/:deviceId returns 400 when deviceId is blank', async () => {
  const { base, close } = await start();
  try {
    const res = await fetch(`${base}/sync/%20`, { method: 'POST' });
    const body = await res.json();
    assert.strictEqual(res.status, 400);
    assert.ok(body.error);
  } finally {
    await close();
  }
});