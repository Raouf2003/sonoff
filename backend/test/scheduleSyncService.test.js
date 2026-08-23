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
      if (body) {
        // Model the real firmware: an invalid or missing timer Output is not
        // preserved verbatim - it normalizes to a valid output value (1 here).
        const merged = { ...state.timers[idx - 1], ...body };
        if (!Number.isInteger(merged.Output) || merged.Output < 1 || merged.Output > 16) {
          merged.Output = 1;
        }
        state.timers[idx - 1] = merged;
      }
      return Promise.resolve({ [key]: state.timers[idx - 1] });
    }
    if (/^Rule(\d+)$/.test(key)) {
      const idx = Number(key.slice(4));
      if (payload === '1' || payload === '0') {
        // Real Tasmota: `Rule<n> 1` enables, `Rule<n> 0` disables — the rule
        // TEXT is untouched. (Content writes are the non-numeric payloads.)
        state.rules[idx - 1] = {
          ...state.rules[idx - 1],
          State: payload === '1' ? 'ON' : 'OFF',
        };
      } else if (payload !== '' && payload !== undefined) {
        // Content write: stores the body. Model the observed real device:
        // this alone does NOT change State (stays whatever it was).
        state.rules[idx - 1] = { ...state.rules[idx - 1], Rules: String(payload), Length: String(payload).length };
      }
      return Promise.resolve({ [key]: state.rules[idx - 1] });
    }
    // Clock gate: a healthy NTP-synced device answers `Time` with current wall
    // time (this firmware exposes no Epoch) so ensureDeviceClock takes the
    // healthy path and never issues NtpServer writes in these fixtures.
    if (key === 'Time') {
      const { DateTime } = require('luxon');
      const now = DateTime.now().setZone('Africa/Algiers');
      return Promise.resolve({
        Time: now.toFormat('yyyy-MM-dd\'T\'HH:mm:ss'),
      });
    }
    // Timer-arm gate: healthy devices answer armed.
    if (key === 'Timers') {
      return Promise.resolve({ Timers: 'ON' });
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

test('fake config channel models firmware: invalid timer Output (0) reads back as 1, not 0', async () => {
  const state = deviceState();
  installFakeConfigChannel(state);
  const resp = await tasmotaConfigClient.requestTasmotaConfig('34987AC30304', 'Timer1', JSON.stringify({ ...defaultTimer(), Output: 0, Action: 3 }), { expectedResponseKey: 'Timer1' });
  assert.strictEqual(resp.Timer1.Output, 1, 'firmware must never preserve an invalid Output 0');
  // A valid Output (e.g. channel 2 on a direct timer) is preserved as-is.
  const resp2 = await tasmotaConfigClient.requestTasmotaConfig('34987AC30304', 'Timer2', JSON.stringify({ ...defaultTimer(), Output: 2, Action: 1 }), { expectedResponseKey: 'Timer2' });
  assert.strictEqual(resp2.Timer2.Output, 2);
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

test('a multi-channel plan with Action:3 timers verifies on the first attempt (no retry)', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = deviceState();
  const calls = installFakeConfigChannel(state);
  schedulesFixture = () => [
    dailySchedule({ name: 'multi', channels: [1, 2], timeRanges: [{ start: '07:00', end: '08:00' }] }),
  ];
  const out = await syncService.syncDevice('34987AC30304', { deviceModel: fakeDeviceModel, scheduleModel: fakeScheduleModel });
  assert.strictEqual(out.status, 'synced');
  assert.strictEqual(out.verificationPassed, true);
  assert.strictEqual(out.attempts, 1, 'Action:3 timers with canonical Output:1 must verify immediately');
  for (const v of out.verification) {
    assert.strictEqual(v.matches, true);
    if (v.resource.startsWith('Timer')) assert.strictEqual(v.actual.Output, 1);
  }
  const timerWrites = calls.filter((c) => /^Timer[12]$/.test(c.command) && c.payload !== '');
  for (const w of timerWrites) {
    assert.strictEqual(JSON.parse(w.payload).Output, 1, 'writes must send canonical Output 1');
  }
});

test('verification re-reads ONLY the written slots (Timer1, Timer2, Rule2), not all 19', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = deviceState();
  const calls = installFakeConfigChannel(state);
  schedulesFixture = () => [
    dailySchedule({ name: 'multi', channels: [1, 2], timeRanges: [{ start: '07:00', end: '08:00' }] }),
  ];
  const out = await syncService.syncDevice('34987AC30304', { deviceModel: fakeDeviceModel, scheduleModel: fakeScheduleModel });
  assert.strictEqual(out.status, 'synced');
  assert.deepStrictEqual(out.changedTimers.sort(), [1, 2]);
  assert.deepStrictEqual(out.changedRules, [2]);

  const reads = calls.filter((c) => c.payload === '').map((c) => c.command);
  const count = (name) => reads.filter((cmd) => cmd === name).length;

  // The full-state snapshot (initial read + allocation/diff) touches every slot exactly once.
  // Verification adds a SECOND read ONLY for the two written timers and Rule2.
  assert.strictEqual(count('Timer1'), 2, 'Timer1 read once for initial snapshot + once for verification');
  assert.strictEqual(count('Timer2'), 2, 'Timer2 read once for initial snapshot + once for verification');
  assert.strictEqual(count('Rule2'), 2, 'Rule2 read once for initial snapshot + once for verification');
  for (let i = 3; i <= 16; i++) {
    assert.strictEqual(count(`Timer${i}`), 1, `unchanged Timer${i} must only appear in the initial snapshot`);
  }
  assert.strictEqual(count('Rule1'), 1, 'unchanged Rule1 must only appear in the initial snapshot');
  assert.strictEqual(count('Rule3'), 1, 'unchanged Rule3 must only appear in the initial snapshot');
  // 19 initial + exactly 3 verification reads + clock (`Time`) + arm
  // (`Timers`) gate reads; nothing beyond the changed slots was re-read.
  assert.strictEqual(reads.length, 24, '19 initial + 3 verification + Time + Timers reads');
});

test('verification for a direct-only plan re-reads ONLY the written timers (no rule reads)', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = deviceState();
  const calls = installFakeConfigChannel(state);
  schedulesFixture = () => [dailySchedule()];
  const out = await syncService.syncDevice('34987AC30304', { deviceModel: fakeDeviceModel, scheduleModel: fakeScheduleModel });
  assert.strictEqual(out.status, 'synced');
  assert.deepStrictEqual(out.changedTimers.sort(), [1, 2]);
  assert.deepStrictEqual(out.changedRules, []);

  const reads = calls.filter((c) => c.payload === '').map((c) => c.command);
  const count = (name) => reads.filter((cmd) => cmd === name).length;

  assert.strictEqual(count('Timer1'), 2);
  assert.strictEqual(count('Timer2'), 2);
  assert.strictEqual(count('Rule2'), 1, 'Rule2 unchanged and never re-read during verification');
  for (let i = 3; i <= 16; i++) {
    assert.strictEqual(count(`Timer${i}`), 1, `unchanged Timer${i} read only in the initial snapshot`);
  }
  assert.strictEqual(reads.length, 23, '19 initial + 2 verification + Time + Timers reads');
});

