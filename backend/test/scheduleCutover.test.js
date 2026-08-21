const { test, after } = require('node:test');
const assert = require('node:assert');

// Cutover tests: engine audit-only, retry sweep finalize/backfill, NTP clock
// verification. Each test isolates its stubs and restores them.

const scheduleEngine = require('../services/scheduleEngine');
const runtimeState = require('../services/runtimeState');
const scheduleSyncRetry = require('../services/scheduleSyncRetry');
const scheduleSyncService = require('../services/scheduleSyncService');
const Schedule = require('../models/Schedule');
const Device = require('../models/Device');
const tasmotaConfigClient = require('../services/tasmotaConfigClient');

// ─────────────────────────── 1. Engine audit-only ──────────────────────────

test('engine evaluate() is audit-only: divergence logged, ZERO publishes', async () => {
  const origFind = Schedule.find;
  const origOnline = runtimeState.isOnline;
  const origState = runtimeState.getDeviceState;
  const logs = [];
  const origWarn = console.warn;
  let publishCalls = 0;

  const fakeGateway = {
    publishCommandNoWait: async () => { publishCalls++; },
  };
  scheduleEngine.mqttGateway = fakeGateway;

  Schedule.find = async () => [
    {
      _id: 's1',
      name: 'morning',
      deviceId: 'DEV1',
      enabled: true,
      channels: [1],
      recurrence: { type: 'daily', daysOfWeek: [] },
      timeRanges: [{ start: '00:00', end: '23:59' }],
    },
  ];
  runtimeState.isOnline = () => true;
  runtimeState.getDeviceState = () => ({
    channels: { 1: { state: 'OFF', updatedAt: Date.now() } }, // desired ON, actual OFF
  });
  console.warn = (...a) => logs.push(a.join(' '));

  try {
    await scheduleEngine.evaluate();
    assert.strictEqual(publishCalls, 0,
      'audit-only engine must NEVER publish relay commands');
    assert.ok(logs.some((l) => l.includes('[AUDIT] divergence') && l.includes('desired=ON')),
      'divergence must be logged for operator visibility');
    // Throttle: second immediate pass adds no duplicate log line.
    const countAfterFirst = logs.length;
    await scheduleEngine.evaluate();
    assert.strictEqual(logs.length, countAfterFirst, 'divergence logging is throttled');
  } finally {
    Schedule.find = origFind;
    runtimeState.isOnline = origOnline;
    runtimeState.getDeviceState = origState;
    console.warn = origWarn;
    scheduleEngine.mqttGateway = null;
  }
});

test('engine release() reverts only channels desired-ON AND device-reported ON', async () => {
  const origOnline = runtimeState.isOnline;
  const origState = runtimeState.getDeviceState;
  const published = [];
  scheduleEngine.mqttGateway = {
    publishCommandNoWait: async (deviceId, ch, state) => { published.push(`${ch}:${state}`); },
  };

  const schedule = {
    name: 'morning',
    deviceId: 'DEV1',
    channels: [1, 2],
    recurrence: { type: 'daily', daysOfWeek: [] },
    timeRanges: [{ start: '00:00', end: '23:59' }],
  };
  runtimeState.isOnline = () => true;
  runtimeState.getDeviceState = () => ({
    channels: { 1: { state: 'ON' }, 2: { state: 'OFF' } },
  });

  try {
    await scheduleEngine.release(schedule);
    assert.deepStrictEqual(published, ['1:OFF'],
      'only the reported-ON channel inside an active window is released');
  } finally {
    runtimeState.isOnline = origOnline;
    runtimeState.getDeviceState = origState;
    scheduleEngine.mqttGateway = null;
  }
});

// ─────────────────────── 2. Retry sweep + finalize ─────────────────────────

test('retry sweep finalizes pendingDelete rows once device sync confirms', async () => {
  const origFindS = Schedule.find;
  const origDeleteMany = Schedule.deleteMany;
  const origFindD = Device.find;
  const origOnline = scheduleSyncRetry.isOnlineFn;
  const origSync = scheduleSyncRetry.syncFn;
  const origEnabled = scheduleSyncService.syncEnabled;

  const deletedRows = [];
  Schedule.find = async (q) =>
    q && q.pendingDelete === true
      ? [{ deviceId: 'DEV1' }]
      : [];
  Schedule.deleteMany = async (q) => {
    deletedRows.push(q);
    return { deletedCount: 2 };
  };
  Device.find = async () => [];
  scheduleSyncRetry.isOnlineFn = () => true;
  scheduleSyncRetry.syncFn = async () => ({ status: 'synced', deviceId: 'DEV1' });
  scheduleSyncService.syncEnabled = () => true;

  try {
    const res = await scheduleSyncRetry.sweep();
    assert.strictEqual(res.status, 'done');
    assert.strictEqual(res.retried, 1);
    assert.strictEqual(res.finalized, 2);
    assert.deepStrictEqual(deletedRows, [{ deviceId: 'DEV1', pendingDelete: true }]);
  } finally {
    Schedule.find = origFindS;
    Schedule.deleteMany = origDeleteMany;
    Device.find = origFindD;
    scheduleSyncRetry.isOnlineFn = origOnline;
    scheduleSyncRetry.syncFn = origSync;
    scheduleSyncService.syncEnabled = origEnabled;
  }
});

