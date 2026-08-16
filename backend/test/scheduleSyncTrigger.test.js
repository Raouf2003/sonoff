const { test, afterEach } = require('node:test');
const assert = require('node:assert');
const { ScheduleSyncTrigger } = require('../services/scheduleSyncTrigger');
const syncService = require('../services/scheduleSyncService');

// A self-resolving sync function: records invocation order and per-device
// concurrency, then resolves after a short delay. Because `trigger()` runs
// synchronously, the first call for a device is always recorded before any
// later coalesced triggers arrive, mirroring real serialized drains.
function makeAutoSync() {
  const calls = [];
  let maxConcurrent = 0;
  const active = new Map();
  const resolveVal = { status: 'synced' };
  function syncFn(deviceId) {
    const n = (active.get(deviceId) || 0) + 1;
    active.set(deviceId, n);
    if (n > maxConcurrent) maxConcurrent = n;
    calls.push({ deviceId });
    return new Promise((resolve) => {
      setTimeout(() => {
        active.set(deviceId, active.get(deviceId) - 1);
        resolve({ ...resolveVal, deviceId });
      }, 5);
    });
  }
  return {
    syncFn,
    calls,
    maxConcurrent: () => maxConcurrent,
  };
}

let trigger;

afterEach(() => {
  trigger = null;
  delete process.env.TASMOTA_SCHEDULE_SYNC_ENABLED;
});

test('trigger reports queued and forwards the deviceId to the sync service', async () => {
  const gs = makeAutoSync();
  trigger = new ScheduleSyncTrigger({ syncFn: gs.syncFn, logger: console });
  const out = trigger.trigger('34987AC30304');
  assert.deepStrictEqual(out, { status: 'queued', deviceId: '34987AC30304' });
  await trigger.whenIdle('34987AC30304');
  assert.strictEqual(gs.calls.length, 1);
  assert.strictEqual(gs.calls[0].deviceId, '34987AC30304');
});

test('invalid/blank deviceId is rejected without touching the sync service', async () => {
  const gs = makeAutoSync();
  trigger = new ScheduleSyncTrigger({ syncFn: gs.syncFn, logger: console });
  const out = trigger.trigger('');
  assert.strictEqual(out.status, 'unsupported');
  assert.strictEqual(gs.calls.length, 0);
});

test('same-device rapid triggers coalesce to running sync + a single latest-state follow-up', async () => {
  const gs = makeAutoSync();
  trigger = new ScheduleSyncTrigger({ syncFn: gs.syncFn, logger: console });
  trigger.trigger('DEV-A');
  // While the first sync is running, five more edits arrive.
  for (let i = 0; i < 5; i++) trigger.trigger('DEV-A');
  assert.strictEqual(gs.calls.length, 1, 'only one sync may be in flight');
  await trigger.whenIdle('DEV-A');
  // Coalesced: the 5 queued edits collapse into exactly ONE follow-up (not 5).
  assert.strictEqual(gs.calls.length, 2, '5 rapid edits -> 1 running + 1 follow-up = 2 syncs');
});

test('same-device syncs never run concurrently (per-device serialization)', async () => {
  const gs = makeAutoSync();
  trigger = new ScheduleSyncTrigger({ syncFn: gs.syncFn, logger: console });
  trigger.trigger('DEV-A');
  trigger.trigger('DEV-A');
  trigger.trigger('DEV-A');
  await trigger.whenIdle('DEV-A');
  assert.strictEqual(gs.calls.length, 2);
  assert.ok(gs.maxConcurrent() <= 1, 'same-device syncs must never overlap');
});

test('different devices run independently and never block each other', async () => {
  const gs = makeAutoSync();
  trigger = new ScheduleSyncTrigger({ syncFn: gs.syncFn, logger: console });
  trigger.trigger('DEV-A');
  trigger.trigger('DEV-B');
  assert.strictEqual(gs.calls.length, 2, 'both in flight simultaneously (separate per-device queues)');
  await Promise.all([trigger.whenIdle('DEV-A'), trigger.whenIdle('DEV-B')]);
  assert.strictEqual(gs.calls.length, 2);
});

