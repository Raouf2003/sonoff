const { test, mock, afterEach } = require('node:test');
const assert = require('node:assert');
const tasmotaConfigClient = require('../services/tasmotaConfigClient');
const syncService = require('../services/scheduleSyncService');
const { compile } = require('../services/scheduleCompiler');

const USER_RULE1_TEXT = 'ON Clock#Timer=3 DO Backlog Power1 ON; Power2 ON ENDON';

function defaultTimer() {
  return { Enable: 0, Mode: 0, Time: '00:00', Window: 0, Days: '0000000', Repeat: 0, Output: 1, Action: 0 };
}

// Simulated device state mirroring the real 34987AC30304 read in Phase 5:
// user Rule1 (ON), its protected trigger Timer3, and default timers elsewhere.
function deviceState() {
  const timers = Array.from({ length: 16 }, () => defaultTimer());
  timers[2] = { Enable: 0, Mode: 0, Time: '15:32', Window: 0, Days: '1111111', Repeat: 0, Output: 1, Action: 3 };
  const rules = [
    { index: 1, State: 'ON', Once: 'OFF', StopOnError: 'OFF', Length: USER_RULE1_TEXT.length, Free: 511 - USER_RULE1_TEXT.length, Rules: USER_RULE1_TEXT },
    { index: 2, State: 'OFF', Once: 'OFF', StopOnError: 'OFF', Length: 0, Free: 511, Rules: '' },
    { index: 3, State: 'OFF', Once: 'OFF', StopOnError: 'OFF', Length: 0, Free: 511, Rules: '' },
  ];
  return { timers, rules };
}

// Fake MQTT config channel: reads return the simulated state, writes mutate it.
function installFakeConfigChannel(state) {
  const calls = [];
  mock.method(tasmotaConfigClient, 'requestTasmotaConfig', (deviceId, command, payload, opts) => {
    const key = opts && opts.expectedResponseKey ? opts.expectedResponseKey : command;
    calls.push({ deviceId, command, payload });
    if (/^Timer(\d+)$/.test(key)) {
      const idx = Number(key.slice(5));
      const body = payload === '' || payload === undefined ? null : JSON.parse(payload);
      if (body) state.timers[idx - 1] = { ...state.timers[idx - 1], ...body };
      return Promise.resolve({ [key]: state.timers[idx - 1] });
    }
    if (/^Rule(\d+)$/.test(key)) {
      const idx = Number(key.slice(4));
      if (payload !== '' && payload !== undefined) {
        state.rules[idx - 1] = { ...state.rules[idx - 1], State: 'ON', Rules: String(payload), Length: String(payload).length };
      }
      return Promise.resolve({ [key]: state.rules[idx - 1] });
    }
    return Promise.reject(new Error(`unhandled command ${key}`));
  });
  return calls;
}

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

const deviceDoc = { deviceId: '34987AC30304', channels: 4 };

const fakeDeviceModel = {
  findOne: async ({ deviceId }) => (deviceId === deviceDoc.deviceId ? { ...deviceDoc } : null),
  updateOne: async (filter, update) => ({ ok: 1 }),
};

const fakeScheduleModel = {
  find: async ({ deviceId }) => (deviceId === deviceDoc.deviceId ? schedulesFixture() : []),
};

let schedulesFixture = () => [];

afterEach(() => {
  mock.restoreAll();
  delete process.env.TASMOTA_SCHEDULE_SYNC_ENABLED;
});

// ---------------------------------------------------------------------------
// readDeviceScheduleState and normalization
// ---------------------------------------------------------------------------
test('readDeviceScheduleState returns all 16 timers and 3 rules normalized', async () => {
  const state = deviceState();
  installFakeConfigChannel(state);
  const { timers, rules } = await syncService.readDeviceScheduleState('34987AC30304');
  assert.strictEqual(timers.length, 16);
  assert.strictEqual(rules.length, 3);
  assert.strictEqual(timers[2].index, 3);
  assert.strictEqual(timers[2].Time, '15:32');
  assert.strictEqual(timers[2].Action, 3);
  assert.strictEqual(timers[0].Enable, 0);
  assert.strictEqual(rules[0].State, 'ON');
  assert.strictEqual(rules[0].Rules, USER_RULE1_TEXT);
  assert.strictEqual(rules[1].State, 'OFF');
});

