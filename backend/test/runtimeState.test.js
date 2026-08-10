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