test('readDeviceScheduleState can fetch a named subset without the full-state snapshot', async () => {
  const state = deviceState();
  const calls = installFakeConfigChannel(state);
  const out = await syncService.readDeviceScheduleState('34987AC30304', { timerIndexes: [1, 2], ruleIndexes: [2] });
  assert.strictEqual(out.timers.length, 2);
  assert.strictEqual(out.timers[0].index, 1);
  assert.strictEqual(out.timers[1].index, 2);
  assert.strictEqual(out.rules.length, 1);
  assert.strictEqual(out.rules[0].index, 2);
  const readCommands = calls.filter((c) => c.payload === '').map((c) => c.command).sort();
  assert.deepStrictEqual(readCommands, ['Rule2', 'Timer1', 'Timer2']);
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

// ---------------------------------------------------------------------------
// Per-device serialization gate (Phase 7B): overlapping full syncs for the same
// device must never interleave, while different devices stay fully parallel.
// ---------------------------------------------------------------------------

// Injectable models for an arbitrary deviceId (the shared fixtures above pin
// the device to 34987AC30304, which would collapse the two-device test).
function modelsFor(deviceId) {
  return {
    deviceModel: {
      findOne: async ({ deviceId: id }) => ({ deviceId: id, channels: 4 }),
      updateOne: async () => ({ ok: 1 }),
    },
    scheduleModel: {
      find: async ({ deviceId: id }) => [dailySchedule({ deviceId: id })],
    },
  };
}

// A Tasmota config channel whose replies are stalled until releaseAll(), so a
// test can observe exactly how many sync runs are in flight at any moment.
// Reads made before release are parked; reads made after release resolve
// immediately (so later queued runs never hang on the released gate).
function installDeferredConfigChannel(stateByDevice) {
  const calls = [];
  const waiters = [];
  let released = false;
  const reply = (deviceId, command, payload) => {
    const key = command;
    const state = stateByDevice[deviceId];
    if (/^Timer(\d+)$/.test(key)) {
      const idx = Number(key.slice(5));
      if (payload !== '' && payload !== undefined && state) {
        const merged = { ...state.timers[idx - 1], ...JSON.parse(payload) };
        if (!Number.isInteger(merged.Output) || merged.Output < 1 || merged.Output > 16) {
          merged.Output = 1;
        }
        state.timers[idx - 1] = merged;
      }
      return Promise.resolve({ [key]: state ? state.timers[idx - 1] : null });
    }
    if (/^Rule(\d+)$/.test(key)) {
      const idx = Number(key.slice(4));
      if (payload !== '' && payload !== undefined && state) {
        state.rules[idx - 1] = { ...state.rules[idx - 1], State: 'ON', Rules: String(payload), Length: String(payload).length };
      }
      return Promise.resolve({ [key]: state ? state.rules[idx - 1] : null });
    }
    return Promise.reject(new Error(`unhandled ${key}`));
  };
  mock.method(tasmotaConfigClient, 'requestTasmotaConfig', (deviceId, command, payload) => {
    calls.push({ deviceId, command, payload });
    if (released) return reply(deviceId, command, payload);
    return new Promise((resolve) => waiters.push(() => resolve(reply(deviceId, command, payload))));
  });
  return {
    calls,
    reads: () => calls.filter((c) => c.payload === ''),
    releaseAll: () => {
      released = true;
      const ws = waiters.splice(0);
      for (const w of ws) w();
    },
  };
}

test('rapid syncDevice calls for the same device serialize: one full run in flight until the prior finishes', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'false';
  const state = deviceState();
  const ch = installDeferredConfigChannel({ 'DEV-SER': state });

  const pA = syncService.syncDevice('DEV-SER', modelsFor('DEV-SER'));
  const pB = syncService.syncDevice('DEV-SER', modelsFor('DEV-SER'));
  const pC = syncService.syncDevice('DEV-SER', modelsFor('DEV-SER'));
  // Let the gate settle: only the FIRST run may be mid-read (19 Timer/Rule
  // reads). B and C are queued on the gate, not reading.
  await new Promise((r) => setTimeout(r, 0));
  assert.strictEqual(
    ch.reads().every((c) => c.deviceId === 'DEV-SER') ? ch.reads().length : 0,
    19,
    'exactly one full read pass is in flight; the later runs are gated',
  );

  ch.releaseAll();
  const [rA, rB, rC] = await Promise.all([pA, pB, pC]);
  for (const r of [rA, rB, rC]) {
    assert.strictEqual(r.status, 'pending');
  }
  // All three runs completed serially, never overlapping: 19 reads x 3 runs.
  assert.strictEqual(ch.reads().length, 19 * 3, 'all three runs ran to completion with no interleaving');
});

test('different devices sync fully in parallel: one device never blocks another', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'false';
  const stateA = deviceState();
  const stateB = deviceState();
  const ch = installDeferredConfigChannel({ 'DEV-A': stateA, 'DEV-B': stateB });

  const pA = syncService.syncDevice('DEV-A', modelsFor('DEV-A'));
  const pB = syncService.syncDevice('DEV-B', modelsFor('DEV-B'));
  await new Promise((r) => setTimeout(r, 0));
  // Both devices' full 19-read passes are in flight simultaneously: there is
  // no global lock and DEV-A's sync never queues behind DEV-B's.
  assert.strictEqual(ch.reads().filter((c) => c.deviceId === 'DEV-A').length, 19, 'DEV-A reads underway');
  assert.strictEqual(ch.reads().filter((c) => c.deviceId === 'DEV-B').length, 19, 'DEV-B reads underway in parallel');

  ch.releaseAll();
  const [rA, rB] = await Promise.all([pA, pB]);
  assert.strictEqual(rA.status, 'pending');
  assert.strictEqual(rB.status, 'pending');
});

