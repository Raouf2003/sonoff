const { test } = require('node:test');
const assert = require('node:assert');
const { compile, MAX_TIMERS, MAX_RULE_LENGTH, daysMask } = require('../services/scheduleCompiler');

const DEVICE = { deviceId: 'DEV1', channels: 4 };

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

function build(schedules, device = DEVICE) {
  return compile({ deviceId: 'DEV1', schedules, device });
}

// 1. Single channel, single range
test('single channel single range compiles to two direct timers with no rules', () => {
  const plan = build([schedule()]);
  assert.strictEqual(plan.requiredTimerCount, 2);
  assert.deepStrictEqual(plan.timers[0].config, {
    Enable: 1, Mode: 0, Time: '06:00', Window: 0, Days: '1111111', Repeat: 1, Action: 1, Output: 1,
  });
  assert.deepStrictEqual(plan.timers[1].config, {
    Enable: 1, Mode: 0, Time: '09:00', Window: 0, Days: '1111111', Repeat: 1, Action: 0, Output: 1,
  });
  assert.deepStrictEqual(plan.rules, []);
  assert.deepStrictEqual(plan.unsupportedReasons, []);
});

// 2. Multiple channels, same range -> grouped into one ON + one OFF rule event
test('multiple channels in the same range are grouped into rule events', () => {
  const plan = build([schedule({ channels: [1, 2] })]);
  assert.strictEqual(plan.requiredTimerCount, 2);
  assert.strictEqual(plan.timers[0].config.Action, 3);
  assert.strictEqual(plan.timers[1].config.Action, 3);
  for (const timer of plan.timers) {
    assert.strictEqual(timer.config.Output, 1, 'Action:3 rule timers must carry the valid canonical Output value 1');
  }
  assert.deepStrictEqual(plan.timers[0].event.on, [1, 2]);
  assert.deepStrictEqual(plan.timers[1].event.off, [1, 2]);
  assert.strictEqual(plan.rules.length, 1);
  assert.ok(plan.rules[0].text.includes('ON Clock#Timer=1 DO Backlog Power1 ON; Power2 ON ENDON'));
  assert.ok(plan.rules[0].text.includes('ON Clock#Timer=2 DO Backlog Power1 OFF; Power2 OFF ENDON'));
});

// 3. Multiple ranges
test('multiple ranges produce one ON/OFF pair per range', () => {
  const plan = build([
    schedule({ timeRanges: [{ start: '06:00', end: '09:00' }, { start: '17:00', end: '19:00' }] }),
  ]);
  assert.strictEqual(plan.requiredTimerCount, 4);
  assert.deepStrictEqual(plan.timers.map((t) => t.config.Time), ['06:00', '09:00', '17:00', '19:00']);
});

// 4. Daily recurrence -> all-days mask
test('daily recurrence expands to every day (Days 1111111)', () => {
  const plan = build([schedule()]);
  for (const timer of plan.timers) {
    assert.strictEqual(timer.config.Days, '1111111');
  }
});

// 5. Custom weekdays
test('custom weekdays map into the SMTWTFS mask', () => {
  const plan = build([
    schedule({ recurrence: { type: 'custom', daysOfWeek: [1, 3] } }),
  ]);
  assert.strictEqual(plan.requiredTimerCount, 2);
  for (const timer of plan.timers) {
    assert.strictEqual(timer.config.Days, '0010100', 'Tue + Thu only');
  }
});

// 6. Monday / Sunday day mapping
test('Monday maps to position 1 and Sunday to position 0 of the mask', () => {
  const monday = build([schedule({ recurrence: { type: 'custom', daysOfWeek: [0] } })]);
  assert.strictEqual(daysMask([0]), '0100000');
  for (const timer of monday.timers) assert.strictEqual(timer.config.Days, '0100000');

  const sunday = build([schedule({ recurrence: { type: 'custom', daysOfWeek: [6] } })]);
  assert.strictEqual(daysMask([6]), '1000000');
  for (const timer of sunday.timers) assert.strictEqual(timer.config.Days, '1000000');
});

