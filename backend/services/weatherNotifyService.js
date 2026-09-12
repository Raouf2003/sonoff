const Device = require('../models/Device');
const Schedule = require('../models/Schedule');
const WeatherAdvisory = require('../models/WeatherAdvisory');
const PushToken = require('../models/PushToken');
const weatherService = require('./weatherService');
const { analyzeSchedules } = require('./weatherScheduleAnalyzer');
const { APP_TIMEZONE } = require('./weatherConfig');

function advisoryText({ farmName, schedule, advisory }) {
  const farm = farmName ? `${farmName}\n` : '';
  return (
    `\u{1F327} Rain expected during irrigation\n\n${farm}` +
    `Schedule: ${advisory.scheduleStart}\u2013${advisory.scheduleEnd}\n` +
    `Rain: ${advisory.rainStart}\u2013${advisory.rainEnd} (${advisory.rainDate})\n` +
    `Expected: ${advisory.precipitationMm} mm\n` +
    `Probability: ${advisory.probability}%\n\n` +
    `Consider reviewing today's irrigation schedule.`
  );
}

// Server-side push hook. FCM credentials (if configured) stay in env and are
// used here only. Without FCM configured this is a safe no-op that still
// records the advisory as sent (dedup) and emits the Socket.IO foreground
// event via the caller. Never touches MQTT/Tasmota/schedules.
async function sendPush({ ownerId, title, body, data, io } = {}) {
  let tokens = [];
  try {
    tokens = await PushToken.find({ ownerId }).lean();
  } catch (err) {
    tokens = [];
  }
  if (io) {
    io.to(`user:${String(ownerId)}`).emit('weather_advisory', {
      title,
      body,
      data: data || null,
      at: new Date().toISOString(),
    });
  }
  const fcmKey =
    process.env.FCM_SERVER_KEY || process.env.FIREBASE_SERVER_KEY || null;
  if (!fcmKey || tokens.length === 0) {
    return { delivered: false, reason: !fcmKey ? 'FCM_NOT_CONFIGURED' : 'NO_TOKENS', tokens: tokens.length, socketEmitted: !!io };
  }
  // FCM legacy HTTP path kept minimal and server-side only. Production should
  // prefer HTTP v1 with a service account; this hook is the single place to
  // swap it without touching routes or the app.
  try {
    const res = await fetch('https://fcm.googleapis.com/fcm/send', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `key=${fcmKey}` },
      body: JSON.stringify({
        registration_ids: tokens.map((t) => t.token).slice(0, 500),
        notification: { title, body },
        data: data || {},
      }),
    });
    return { delivered: res.ok, status: res.status, tokens: tokens.length, socketEmitted: !!io };
  } catch (err) {
    console.warn(`[weather] FCM send failed: ${err.message}`);
    return { delivered: false, reason: 'FCM_ERROR', error: err.message };
  }
}

// Callable job: evaluate every owned device with coordinates, create HIGH
// advisories idempotently, notify once each. Idempotent, restart-safe,
// Render-sleep-safe (missed runs simply evaluate on next invocation),
// non-blocking for irrigation (pure read + notify).
async function runWeatherNotify({ ownerId, deviceId, io, deviceModel, scheduleModel, advisoryModel } = {}) {
  const D = deviceModel || Device;
  const S = scheduleModel || Schedule;
  const A = advisoryModel || WeatherAdvisory;
  const q = {};
  if (ownerId) q.ownerId = ownerId;
  if (deviceId) q.deviceId = deviceId;
  const devices = await D.find(q);
  const result = { checked: 0, advisories: 0, notified: 0, skipped: 0, errors: [] };
  for (const device of devices) {
    if (typeof device.lat !== 'number' || typeof device.lon !== 'number') {
      result.skipped++;
      continue;
    }
    const forecast = await weatherService.getForecast({
      lat: device.lat,
      lon: device.lon,
      timezone: device.timezone || APP_TIMEZONE,
    });
    if (!forecast) {
      result.skipped++;
      continue;
    }
    const schedules = await S.find({
      deviceId: device.deviceId,
      enabled: true,
      pendingDelete: { $ne: true },
    });
    if (device.ownerId) {
      const owned = schedules.filter(
        (s) => !s.ownerId || String(s.ownerId) === String(device.ownerId),
      );
      schedules.length = 0;
      schedules.push(...owned);
    }
    const { advisories } = analyzeSchedules({
      schedules,
      hourly: forecast.hourly,
      device,
    });
    result.checked++;
    for (const adv of advisories) {
      if (adv.type !== 'overlap') continue; // conservative: HIGH overlap only notifies
      result.advisories++;
      let existing = null;
      try {
        existing = await A.findOne({
          deviceId: adv.deviceId,
          scheduleId: adv.scheduleId,
          rainDate: adv.rainDate,
        });
      } catch (err) {
        result.errors.push(err.message);
        continue;
      }
      if (existing && existing.status === 'sent') continue;
      const payload = { ...adv, farmName: device.farmName || null, timezone: device.timezone || APP_TIMEZONE };
      try {
        await A.findOneAndUpdate(
          { deviceId: adv.deviceId, scheduleId: adv.scheduleId, rainDate: adv.rainDate },
          {
            $setOnInsert: {
              ownerId: device.ownerId,
              deviceId: adv.deviceId,
              scheduleId: adv.scheduleId,
              rainDate: adv.rainDate,
            },
            $set: { type: adv.type, severity: adv.severity, status: 'sent', payload },
          },
          { upsert: true, new: true },
        );
      } catch (err) {
        if (err && err.code === 11000) continue; // lost dedup race: already sent
        result.errors.push(err.message);
        continue;
      }
      const body = advisoryText({ farmName: device.farmName, schedule: null, advisory: adv });
      try {
        await sendPush({
          ownerId: device.ownerId,
          title: '\u{1F327} Rain expected during irrigation',
          body,
          data: { deviceId: adv.deviceId, scheduleId: adv.scheduleId, rainDate: adv.rainDate },
          io,
        });
        result.notified++;
      } catch (err) {
        result.errors.push(err.message);
      }
    }
  }
  return result;
}

module.exports = { runWeatherNotify, sendPush, advisoryText };
