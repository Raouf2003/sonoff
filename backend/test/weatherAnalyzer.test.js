const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { analyzeSchedules, buildRainBlocks } = require('../services/weatherScheduleAnalyzer');

function sched(over) {
  return {
    _id: 's1', name: 'Morning', deviceId: 'D1', channels: [1, 2],
    recurrence: { type: 'daily', daysOfWeek: [] },
    timeRanges: [{ start: '06:00', end: '10:00' }],
    enabled: true, ...over,
  };
}

function hour(date, hh, mm, prob) {
  const p = (n) => String(n).padStart(2, '0');
  return { localTime: `${date}T${p(hh)}:00`, temperature: 20, precipitationMm: mm, precipitationProbability: prob };
}

describe('weather analyzer', () => {
  it('basic overlap 06-10 vs rain 08-11 => advisory', () => {
    const hourly = [8, 9, 10].map((h) => hour('2026-09-14', h, 4, 80));
    const { advisories } = analyzeSchedules({ schedules: [sched()], hourly, device: { deviceId: 'D1' } });
    const overlap = advisories.filter((a) => a.type === 'overlap');
    assert.ok(overlap.length >= 1);
    assert.equal(overlap[0].scheduleId, 's1');
    assert.ok(overlap[0].precipitationMm >= 2);
  });

  it('no overlap 06-07 vs rain 14-17 => no advisory', () => {
    const s = sched({ timeRanges: [{ start: '06:00', end: '07:00' }] });
    const hourly = [14, 15, 16].map((h) => hour('2026-09-14', h, 5, 90));
    const { advisories } = analyzeSchedules({ schedules: [s], hourly, device: { deviceId: 'D1' } });
    assert.equal(advisories.filter((a) => a.type === 'overlap').length, 0);
  });

  it('threshold 1mm => no advisory', () => {
    const hourly = [8, 9].map((h) => hour('2026-09-14', h, 1, 90));
    const { advisories } = analyzeSchedules({ schedules: [sched()], hourly, device: { deviceId: 'D1' } });
    assert.equal(advisories.length, 0);
  });

  it('20% probability => no HIGH advisory', () => {
    const hourly = [8, 9].map((h) => hour('2026-09-14', h, 8, 20));
    const { advisories } = analyzeSchedules({ schedules: [sched()], hourly, device: { deviceId: 'D1' } });
    assert.equal(advisories.filter((a) => a.type === 'overlap').length, 0);
  });

  it('multiple schedules: only overlapping gets advisory', () => {
    const a = sched({ _id: 'a', timeRanges: [{ start: '06:00', end: '08:00' }] });
    const b = sched({ _id: 'b', timeRanges: [{ start: '17:00', end: '19:00' }] });
    const hourly = [7, 8, 9].map((h) => hour('2026-09-14', h, 4, 80));
    const { advisories } = analyzeSchedules({ schedules: [a, b], hourly, device: { deviceId: 'D1' } });
    const ids = new Set(advisories.filter((x) => x.type === 'overlap').map((x) => x.scheduleId));
    assert.ok(ids.has('a'));
    assert.ok(!ids.has('b'));
  });

  it('disabled + pendingDelete => no advisory', () => {
    const hourly = [8].map((h) => hour('2026-09-14', h, 5, 90));
    const off = sched({ enabled: false });
    const del = sched({ _id: 'del', pendingDelete: true });
    const { advisories } = analyzeSchedules({ schedules: [off, del], hourly, device: { deviceId: 'D1' } });
    assert.equal(advisories.length, 0);
  });

  it('merges contiguous hours into one block with summed mm', () => {
    const hourly = [8, 9, 10].map((h) => hour('2026-09-14', h, h === 9 ? 5 : 3, 75));
    const blocks = buildRainBlocks(hourly);
    assert.equal(blocks.length, 1);
    assert.equal(blocks[0].start, '08:00');
    assert.equal(blocks[0].precipitationMm, 11);
  });

  it('uses Africa/Algiers local-hour comparison', () => {
    const hourly = [hour('2026-09-14', 8, 5, 90)];
    const { advisories } = analyzeSchedules({ schedules: [sched()], hourly, device: { deviceId: 'D1' } });
    assert.equal(advisories[0].rainDate, '2026-09-14');
    assert.equal(advisories[0].scheduleStart, '06:00');
  });
});