// 7. Overlapping ranges merge into a single window
test('overlapping ranges are merged (06-09 + 08-12 -> 06-12)', () => {
  const plan = build([
    schedule({ timeRanges: [{ start: '06:00', end: '09:00' }, { start: '08:00', end: '12:00' }] }),
  ]);
  assert.strictEqual(plan.requiredTimerCount, 2);
  assert.deepStrictEqual(plan.timers.map((t) => t.config.Time), ['06:00', '12:00']);
});

// 8. Adjacent ranges do not produce a spurious boundary
test('adjacent ranges (06-09 + 09-12) stay continuous with no event at 09:00', () => {
  const plan = build([
    schedule({ timeRanges: [{ start: '06:00', end: '09:00' }, { start: '09:00', end: '12:00' }] }),
  ]);
  assert.strictEqual(plan.requiredTimerCount, 2);
  assert.deepStrictEqual(plan.timers.map((t) => t.config.Time), ['06:00', '12:00']);
});

// 9. Multiple schedules affecting the same channel merge
test('two schedules on the same channel merge into one window', () => {
  const plan = build([
    schedule({ _id: 'a', timeRanges: [{ start: '06:00', end: '09:00' }] }),
    schedule({ _id: 'b', timeRanges: [{ start: '08:00', end: '11:00' }] }),
  ]);
  assert.strictEqual(plan.requiredTimerCount, 2);
  assert.deepStrictEqual(plan.timers.map((t) => t.config.Time), ['06:00', '11:00']);
});

// 10. Multiple schedules on multiple channels group at shared boundaries
test('schedules on different channels with the same window share one event', () => {
  const plan = build([
    schedule({ _id: 'a', channels: [1], timeRanges: [{ start: '06:00', end: '09:00' }] }),
    schedule({ _id: 'b', channels: [2], timeRanges: [{ start: '06:00', end: '09:00' }] }),
  ]);
  assert.strictEqual(plan.requiredTimerCount, 2);
  assert.deepStrictEqual(plan.timers[0].event.on, [1, 2]);
  assert.deepStrictEqual(plan.timers[0].event.off, []);
  assert.deepStrictEqual(plan.timers[1].event.off, [1, 2]);
  assert.strictEqual(plan.timers[0].config.Action, 3);
  assert.strictEqual(plan.rules.length, 1);
});

// 11. Exactly the 16-timer limit fits
test('exactly 16 timers fits without unsupported reasons', () => {
  const ranges = [];
  for (let i = 0; i < 8; i++) {
    const start = i * 30;
    const pad = (n) => String(n).padStart(2, '0');
    ranges.push({ start: `${pad(Math.floor(start / 60))}:${pad(start % 60)}`, end: `${pad(Math.floor((start + 15) / 60))}:${pad((start + 15) % 60)}` });
  }
  const plan = build([schedule({ timeRanges: ranges })]);
  assert.strictEqual(plan.requiredTimerCount, MAX_TIMERS);
  assert.strictEqual(plan.requiredTimerCount, 16);
  assert.deepStrictEqual(plan.unsupportedReasons, []);
});

// 12. More than 16 timers -> unsupported
test('more than 16 timers is reported as unsupported', () => {
  const ranges = [];
  for (let i = 0; i < 9; i++) {
    const start = i * 30;
    const pad = (n) => String(n).padStart(2, '0');
    ranges.push({ start: `${pad(Math.floor(start / 60))}:${pad(start % 60)}`, end: `${pad(Math.floor((start + 15) / 60))}:${pad((start + 15) % 60)}` });
  }
  const plan = build([schedule({ timeRanges: ranges })]);
  assert.ok(plan.requiredTimerCount > MAX_TIMERS);
  assert.ok(
    plan.unsupportedReasons.some((r) => r.startsWith(`Requires ${plan.requiredTimerCount} timers`)),
  );
});

// 13. Rule length limit
test('a plan whose Rule1 exceeds 511 chars is reported as unsupported', () => {
  const channels = Array.from({ length: 10 }, (_, i) => i + 1);
  const ranges = [
    { start: '06:00', end: '07:00' },
    { start: '08:00', end: '09:00' },
    { start: '10:00', end: '11:00' },
    { start: '12:00', end: '13:00' },
    { start: '14:00', end: '15:00' },
  ];
  const plan = build([schedule({ channels, timeRanges: ranges })], { deviceId: 'DEV1', channels: 16 });
  assert.ok(plan.rules.length === 1, 'one Rule1 set');
  assert.ok(plan.rules[0].length > MAX_RULE_LENGTH, `rule is ${plan.rules[0].length} chars`);
  assert.ok(
    plan.unsupportedReasons.some((r) => r.startsWith(`Rule1 requires ${plan.rules[0].length}`)),
  );
});

