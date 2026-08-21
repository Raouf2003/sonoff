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

// ─────────────────── 5. Rule2 activation (State:"ON") ──────────────────────

const { dailySchedule } = (() => {
  const dailySchedule = (over = {}) => ({
    _id: 's1',
    name: 'morning',
    enabled: true,
    deviceId: '34987AC30304',
    channels: [1],
    recurrence: { type: 'daily', daysOfWeek: [] },
    timeRanges: [{ start: '07:00', end: '09:00' }],
    ...over,
  });
  return { dailySchedule };
})();

// Local fake firmware that models the REAL device behavior from the MQTT log:
// writing rule TEXT stores it but leaves State untouched (OFF); only an
// explicit numeric payload activates/deactivates. `ignoreActivation` models a
// hostile/faulty device where even `Rule2 1` fails to enable.
function installRuleFake(state, { ignoreActivation = false, timersArmed = true } = {}) {
  const orig = tasmotaConfigClient.requestTasmotaConfig;
  const calls = [];
  let armed = timersArmed;
  tasmotaConfigClient.requestTasmotaConfig = async (deviceId, command, payload, opts = {}) => {
    const key = opts.expectedResponseKey || command;
    calls.push({ command, payload });
    if (key === 'Timers') {
      if (payload === '1' || payload === '0') armed = payload === '1';
      return Promise.resolve({ Timers: armed ? 'ON' : 'OFF' });
    }
    const m = /^Rule(\d+)$/.exec(key);
    if (m) {
      const idx = Number(m[1]);
      if (payload === '1' || payload === '0') {
        if (!ignoreActivation) {
          state.rules[idx - 1] = { ...state.rules[idx - 1], State: payload === '1' ? 'ON' : 'OFF' };
        }
      } else if (payload !== '' && payload !== undefined) {
        state.rules[idx - 1] = {
          ...state.rules[idx - 1],
          Rules: String(payload),
          Length: String(payload).length,
        };
      }
      return Promise.resolve({ [key]: state.rules[idx - 1] });
    }
    if (/^Timer(\d+)$/.test(key)) {
      const idx = Number(key.slice(5));
      const body = payload === '' || payload === undefined ? null : JSON.parse(payload);
      if (body) state.timers[idx - 1] = { ...state.timers[idx - 1], ...body };
      return Promise.resolve({ [key]: state.timers[idx - 1] });
    }
    if (key === 'Time') {
      const { DateTime } = require('luxon');
      const now = DateTime.now().setZone('Africa/Algiers');
      return Promise.resolve({ Time: now.toFormat('yyyy-MM-dd\'T\'HH:mm:ss') });
    }
    if (key === 'Timers') {
      return Promise.resolve({ Timers: timersArmed ? 'ON' : 'OFF' });
    }
    return Promise.reject(new Error(`unhandled ${key}`));
  };
  return {
    calls,
    isArmed: () => armed,
    restore() {
      tasmotaConfigClient.requestTasmotaConfig = orig;
    },
  };
}

function emptyDeviceState() {
  const timers = Array.from({ length: 16 }, () => ({
    Enable: 0, Mode: 0, Time: '00:00', Window: 0, Days: '0000000', Repeat: 0, Output: 0, Action: 0,
  }));
  const rules = [
    { index: 1, State: 'OFF', Once: 'OFF', StopOnError: 'OFF', Length: 0, Free: 511, Rules: '' },
    { index: 2, State: 'OFF', Once: 'OFF', StopOnError: 'OFF', Length: 0, Free: 511, Rules: '' },
    { index: 3, State: 'OFF', Once: 'OFF', StopOnError: 'OFF', Length: 0, Free: 511, Rules: '' },
  ];
  return { timers, rules };
}

