const { test } = require('node:test');
const assert = require('node:assert');
const mongoose = require('mongoose');
// Schema-level tests only: loading the model does not require a DB connection.
const Rule = require('../models/Rule');

function makeRule(overrides = {}) {
  return new Rule({
    ownerId: new mongoose.Types.ObjectId(),
    name: 'test rule',
    sensorId: 'sensor_1',
    deviceId: 'stees_device',
    channels: [1],
    condition: 'above',
    threshold: 10,
    action: 'ON',
    ...overrides,
  });
}

test('channels beyond 4 are accepted (device max enforced in routes)', () => {
  const err = makeRule({ channels: [5, 8] }).validateSync();
  assert.strictEqual(err, undefined);
});

test('duplicate channels are rejected', () => {
  assert.ok(makeRule({ channels: [1, 1] }).validateSync());
});

test('non-positive channels are rejected', () => {
  assert.ok(makeRule({ channels: [0] }).validateSync());
});

test('empty channels are rejected', () => {
  assert.ok(makeRule({ channels: [] }).validateSync());
});