// 14. Deterministic output
test('output is deterministic regardless of input order or repeated runs', () => {
  const a = schedule({ _id: 'a', channels: [1, 2], timeRanges: [{ start: '06:00', end: '09:00' }] });
  const b = schedule({ _id: 'b', recurrence: { type: 'custom', daysOfWeek: [0, 3] }, timeRanges: [{ start: '18:00', end: '20:00' }] });
  const first = build([a, b]);
  const second = build([b, a]);
  const third = build([a, b]);
  assert.deepStrictEqual(first, second);
  assert.deepStrictEqual(first, third);
});

// 15. Disabled schedules are ignored
test('disabled schedules are excluded from the plan', () => {
  const plan = build([
    schedule({ _id: 'disabled', enabled: false }),
    schedule({ _id: 'active' }),
  ]);
  assert.strictEqual(plan.requiredTimerCount, 2);
  assert.deepStrictEqual(plan.unsupportedReasons, []);
});

// 16. Empty schedule list
test('an empty or all-disabled schedule list produces an empty plan', () => {
  const empty = build([]);
  assert.strictEqual(empty.requiredTimerCount, 0);
  assert.deepStrictEqual(empty.timers, []);
  assert.deepStrictEqual(empty.rules, []);
  assert.deepStrictEqual(empty.unsupportedReasons, []);
  assert.deepStrictEqual(empty.conflicts, []);

  const disabledOnly = build([schedule({ enabled: false })]);
  assert.strictEqual(disabledOnly.requiredTimerCount, 0);
  assert.deepStrictEqual(disabledOnly.timers, []);
});

test('a channel outside the device capacity is reported as a conflict, not applied', () => {
  const plan = build([schedule({ channels: [9] })], { deviceId: 'DEV1', channels: 4 });
  assert.ok(plan.conflicts.some((c) => c.includes('targets channel 9')));
  assert.strictEqual(plan.requiredTimerCount, 0);
});

// ─────────────────────────────────────────────────────────────────────────
// Overlap-merge semantics (audit item 1): timeRanges are ON-windows by
// definition (Schedule model, engine _desiredState, dry-run reference all
// agree). A second schedule covering a sub-window of another is an ON-range,
// NEVER a "pause" — so overlapping union must produce exactly the merged
// envelope with no mid-window toggles. This test PINS that behavior.
// ─────────────────────────────────────────────────────────────────────────
test('overlap: sub-window schedule merges into envelope (no mid-window ch2 OFF/ON events)', () => {
  const a = schedule({ _id: 'sA', name: 'A', channels: [1, 2], timeRanges: [{ start: '10:00', end: '11:00' }] });
  const b = schedule({ _id: 'sB', name: 'B', channels: [2], timeRanges: [{ start: '10:30', end: '10:45' }] });
  const plan = compile({ deviceId: 'DEV1', schedules: [a, b], device: DEVICE });

  assert.strictEqual(plan.unsupportedReasons.length, 0);
  // Union semantics: only the envelope edges are transitions.
  assert.strictEqual(plan.timers.length, 2, `expected envelope-only timers, got ${plan.timers.length}`);
  assert.deepStrictEqual(plan.timers.map((t) => t.config.Time), ['10:00', '11:00']);
  assert.ok(!plan.timers.some((t) => ['10:30', '10:45'].includes(t.config.Time)),
    'sub-window edges must NOT emit timers under ON-window semantics');
  for (const t of plan.timers) {
    assert.strictEqual(t.config.Action, 3);
    assert.deepStrictEqual(t.event.on.concat(t.event.off).sort().join(','), '1,2',
      'both channels switch together at the envelope edges');
  }
  assert.strictEqual(
    plan.rules[0].text,
    'ON Clock#Timer=1 DO Backlog Power1 ON; Power2 ON ENDON ' +
    'ON Clock#Timer=2 DO Backlog Power1 OFF; Power2 OFF ENDON',
  );
});
