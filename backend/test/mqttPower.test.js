const { test } = require('node:test');
const assert = require('node:assert');
const { powerUpdatesFrom } = require('../services/mqttGateway');

test('bare POWER maps to channel 1 when no numbered keys exist', () => {
  const updates = powerUpdatesFrom({ POWER: 'ON' }, 4);
  assert.deepStrictEqual(updates, { 1: 'ON' });
});

test('numbered POWER keys take precedence over a bare key', () => {
  const updates = powerUpdatesFrom({ POWER: 'ON', POWER1: 'OFF' }, 4);
  assert.deepStrictEqual(updates, { 1: 'OFF' });
});

test('multi-relay mapping covers every reported channel', () => {
  const updates = powerUpdatesFrom({ POWER1: 'ON', POWER2: 'OFF', POWER3: 'ON' }, 4);
  assert.deepStrictEqual(updates, { 1: 'ON', 2: 'OFF', 3: 'ON' });
});

test('transient values like TOGGLE are ignored', () => {
  assert.deepStrictEqual(powerUpdatesFrom({ POWER: 'TOGGLE' }, 4), {});
});

test('malformed payloads yield no updates', () => {
  assert.deepStrictEqual(powerUpdatesFrom(null, 4), {});
  assert.deepStrictEqual(powerUpdatesFrom('not-json', 4), {});
  assert.deepStrictEqual(powerUpdatesFrom(undefined, 4), {});
});