const { test } = require('node:test');
const assert = require('node:assert');
const { normalizeMac, MAC_ID_RE } = require('../services/macIdentity');

test('same MAC always maps to the same canonical deviceId', () => {
  const a = normalizeMac('34:98:7A:C3:03:04');
  const b = normalizeMac('34:98:7A:C3:03:04');
  assert.strictEqual(a, b);
  assert.strictEqual(a, '34987AC30304');
});

test('common separators are normalized: colon, dash, none', () => {
  assert.strictEqual(normalizeMac('34:98:7A:C3:03:04'), '34987AC30304');
  assert.strictEqual(normalizeMac('34-98-7A-C3-03-04'), '34987AC30304');
  assert.strictEqual(normalizeMac('34987AC30304'), '34987AC30304');
});

test('normalization is case-insensitive', () => {
  assert.strictEqual(normalizeMac('34:98:7a:c3:03:04'), '34987AC30304');
  assert.strictEqual(normalizeMac('34-98-7a-c3-03-04'), '34987AC30304');
});

test('whitespace around the MAC is tolerated', () => {
  assert.strictEqual(normalizeMac('  34:98:7A:C3:03:04 '), '34987AC30304');
});

test('canonical form matches the strict identity regex', () => {
  assert.ok(MAC_ID_RE.test(normalizeMac('34:98:7A:C3:03:04')));
  assert.ok(MAC_ID_RE.test('34987AC30304'));
});

test('invalid MACs are rejected (return null)', () => {
  assert.strictEqual(normalizeMac(''), null);
  assert.strictEqual(normalizeMac('   '), null);
  assert.strictEqual(normalizeMac('34987AC3030'), null); // 11 digits
  assert.strictEqual(normalizeMac('34987AC30304X'), null); // non-hex
  assert.strictEqual(normalizeMac('GG:98:7A:C3:03:04'), null);
  assert.strictEqual(normalizeMac('34:98:7A:C3:03:0'), null);
  assert.strictEqual(normalizeMac(null), null);
  assert.strictEqual(normalizeMac(34987), null); // not a string
  assert.strictEqual(normalizeMac('34:98:7A:C3:03:04:XX'), null);
});

test('deviceId is derived only from the MAC - never user-invented', () => {
  // An arbitrary user-supplied "id" must never normalize to something claimable.
  assert.strictEqual(normalizeMac('stees_0123456789abcdef'), null);
  assert.strictEqual(normalizeMac('my-cool-device'), null);
});