test('normalizeTimer tolerates missing and firmware-variant fields', () => {
  const t = syncService.normalizeTimer({ Enable: '1', Time: '07:00' });
  assert.strictEqual(t.Enable, 1);
  assert.strictEqual(t.Time, '07:00');
  assert.strictEqual(t.Days, '0000000');
  assert.strictEqual(t.Window, 0);
  assert.strictEqual(t.Repeat, 0);
  const d = syncService.normalizeTimer({});
  assert.deepStrictEqual(d, { Enable: 0, Mode: 0, Time: '00:00', Window: 0, Days: '0000000', Repeat: 0, Output: 0, Action: 0 });
});

test('normalizeRule tolerates the raw-text reply shape after a write', () => {
  const r = syncService.normalizeRule(2, 'ON Clock#Timer=4 DO Power1 ON ENDON');
  assert.strictEqual(r.State, 'ON');
  assert.strictEqual(r.Length, 'ON Clock#Timer=4 DO Power1 ON ENDON'.length);
  const full = syncService.normalizeRule(1, { State: 'ON', Once: 'OFF', StopOnError: 'OFF', Length: 54, Free: 457, Rules: USER_RULE1_TEXT });
  assert.strictEqual(full.Rules, USER_RULE1_TEXT);
});

// ---------------------------------------------------------------------------
// computeWrites: diff, ownership, no-op zero writes
// ---------------------------------------------------------------------------
// Seed `actual` so the compiled plan is already present in its allocated slots
// and record those slots as STEES-managed (sticky ownership across re-syncs).
function seedPlan(plan, actual, managed) {
  const alloc = syncService.allocateSlots(plan, actual, managed);
  assert.strictEqual(alloc.okay, true);
  for (const timer of plan.timers) {
    const slot = alloc.allocation.get(timer.index);
    actual.timers[slot - 1] = { index: slot, ...syncService.normalizeTimer({ ...timer.config }) };
  }
  return alloc;
}

test('computeWrites produces zero writes when plan already matches device (no-op)', () => {
  const state = deviceState();
  const plan = compile({ deviceId: '34987AC30304', schedules: [dailySchedule()], device: deviceDoc });
  const actual = { timers: state.timers.map((t, i) => ({ index: i + 1, ...syncService.normalizeTimer(t) })), rules: state.rules };
  const alloc = seedPlan(plan, actual, [1, 2]);
  const writes = syncService.computeWrites(plan, actual, alloc.managed);
  assert.strictEqual(writes.okay, true);
  assert.strictEqual(writes.writes.length, 0);
});

test('computeWrites emits a write only for the slot that differs (diff-only)', () => {
  const state = deviceState();
  const plan = compile({ deviceId: '34987AC30304', schedules: [dailySchedule()], device: deviceDoc });
  const actual = { timers: state.timers.map((t, i) => ({ index: i + 1, ...syncService.normalizeTimer(t) })), rules: state.rules };
  const alloc = seedPlan(plan, actual, [1, 2]);
  // Toggle slot 1's time so the diff fires only there.
  actual.timers[0].Time = '08:00';
  const writes2 = syncService.computeWrites(plan, actual, alloc.managed);
  const changed = writes2.writes.filter((w) => w.kind === 'timer').map((w) => w.index);
  assert.deepStrictEqual(changed, [1]);
});

test('computeWrites never touches user Timer3 or Rule1/Rule3', () => {
  const state = deviceState();
  const plan = compile({ deviceId: '34987AC30304', schedules: [dailySchedule()], device: deviceDoc });
  const actual = { timers: state.timers.map((t, i) => ({ index: i + 1, ...syncService.normalizeTimer(t) })), rules: state.rules };
  const result = syncService.computeWrites(plan, actual);
  for (const w of result.writes) {
    if (w.kind === 'timer') {
      assert.notStrictEqual(w.index, syncService.USER_TRIGGER_TIMER, 'Timer3 must never be written');
    } else {
      assert.ok(!syncService.USER_RULE_INDEXES.includes(w.index), 'user rules must never be written');
    }
  }
});

test('allocateSlots reports insuffiicient safe slots without overwriting user timers', () => {
  const state = deviceState();
  // Occupy every non-Timer3 slot so only 0 free slots remain for a 2-timer plan.
  for (let i = 0; i < 16; i++) {
    if (i + 1 === syncService.USER_TRIGGER_TIMER) continue;
    state.timers[i] = { ...defaultTimer(), Enable: 1, Time: '10:00', Days: '1111111', Action: 1, Output: 1 };
  }
  const plan = compile({ deviceId: '34987AC30304', schedules: [dailySchedule()], device: deviceDoc });
  const actual = { timers: state.timers.map((t, i) => ({ index: i + 1, ...syncService.normalizeTimer(t) })), rules: state.rules };
  const result = syncService.computeWrites(plan, actual, []);
  assert.strictEqual(result.okay, false);
  assert.ok(result.conflicts.some((c) => c.includes('safe managed slot')));
});