test('computeWrites emits a rule write when text matches but State is OFF (activation-only)', () => {
  const { compile } = require('../services/scheduleCompiler');
  const plan = compile({
    deviceId: '34987AC30304',
    schedules: [dailySchedule({ channels: [1, 2] })],
    device: { deviceId: '34987AC30304', channels: 4 },
  });
  assert.ok(plan.rules.length > 0, 'multi-channel plan must produce a rule');
  const state = emptyDeviceState();
  // Pre-store EXACTLY the desired text but leave the rule disabled.
  const slotMap = new Map([[1, 1], [2, 2]]);
  const clauses = [];
  for (const t of plan.timers) {
    const slot = slotMap.get(t.index);
    const cmds = [];
    for (const c of t.event.on) cmds.push(`Power${c} ON`);
    for (const c of t.event.off) cmds.push(`Power${c} OFF`);
    clauses.push(`ON Clock#Timer=${slot} DO Backlog ${cmds.join('; ')} ENDON`);
  }
  const text = clauses.join(' ');
  state.rules[1] = { index: 2, State: 'OFF', Once: 'OFF', StopOnError: 'OFF', Length: text.length, Free: 511 - text.length, Rules: text };
  const actual = {
    timers: state.timers.map((t, i) => ({ index: i + 1, ...t })),
    rules: state.rules,
  };
  const result = scheduleSyncService.computeWrites(plan, actual, []);
  assert.strictEqual(result.okay, true);
  const ruleWrites = result.writes.filter((w) => w.kind === 'rule');
  assert.strictEqual(ruleWrites.length, 1,
    'stored-but-disabled rule MUST be rewritten/re-activated, not skipped as "unchanged"');
});

test('sync sends Rule2 content write FOLLOWED BY activation (`Rule2` payload 1)', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = emptyDeviceState();
  const fake = installRuleFake(state);
  const origFindS = Schedule.find;
  Schedule.find = async ({ deviceId, pendingDelete } = {}) =>
    deviceId === '34987AC30304' && pendingDelete !== true
      ? [dailySchedule({ channels: [1, 2], timeRanges: [{ start: '07:00', end: '08:00' }] })]
      : [];
  const origFindD = Device.find;
  Device.find = async () => [];
  try {
    const out = await scheduleSyncService.syncDevice('34987AC30304', {
      deviceModel: { findOne: async () => ({ deviceId: '34987AC30304', channels: 4 }), updateOne: async () => ({}) },
      scheduleModel: { find: async () => [dailySchedule({ channels: [1, 2], timeRanges: [{ start: '07:00', end: '08:00' }] })] },
    });
    assert.strictEqual(out.status, 'synced', `expected synced, got ${out.status}: ${out.error}`);
    const ruleCalls = fake.calls.filter((c) => c.command === 'Rule2');
    const contentIdx = ruleCalls.findIndex((c) => c.payload.includes('Clock#Timer'));
    const activateIdx = ruleCalls.findIndex((c) => c.payload === '1');
    assert.ok(contentIdx !== -1, 'rule CONTENT write must be sent');
    assert.ok(activateIdx !== -1, 'rule ACTIVATION command (payload "1") must be sent');
    assert.ok(activateIdx > contentIdx, 'activation must come AFTER the content write');
    // Verification recorded the active-state requirement.
    const ruleVerdict = out.verification.find((v) => v.resource === 'Rule2');
    assert.ok(ruleVerdict, 'Rule2 verification entry present');
    assert.strictEqual(ruleVerdict.desired.State, 'ON');
    assert.strictEqual(ruleVerdict.matches, true);
  } finally {
    fake.restore();
    Schedule.find = origFindS;
    Device.find = origFindD;
  }
});

