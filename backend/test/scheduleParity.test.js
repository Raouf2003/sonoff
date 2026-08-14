const { test } = require('node:test');
const assert = require('node:assert');
const { DateTime } = require('luxon');
const { compile } = require('../services/scheduleCompiler');
const { simulateCompiledPlan } = require('../services/scheduleSimulator');
const { referenceScheduleState } = require('../services/scheduleDryRunService');

const DEVICE = { deviceId: 'DEV1', channels: 4 };
let deterministicComparisonCount = 0;
const WEEK = Array.from({ length: 7 }, (_, dayOffset) =>
  DateTime.fromISO('2026-08-03T00:00:00Z').plus({ days: dayOffset }),
);
const BOUNDARY = [
  0, 1, 359, 360, 361, 419, 539, 540, 541, 629, 631, 719, 720, 721, 839, 899, 900, 901, 1079, 1080,
  1081, 1199, 1438, 1439,
];

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

const hhmm = (minutes) =>
  `${String(Math.floor(minutes / 60)).padStart(2, '0')}:${String(minutes % 60).padStart(2, '0')}`;

function probeMinutes(schedules) {
  const minutes = new Set(BOUNDARY);
  for (const range of (schedules || []).flatMap((s) => s.timeRanges || [])) {
    const toM = (value) => {
      const [h, m] = String(value).split(':').map(Number);
      return h * 60 + m;
    };
    const start = toM(range.start);
    const end = toM(range.end);
    const mid = start + Math.floor((end - start) / 2);
    for (const v of [start - 1, start, start + 1, mid, end - 1, end, end + 1]) {
      if (v >= 0 && v <= 1439) minutes.add(v);
    }
  }
  return Array.from(minutes).sort((a, b) => a - b);
}

function normalized({ expected, actual, deviceChannels }) {
  const result = { expected: {}, actual: {} };
  const keys = new Set([...Object.keys(expected || {}), ...Object.keys(actual || {})]);
  for (const key of keys) {
    if (Number(key) > deviceChannels) continue;
    result.expected[key] = expected[key] || 'OFF';
    result.actual[key] = actual[key] || 'OFF';
  }
  return result;
}

function mismatchReport(schedules, plan, dt, expected, actual, deviceChannels) {
  const view = normalized({ expected, actual, deviceChannels });
  return [
    'PARITY MISMATCH',
    `Schedules=${JSON.stringify(schedules)}`,
    `Compiled plan=${JSON.stringify(plan)}`,
    `Timestamp=${dt.toISO()}`,
    `Expected=${JSON.stringify(view.expected)}`,
    `Actual=${JSON.stringify(view.actual)}`,
  ].join('\n');
}

function assertParity(schedules, device = DEVICE) {
  const plan = compile({ deviceId: device.deviceId, schedules, device });
  const minutes = probeMinutes(schedules);
  let comparisons = 0;
  for (const day of WEEK) {
    for (const minute of minutes) {
      const dt = day.set({ hour: Math.floor(minute / 60), minute: minute % 60 });
      const expected = referenceScheduleState(schedules, dt);
      const actual = simulateCompiledPlan(plan, dt);
      comparisons++;
      const a = normalized({ expected, actual, deviceChannels: device.channels });
      if (JSON.stringify(a.expected) !== JSON.stringify(a.actual)) {
        assert.fail(mismatchReport(schedules, plan, dt, expected, actual, device.channels));
      }
    }
  }
  deterministicComparisonCount += comparisons;
  return comparisons;
}

test('parity: empty and all-disabled schedules', () => {
  assertParity([], DEVICE);
  assertParity([schedule({ enabled: false })], DEVICE);
});

test('parity: single channel single range daily', () => {
  assertParity([schedule()], DEVICE);
});

test('parity: boundary timestamps before/at/after boundaries', () => {
  assertParity([schedule({ timeRanges: [{ start: '06:00', end: '09:00' }] })], DEVICE);
});

test('parity: all seven weekdays', () => {
  assertParity([schedule()], DEVICE);
});

test('parity: custom weekdays restrict to those days', () => {
  for (const daysOfWeek of [[0], [1], [2], [3], [4], [5], [6], [0, 6]]) {
    assertParity([schedule({ recurrence: { type: 'custom', daysOfWeek } })], DEVICE);
  }
});

test('parity: monday/sunday mask verification', () => {
  assertParity([schedule({ recurrence: { type: 'custom', daysOfWeek: [0] } })], DEVICE);
  assertParity([schedule({ recurrence: { type: 'custom', daysOfWeek: [6] } })], DEVICE);
});

test('parity: multiple channels share one range (rule events)', () => {
  assertParity([schedule({ channels: [1, 2, 3, 4] })], DEVICE);
});

test('parity: overlapping schedules on the same channel merge', () => {
  assertParity(
    [
      schedule({ _id: 'a', timeRanges: [{ start: '06:00', end: '10:00' }] }),
      schedule({ _id: 'b', timeRanges: [{ start: '08:00', end: '12:00' }] }),
    ],
    DEVICE,
  );
});

test('parity: adjacent ranges stay continuous', () => {
  assertParity(
    [schedule({ timeRanges: [{ start: '06:00', end: '09:00' }, { start: '09:00', end: '12:00' }] })],
    DEVICE,
  );
});

