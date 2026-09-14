const { test, after } = require('node:test');
const assert = require('node:assert');
const express = require('express');
const devicesRouter = require('../routes/devices');
const Device = require('../models/Device');
const WeatherAdvisory = require('../models/WeatherAdvisory');
const weatherNotifyScheduler = require('../services/weatherNotifyScheduler');

// Route-level contract for PATCH /devices/:deviceId/location: a material
// lat/lon/timezone change must clear this device's weather advisory dedup
// (legacy unique index would otherwise 11000-eat the new-location insert),
// then fire the notify trigger. farmName-only edits must not reset (no
// re-spam) but still trigger re-evaluation.

let dedupResets = [];
let triggers = [];
let savedDoc = null;

const originals = {
  deviceFindOne: Device.findOne,
  advisoryDeleteMany: WeatherAdvisory.deleteMany,
  schedulerTrigger: weatherNotifyScheduler.trigger,
};

function deviceDoc(overrides = {}) {
  const doc = {
    deviceId: 'D1',
    ownerId: 'u1',
    farmName: 'North',
    lat: 36.1,
    lon: 3.5,
    timezone: 'Africa/Algiers',
    toJSON() {
      return { deviceId: this.deviceId, lat: this.lat, lon: this.lon, farmName: this.farmName };
    },
    async save() {
      savedDoc = this;
    },
    ...overrides,
  };
  return doc;
}

// No Mongo in tests: stub every static the route touches.
Device.findOne = async (query) => (query.deviceId === 'D1' ? savedDoc || deviceDoc() : null);
WeatherAdvisory.deleteMany = async (filter) => {
  dedupResets.push(filter);
  return { deletedCount: 1 };
};
weatherNotifyScheduler.trigger = (deviceId, io) => {
  triggers.push(String(deviceId || ''));
};

after(() => {
  Device.findOne = originals.deviceFindOne;
  WeatherAdvisory.deleteMany = originals.advisoryDeleteMany;
  weatherNotifyScheduler.trigger = originals.schedulerTrigger;
});

function makeApp() {
  const app = express();
  app.use(express.json());
  app.use((req, res, next) => {
    req.userId = 'u1';
    req.app = { get: () => null }; // io stub for fire-and-forget trigger
    next();
  });
  app.use(devicesRouter);
  return app.listen(0);
}

async function start() {
  const server = makeApp();
  await new Promise((r) => server.once('listening', r));
  return {
    server,
    base: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise((r) => server.close(r)),
  };
}

async function patchLocation(base, body) {
  const res = await fetch(`${base}/D1/location`, {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.json() };
}

test('PATCH location with material lat/lon change clears device dedup and triggers', async () => {
  dedupResets = [];
  triggers = [];
  savedDoc = deviceDoc({ lat: 36.1, lon: 3.5 });
  const { base, close } = await start();
  try {
    const { status } = await patchLocation(base, { lat: 40.7, lon: -74.0 });
    assert.strictEqual(status, 200);
    assert.deepStrictEqual(dedupResets, [{ deviceId: 'D1' }], 'material location change resets dedup');
    assert.deepStrictEqual(triggers, ['D1'], 'notify trigger fired for the device');
  } finally {
    await close();
  }
});

test('PATCH location farmName-only keeps dedup (no re-spam) but still triggers', async () => {
  dedupResets = [];
  triggers = [];
  savedDoc = deviceDoc({ lat: 36.1, lon: 3.5 });
  const { base, close } = await start();
  try {
    const { status } = await patchLocation(base, { farmName: 'South' });
    assert.strictEqual(status, 200);
    assert.deepStrictEqual(dedupResets, [], 'farmName-only edit must not reset dedup');
    assert.deepStrictEqual(triggers, ['D1'], 'notify trigger still fires');
  } finally {
    await close();
  }
});

test('PATCH location with no material coordinate change keeps dedup', async () => {
  dedupResets = [];
  triggers = [];
  // Same coordinates re-sent (e.g. user re-picks the same farm spot).
  savedDoc = deviceDoc({ lat: 36.1, lon: 3.5 });
  const { base, close } = await start();
  try {
    const { status } = await patchLocation(base, { lat: 36.1, lon: 3.5, farmName: 'North' });
    assert.strictEqual(status, 200);
    assert.deepStrictEqual(dedupResets, [], 'identical location must not reset dedup');
    assert.deepStrictEqual(triggers, ['D1']);
  } finally {
    await close();
  }
});

test('PATCH location timezone change is material (dedup reset)', async () => {
  dedupResets = [];
  triggers = [];
  savedDoc = deviceDoc({ lat: 36.1, lon: 3.5, timezone: 'Africa/Algiers' });
  const { base, close } = await start();
  try {
    const { status } = await patchLocation(base, { timezone: 'Europe/Paris' });
    assert.strictEqual(status, 200);
    assert.deepStrictEqual(dedupResets, [{ deviceId: 'D1' }], 'timezone change resets dedup (part of locationKey)');
  } finally {
    await close();
  }
});
