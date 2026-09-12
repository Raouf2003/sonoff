const express = require('express');
const Device = require('../models/Device');
const Schedule = require('../models/Schedule');
const PushToken = require('../models/PushToken');
const WeatherAdvisory = require('../models/WeatherAdvisory');
const weatherService = require('../services/weatherService');
const { analyzeSchedules } = require('./../services/weatherScheduleAnalyzer');
const { isValidCoords, APP_TIMEZONE } = require('../services/weatherConfig');

const router = express.Router();

function currentTemp(hourly, nowMs) {
  if (!Array.isArray(hourly) || hourly.length === 0) return null;
  const now = new Date(nowMs !== undefined ? nowMs : Date.now());
  const pad = (n) => String(n).padStart(2, '0');
  const prefix = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}T${pad(now.getHours())}`;
  const hit = hourly.find((h) => typeof h.localTime === 'string' && h.localTime.startsWith(prefix));
  const row = hit || hourly[0];
  return row && typeof row.temperature === 'number' ? row.temperature : null;
}

// GET /api/weather/:deviceId/today — advisory read model. Computes from
// (cached forecast + Mongo schedules); never writes relays/timers/rules.
router.get('/:deviceId/today', async (req, res) => {
  try {
    const device = await Device.findOne({ deviceId: req.params.deviceId });
    if (!device) return res.status(404).json({ error: 'Device not found' });
    if (!device.ownerId || device.ownerId.toString() !== req.userId) {
      return res.status(403).json({ error: 'You do not own this device' });
    }
    if (!isValidCoords(device.lat, device.lon)) {
      return res.json({
        deviceId: device.deviceId,
        timezone: device.timezone || APP_TIMEZONE,
        location: { farmName: device.farmName || null, lat: null, lon: null },
        weatherDisabled: true,
        forecast: null,
        schedules: [],
        advisories: [],
      });
    }
    const forecast = await weatherService.getForecast({
      lat: device.lat,
      lon: device.lon,
      timezone: device.timezone || APP_TIMEZONE,
    });
    const schedules = await Schedule.find({
      deviceId: device.deviceId,
      ownerId: req.userId,
      enabled: true,
      pendingDelete: { $ne: true },
    });
    if (!forecast) {
      return res.json({
        deviceId: device.deviceId,
        timezone: device.timezone || APP_TIMEZONE,
        location: { farmName: device.farmName || null, lat: device.lat, lon: device.lon },
        weatherDisabled: false,
        weatherUnavailable: true,
        forecast: null,
        schedules: schedules.map((s) => ({
          scheduleId: String(s._id),
          channels: s.channels,
          timeRanges: s.timeRanges,
        })),
        advisories: [],
      });
    }
    const { advisories, rainBlocks } = analyzeSchedules({
      schedules,
      hourly: forecast.hourly,
      device,
    });
    const top = advisories.find((a) => a.type === 'overlap') || advisories[0] || null;
    res.json({
      deviceId: device.deviceId,
      timezone: device.timezone || APP_TIMEZONE,
      location: { farmName: device.farmName || null, lat: device.lat, lon: device.lon },
      forecast: {
        temperature: currentTemp(forecast.hourly),
        rainProbability: top ? top.probability : 0,
        precipitationMm: top ? top.precipitationMm : 0,
      },
      schedules: schedules.map((s) => ({
        scheduleId: String(s._id),
        channels: s.channels,
        timeRanges: s.timeRanges,
        start: s.timeRanges && s.timeRanges[0] ? s.timeRanges[0].start : null,
        end: s.timeRanges && s.timeRanges[0] ? s.timeRanges[0].end : null,
      })),
      rainBlocks,
      advisories,
    });
  } catch (err) {
    console.error('Weather today error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.get('/advisories/mine', async (req, res) => {
  try {
    const rows = await WeatherAdvisory.find({ ownerId: req.userId }).sort({ createdAt: -1 }).limit(50);
    res.json(rows);
  } catch (err) {
    console.error('Weather advisories error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.post('/push-tokens', async (req, res) => {
  try {
    const { token, platform } = req.body || {};
    if (!token || typeof token !== 'string' || token.length > 512) {
      return res.status(400).json({ error: 'token is required' });
    }
    const row = await PushToken.findOneAndUpdate(
      { ownerId: req.userId, token: token.trim() },
      { $set: { platform: typeof platform === 'string' ? platform.slice(0, 20) : 'android' } },
      { upsert: true, new: true },
    );
    res.status(201).json(row.toJSON());
  } catch (err) {
    console.error('Push token error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.delete('/push-tokens', async (req, res) => {
  try {
    const { token } = req.body || {};
    if (!token) return res.status(400).json({ error: 'token is required' });
    await PushToken.deleteOne({ ownerId: req.userId, token: String(token) });
    res.json({ ok: true });
  } catch (err) {
    console.error('Push token delete error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