// ---------------------------------------------------------------------------
// Diagnostic trace (observability only - no behavior change)
// ---------------------------------------------------------------------------

// Capture the diagnostic [SYNC ...] log lines emitted by syncDevice while the
// trace is enabled. A capture logger is injected via options.logger so tests
// assert on traceIds WITHOUT touching the real console.
function makeCaptureLogger() {
  const lines = [];
  const logger = {
    log: (m) => lines.push(String(m)),
    error: () => {},
    warn: () => {},
    info: () => {},
  };
  return { lines, logger };
}

test('three independent syncDevice invocations receive distinct traceIds', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'false';
  const state = deviceState();
  installFakeConfigChannel(state);
  schedulesFixture = () => [dailySchedule()];
  const { lines, logger } = makeCaptureLogger();
  const opts = { deviceModel: fakeDeviceModel, scheduleModel: fakeScheduleModel, logger };
  await Promise.all([
    syncService.syncDevice('34987AC30304', opts),
    syncService.syncDevice('34987AC30304', opts),
    syncService.syncDevice('34987AC30304', opts),
  ]);
  const enters = lines.filter((l) => l.includes('[SYNC ENTER]'));
  assert.strictEqual(enters.length, 3, 'one ENTER per invocation');
  const ids = enters.map((l) => /traceId=(\S+)/.exec(l)[1]);
  assert.strictEqual(new Set(ids).size, 3, 'each invocation must get a distinct traceId');
});

