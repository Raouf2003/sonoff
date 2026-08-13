const { test } = require('node:test');
const assert = require('node:assert');
const runtimeState = require('../services/runtimeState');

test('isOnline fallback uses the configured freshMs window', () => {
  runtimeState.ensureDeviceState('dev-a', 4);
  const state = runtimeState.getDeviceState('dev-a');
  assert.ok(state);
  state.online = false;
  state.lastSeen = Date.now();
  assert.strictEqual(runtimeState.isOnline('dev-a'), true);

  // Just past the window the device flips offline, even with recent history
  // and no LWT event. Uses the same freshMs as touchDevice, not a hidden 60s.
  state.lastSeen = Date.now() - (runtimeState.freshMs + 1000);
  assert.strictEqual(runtimeState.isOnline('dev-a'), false);
  assert.ok(runtimeState.freshMs >= 300000);
});

test('LWT online flag beats stale telemetry', () => {
  runtimeState.ensureDeviceState('dev-b', 4);
  const state = runtimeState.getDeviceState('dev-b');
  state.lastSeen = Date.now() - 999999;
  runtimeState.setOnline('dev-b', true);
  assert.strictEqual(runtimeState.isOnline('dev-b'), true);
});

test('unknown device is offline', () => {
  assert.strictEqual(runtimeState.isOnline('nope'), false);
});

test('channels are seeded UNKNOWN with null timestamps, never OFF', () => {
  const chans = runtimeState.ensureDeviceState('dev-seed', 4);
  for (let i = 1; i <= 4; i++) {
    assert.deepStrictEqual(chans[i], { state: 'UNKNOWN', updatedAt: null });
  }
});

test('applyChannelState records a device-reported state with a server timestamp', () => {
  runtimeState.ensureDeviceState('dev-apply', 1);
  const before = Date.now();
  const entry = runtimeState.applyChannelState('dev-apply', 1, 'ON');
  const after = Date.now();
  assert.strictEqual(entry.state, 'ON');
  assert.ok(entry.updatedAt >= before && entry.updatedAt <= after);
});

test('applyChannelState normalizes non-ON/OFF reports to UNKNOWN', () => {
  runtimeState.ensureDeviceState('dev-norm', 1);
  assert.strictEqual(runtimeState.applyChannelState('dev-norm', 1, 'TOGGLE').state, 'UNKNOWN');
});

test('getDeviceStatus exposes per-channel state and updatedAt, UNKNOWN for unobserved', () => {
  runtimeState.ensureDeviceState('dev-status', 2);
  runtimeState.applyChannelState('dev-status', 2, 'OFF');
  const status = runtimeState.getDeviceStatus('dev-status');
  assert.strictEqual(status.channels['1'].state, 'UNKNOWN');
  assert.strictEqual(status.channels['1'].updatedAt, null);
  assert.strictEqual(status.channels['2'].state, 'OFF');
  assert.ok(typeof status.channels['2'].updatedAt === 'string', 'updatedAt is ISO string');
  assert.ok(typeof status.online === 'boolean');
});

test('getDeviceStatus for an unknown device reports all channels as empty and offline', () => {
  const status = runtimeState.getDeviceStatus('never-seen');
  assert.strictEqual(status.online, false);
  assert.deepStrictEqual(status.channels, {});
});