const { test } = require('node:test');
const assert = require('node:assert');
const {
  buildDryRun,
  dryRunForDevice,
  buildPreview,
  referenceScheduleState,
} = require('../services/scheduleDryRunService');
const { simulateCompiledPlan } = require('../services/scheduleSimulator');
const { DateTime } = require('luxon');

const DEVICE = { deviceId: 'DEV1', channels: 4 };

const hhmm = (minutes) =>
  `${String(Math.floor(minutes / 60)).padStart(2, '0')}:${String(minutes % 60).padStart(2, '0')}`;

function schedule(overrides = {}) {
  return {
    _id: 's1',
    deviceId: 'DEV1',
    name: 'sched',
    enabled: true,
    channels: [1],
    recurrence: { type: 'daily', daysOfWeek: [] },
    timeRanges: [{ start: '06:00', end: '09:00' }],
    ...overrides,
  };
}

test('dry-run result has the documented shape', () => {
  const now = new Date('2026-08-03T10:00:00Z');
  const dry = buildDryRun({ deviceId: 'DEV1', schedules: [schedule()], device: DEVICE, now });
  assert.strictEqual(dry.deviceId, 'DEV1');
  assert.strictEqual(dry.generatedAt, now.toISOString());
  assert.strictEqual(dry.compiler.supported, true);
  assert.strictEqual(dry.compiler.requiredTimerCount, 2);
  assert.strictEqual(dry.compiler.ruleCount, 0);
  assert.deepStrictEqual(dry.compiler.ruleLengths, {});
  assert.deepStrictEqual(dry.compiler.unsupportedReasons, []);
  assert.deepStrictEqual(dry.compiler.conflicts, []);
  assert.ok(Array.isArray(dry.plan.timers));
  assert.ok(Array.isArray(dry.plan.rules));
});

test('dry-run result is JSON-safe (no Sets/Maps/Dates)', () => {
  const dry = buildDryRun({
    deviceId: 'DEV1',
    schedules: [schedule({ channels: [1, 2] })],
    device: DEVICE,
  });
  const json = JSON.stringify(dry);
  assert.ok(json.length > 0);
  const parsed = JSON.parse(json);
  assert.strictEqual(parsed.deviceId, 'DEV1');
  assert.ok(Array.isArray(parsed.plan.timers));
  assert.ok(Array.isArray(parsed.plan.rules));
});

test('dry-run reports unsupported reasons and rule lengths for rule plans', () => {
  const ranges = [];
  for (let i = 0; i < 9; i++) {
    ranges.push({ start: hhmm(i * 30), end: hhmm(i * 30 + 15) });
  }
  const dry = buildDryRun({
    deviceId: 'DEV1',
    schedules: [schedule({ timeRanges: ranges })],
    device: DEVICE,
  });
  assert.strictEqual(dry.compiler.supported, false);
  assert.ok(dry.compiler.unsupportedReasons.some((r) => r.startsWith('Requires 18 timers')));

  const multi = buildDryRun({
    deviceId: 'DEV1',
    schedules: [schedule({ channels: [1, 2] })],
    device: DEVICE,
  });
  assert.strictEqual(multi.compiler.ruleCount, 1);
  assert.ok(multi.compiler.ruleLengths.rule1 > 0);
  assert.strictEqual(typeof multi.compiler.ruleLengths.rule1, 'number');
});

test('dry-run is pure when schedules and device are passed in', async () => {
  let scheduleCalls = 0;
  let deviceCalls = 0;
  const fakeScheduleModel = {
    find: async () => {
      scheduleCalls++;
      return [schedule()];
    },
  };
  const fakeDeviceModel = {
    findOne: async () => {
      deviceCalls++;
      return DEVICE;
    },
  };
  const dry = await dryRunForDevice('DEV1', {
    deviceModel: fakeDeviceModel,
    scheduleModel: fakeScheduleModel,
  });
  assert.strictEqual(scheduleCalls, 1);
  assert.strictEqual(deviceCalls, 1);
  assert.strictEqual(dry.deviceId, 'DEV1');
  assert.strictEqual(dry.compiler.supported, true);
});

test('preview output includes timers, rule text, counts, and parity mismatches', () => {
  const preview = buildPreview({
    deviceId: 'DEV1',
    schedules: [schedule({ channels: [1, 2] })],
    device: DEVICE,
  });
  assert.strictEqual(preview.deviceId, 'DEV1');
  assert.strictEqual(preview.timerCount, 2);
  assert.ok(typeof preview.rule1 === 'string' && preview.rule1.length > 0);
  assert.ok(preview.ruleCharacterCount > 0);
  assert.strictEqual(preview.supported, true);
  assert.deepStrictEqual(preview.unsupportedReasons, []);
  assert.strictEqual(preview.parity.sampleCount, 7 * 15);
  assert.deepStrictEqual(preview.parity.mismatches, []);
  assert.ok(Array.isArray(preview.timers));
});

test('referenceScheduleState matches the real engine per schedule', () => {
  const dt = DateTime.local(2026, 8, 4, 7, 0);
  const state = referenceScheduleState([schedule()], dt);
  assert.deepStrictEqual(state, { 1: 'ON' });
  const off = referenceScheduleState([schedule()], DateTime.local(2026, 8, 4, 5, 59));
  assert.deepStrictEqual(off, { 1: 'OFF' });
});

test('simulating the compiled plan reproduces the reference state', () => {
  const schedules = [schedule({ channels: [1, 2], timeRanges: [{ start: '06:00', end: '09:00' }] })];
  const dry = buildDryRun({ deviceId: 'DEV1', schedules, device: DEVICE });
  const dt = DateTime.local(2026, 8, 4, 8, 0);
  const simulated = simulateCompiledPlan(dry.plan, dt);
  const reference = referenceScheduleState(schedules, dt);
  assert.deepStrictEqual(simulated, reference);
  const after = DateTime.local(2026, 8, 4, 9, 30);
  assert.deepStrictEqual(simulateCompiledPlan(dry.plan, after), referenceScheduleState(schedules, after));
});