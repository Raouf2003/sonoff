const { test, after } = require('node:test');
const assert = require('node:assert');
const express = require('express');
const schedulesRouter = require('../routes/schedules');
const Schedule = require('../models/Schedule');
const Device = require('../models/Device');
const scheduleSyncTrigger = require('../services/scheduleSyncTrigger');
const scheduleEngine = require('../services/scheduleEngine');

const DEVICE = { deviceId: '34987AC30304', ownerId: 'owner1', channels: 4 };

// Exactly-once contract (Phase 7A): every successful schedule CRUD operation
// triggers ONE background schedule->Tasmota sync for the affected device, and
// validation failures trigger NONE.
let triggers = [];

const originals = {
  scheduleFindOne: Schedule.findOne,
  scheduleCreate: Schedule.create,
  deviceFindOne: Device.findOne,
  trigger: scheduleSyncTrigger.trigger,
  invalidate: scheduleEngine.invalidate,
  release: scheduleEngine.release,
};

function scheduleDoc() {
  const doc = {
    _id: 'sch1',
    deviceId: DEVICE.deviceId,
    ownerId: 'owner1',
    name: 'morning',
    enabled: true,
    channels: [1],
    recurrence: { type: 'daily', daysOfWeek: [] },
    timeRanges: [{ start: '07:00', end: '09:00' }],
    lastAppliedState: {},
    toJSON() {
      return {
        _id: this._id,
        deviceId: this.deviceId,
        ownerId: this.ownerId,
        name: this.name,
        enabled: this.enabled,
        channels: this.channels,
        recurrence: this.recurrence,
        timeRanges: this.timeRanges,
      };
    },
    async save() {},
    async deleteOne() {},
  };
  return doc;
}

// No Mongo in tests: replace every static the routes touch with in-memory stubs.
Schedule.findOne = async (query) => (query._id === 'sch1' && query.ownerId === 'owner1' ? scheduleDoc() : null);
Schedule.create = async (data) => scheduleDoc();
Device.findOne = async (query) => (query.deviceId === DEVICE.deviceId ? { ...DEVICE } : null);
scheduleSyncTrigger.trigger = (deviceId) => {
  triggers.push(String(deviceId || ''));
  return { status: 'queued', deviceId };
};
scheduleEngine.invalidate = () => {};
scheduleEngine.release = async () => {};

after(() => {
  Schedule.findOne = originals.scheduleFindOne;
  Schedule.create = originals.scheduleCreate;
  Device.findOne = originals.deviceFindOne;
  scheduleSyncTrigger.trigger = originals.trigger;
  scheduleEngine.invalidate = originals.invalidate;
  scheduleEngine.release = originals.release;
});

function makeApp() {
  const app = express();
  app.use(express.json());
  app.use((req, res, next) => {
    req.userId = 'owner1';
    next();
  });
  app.use(schedulesRouter);
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

const validBody = {
  deviceId: DEVICE.deviceId,
  name: 'morning',
  channels: [1, 2],
  recurrence: { type: 'daily', daysOfWeek: [] },
  timeRanges: [{ start: '07:00', end: '09:00' }],
};

const invalidBody = {
  deviceId: DEVICE.deviceId,
  name: 'morning',
  channels: [1],
  recurrence: { type: 'daily', daysOfWeek: [] },
  timeRanges: [{ start: '09:00', end: '07:00' }],
};

async function post(base, path, body) {
  const res = await fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.json() };
}

test('POST /schedules creates the schedule and triggers EXACTLY ONE sync for the device', async () => {
  triggers = [];
  const { base, close } = await start();
  try {
    const { status, body } = await post(base, '/', validBody);
    assert.strictEqual(status, 201);
    assert.strictEqual(body.sync.status, 'queued');
    assert.deepStrictEqual(triggers, [DEVICE.deviceId]);
  } finally {
    await close();
  }
});

test('POST /schedules with an invalid body triggers NO sync', async () => {
  triggers = [];
  const { base, close } = await start();
  try {
    const { status } = await post(base, '/', invalidBody);
    assert.strictEqual(status, 400);
    assert.deepStrictEqual(triggers, []);
  } finally {
    await close();
  }
});

test('PATCH /schedules/:id updates and triggers EXACTLY ONE sync', async () => {
  triggers = [];
  const { base, close } = await start();
  try {
    const res = await fetch(`${base}/sch1`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(validBody),
    });
    assert.strictEqual(res.status, 200);
    assert.deepStrictEqual(triggers, [DEVICE.deviceId]);
  } finally {
    await close();
  }
});

test('PATCH /schedules/:id/enable toggles and triggers EXACTLY ONE sync', async () => {
  triggers = [];
  const { base, close } = await start();
  try {
    const res = await fetch(`${base}/sch1/enable`, { method: 'PATCH' });
    assert.strictEqual(res.status, 200);
    assert.deepStrictEqual(triggers, [DEVICE.deviceId]);
  } finally {
    await close();
  }
});

test('DELETE /schedules/:id removes and triggers EXACTLY ONE sync for the captured device', async () => {
  triggers = [];
  const { base, close } = await start();
  try {
    const res = await fetch(`${base}/sch1`, { method: 'DELETE' });
    assert.strictEqual(res.status, 200);
    assert.deepStrictEqual(triggers, [DEVICE.deviceId]);
  } finally {
    await close();
  }
});