test('a failing sync does not reject the trigger, is logged, and the site stays usable', async () => {
  const logLines = [];
  let called = 0;
  trigger = new ScheduleSyncTrigger({
    syncFn: async () => {
      called += 1;
      throw new Error('MQTT timeout');
    },
    logger: { error: (m) => logLines.push(String(m)), warn: () => {}, info: () => {}, log: () => {} },
  });
  const out = trigger.trigger('34987AC30304');
  assert.deepStrictEqual(out, { status: 'queued', deviceId: '34987AC30304' });
  await trigger.whenIdle('34987AC30304');
  assert.strictEqual(called, 1);
  assert.strictEqual(logLines.length, 1);
  assert.match(logLines[0], /MQTT timeout/);
  assert.strictEqual(trigger.lastResult('34987AC30304').status, 'failed');
  assert.strictEqual(trigger.lastResult('34987AC30304').error, 'MQTT timeout');
});

test('a crashed logger inside the drain cannot create an unhandled rejection and the queue stays salvageable', async () => {
  // The drain's inner error handler calls logger.error; if THAT throws, the
  // drain itself would normally reject. The trigger's backstop must swallow it,
  // resolve the tail, and keep the device usable for the next sync.
  const errors = [];
  let syncs = 0;
  trigger = new ScheduleSyncTrigger({
    syncFn: async () => {
      syncs += 1;
      if (syncs === 1) throw new Error('MQTT timeout');
      return { status: 'synced', deviceId: 'DEV-A' };
    },
    logger: {
      error: (m) => {
        errors.push(String(m));
        if (String(m).includes('MQTT timeout')) throw new Error('logger exploded');
      },
      warn: () => {},
      info: () => {},
      log: () => {},
    },
  });
  trigger.trigger('DEV-A');
  // Follow-up arrives while the (crashed) run is draining; it must still sync.
  trigger.trigger('DEV-A');
  await trigger.whenIdle('DEV-A');
  assert.strictEqual(syncs, 2, 'follow-up must run even after the logger crash');
  assert.deepStrictEqual(trigger.lastResult('DEV-A'), { status: 'synced', deviceId: 'DEV-A' });
  assert.deepStrictEqual(trigger.lastResult('DEV-A').status, 'synced');
});

test('lastResult carries the successful sync report after drain', async () => {
  const gs = makeAutoSync();
  trigger = new ScheduleSyncTrigger({ syncFn: gs.syncFn, logger: console });
  trigger.trigger('34987AC30304');
  await trigger.whenIdle('34987AC30304');
  assert.deepStrictEqual(trigger.lastResult('34987AC30304'), { status: 'synced', deviceId: '34987AC30304' });
});

test('trigger forwards the source option into the sync service call (diagnostic metadata only)', async () => {
  const seen = [];
  trigger = new ScheduleSyncTrigger({
    syncFn: (deviceId, options) => {
      seen.push({ deviceId, options });
      return Promise.resolve({ status: 'synced', deviceId });
    },
    logger: console,
  });
  trigger.trigger('DEV-A', { source: 'schedule-create' });
  await trigger.whenIdle('DEV-A');
  assert.strictEqual(seen.length, 1);
  assert.strictEqual(seen[0].options.source, 'schedule-create');
});

test('environment safety: with TASMOTA_SCHEDULE_SYNC_ENABLED=false the integration path stays a dry-run and never enables writes', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'false';
  let syncedDeviceId = null;
  let enabledSeen = null;
  trigger = new ScheduleSyncTrigger({
    syncFn: async (deviceId) => {
      syncedDeviceId = deviceId;
      enabledSeen = syncService.syncEnabled();
      return { status: 'pending', deviceId, publishedWrites: [], enabled: false };
    },
    logger: console,
  });
  trigger.trigger('34987AC30304');
  await trigger.whenIdle('34987AC30304');
  assert.strictEqual(syncedDeviceId, '34987AC30304');
  assert.strictEqual(enabledSeen, false, 'integration layer must observe, never enable, the write flag');
  assert.strictEqual(trigger.lastResult('34987AC30304').publishedWrites.length, 0);
});