test('retries inside one invocation share a single traceId across all attempts', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = deviceState();
  // Sabotage readback: any Timer write returns an Enable:0 (verification fails),
  // forcing the bounded retry loop to run all MAX_SYNC_ATTEMPTS attempts.
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
  const { lines, logger } = makeCaptureLogger();
  const out = await syncService.syncDevice('34987AC30304', {
    deviceModel: fakeDeviceModel,
    scheduleModel: fakeScheduleModel,
    logger,
  });
  assert.strictEqual(out.status, 'failed');
  assert.strictEqual(out.attempts, syncService.MAX_SYNC_ATTEMPTS);
  const enters = lines.filter((l) => l.includes('[SYNC ENTER]'));
  const exits = lines.filter((l) => l.includes('[SYNC EXIT]'));
  const attempts = lines.filter((l) => l.includes('[SYNC ATTEMPT]'));
  assert.strictEqual(enters.length, 1, 'exactly ONE invocation');
  assert.strictEqual(exits.length, 1, 'exactly ONE exit');
  assert.strictEqual(attempts.length, syncService.MAX_SYNC_ATTEMPTS, 'all retry attempts logged');
  const enterId = /traceId=(\S+)/.exec(enters[0])[1];
  for (const a of attempts) {
    assert.strictEqual(/traceId=(\S+)/.exec(a)[1], enterId, 'every attempt shares the invocation traceId');
  }
  const mismatch = lines.filter((l) => l.includes('[SYNC VERIFY MISMATCH]'));
  assert.ok(mismatch.length > 0, 'verification mismatches must be logged with a field-level diff');
  assert.ok(mismatch.every((l) => l.includes('diff={')), 'mismatch logs must include the exact field diff');
});

test('manualSync forwards source=manual-sync into the trace log', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'false';
  const state = deviceState();
  installFakeConfigChannel(state);
  schedulesFixture = () => [dailySchedule()];
  const { lines, logger } = makeCaptureLogger();
  await syncService.manualSync('34987AC30304', {
    deviceModel: fakeDeviceModel,
    scheduleModel: fakeScheduleModel,
    logger,
    source: 'manual-sync',
  });
  const enter = lines.find((l) => l.includes('[SYNC ENTER]'));
  assert.ok(enter, 'ENTER log expected');
  assert.ok(enter.includes('source=manual-sync'), 'manualSync must propagate source=manual-sync');
});

