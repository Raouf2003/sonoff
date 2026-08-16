const MAX_TIMERS = 16;
const MAX_RULE_LENGTH = 511;

const ALL_DAYS = [0, 1, 2, 3, 4, 5, 6];

function toMinutes(hhmm) {
  if (typeof hhmm !== 'string') return null;
  const m = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(hhmm);
  if (!m) return null;
  return parseInt(m[1], 10) * 60 + parseInt(m[2], 10);
}

function toHhmm(minutes) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${pad(Math.floor(minutes / 60))}:${pad(minutes % 60)}`;
}

function tasmotaDayPosition(steesDay) {
  return (steesDay + 1) % 7;
}

function daysMask(steesDays) {
  const chars = ['0', '0', '0', '0', '0', '0', '0'];
  for (const day of steesDays) {
    chars[tasmotaDayPosition(day)] = '1';
  }
  return chars.join('');
}

function expandDays(recurrence) {
  if (!recurrence || recurrence.type === 'daily') return new Set(ALL_DAYS);
  if (recurrence.type !== 'custom') return null;
  const days = new Set();
  for (const d of recurrence.daysOfWeek || []) {
    if (Number.isInteger(d) && d >= 0 && d <= 6) days.add(d);
  }
  return days;
}

function scheduleLabel(schedule) {
  return String(schedule._id || schedule.name || '?');
}

function channelsForSchedule(schedule, deviceMax, conflicts, unsupportedReasons) {
  const channels = new Set();
  for (const c of schedule.channels || []) {
    if (Number.isInteger(c) && c >= 1 && c <= deviceMax) {
      channels.add(c);
    } else {
      conflicts.push(
        `Schedule ${scheduleLabel(schedule)} targets channel ${c} which is outside the device (1..${deviceMax})`,
      );
    }
  }
  if (channels.size === 0) {
    unsupportedReasons.push(
      `Schedule ${scheduleLabel(schedule)} has no valid channels after validation`,
    );
  }
  return channels;
}

function statesForDay(day, intervals) {
  const times = new Set();
  for (const iv of intervals) {
    times.add(iv.start);
    times.add(iv.end);
  }
  const sorted = Array.from(times).sort((a, b) => a - b);
  const coverageAt = (t) => {
    const on = new Set();
    for (const iv of intervals) {
      if (iv.start <= t && t < iv.end) {
        for (const c of iv.channels) on.add(c);
      }
    }
    return on;
  };
  const transitions = [];
  let previous = new Set();
  for (const t of sorted) {
    const next = coverageAt(t);
    const on = [];
    const off = [];
    for (const c of next) if (!previous.has(c)) on.push(c);
    for (const c of previous) if (!next.has(c)) off.push(c);
    on.sort((a, b) => a - b);
    off.sort((a, b) => a - b);
    if (on.length || off.length) transitions.push({ time: t, on, off });
    previous = next;
  }
  return transitions;
}

function scheduleKey(schedule) {
  const recurrence = schedule.recurrence || {};
  return JSON.stringify([
    schedule._id ? String(schedule._id) : '',
    schedule.name ? String(schedule.name) : '',
    schedule.enabled === true ? 1 : 0,
    (schedule.channels || []).slice().sort((a, b) => a - b),
    recurrence.type || '',
    (recurrence.daysOfWeek || []).slice().sort((a, b) => a - b),
    (schedule.timeRanges || []).map((r) => [r && r.start, r && r.end]),
  ]);
}

function compile({ deviceId, schedules, device }) {
  const conflicts = [];
  const unsupportedReasons = [];
  const deviceMax = device && Number.isInteger(device.channels) ? device.channels : 4;

  const enabled = (schedules || [])
    .filter((s) => s && s.enabled === true)
    .filter((s) => !deviceId || !s.deviceId || String(s.deviceId) === String(deviceId))
    .sort((a, b) => (scheduleKey(a) < scheduleKey(b) ? -1 : scheduleKey(a) > scheduleKey(b) ? 1 : 0));

  const intervals = [];
  for (const schedule of enabled) {
    const days = expandDays(schedule.recurrence);
    if (!days || days.size === 0) {
      unsupportedReasons.push(
        `Schedule ${scheduleLabel(schedule)} has an unsupported or empty recurrence`,
      );
      continue;
    }
    const channels = channelsForSchedule(schedule, deviceMax, conflicts, unsupportedReasons);
    if (channels.size === 0) continue;
    for (const range of schedule.timeRanges || []) {
      const start = toMinutes(range && range.start);
      const end = toMinutes(range && range.end);
      if (start === null || end === null || end <= start) {
        unsupportedReasons.push(
          `Schedule ${scheduleLabel(schedule)} has an invalid time range ${range && range.start}-${range && range.end}`,
        );
        continue;
      }
      for (const day of days) {
        intervals.push({ day, start, end, channels, scheduleId: String(schedule._id || '') });
      }
    }
  }

  const eventsByKey = new Map();
  for (const day of ALL_DAYS) {
    const dayIntervals = intervals.filter((iv) => iv.day === day);
    if (!dayIntervals.length) continue;
    for (const tr of statesForDay(day, dayIntervals)) {
      const key = `${tr.time}|${tr.on.join(',')}|${tr.off.join(',')}`;
      let event = eventsByKey.get(key);
      if (!event) {
        event = { time: tr.time, on: tr.on, off: tr.off, days: new Set(), sources: new Set() };
        eventsByKey.set(key, event);
      }
      event.days.add(day);
      for (const iv of dayIntervals) {
        if ((iv.start <= tr.time && tr.time < iv.end) || iv.end === tr.time) {
          if (iv.scheduleId) event.sources.add(iv.scheduleId);
        }
      }
    }
  }

  const events = Array.from(eventsByKey.values())
    .map((e) => ({
      time: e.time,
      on: e.on.slice(),
      off: e.off.slice(),
      days: Array.from(e.days).sort((a, b) => a - b),
      sources: Array.from(e.sources).sort(),
    }))
    .sort((a, b) => a.time - b.time || String(a.on).localeCompare(String(b.on)) || String(a.off).localeCompare(String(b.off)));

  const timers = [];
  const ruleClauses = [];
  events.forEach((event, i) => {
    const index = i + 1;
    const mask = daysMask(event.days);
    const actionCount = event.on.length + event.off.length;
    const isDirect = actionCount === 1;
    let config;
    if (isDirect) {
      const channel = event.on.length ? event.on[0] : event.off[0];
      config = {
        Enable: 1,
        Mode: 0,
        Time: toHhmm(event.time),
        Window: 0,
        Days: mask,
        Repeat: 1,
        Action: event.on.length ? 1 : 0,
        Output: channel,
      };
    } else {
      config = {
        Enable: 1,
        Mode: 0,
        Time: toHhmm(event.time),
        Window: 0,
        Days: mask,
        Repeat: 1,
        Output: 1,
        Action: 3,
      };
    }
    timers.push({
      index,
      config,
      event: { on: event.on.slice(), off: event.off.slice() },
      sources: event.sources.slice(),
    });
    if (!isDirect) {
      const commands = [];
      for (const c of event.on) commands.push(`Power${c} ON`);
      for (const c of event.off) commands.push(`Power${c} OFF`);
      const body = commands.length === 1 ? commands[0] : `Backlog ${commands.join('; ')}`;
      ruleClauses.push(`ON Clock#Timer=${index} DO ${body} ENDON`);
    }
  });

  const rules = [];
  const ruleText = ruleClauses.join(' ');
  if (ruleText) {
    rules.push({ ruleIndex: 1, length: ruleText.length, text: ruleText });
    if (ruleText.length > MAX_RULE_LENGTH) {
      unsupportedReasons.push(`Rule1 requires ${ruleText.length} chars (${MAX_RULE_LENGTH} max)`);
    }
  }

  const requiredTimerCount = timers.length;
  if (requiredTimerCount > MAX_TIMERS) {
    unsupportedReasons.push(`Requires ${requiredTimerCount} timers (${MAX_TIMERS} max)`);
  }

  return { deviceId, timers, rules, requiredTimerCount, conflicts, unsupportedReasons };
}

module.exports = { compile, MAX_TIMERS, MAX_RULE_LENGTH, daysMask };