test('parity: schedules on different channels group at shared boundaries', () => {
  assertParity(
    [
      schedule({ _id: 'a', channels: [1], timeRanges: [{ start: '06:00', end: '09:00' }] }),
      schedule({ _id: 'b', channels: [2], timeRanges: [{ start: '06:00', end: '09:00' }] }),
    ],
    DEVICE,
  );
});

test('parity: disjoint windows with gaps restore OFF', () => {
  assertParity(
    [schedule({ timeRanges: [{ start: '06:00', end: '07:00' }, { start: '18:00', end: '20:00' }] })],
    DEVICE,
  );
});

test('parity: one schedule covers two others on multiple channels', () => {
  assertParity(
    [
      schedule({ _id: 'a', channels: [1, 2], timeRanges: [{ start: '06:00', end: '12:00' }] }),
      schedule({ _id: 'b', channels: [1], timeRanges: [{ start: '08:00', end: '10:00' }] }),
    ],
    DEVICE,
  );
});

test('parity: the 16-timer boundary', () => {
  const ranges = [];
  for (let i = 0; i < 8; i++) {
    const start = i * 90;
    ranges.push({ start: hhmm(start), end: hhmm(start + 60) });
  }
  assertParity([schedule({ timeRanges: ranges })], DEVICE);
});

test('parity: custom weekday windows only active on their days', () => {
  assertParity(
    [
      schedule({
        _id: 'a',
        recurrence: { type: 'custom', daysOfWeek: [0, 2, 4] },
        timeRanges: [{ start: '06:00', end: '09:00' }],
      }),
      schedule({
        _id: 'b',
        recurrence: { type: 'custom', daysOfWeek: [1, 3, 5] },
        timeRanges: [{ start: '12:00', end: '15:00' }],
      }),
    ],
    DEVICE,
  );
});

test('parity: disabled schedules do not affect state', () => {
  assertParity(
    [
      schedule({ _id: 'a', enabled: false, timeRanges: [{ start: '06:00', end: '12:00' }] }),
      schedule({ _id: 'b', timeRanges: [{ start: '10:00', end: '11:00' }] }),
    ],
    DEVICE,
  );
});

function mulberry32(seed) {
  let a = seed >>> 0;
  return function next() {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function randomWindow(rng) {
  const start = Math.floor(rng() * 1430);
  const length = 1 + Math.floor(rng() * (1439 - start));
  return { start, end: start + length };
}

function randomSchedule(rng, idx) {
  const windows = [];
  const count = 1 + Math.floor(rng() * 3);
  for (let i = 0; i < count; i++) windows.push(randomWindow(rng));
  const custom = [0, 1, 2, 3, 4, 5, 6].filter(() => rng() < 0.5);
  const allDays = [0, 1, 2, 3, 4, 5, 6];
  const days = rng() < 0.5
    ? allDays
    : (custom.length ? custom : [Math.floor(rng() * 7)]);
  return {
    _id: `rand-${idx}-${rng().toFixed(6)}`,
    deviceId: 'DEV1',
    name: `rand-${idx}`,
    enabled: rng() < 0.9,
    channels: [1 + Math.floor(rng() * DEVICE.channels)],
    recurrence: { type: days.length === 7 ? 'daily' : 'custom', daysOfWeek: days },
    timeRanges: windows.map((w) => ({ start: hhmm(w.start), end: hhmm(w.end) })),
  };
}

test('parity: randomized comparison with fixed seed', (t) => {
  const rng = mulberry32(42);
  const sets = 100;
  const timestampsPerSet = 100;
  let comparisons = 0;
  let mismatches = 0;
  const failures = [];
  for (let set = 0; set < sets; set++) {
    const count = 1 + Math.floor(rng() * 3);
    const plans = Array.from({ length: count }, (_, i) => randomSchedule(rng, i));
    const plan = compile({ deviceId: 'DEV1', schedules: plans, device: DEVICE });
    for (let stamp = 0; stamp < timestampsPerSet; stamp++) {
      const dt = WEEK[Math.floor(rng() * 7)].set({
        hour: Math.floor(rng() * 24),
        minute: Math.floor(rng() * 60),
      });
      const expected = referenceScheduleState(plans, dt);
      const actual = simulateCompiledPlan(plan, dt);
      comparisons++;
      const a = normalized({ expected, actual, deviceChannels: DEVICE.channels });
      if (JSON.stringify(a.expected) !== JSON.stringify(a.actual)) {
        mismatches++;
        if (failures.length < 5) {
          failures.push(mismatchReport(plans, plan, dt, expected, actual, DEVICE.channels));
        }
      }
    }
  }
  assert.strictEqual(
    mismatches,
    0,
    failures.length ? failures.join('\n\n') : 'randomized parity produced no mismatches',
  );
  t.diagnostic(
    `randomized parity: ${sets} sets x ${timestampsPerSet} timestamps = ${comparisons} comparisons, ${mismatches} mismatches`,
  );
});

test('parity: totals for the report', (t) => {
  t.diagnostic(
    `deterministic parity: ${deterministicComparisonCount} timestamp comparisons, 0 mismatches`,
  );
});