test('a failed sync in the middle of a same-device queue does not poison the next sync', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'false';
  const state = deviceState();
  const calls = [];
  let readNumber = 0;
  mock.method(tasmotaConfigClient, 'requestTasmotaConfig', (deviceId, command, payload) => {
    const key = command;
    calls.push({ deviceId, command, payload });
    const respond = () => {
      if (/^Timer(\d+)$/.test(key)) return Promise.resolve({ [key]: state.timers[Number(key.slice(5)) - 1] });
      if (/^Rule(\d+)$/.test(key)) return Promise.resolve({ [key]: state.rules[Number(key.slice(4)) - 1] });
      return Promise.reject(new Error(`unhandled ${key}`));
    };
    if (payload === '' || payload === undefined) {
      readNumber += 1;
      // Fail the ENTIRE SECOND run (read pass #20..38); runs 1 and 3 stay intact.
      if (readNumber > 19 && readNumber <= 38) {
        return Promise.reject(new Error('simulated read failure'));
      }
    }
    return respond();
  });

  const m = modelsFor('DEV-FAIL');
  const pA = syncService.syncDevice('DEV-FAIL', m);
  const pB = syncService.syncDevice('DEV-FAIL', m);
  const pC = syncService.syncDevice('DEV-FAIL', m);
  const [rA, rB, rC] = await Promise.all([pA, pB, pC]);

  assert.strictEqual(rA.status, 'pending', 'first sync succeeds');
  assert.strictEqual(rB.status, 'failed', 'middle sync fails');
  assert.match(rB.error, /simulated read failure/);
  assert.strictEqual(rC.status, 'pending', 'third sync must still run despite the middle failure');
  assert.strictEqual(calls.filter((c) => c.payload === '').length, 19 * 3, 'all three runs completed in order');

  // The queue must remain usable for the NEXT sync after a failure.
  const rD = await syncService.syncDevice('DEV-FAIL', m);
  assert.strictEqual(rD.status, 'pending', 'future sync works after a previous failure');
});

// ---------------------------------------------------------------------------
// Rule2 ownership recognition (isSteesOwnedRule2): pattern-based, not
// byte-exact. A Rule2 authored by ANY STEES compiler revision must be
// recognized as ours and safely overwritten; genuinely foreign content must
// still hard-fail with "Rule2 is not free".
// ---------------------------------------------------------------------------

// Legacy compiler output: ';' separators WITHOUT spaces (as found live on
// device 34987AC30304), referencing previously-managed slots 1 and 2.
const LEGACY_RULE2_TEXT =
  'ON Clock#Timer=1 DO Backlog Power1 ON;Power2 ON;Power3 ON ENDON ' +
  'ON Clock#Timer=2 DO Backlog Power1 OFF;Power2 OFF;Power3 OFF ENDON';

const multiChannelSchedule = () =>
  dailySchedule({
    name: 'تز',
    channels: [1, 2, 3],
    timeRanges: [{ start: '18:40', end: '23:59' }],
  });

// Device holding the STALE legacy STEES state: old-format Rule2 (State ON),
// old 16:47/16:48 timer configs in the sticky-managed slots 1/2.
function staleLegacyActual({ ruleText = LEGACY_RULE2_TEXT, managed = [1, 2], extraOccupiedSlot = null } = {}) {
  const base = deviceState();
  const timers = base.timers.map((t, i) => ({ index: i + 1, ...syncService.normalizeTimer(t) }));
  const oldSteesTimer = (time) =>
    syncService.normalizeTimer({ Enable: 1, Mode: 0, Time: time, Window: 0, Days: '1111111', Repeat: 1, Output: 1, Action: 3 });
  timers[0] = { index: 1, ...oldSteesTimer('16:47') };
  timers[1] = { index: 2, ...oldSteesTimer('16:48') };
  if (extraOccupiedSlot !== null) {
    // A user-authored timer occupying an unrelated slot (unmanaged by STEES).
    timers[extraOccupiedSlot - 1] = {
      index: extraOccupiedSlot,
      ...syncService.normalizeTimer({ Enable: 1, Time: '09:00', Days: '1111111', Repeat: 1, Output: 2, Action: 1 }),
    };
  }
  const rules = base.rules.map((r) => ({ ...r }));
  rules[1] = { index: 2, State: 'ON', Once: 'OFF', StopOnError: 'OFF', Length: ruleText.length, Free: 511 - ruleText.length, Rules: ruleText };
  return { timers, rules, managed };
}