// ---------------------------------------------------------------------------
// syncDevice end-to-end
// ---------------------------------------------------------------------------
test('syncDevice with flag off returns pending and publishes zero writes', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'false';
  const state = deviceState();
  const calls = installFakeConfigChannel(state);
  schedulesFixture = () => [dailySchedule()];
  const out = await syncService.syncDevice('34987AC30304', { deviceModel: fakeDeviceModel, scheduleModel: fakeScheduleModel });
  assert.strictEqual(out.status, 'pending');
  assert.strictEqual(out.enabled, false);
  assert.strictEqual(out.verificationPassed, null);
  assert.ok(out.error.includes('disabled'));
  // Only read commands (payload '') were issued; no timer/rule writes.
  const writes = calls.filter((c) => c.payload !== '');
  assert.strictEqual(writes.length, 0);
  assert.ok(Array.isArray(out.intendedWrites));
});

test('flag-off report exposes the compiled plan, allocation, protected resources and zero published writes', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'false';
  const state = deviceState();
  installFakeConfigChannel(state);
  schedulesFixture = () => [dailySchedule()];
  const out = await syncService.syncDevice('34987AC30304', { deviceModel: fakeDeviceModel, scheduleModel: fakeScheduleModel });

  // Compiled plan: 2 direct timers for a single daily range, no rules.
  assert.ok(out.plan, 'plan must be present');
  assert.strictEqual(out.plan.requiredTimerCount, 2);
  assert.strictEqual(out.plan.timers.length, 2);
  assert.strictEqual(out.plan.rules.length, 0);

  // Allocation: logical 1..2 -> physical slots 1 and 2 (safe empty slots).
  assert.deepStrictEqual(out.allocation, [
    { logical: 1, physical: 1 },
    { logical: 2, physical: 2 },
  ]);

  // Protected resources: Timer3 (user Rule1 trigger), Rule1 + Rule3 user rules.
  const protectedTimerIndexes = out.protected.timers.map((t) => t.index);
  assert.ok(protectedTimerIndexes.includes(syncService.USER_TRIGGER_TIMER), 'Timer3 must be reported as protected');
  const protectedRuleIndexes = out.protected.rules.map((r) => r.index);
  for (const idx of syncService.USER_RULE_INDEXES) {
    assert.ok(protectedRuleIndexes.includes(idx), `Rule${idx} must be reported as protected`);
  }

  // Intended writes are the two direct timers; nothing was published.
  assert.deepStrictEqual(out.changedTimers.sort(), [1, 2]);
  assert.deepStrictEqual(out.intendedWrites.length, 2);
  assert.deepStrictEqual(out.publishedWrites, []);
  assert.deepStrictEqual(out.verification, []);
});

test('flag-on report includes per-resource readback verification with actual vs desired', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = deviceState();
  installFakeConfigChannel(state);
  schedulesFixture = () => [dailySchedule()];
  const out = await syncService.syncDevice('34987AC30304', { deviceModel: fakeDeviceModel, scheduleModel: fakeScheduleModel });
  assert.strictEqual(out.status, 'synced');
  assert.strictEqual(out.verificationPassed, true);
  // Two published writes match the two changed timers.
  assert.deepStrictEqual(out.publishedWrites.length, 2);
  assert.strictEqual(out.verification.length, 2);
  for (const v of out.verification) {
    assert.strictEqual(v.matches, true);
    assert.ok(v.desired, 'desired config must be reported');
    assert.ok(v.actual, 'actual readback config must be reported');
    if (v.resource.startsWith('Timer')) {
      assert.strictEqual(v.desired.Enable, 1);
      const actualNoIndex = { ...v.actual };
      delete actualNoIndex.index;
      assert.deepStrictEqual(v.desired, actualNoIndex);
    }
  }
});

test('protectedResources reports occupied unmanaged timers and a user-occupied Rule2', () => {
  const state = deviceState();
  // Occupy a non-managed slot and occupy Rule2 with user config.
  state.timers[4] = { ...defaultTimer(), Enable: 1, Time: '11:11', Days: '1010101', Action: 1, Output: 1 };
  state.rules[1] = { index: 2, State: 'ON', Once: 'OFF', StopOnError: 'OFF', Length: 20, Free: 491, Rules: 'ON Time#OfDay DO Power1 ON ENDON' };
  const actual = { timers: state.timers.map((t, i) => ({ index: i + 1, ...syncService.normalizeTimer(t) })), rules: state.rules };
  const protectedInfo = syncService.protectedResources(actual, []);
  const timerIndexes = protectedInfo.timers.map((t) => t.index);
  assert.ok(timerIndexes.includes(3), 'Timer3 protected');
  assert.ok(timerIndexes.includes(5), 'occupied slot 5 protected as unmanaged');
  const ruleIndexes = protectedInfo.rules.map((r) => r.index);
  assert.ok(ruleIndexes.includes(1) && ruleIndexes.includes(3), 'user rules protected');
  assert.ok(ruleIndexes.includes(2), 'user-occupied Rule2 protected');
});