test('retry sweep skips offline devices and no-ops when native sync flag is off', async () => {
  const origEnabled = scheduleSyncService.syncEnabled;
  const origOnline = scheduleSyncRetry.isOnlineFn;
  const origSync = scheduleSyncRetry.syncFn;
  const origFindS = Schedule.find;
  const origFindD = Device.find;

  let syncCalls = 0;
  Schedule.find = async () => [{ deviceId: 'DEV1' }];
  Device.find = async () => [];
  scheduleSyncRetry.syncFn = async () => { syncCalls++; return { status: 'synced' }; };
  scheduleSyncService.syncEnabled = () => true;
  scheduleSyncRetry.isOnlineFn = () => false; // offline

  try {
    const offlineRes = await scheduleSyncRetry.sweep();
    assert.strictEqual(syncCalls, 0, 'offline device must not be retried this pass');
    assert.strictEqual(offlineRes.status, 'done');

    scheduleSyncService.syncEnabled = () => false; // flag off
    scheduleSyncRetry.isOnlineFn = () => true;
    const flagOffRes = await scheduleSyncRetry.sweep();
    assert.strictEqual(flagOffRes.status, 'skipped-flag-off',
      'graceful degradation: sweep disabled when native sync is off');
    assert.strictEqual(syncCalls, 0);
  } finally {
    scheduleSyncService.syncEnabled = origEnabled;
    scheduleSyncRetry.isOnlineFn = origOnline;
    scheduleSyncRetry.syncFn = origSync;
    Schedule.find = origFindS;
    Device.find = origFindD;
  }
});

// ─────────────────────────── 3. Startup backfill ───────────────────────────

test('backfill triggers ONLY devices with schedules lacking a synced outcome', async () => {
  const origFindD = Device.find;
  const origFindS = Schedule.find;
  const origTrigger = require('../services/scheduleSyncTrigger').trigger;
  const origEnabled = scheduleSyncService.syncEnabled;

  const triggered = [];
  Device.find = async () => [
    { deviceId: 'SYNCED1', scheduleSyncInfo: { status: 'synced' } },
    { deviceId: 'NEVER1', scheduleSyncInfo: null },
    { deviceId: 'FAILED1', scheduleSyncInfo: { status: 'failed' } },
    { deviceId: 'NOSCHEDULES1', scheduleSyncInfo: null },
  ];
  Schedule.find = async () => [
    { deviceId: 'SYNCED1' }, { deviceId: 'NEVER1' }, { deviceId: 'FAILED1' },
  ];
  require('../services/scheduleSyncTrigger').trigger = (id) => {
    triggered.push(id);
    return { status: 'queued', deviceId: id };
  };
  scheduleSyncService.syncEnabled = () => true;

  try {
    const res = await scheduleSyncRetry.backfill();
    assert.deepStrictEqual(triggered.sort(), ['FAILED1', 'NEVER1'],
      'synced devices are never duplicate-synced; schedule-less devices skipped');
    assert.strictEqual(res.triggered.length, 2);
  } finally {
    Device.find = origFindD;
    Schedule.find = origFindS;
    require('../services/scheduleSyncTrigger').trigger = origTrigger;
    scheduleSyncService.syncEnabled = origEnabled;
  }
});

// ───────────────────────────── 4. NTP clock gate ───────────────────────────

test('ensureDeviceClock corrects missing/stale Epoch via NTP rewrite; healthy clock untouched', async () => {
  const origReq = tasmotaConfigClient.requestTasmotaConfig;
  const calls = [];

  function stub(sequence) {
    let i = 0;
    tasmotaConfigClient.requestTasmotaConfig = async (deviceId, command) => {
      calls.push(command);
      const step = sequence[Math.min(i++, sequence.length - 1)];
      if (step.reject) throw new Error('timeout');
      return step.reply;
    };
  }

  const quietLogger = { log: () => {}, warn: () => {} };

  try {
    // Case A: healthy clock (Epoch within tolerance) → read only, no writes.
    stub([{ reply: { Time: 'x', Epoch: Math.floor(Date.now() / 1000) } }]);
    calls.length = 0;
    let r = await scheduleSyncService.ensureDeviceClock('DEV1', { traceId: 't', logger: quietLogger });
    assert.deepStrictEqual(calls, ['Time'], 'healthy clock: read-only');
    assert.strictEqual(r.corrected, false);

    // Case B: stale Epoch → Time read + NtpServer1..3 rewritten.
    stub([{ reply: { Time: 'x', Epoch: Math.floor(Date.now() / 1000) - 3600 } }]);
    calls.length = 0;
    r = await scheduleSyncService.ensureDeviceClock('DEV1', { traceId: 't', logger: quietLogger });
    assert.deepStrictEqual(calls, ['Time', 'NtpServer1', 'NtpServer2', 'NtpServer3']);
    assert.strictEqual(r.corrected, true);

    // Case C: no Epoch at all (NTP never configured) → corrected.
    stub([{ reply: { Time: 'not-set' } }]);
    calls.length = 0;
    r = await scheduleSyncService.ensureDeviceClock('DEV1', { traceId: 't', logger: quietLogger });
    assert.deepStrictEqual(calls, ['Time', 'NtpServer1', 'NtpServer2', 'NtpServer3']);
    assert.strictEqual(r.corrected, true);
    assert.strictEqual(r.driftSec, null);

    // Case D: Time read fails → non-fatal, checked with error.
    stub([{ reject: true }]);
    r = await scheduleSyncService.ensureDeviceClock('DEV1', { traceId: 't', logger: quietLogger });
    assert.strictEqual(r.checked, true);
    assert.notStrictEqual(r.error, null);
  } finally {
    tasmotaConfigClient.requestTasmotaConfig = origReq;
  }
});

after(() => {
  scheduleEngine.stop();
  scheduleSyncRetry.stop();
});
