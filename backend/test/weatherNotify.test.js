const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { runWeatherNotify } = require('../services/weatherNotifyService');
const weatherService = require('../services/weatherService');

function hour(date, hh, mm, prob) {
  const p = (n) => String(n).padStart(2, '0');
  return { localTime: `${date}T${p(hh)}:00`, temperature: 20, precipitationMm: mm, precipitationProbability: prob };
}

describe('weatherNotify dedup + isolation', () => {
  it('same device+schedule+rainDate notifies once', async () => {
    weatherService.clearCache();
    const schedRow = {
      _id: 's1', name: 'M', deviceId: 'D1', channels: [1],
      recurrence: { type: 'daily', daysOfWeek: [] },
      timeRanges: [{ start: '06:00', end: '10:00' }], enabled: true,
    };
    const device = { deviceId: 'D1', ownerId: 'u1', lat: 36.1, lon: 3.5, farmName: 'North', timezone: 'Africa/Algiers' };
    weatherService.getForecast = async () => ({
      timezone: 'Africa/Algiers',
      hourly: [8, 9].map((h) => hour('2026-09-14', h, 5, 90)),
    });
    const store = new Map();
    const advisoryModel = {
      findOne: async (q) => store.get(`${q.deviceId}|${q.scheduleId}|${q.rainDate}`) || null,
      findOneAndUpdate: async (filter, update, opts) => {
        const key = `${filter.deviceId}|${filter.scheduleId}|${filter.rainDate}`;
        if (store.has(key)) {
          const e = new Error('dup');
          e.code = 11000;
          throw e;
        }
        const row = { ...filter, status: 'sent' };
        store.set(key, row);
        return row;
      },
    };
    const deviceModel = { find: async () => [device] };
    const scheduleModel = { find: async () => [schedRow] };
    const emitted = [];
    const io = { to: () => ({ emit: (ev, data) => emitted.push({ ev, data }) }) };
    const r1 = await runWeatherNotify({ deviceModel, scheduleModel, advisoryModel, io });
    const r2 = await runWeatherNotify({ deviceModel, scheduleModel, advisoryModel, io });
    assert.equal(r1.notified, 1);
    assert.equal(r2.notified, 0);
    assert.equal(emitted.filter((e) => e.ev === 'weather_advisory').length, 1);
  });

  it('weather failure does not throw and notifies nothing', async () => {
    const device = { deviceId: 'D9', ownerId: 'u9', lat: 36.1, lon: 3.5, timezone: 'Africa/Algiers' };
    weatherService.getForecast = async () => null;
    const r = await runWeatherNotify({
      deviceModel: { find: async () => [device] },
      scheduleModel: { find: async () => [] },
      advisoryModel: { findOne: async () => null, findOneAndUpdate: async () => ({}) },
      io: null,
    });
    assert.equal(r.notified, 0);
  });
});
