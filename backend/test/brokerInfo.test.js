const { test } = require('node:test');
const assert = require('node:assert');
const {
  resolveBrokerInfo,
  configuredBrokerInfo,
} = require('../services/brokerInfo');

test('resolveBrokerInfo parses host:port from an mqtt:// URL', () => {
  const info = resolveBrokerInfo('mqtt://broker.emqx.io:1883');
  assert.deepStrictEqual(info, { host: 'broker.emqx.io', port: 1883 });
});

test('resolveBrokerInfo applies the standard mqtts port when omitted', () => {
  const info = resolveBrokerInfo('mqtts://broker.example.com');
  assert.deepStrictEqual(info, { host: 'broker.example.com', port: 8883 });
});

test('resolveBrokerInfo applies the standard mqtt port when omitted', () => {
  const info = resolveBrokerInfo('mqtt://broker.example.com');
  assert.deepStrictEqual(info, { host: 'broker.example.com', port: 1883 });
});

test('resolveBrokerInfo preserves an explicit non-standard port', () => {
  const info = resolveBrokerInfo('mqtt://broker.example.com:2883');
  assert.deepStrictEqual(info, { host: 'broker.example.com', port: 2883 });
});

test('resolveBrokerInfo rejects non-mqtt schemes and malformed URLs', () => {
  assert.strictEqual(resolveBrokerInfo('http://broker.example.com'), null);
  assert.strictEqual(resolveBrokerInfo('not a url'), null);
  assert.strictEqual(resolveBrokerInfo(''), null);
  assert.strictEqual(resolveBrokerInfo(undefined), null);
  assert.strictEqual(resolveBrokerInfo('mqtt://'), null);
});

test('configuredBrokerInfo reads from MQTT_BROKER_URL', () => {
  const prev = process.env.MQTT_BROKER_URL;
  try {
    process.env.MQTT_BROKER_URL = 'mqtts://a1b2c3.s1.eu.hivemq.cloud:8883';
    assert.deepStrictEqual(configuredBrokerInfo(), {
      host: 'a1b2c3.s1.eu.hivemq.cloud',
      port: 8883,
    });
    delete process.env.MQTT_BROKER_URL;
    assert.strictEqual(configuredBrokerInfo(), null);
  } finally {
    if (prev === undefined) delete process.env.MQTT_BROKER_URL;
    else process.env.MQTT_BROKER_URL = prev;
  }
});