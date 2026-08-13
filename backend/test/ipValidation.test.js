const { test } = require('node:test');
const assert = require('node:assert');
const { classifyIp, isValidLocalIp } = require('../services/ipValidation');

test('valid IPv4 addresses are accepted', () => {
  for (const ip of ['192.168.1.42', '10.0.0.9', '172.16.5.5', '8.8.8.8']) {
    assert.strictEqual(classifyIp(ip), 'valid', ip);
    assert.strictEqual(isValidLocalIp(ip), true, ip);
  }
});

test('valid IPv6 addresses are accepted', () => {
  for (const ip of ['fe80::1', '2001:db8::1', 'fd00::1234']) {
    assert.strictEqual(classifyIp(ip), 'valid', ip);
    assert.strictEqual(isValidLocalIp(ip), true, ip);
  }
});

test('unspecified addresses (0.0.0.0 / ::) are rejected', () => {
  for (const ip of ['0.0.0.0', '0.0.0.1', '::', '0:0:0:0:0:0:0:0']) {
    assert.notStrictEqual(classifyIp(ip), 'valid', ip);
    assert.strictEqual(isValidLocalIp(ip), false, ip);
  }
  assert.strictEqual(classifyIp('0.0.0.0'), 'unspecified');
});

test('loopback addresses are rejected', () => {
  for (const ip of ['127.0.0.1', '127.0.0.2', '127.255.255.254', '::1']) {
    assert.notStrictEqual(classifyIp(ip), 'valid', ip);
    assert.strictEqual(isValidLocalIp(ip), false, ip);
  }
  assert.strictEqual(classifyIp('127.0.0.1'), 'loopback');
});

test('multicast addresses are rejected', () => {
  for (const ip of ['224.0.0.1', '239.255.255.250', 'ff02::1', 'ff00::']) {
    assert.notStrictEqual(classifyIp(ip), 'valid', ip);
    assert.strictEqual(isValidLocalIp(ip), false, ip);
  }
  assert.strictEqual(classifyIp('224.0.0.1'), 'multicast');
});

test('malformed / non-IP values are rejected', () => {
  for (const ip of ['not-an-ip', 'bad host', '999.999.999.999', '1.2.3', '192.168.1.300', '']) {
    assert.strictEqual(classifyIp(ip), 'invalid', String(ip));
    assert.strictEqual(isValidLocalIp(ip), false, String(ip));
  }
  assert.strictEqual(isValidLocalIp(undefined), false);
  assert.strictEqual(isValidLocalIp(null), false);
  assert.strictEqual(isValidLocalIp(42), false);
});

test('whitespace around a valid IPv4 is trimmed and accepted', () => {
  assert.strictEqual(isValidLocalIp('  192.168.1.42  '), true);
  assert.strictEqual(isValidLocalIp(' 0.0.0.0 '), false);
});