function multiChannelPlan() {
  return compile({ deviceId: '34987AC30304', schedules: [multiChannelSchedule()], device: deviceDoc });
}

test('isSteesOwnedRule2: legacy no-space STEES text over managed slots is recognized as ours', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = deviceState();
  // Seed the stale legacy world directly into the fake device.
  const legacy = staleLegacyActual();
  for (let i = 0; i < 16; i++) {
    const { index, ...plain } = legacy.timers[i];
    state.timers[i] = plain;
  }
  state.rules[1] = { ...legacy.rules[1] };

  installFakeConfigChannel(state);
  schedulesFixture = () => [multiChannelSchedule()];
  const ownedDeviceModel = {
    findOne: async ({ deviceId }) => ({
      ...deviceDoc,
      // Sticky ownership recorded by earlier successful syncs: slots 1/2.
      scheduleSyncInfo: { managedTimerIndexes: [1, 2], status: 'synced', lastSyncedAt: new Date(), error: null },
    }),
    updateOne: async () => ({ ok: 1 }),
  };
  const out = await syncService.syncDevice('34987AC30304', {
    deviceModel: ownedDeviceModel,
    scheduleModel: fakeScheduleModel,
  });
  assert.strictEqual(out.status, 'synced', `expected synced, got ${out.status}: ${out.error}`);
  assert.strictEqual(out.verificationPassed, true);
  assert.deepStrictEqual(out.changedTimers.slice().sort(), [1, 2], 'stale 16:47/16:48 timers must be rewritten');
  assert.deepStrictEqual(out.changedRules, [2], 'Rule2 must be recognized as ours and rewritten');
  assert.ok(out.verification.every((v) => v.matches === true), 'every resource must verify');
  assert.strictEqual(state.timers[0].Time, '18:40');
  assert.strictEqual(state.timers[1].Time, '23:59');
  const ruleWrite = out.intendedWrites.find((w) => w.kind === 'rule');
  assert.ok(ruleWrite, 'a Rule2 write was intended');
  assert.strictEqual(state.rules[1].Rules, ruleWrite.text, 'device now holds the exact new compiled text');
  assert.ok(ruleWrite.text.includes('; Power2 ON'), 'new text uses current "; " spacing (rewrite happened)');
  assert.strictEqual(String(state.rules[1].State).toUpperCase(), 'ON');
});
test('isSteesOwnedRule2: foreign Energy#Total rule is still rejected as not free', () => {
  const plan = multiChannelPlan();
  const foreign = 'ON Energy#Total>75 DO Power1 OFF ENDON';
  const a = staleLegacyActual({ ruleText: foreign });
  const actual = { timers: a.timers, rules: a.rules };
  const result = syncService.computeWrites(plan, actual, a.managed);
  assert.strictEqual(result.okay, false);
  assert.ok(result.unsupportedReasons.includes('Rule2 is not free'));
  assert.ok(result.conflicts.some((c) => c.includes('occupied by user configuration')));
});

test('isSteesOwnedRule2: STEES grammar pointing at user Timer3 is rejected', () => {
  const plan = multiChannelPlan();
  const a = staleLegacyActual({ ruleText: 'ON Clock#Timer=3 DO Power1 ON ENDON' });
  const actual = { timers: a.timers, rules: a.rules };
  const result = syncService.computeWrites(plan, actual, a.managed);
  assert.strictEqual(result.okay, false);
  assert.ok(result.unsupportedReasons.includes('Rule2 is not free'), 'slot 3 is never STEES-managed or default-free');
});

test('isSteesOwnedRule2: STEES grammar driving an unmanaged occupied slot is rejected', () => {
  const plan = multiChannelPlan();
  // Slot 7 holds a user timer (non-default) and is absent from managed [1,2].
  const a = staleLegacyActual({ ruleText: 'ON Clock#Timer=7 DO Power1 ON ENDON', extraOccupiedSlot: 7 });
  const actual = { timers: a.timers, rules: a.rules };
  const result = syncService.computeWrites(plan, actual, a.managed);
  assert.strictEqual(result.okay, false);
  assert.ok(result.unsupportedReasons.includes('Rule2 is not free'));
});

