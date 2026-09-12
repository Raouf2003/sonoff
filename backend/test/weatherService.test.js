const { describe, it, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const weatherService = require('../services/weatherService');

function payload() {
  return {
    hourly: {
      time: ['2026-09-14T08:00', '2026-09-14T09:00'],
      temperature_2m: [21.5, 22],
      precipitation: [0, 3.2],
      precipitation_probability: [10, 75],
    },
  };
}

describe('weatherService', () => {
  beforeEach(() => weatherService.clearCache());

  it('normalizes Open-Meteo into project shape', async () => {
    let calls = 0;
    const fetchFn = async () => ({ ok: true, json: async () => payload() });
    const data = await weatherService.getForecast({ lat: 36.1, lon: 3.5, fetchFn });
    calls++;
    assert.equal(data.timezone, 'Africa/Algiers');
    assert.equal(data.hourly.length, 2);
    assert.equal(data.hourly[1].precipitationMm, 3.2);
    assert.equal(calls, 1);
  });

  it('shares cache for identical coordinates', async () => {
    let calls = 0;
    const fetchFn = async () => { calls++; return { ok: true, json: async () => payload() }; };
    await weatherService.getForecast({ lat: 36.1, lon: 3.5, fetchFn });
    await weatherService.getForecast({ lat: 36.1, lon: 3.5, fetchFn });
    assert.equal(calls, 1);
  });

  it('isolates cache per device location', async () => {
    let calls = 0;
    const fetchFn = async () => { calls++; return { ok: true, json: async () => payload() }; };
    await weatherService.getForecast({ lat: 36.1, lon: 3.5, fetchFn });
    await weatherService.getForecast({ lat: 35.0, lon: 4.0, fetchFn });
    assert.equal(calls, 2);
  });

  it('no coordinates => no request', async () => {
    let calls = 0;
    const fetchFn = async () => { calls++; return { ok: true, json: async () => payload() }; };
    const data = await weatherService.getForecast({ lat: null, lon: null, fetchFn });
    assert.equal(data, null);
    assert.equal(calls, 0);
  });

  it('API failure returns null and never throws', async () => {
    const fetchFn = async () => { throw new Error('boom'); };
    const data = await weatherService.getForecast({ lat: 36.1, lon: 3.5, fetchFn });
    assert.equal(data, null);
  });
});