test('planView and allocationView are JSON-safe views', () => {
  const state = deviceState();
  const plan = compile({ deviceId: '34987AC30304', schedules: [dailySchedule()], device: deviceDoc });
  const view = syncService.planView(plan);
  JSON.stringify(view);
  assert.strictEqual(view.requiredTimerCount, 2);
  assert.ok(view.timers[0].config.Enable === 1);
  assert.ok(Array.isArray(view.timers[0].sources));
  const alloc = new Map([[1, 2], [2, 4]]);
  assert.deepStrictEqual(syncService.allocationView(alloc), [
    { logical: 1, physical: 2 },
    { logical: 2, physical: 4 },
  ]);
});

test('manualSync passes through to syncDevice with injectable models', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'false';
  const state = deviceState();
  installFakeConfigChannel(state);
  schedulesFixture = () => [dailySchedule()];
  const out = await syncService.manualSync('34987AC30304', { deviceModel: fakeDeviceModel, scheduleModel: fakeScheduleModel });
  assert.strictEqual(out.status, 'pending');
  assert.strictEqual(out.enabled, false);
});

test('syncDevice with flag on applies changed timers and verifies readback', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = deviceState();
  const calls = installFakeConfigChannel(state);
  schedulesFixture = () => [dailySchedule()];
  const out = await syncService.syncDevice('34987AC30304', { deviceModel: fakeDeviceModel, scheduleModel: fakeScheduleModel });
  assert.strictEqual(out.status, 'synced');
  assert.strictEqual(out.verificationPassed, true);
  assert.deepStrictEqual(out.changedTimers.sort(), [1, 2]);
  assert.deepStrictEqual(out.changedRules, []);
  // Writes issued for Timer1 + Timer2, then a full 16+3 readback for verify.
  const timerWrites = calls.filter((c) => /^Timer[12]$/.test(c.command) && c.payload !== '');
  assert.strictEqual(timerWrites.length, 2);
  // Timer3 must never be written by sync.
  assert.strictEqual(calls.some((c) => /^Timer3$/.test(c.command) && c.payload !== ''), false);
});

test('syncDevice verification failure retries and returns failed after bounded retries', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = deviceState();
  // Sabotage readback: any Timer write returns an Enable:0 (fails verification).
  mock.method(tasmotaConfigClient, 'requestTasmotaConfig', (deviceId, command, payload, opts) => {
    const key = opts && opts.expectedResponseKey ? opts.expectedResponseKey : command;
    if (/^Timer(\d+)$/.test(key)) {
      const idx = Number(key.slice(5));
      const body = payload === '' || payload === undefined ? null : JSON.parse(payload);
      if (body) state.timers[idx - 1] = { ...state.timers[idx - 1], ...body, Enable: 0 };
      return Promise.resolve({ [key]: state.timers[idx - 1] });
    }
    if (/^Rule(\d+)$/.test(key)) {
      const idx = Number(key.slice(4));
      if (payload !== '' && payload !== undefined) state.rules[idx - 1] = { ...state.rules[idx - 1], Rules: String(payload) };
      return Promise.resolve({ [key]: state.rules[idx - 1] });
    }
    return Promise.reject(new Error(`unhandled ${key}`));
  });
  schedulesFixture = () => [dailySchedule()];
  const out = await syncService.syncDevice('34987AC30304', { deviceModel: fakeDeviceModel, scheduleModel: fakeScheduleModel });
  assert.strictEqual(out.status, 'failed');
  assert.strictEqual(out.verificationPassed, false);
  assert.strictEqual(out.attempts, syncService.MAX_SYNC_ATTEMPTS);
  assert.ok(out.error.toLowerCase().includes('verification failed'));
});