test('isSteesOwnedRule2: mixed STEES clause + foreign tail fails full-consumption check', () => {
  const plan = multiChannelPlan();
  const mixed = LEGACY_RULE2_TEXT + ' ON Sys#Boot DO Power4 ON ENDON';
  const a = staleLegacyActual({ ruleText: mixed });
  const actual = { timers: a.timers, rules: a.rules };
  const result = syncService.computeWrites(plan, actual, a.managed);
  assert.strictEqual(result.okay, false);
  assert.ok(result.unsupportedReasons.includes('Rule2 is not free'));
});

test('protectedResources stops listing a recognized STEES Rule2 but still lists foreign content', () => {
  const ours = staleLegacyActual(); // legacy text over managed slots
  const protectedOurs = syncService.protectedResources(
    { timers: ours.timers, rules: ours.rules },
    ours.managed,
  );
  assert.deepStrictEqual(
    protectedOurs.rules.map((r) => r.index),
    [1, 3],
    'recognized Rule2 must NOT be reported as occupied-by-user-config',
  );

  const foreign = 'ON Rules#Created=1 DO Power1 ON ENDON';
  const theirs = staleLegacyActual({ ruleText: foreign });
  const protectedTheirs = syncService.protectedResources(
    { timers: theirs.timers, rules: theirs.rules },
    theirs.managed,
  );
  assert.ok(
    protectedTheirs.rules.some((r) => r.index === 2 && r.reason === 'occupied by user config'),
    'foreign Rule2 must still be reported as protected',
  );
});

// ---------------------------------------------------------------------------
// Orphan-slot cleanup (plan-shrink / deletion): previously-managed timer slots
// that a smaller plan no longer uses must be reset to factory default,
// VERIFIED on-device, and dropped from Device.scheduleSyncInfo.
// Mirrors live evidence from 34987AC30304: slots 1/2/6/7 managed, schedules
// deleted -> Timer6/Timer7 stayed armed forever.
// ---------------------------------------------------------------------------

function liveEvidenceState() {
  const state = deviceState();
  const st = (time) => ({ Enable: 1, Mode: 0, Time: time, Window: 0, Days: '1111111', Repeat: 1, Output: 1, Action: 3 });
  state.timers[0] = st('16:47'); // Timer1
  state.timers[1] = st('16:48'); // Timer2
  state.timers[5] = st('20:16'); // Timer6 (orphan candidate)
  state.timers[6] = st('20:20'); // Timer7 (orphan candidate)
  state.rules[1] = {
    index: 2, State: 'ON', Once: 'OFF', StopOnError: 'OFF',
    Rules:
      'ON Clock#Timer=1 DO Backlog Power1 ON; Power2 ON ENDON ' +
      'ON Clock#Timer=2 DO Backlog Power1 OFF; Power2 OFF ENDON ' +
      'ON Clock#Timer=6 DO Backlog Power1 ON ENDON ' +
      'ON Clock#Timer=7 DO Backlog Power1 OFF ENDON',
  };
  return state;
}

const MANAGED_4 = [1, 2, 6, 7];

function recordingOwnedModel(managed) {
  const updates = [];
  return {
    updates,
    deviceModel: {
      findOne: async ({ deviceId }) => ({
        ...deviceDoc,
        scheduleSyncInfo: { managedTimerIndexes: managed.slice(), status: 'synced', lastSyncedAt: new Date(), error: null },
      }),
      updateOne: async (filter, update) => { updates.push(update); return { ok: 1 }; },
    },
  };
}

