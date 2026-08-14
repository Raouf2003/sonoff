const { DateTime } = require('luxon');
const Schedule = require('../models/Schedule');
const Device = require('../models/Device');
const scheduleEngine = require('./scheduleEngine');
const { compile } = require('./scheduleCompiler');
const { simulateCompiledPlan } = require('./scheduleSimulator');

const PROBE_MINUTES = [0, 359, 360, 361, 539, 540, 541, 719, 720, 721, 899, 900, 901, 1080, 1439];

// Reference: the real engine's per-schedule _desiredState, aggregated with
// ON-wins semantics (a channel is ON if any enabled schedule wants it ON).
function referenceScheduleState(schedules, dt) {
  const state = {};
  for (const schedule of schedules) {
    if (!schedule || schedule.enabled === false) continue;
    if (scheduleEngine._desiredState(schedule, dt) !== 'ON') continue;
    for (const channel of schedule.channels || []) {
      if (state[channel] !== 'ON') state[channel] = 'ON';
    }
  }
  for (const schedule of schedules) {
    if (!schedule || schedule.enabled === false) continue;
    for (const channel of schedule.channels || []) {
      if (state[channel] !== 'ON') state[channel] = 'OFF';
    }
  }
  return state;
}

function buildDryRun({ deviceId, schedules, device, now = new Date() }) {
  const result = compile({ deviceId, schedules, device });
  const ruleLengths = {};
  for (const rule of result.rules) {
    ruleLengths[`rule${rule.ruleIndex}`] = rule.length;
  }
  return {
    deviceId,
    generatedAt: now instanceof Date ? now.toISOString() : String(now),
    compiler: {
      supported: result.unsupportedReasons.length === 0,
      requiredTimerCount: result.requiredTimerCount,
      ruleCount: result.rules.length,
      ruleLengths,
      unsupportedReasons: result.unsupportedReasons,
      conflicts: result.conflicts,
    },
    plan: { timers: result.timers, rules: result.rules },
  };
}

async function dryRunForDevice(deviceId, { deviceModel = Device, scheduleModel = Schedule, now } = {}) {
  const device = await deviceModel.findOne({ deviceId });
  const schedules = await scheduleModel.find({ deviceId });
  return buildDryRun({ deviceId, schedules, device, now });
}

function sampleParityMismatches(schedules, plan, deviceChannels) {
  const mismatches = [];
  for (let dayOffset = 0; dayOffset < 7; dayOffset++) {
    const day = DateTime.fromISO('2026-08-03T00:00:00Z').plus({ days: dayOffset });
    for (const minute of PROBE_MINUTES) {
      const dt = day.set({
        hour: Math.floor(minute / 60),
        minute: minute % 60,
        second: 0,
        millisecond: 0,
      });
      const expected = referenceScheduleState(schedules, dt);
      const actual = simulateCompiledPlan(plan, dt);
      const channels = Array.from(new Set([...Object.keys(expected), ...Object.keys(actual)])).sort();
      const expectedTrim = {};
      const actualTrim = {};
      for (const c of channels) {
        if (Number(c) > deviceChannels) continue;
        expectedTrim[c] = expected[c] || 'OFF';
        actualTrim[c] = actual[c] || 'OFF';
      }
      const eq = Object.keys(expectedTrim).length === Object.keys(actualTrim).length &&
        Object.keys(expectedTrim).every((c) => expectedTrim[c] === actualTrim[c]);
      if (!eq) {
        mismatches.push({
          timestamp: dt.toISO(),
          expected: expectedTrim,
          actual: actualTrim,
        });
      }
    }
  }
  return mismatches;
}

function buildPreview({ deviceId, schedules, device, now = new Date() }) {
  const dry = buildDryRun({ deviceId, schedules, device, now });
  const deviceChannels = device && Number.isInteger(device.channels) ? device.channels : 4;
  const mismatches = sampleParityMismatches(schedules, dry.plan, deviceChannels);
  return {
    deviceId,
    schedules,
    timers: dry.plan.timers,
    rule1: dry.plan.rules[0] ? dry.plan.rules[0].text : null,
    timerCount: dry.compiler.requiredTimerCount,
    ruleCharacterCount: dry.compiler.ruleCount ? dry.compiler.ruleLengths.rule1 : 0,
    supported: dry.compiler.supported,
    unsupportedReasons: dry.compiler.unsupportedReasons,
    parity: {
      sampleCount: 7 * PROBE_MINUTES.length,
      mismatches,
    },
  };
}

module.exports = {
  buildDryRun,
  dryRunForDevice,
  buildPreview,
  referenceScheduleState,
};