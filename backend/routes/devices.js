const express = require('express');
const Device = require('../models/Device');
const Sensor = require('../models/Sensor');
const Rule = require('../models/Rule');
const Schedule = require('../models/Schedule');
const deviceRegistry = require('../services/deviceRegistry');
const runtimeState = require('../services/runtimeState');
const ruleEngine = require('../services/ruleEngine');
const scheduleEngine = require('../services/scheduleEngine');

const router = express.Router();

router.get('/', async (req, res) => {
  try {
    const devices = await Device.find({ ownerId: req.userId });
    res.json(devices);
  } catch (err) {
    console.error('List devices error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// NOTE: there is intentionally NO possession-free /claim here anymore. Claiming
// now requires a provisioning session + one-time token + device-seen proof via
// POST /api/provisioning/sessions/:sessionId/claim. This closes the previous
// vulnerability where any authenticated user could claim any deviceId observed
// on the public MQTT snapshot.

router.post('/unclaim', async (req, res) => {
  try {
    const { deviceId } = req.body;
    if (!deviceId) return res.status(400).json({ error: 'deviceId is required' });

    const device = await Device.findOne({ deviceId });
    if (!device || !device.ownerId || device.ownerId.toString() !== req.userId) {
      return res.status(403).json({ error: 'You do not own this device' });
    }

    device.ownerId = null;
    device.claimedAt = null;
    await device.save();

    deviceRegistry.remove(device.deviceId);
    res.json(device.toJSON());
  } catch (err) {
    console.error('Unclaim device error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.delete('/:deviceId', async (req, res) => {
  try {
    const device = await Device.findOne({ deviceId: req.params.deviceId });
    if (!device || !device.ownerId || device.ownerId.toString() !== req.userId) {
      return res.status(403).json({ error: 'You do not own this device' });
    }

    // Cascade: sensors on the device, their rules, and the device's schedules
    // must go too, or the app would keep showing orphaned automation entries
    // that can never run.
    const sensors = await Sensor.find({ deviceId: device.deviceId, ownerId: req.userId });
    const sensorIds = sensors.map((s) => s.sensorId);

    const rules = sensorIds.length
      ? await Rule.find({ sensorId: { $in: sensorIds }, ownerId: req.userId })
      : [];
    for (const rule of rules) ruleEngine.invalidate(rule._id);
    if (rules.length) await Rule.deleteMany({ _id: { $in: rules.map((r) => r._id) } });

    const schedules = await Schedule.find({ deviceId: device.deviceId, ownerId: req.userId });
    for (const schedule of schedules) scheduleEngine.invalidate(schedule._id);
    // Release relays a schedule may have left ON so they don't stay stuck after
    // the schedule (and device) are gone. Best-effort; the device may be offline.
    if (schedules.length) {
      for (const schedule of schedules) {
        try {
          await scheduleEngine.release(schedule);
        } catch (err) {
          console.error(`Delete device: schedule release error (${schedule._id}):`, err.message);
        }
      }
      await Schedule.deleteMany({ _id: { $in: schedules.map((s) => s._id) } });
    }

    if (sensorIds.length) {
      await Sensor.deleteMany({ sensorId: { $in: sensorIds }, ownerId: req.userId });
    }

    await device.deleteOne();
    deviceRegistry.remove(device.deviceId);
    runtimeState.deviceStates.delete(device.deviceId);
    res.json({ ok: true });
  } catch (err) {
    console.error('Delete device error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