test('syncDevice never writes Rule2 when it is occupied by user configuration', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = deviceState();
  state.rules[1] = { index: 2, State: 'ON', Once: 'OFF', StopOnError: 'OFF', Length: 10, Free: 501, Rules: 'ON Time#OfDay DO Power1 ON ENDON' };
  const calls = installFakeConfigChannel(state);
  // A multi-channel schedule forces a rule write attempt.
  schedulesFixture = () => [
    dailySchedule({ name: 'multi', channels: [1, 2], timeRanges: [{ start: '07:00', end: '08:00' }] }),
  ];
  const out = await syncService.syncDevice('34987AC30304', { deviceModel: fakeDeviceModel, scheduleModel: fakeScheduleModel });
  assert.strictEqual(out.status, 'unsupported');
  assert.ok(out.conflicts.some((c) => c.includes('Rule2')));
  assert.strictEqual(calls.some((c) => /^Rule2$/.test(c.command) && c.payload !== ''), false);
});

test('syncDevice with a multi-channel plan writes Rule2 and remaps timer slots', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = deviceState();
  const calls = installFakeConfigChannel(state);
  schedulesFixture = () => [
    dailySchedule({ name: 'multi', channels: [1, 2], timeRanges: [{ start: '07:00', end: '08:00' }] }),
  ];
  const out = await syncService.syncDevice('34987AC30304', { deviceModel: fakeDeviceModel, scheduleModel: fakeScheduleModel });
  assert.strictEqual(out.status, 'synced');
  assert.strictEqual(out.verificationPassed, true);
  assert.deepStrictEqual(out.changedTimers.sort(), [1, 2]);
  assert.deepStrictEqual(out.changedRules, [2]);
  const ruleWrite = calls.find((c) => /^Rule2$/.test(c.command) && c.payload !== '');
  assert.ok(ruleWrite, 'Rule2 must be written');
  assert.ok(ruleWrite.payload.includes('Clock#Timer=1'), 'rule must reference remapped physical slot 1');
  // Rule2 now contains our text; a second sync is a no-op on the rule.
});

test('syncDevice no-op: unchanged device yields synced with zero changes', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = deviceState();
  installFakeConfigChannel(state);
  const plan = compile({ deviceId: '34987AC30304', schedules: [dailySchedule()], device: deviceDoc });
  // Seed the device state at the allocated slots, and record them as managed
  // on the (sticky) fake device model.
  const actual = { timers: state.timers.map((t, i) => ({ index: i + 1, ...syncService.normalizeTimer(t) })), rules: state.rules };
  const alloc = syncService.allocateSlots(plan, actual, []);
  for (const timer of plan.timers) {
    const slot = alloc.allocation.get(timer.index);
    state.timers[slot - 1] = { ...state.timers[slot - 1], ...syncService.normalizeTimer({ ...timer.config }) };
  }
  const managed = alloc.managed;
  const stickyModel = {
    findOne: async ({ deviceId }) => ({ ...deviceDoc, scheduleSyncInfo: { managedTimerIndexes: managed, status: 'synced', lastSyncedAt: new Date(), error: null } }),
    updateOne: async (filter, update) => ({ ok: 1 }),
  };
  schedulesFixture = () => [dailySchedule()];
  const out = await syncService.syncDevice('34987AC30304', { deviceModel: stickyModel, scheduleModel: fakeScheduleModel });
  assert.strictEqual(out.status, 'synced');
  assert.deepStrictEqual(out.changedTimers, []);
  assert.deepStrictEqual(out.changedRules, []);
});

test('syncDevice returns unsupported when no safe managed slot is free', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = deviceState();
  for (let i = 0; i < 16; i++) {
    if (i + 1 === syncService.USER_TRIGGER_TIMER) continue;
    state.timers[i] = { ...defaultTimer(), Enable: 1, Time: '10:00', Days: '1111111', Action: 1, Output: 1 };
  }
  installFakeConfigChannel(state);
  schedulesFixture = () => [dailySchedule()];
  const out = await syncService.syncDevice('34987AC30304', { deviceModel: fakeDeviceModel, scheduleModel: fakeScheduleModel });
  assert.strictEqual(out.status, 'unsupported');
});

test('syncDevice hides scheduleSyncInfo writes behind the disabled flag too', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'false';
  const state = deviceState();
  installFakeConfigChannel(state);
  schedulesFixture = () => [dailySchedule()];
  let updated = false;
  const model = {
    findOne: async () => ({ ...deviceDoc }),
    updateOne: async () => {
      updated = true;
      return { ok: 1 };
    },
  };
  const out = await syncService.syncDevice('34987AC30304', { deviceModel: model, scheduleModel: fakeScheduleModel });
  assert.strictEqual(out.status, 'pending');
  assert.strictEqual(updated, false, 'no DB update should happen while the flag is off');
});