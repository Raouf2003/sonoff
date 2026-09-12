const { config } = require('./weatherConfig');

function toMinutes(hhmm) {
  if (typeof hhmm !== 'string') return null;
  const m = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(hhmm);
  if (!m) return null;
  return parseInt(m[1], 10) * 60 + parseInt(m[2], 10);
}

function toHhmm(minutes) {
  const pad = (n) => String(n).padStart(2, '0');
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return `${pad(h)}:${pad(m)}`;
}

// localTime "YYYY-MM-DDTHH:mm" -> { date, minutes }. Pure wall-time compare;
// the forecast is already requested with timezone=Africa/Algiers so no UTC
// conversion happens here (same convention as Schedule HH:mm windows).
function parseLocalHour(localTime) {
  if (typeof localTime !== 'string') return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(localTime);
  if (!m) return null;
  return {
    date: `${m[1]}-${m[2]}-${m[3]}`,
    minutes: parseInt(m[4], 10) * 60 + parseInt(m[5], 10),
  };
}

// Merge contiguous significant hours into rain blocks. A hour is significant
// when precipMm >= mmThreshold AND probability >= probThreshold.
function buildRainBlocks(hourly, { mmThreshold, probThreshold } = {}) {
  const mmT = mmThreshold !== undefined ? mmThreshold : config.rainMmThreshold;
  const probT = probThreshold !== undefined ? probThreshold : config.rainProbabilityThreshold;
  const byDate = new Map();
  for (const h of hourly || []) {
    const parsed = parseLocalHour(h.localTime);
    if (!parsed) continue;
    const mm = typeof h.precipitationMm === 'number' ? h.precipitationMm : 0;
    const prob = typeof h.precipitationProbability === 'number' ? h.precipitationProbability : 0;
    if (!(mm >= mmT && prob >= probT)) continue;
    if (!byDate.has(parsed.date)) byDate.set(parsed.date, []);
    byDate.get(parsed.date).push({ start: parsed.minutes, end: parsed.minutes + 60, mm, prob });
  }
  const blocks = [];
  for (const [date, hours] of byDate) {
    hours.sort((a, b) => a.start - b.start);
    let cur = null;
    for (const h of hours) {
      if (!cur || h.start > cur.end) {
        if (cur) blocks.push({ date, ...cur });
        cur = { start: h.start, end: h.end, mm: h.mm, maxProb: h.prob };
      } else {
        cur.end = Math.max(cur.end, h.end);
        cur.mm += h.mm;
        cur.maxProb = Math.max(cur.maxProb, h.prob);
      }
    }
    if (cur) blocks.push({ date, ...cur });
  }
  return blocks.map((b) => ({
    date: b.date,
    start: toHhmm(b.start),
    end: toHhmm(b.end === 1440 ? 1439 : b.end),
    startMin: b.start,
    endMin: b.end,
    precipitationMm: Math.round(b.mm * 10) / 10,
    probability: b.maxProb,
  }));
}

function scheduleAppliesOnDate(schedule, weekdayMon0) {
  const rec = schedule.recurrence || {};
  if (rec.type === 'custom') {
    const days = rec.daysOfWeek || [];
    return days.includes(weekdayMon0);
  }
  return true; // daily
}

// weekday of YYYY-MM-DD in Africa/Algiers as Mon0 (0=Mon..6=Sun).
// Computation is calendar-based (no DST in Algiers) via UTC noon anchor.
function weekdayMon0(dateStr) {
  const [y, mo, d] = dateStr.split('-').map(Number);
  const dt = new Date(Date.UTC(y, mo - 1, d, 12, 0, 0));
  return (dt.getUTCDay() + 6) % 7;
}

// Pure analysis. No MQTT, no Tasmota, no DB, no side effects.
// Skips disabled / pendingDelete / coordinate-less inputs at the route layer;
// this function additionally guards disabled+pendingDelete defensively.
function analyzeSchedules({ schedules, hourly, device, options } = {}) {
  const mmT = options && options.mmThreshold !== undefined ? options.mmThreshold : config.rainMmThreshold;
  const probT = options && options.probThreshold !== undefined ? options.probThreshold : config.rainProbabilityThreshold;
  const adjacentMin = options && options.adjacentMinutes !== undefined ? options.adjacentMinutes : config.adjacentWindowMinutes;
  const blocks = buildRainBlocks(hourly, { mmThreshold: mmT, probThreshold: probT });
  const advisories = [];
  for (const schedule of schedules || []) {
    if (!schedule || schedule.enabled !== true) continue;
    if (schedule.pendingDelete === true) continue;
    const ranges = schedule.timeRanges || [];
    for (const block of blocks) {
      const wd = weekdayMon0(block.date);
      if (!scheduleAppliesOnDate(schedule, wd)) continue;
      for (const range of ranges) {
        const s = toMinutes(range && range.start);
        const e = toMinutes(range && range.end);
        if (s === null || e === null || e <= s) continue;
        const overlap = s < block.endMin && block.startMin < e;
        const adjacent =
          !overlap &&
          s < block.endMin + adjacentMin &&
          block.startMin < e + adjacentMin;
        if (!overlap && !adjacent) continue;
        const oStart = Math.max(s, block.startMin);
        const oEnd = Math.min(e, block.endMin);
        advisories.push({
          type: overlap ? 'overlap' : 'adjacent',
          severity: overlap ? 'HIGH' : 'MEDIUM',
          deviceId: device ? device.deviceId : schedule.deviceId,
          scheduleId: String(schedule._id || schedule.id || ''),
          scheduleName: schedule.name || '',
          channels: Array.isArray(schedule.channels) ? schedule.channels.slice() : [],
          scheduleStart: range.start,
          scheduleEnd: range.end,
          rainDate: block.date,
          rainStart: block.start,
          rainEnd: block.end,
          overlapStart: overlap ? toHhmm(oStart) : null,
          overlapEnd: overlap ? toHhmm(oEnd === 1440 ? 1439 : oEnd) : null,
          overlapMinutes: overlap ? Math.max(0, oEnd - oStart) : 0,
          precipitationMm: block.precipitationMm,
          probability: block.probability,
        });
      }
    }
  }
  return { rainBlocks: blocks, advisories };
}

module.exports = {
  analyzeSchedules,
  buildRainBlocks,
  toMinutes,
  toHhmm,
  parseLocalHour,
  weekdayMon0,
};
