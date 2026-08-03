const express = require('express');
const Schedule = require('../models/Schedule');
const Device = require('../models/Device');

const router = express.Router();

const TIME_RE = /^([01]\d|2[0-3]):([0-5]\d)$/;

function minutesFromHhmm(hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  return h * 60 + m;
}

// Shared parse/validate for POST and PATCH. Runs after the device is resolved.
// Returns { ok, status, json, data } where data is the cleaned payload.
function validateSchedule(body, device) {
  const name = body.name;
  if (!name || !String(name).trim()) {
    return { ok: false, status: 400, json: { error: 'name is required' } };
  }

  const channels = body.channels;
  if (!Array.isArray(channels) || channels.length === 0) {
    return { ok: false, status: 400, json: { error: 'channels must be a non-empty array' } };
  }
  const max = device.channels || 4;
  for (const c of channels) {
    if (!Number.isInteger(c) || c < 1 || c > max) {
      return {
        ok: false,
        status: 400,
        json: { error: `each channel must be an integer between 1 and ${max}` },
      };
    }
  }
  const uniqueChannels = [...new Set(channels)];

  const rec = body.recurrence || {};
  const recType = rec.type;
  if (recType !== 'daily' && recType !== 'custom') {
    return { ok: false, status: 400, json: { error: 'recurrence.type must be daily or custom' } };
  }
  let daysOfWeek = [];
  if (recType === 'custom') {
    if (!Array.isArray(rec.daysOfWeek) || rec.daysOfWeek.length === 0) {
      return {
        ok: false,
        status: 400,
        json: { error: 'recurrence.daysOfWeek is required when type is custom' },
      };
    }
    for (const d of rec.daysOfWeek) {
      if (!Number.isInteger(d) || d < 0 || d > 6) {
        return {
          ok: false,
          status: 400,
          json: { error: 'recurrence.daysOfWeek must contain integers 0..6' },
        };
      }
    }
    daysOfWeek = [...new Set(rec.daysOfWeek)].sort();
  }

  const timeRanges = body.timeRanges;
  if (!Array.isArray(timeRanges) || timeRanges.length === 0) {
    return { ok: false, status: 400, json: { error: 'timeRanges must be a non-empty array' } };
  }
  for (const range of timeRanges) {
    const start = range && range.start;
    const end = range && range.end;
    if (typeof start !== 'string' || !TIME_RE.test(start)) {
      return { ok: false, status: 400, json: { error: 'each time range start must be HH:mm' } };
    }
    if (typeof end !== 'string' || !TIME_RE.test(end)) {
      return { ok: false, status: 400, json: { error: 'each time range end must be HH:mm' } };
    }
    // Same-day ranges only: reject overnight / inverted ranges.
    if (minutesFromHhmm(end) <= minutesFromHhmm(start)) {
      return {
        ok: false,
        status: 400,
        json: { error: 'each time range end must be after start (same-day only)' },
      };
    }
  }

  return {
    ok: true,
    data: {
      name: String(name).trim(),
      deviceId: device.deviceId,
      channels: uniqueChannels,
      recurrence: { type: recType, daysOfWeek },
      timeRanges,
    },
  };
}

function toMinutesFromHhmm(hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  return h * 60 + m;
}

router.get('/', async (req, res) => {
  try {
    const schedules = await Schedule.find({ ownerId: req.userId }).sort({ createdAt: -1 });

    const deviceIds = [...new Set(schedules.map((s) => s.deviceId))];
    const devices = await Device.find({ ownerId: req.userId, deviceId: { $in: deviceIds } });
    const deviceMap = new Map(devices.map((d) => [d.deviceId, d.name]));

    res.json(
      schedules.map((s) => ({
        ...s.toJSON(),
        deviceName: deviceMap.get(s.deviceId) || null,
      })),
    );
  } catch (err) {
    console.error('List schedules error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.post('/', async (req, res) => {
  try {
    const device = await Device.findOne({ deviceId: String(req.body.deviceId || '').trim(), ownerId: req.userId });
    if (!device) {
      return res.status(400).json({ error: 'Device not found or not owned by you' });
    }

    const validation = validateSchedule(req.body, device);
    if (!validation.ok) return res.status(validation.status).json(validation.json);
    const data = validation.data;

    const schedule = await Schedule.create({ ownerId: req.userId, ...data });
    res.status(201).json(schedule.toJSON());
  } catch (err) {
    console.error('Create schedule error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.patch('/:id', async (req, res) => {
  try {
    const schedule = await Schedule.findOne({ _id: req.params.id, ownerId: req.userId });
    if (!schedule) {
      return res.status(404).json({ error: 'Schedule not found' });
    }

    const device = await Device.findOne({ deviceId: schedule.deviceId, ownerId: req.userId });
    if (!device) {
      return res.status(400).json({ error: 'The schedule device is not available' });
    }

    const validation = validateSchedule(req.body, device);
    if (!validation.ok) return res.status(validation.status).json(validation.json);
    const data = validation.data;

    schedule.name = data.name;
    schedule.channels = data.channels;
    schedule.recurrence = data.recurrence;
    schedule.timeRanges = data.timeRanges;
    // Editing may change which channels are controlled; reset applied state
    // so every channel is re-evaluated from scratch on the next tick.
    schedule.lastAppliedState = {};
    await schedule.save();

    res.json(schedule.toJSON());
  } catch (err) {
    console.error('Update schedule error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.patch('/:id/enable', async (req, res) => {
  try {
    const schedule = await Schedule.findOne({ _id: req.params.id, ownerId: req.userId });
    if (!schedule) {
      return res.status(404).json({ error: 'Schedule not found' });
    }
    schedule.enabled = !schedule.enabled;
    // When re-enabled, reset applied state so channels are re-synced on the
    // next tick even if they were left ON/OFF while disabled.
    if (schedule.enabled) schedule.lastAppliedState = {};
    await schedule.save();
    res.json(schedule.toJSON());
  } catch (err) {
    console.error('Toggle schedule error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.delete('/:id', async (req, res) => {
  try {
    const schedule = await Schedule.findOne({ _id: req.params.id, ownerId: req.userId });
    if (!schedule) {
      return res.status(404).json({ error: 'Schedule not found' });
    }
    await schedule.deleteOne();
    res.json({ ok: true });
  } catch (err) {
    console.error('Delete schedule error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;