test('plan shrink: orphaned managed slots 6/7 are cleared to factory default, verified, and dropped from ownership', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = liveEvidenceState();
  installFakeConfigChannel(state);
  schedulesFixture = () => [dailySchedule({ channels: [1, 2], timeRanges: [{ start: '18:40', end: '23:59' }] })];
  const rec = recordingOwnedModel(MANAGED_4);
  const out = await syncService.syncDevice('34987AC30304', {
    deviceModel: rec.deviceModel,
    scheduleModel: fakeScheduleModel,
  });
  assert.strictEqual(out.status, 'synced', `got ${out.status}: ${out.error}`);
  assert.strictEqual(out.verificationPassed, true);
  // Slots 1/2 rewritten to the new window; slots 6/7 reset as orphans.
  assert.deepStrictEqual(out.changedTimers.slice().sort(), [1, 2, 6, 7]);
  assert.deepStrictEqual(out.changedRules, [2], 'shrunk Rule2 text is rewritten');
  const clearVerifies = out.verification.filter((v) => ['Timer6', 'Timer7'].includes(v.resource));
  assert.strictEqual(clearVerifies.length, 2, 'cleared slots must be read back, not assumed');
  for (const v of clearVerifies) {
    assert.strictEqual(v.matches, true);
    assert.deepStrictEqual(v.desired, syncService.FACTORY_DEFAULT_TIMER);
  }
  // Physical (simulated) confirmation: Enable 0, factory fields restored.
  for (const idx of [5, 6]) {
    assert.strictEqual(state.timers[idx].Enable, 0);
    assert.strictEqual(state.timers[idx].Time, '00:00');
    assert.strictEqual(state.timers[idx].Days, '0000000');
    assert.strictEqual(state.timers[idx].Action, 0);
    assert.strictEqual(state.timers[idx].Output, 1);
  }
  // Ownership shrinks to exactly the active set.
  assert.strictEqual(rec.updates.length, 1);
  assert.deepStrictEqual(rec.updates[0].$set.scheduleSyncInfo.managedTimerIndexes.sort(), [1, 2]);
});

test('zero schedules left: every previously-managed slot is cleared and ownership empties', async () => {
  process.env.TASMOTA_SCHEDULE_SYNC_ENABLED = 'true';
  const state = liveEvidenceState();
  installFakeConfigChannel(state);
  schedulesFixture = () => [];
  const rec = recordingOwnedModel(MANAGED_4);
  const out = await syncService.syncDevice('34987AC30304', {
    deviceModel: rec.deviceModel,
    scheduleModel: fakeScheduleModel,
  });
  assert.strictEqual(out.status, 'synced', `got ${out.status}: ${out.error}`);
  assert.deepStrictEqual(out.changedTimers.slice().sort(), [1, 2, 6, 7], 'all four managed slots must be cleared');
  assert.strictEqual(out.changedRules.length, 0, 'no plan -> no Rule2 rewrite (residual text is inert once timers are disarmed)');
  assert.ok(out.verification.length >= 4 && out.verification.every((v) => v.matches === true));
  for (const idx of [0, 1, 5, 6]) {
    assert.strictEqual(state.timers[idx].Enable, 0, `Timer${idx + 1} must be disarmed`);
  }
  assert.deepStrictEqual(rec.updates[0].$set.scheduleSyncInfo.managedTimerIndexes, []);
});

test('computeWrites: orphan cleanup emits factory-default clears only when needed (idempotent)', () => {
  const plan = compile({ deviceId: '34987AC30304', schedules: [dailySchedule()], device: deviceDoc });
  // World A: orphan slot 7 holds an armed stale timer -> clear emitted.
  const a = deviceState();
  a.timers[6] = { Enable: 1, Mode: 0, Time: '20:20', Window: 0, Days: '1111111', Repeat: 1, Output: 1, Action: 3 };
  const actualA = { timers: a.timers.map((t, i) => ({ index: i + 1, ...syncService.normalizeTimer(t) })), rules: a.rules };
  const resA = syncService.computeWrites(plan, actualA, [1, 2, 7]);
  const clears = resA.writes.filter((w) => w.index === 7);
  assert.strictEqual(clears.length, 1);
  assert.deepStrictEqual(clears[0].desired, syncService.FACTORY_DEFAULT_TIMER);
  // World B: orphan already factory-default -> NO clear write (idempotent).
  const b = deviceState();
  const actualB = { timers: b.timers.map((t, i) => ({ index: i + 1, ...syncService.normalizeTimer(t) })), rules: b.rules };
  const resB = syncService.computeWrites(plan, actualB, [1, 2, 7]);
  assert.strictEqual(resB.writes.filter((w) => w.index === 7).length, 0);
});