test('verify FAILS and retries when activation does not stick (State stays OFF)', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = emptyDeviceState();
  const fake = installRuleFake(state, { ignoreActivation: true });
  const origFindD = Device.find;
  Device.find = async () => [];
  try {
    const out = await scheduleSyncService.syncDevice('34987AC30304', {
      deviceModel: { findOne: async () => ({ deviceId: '34987AC30304', channels: 4 }), updateOne: async () => ({}) },
      scheduleModel: { find: async () => [dailySchedule({ channels: [1, 2], timeRanges: [{ start: '07:00', end: '08:00' }] })] },
    });
    assert.strictEqual(out.status, 'failed',
      'a stored-but-disabled rule must NOT be reported as synced');
    assert.strictEqual(out.verificationPassed, false);
    assert.strictEqual(out.attempts, scheduleSyncService.MAX_SYNC_ATTEMPTS,
      'all bounded retries must be exhausted');
    const mismatched = out.verification.filter((v) => v.resource === 'Rule2' && !v.matches);
    assert.ok(mismatched.length > 0, 'Rule2 mismatch (State OFF) recorded');
    // Activation was attempted on every attempt.
    const activations = fake.calls.filter((c) => c.command === 'Rule2' && c.payload === '1');
    assert.ok(activations.length >= scheduleSyncService.MAX_SYNC_ATTEMPTS,
      'activation command retried each attempt');
  } finally {
    fake.restore();
    Device.find = origFindD;
  }
});

test('sync ARMS globally-disarmed timers (`Timers` OFF → write "1") and reports it', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = emptyDeviceState();
  const fake = installRuleFake(state, { timersArmed: false });
  const origFindD = Device.find;
  Device.find = async () => [];
  try {
    let storedInfo = null;
    const stickyModel = {
      findOne: async () => ({ deviceId: '34987AC30304', channels: 4, get scheduleSyncInfo() { return storedInfo; } }),
      updateOne: async (_f, u) => { storedInfo = u.$set.scheduleSyncInfo; return {}; },
    };
    const schedModel = { find: async () => [dailySchedule({ channels: [1, 2], timeRanges: [{ start: '07:00', end: '08:00' }] })] };

    const out = await scheduleSyncService.syncDevice('34987AC30304', {
      deviceModel: stickyModel,
      scheduleModel: schedModel,
    });
    assert.strictEqual(out.status, 'synced');
    const armCalls = fake.calls.filter((c) => c.command === 'Timers');
    assert.ok(
      armCalls.some((c) => c.payload === '') && armCalls.some((c) => c.payload === '1'),
      'Timers read + arm write must both be issued',
    );
    assert.strictEqual(fake.isArmed(), true, 'device must end up armed');
    assert.ok(out.timersArmed && out.timersArmed.corrected === true,
      'summary.timersArmed.corrected reports the fix');
    // Idempotent second sync: already armed → read-only. The sticky model
    // carries managedTimerIndexes from run 1, so slots stay "managed" and the
    // run reaches the gates instead of exiting 'unsupported'.
    fake.calls.length = 0;
    await scheduleSyncService.syncDevice('34987AC30304', {
      deviceModel: stickyModel,
      scheduleModel: schedModel,
    });
    const armAgain = fake.calls.filter((c) => c.command === 'Timers');
    assert.deepStrictEqual(armAgain.map((c) => c.payload), [''],
      'armed device: only the Timers READ, no redundant arm write');
  } finally {
    fake.restore();
    Device.find = origFindD;
  }
});

test('Epoch-less firmware with CORRECT wall time is healthy (no false NTP correction)', async () => {
  // Regression for the live-log false positive: this firmware's `Time` reply
  // carries no Epoch — wall-string comparison must clear it.
  const origReq = tasmotaConfigClient.requestTasmotaConfig;
  const calls = [];
  tasmotaConfigClient.requestTasmotaConfig = async (deviceId, command) => {
    calls.push(command);
    if (command === 'Time') {
      const { DateTime } = require('luxon');
      return Promise.resolve({
        Time: DateTime.now().setZone('Africa/Algiers').toFormat('yyyy-MM-dd\'T\'HH:mm:ss'),
      });
    }
    return Promise.resolve({ [command]: {} });
  };
  try {
    const r = await scheduleSyncService.ensureDeviceClock('DEV1', {
      traceId: 't',
      logger: { log: () => {}, warn: () => {} },
    });
    assert.strictEqual(r.corrected, false, 'correct wall time must not trigger correction');
    assert.deepStrictEqual(calls, ['Time'], 'read-only when healthy');
  } finally {
    tasmotaConfigClient.requestTasmotaConfig = origReq;
  }
});

after(() => {
  scheduleEngine.stop();
  scheduleSyncRetry.stop();
});
