const express = require('express');
const Device = require('../models/Device');
const Sensor = require('../models/Sensor');
const Rule = require('../models/Rule');
const Schedule = require('../models/Schedule');
const deviceRegistry = require('../services/deviceRegistry');
const runtimeState = require('../services/runtimeState');
const ruleEngine = require('../services/ruleEngine');
const scheduleEngine = require('../services/scheduleEngine');
const deviceProvisioningService = require('../services/deviceProvisioningService');
const mqttGateway = require('../services/mqttGateway');
const { normalizeMac } = require('../services/macIdentity');
const { authMiddleware } = require('../middleware/auth');

const router = express.Router();

const PROVISION_ERROR_STATUS = {
  INVALID_MAC: 400,
  BAD_CHANNELS: 400,
  BAD_NAME: 400,
  DEVICE_ALREADY_EXISTS: 409,
  DEVICE_ALREADY_REGISTERED: 409,
  DEVICE_NOT_SEEN: 409,
};

router.get('/', async (req, res) => {
  try {
    const devices = await Device.find({ ownerId: req.userId });
    res.json(devices);
  } catch (err) {
    console.error('List devices error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Provision a physical device directly from its canonical MAC. There is no
// provisioning session or claim token: the MAC IS the deviceId and the MQTT
// topic the firmware was configured with. The device must have actually been
// observed on MQTT recently (possession gate) and must not already belong to
// any account. The unique Device.deviceId index is the final serialization
// point, so concurrent registrations of one MAC resolve to one Device.
router.post('/provision', async (req, res) => {
  try {
    const { deviceId, name, channels } = req.body || {};
    const device = await deviceProvisioningService.provision({
      ownerId: req.userId,
      deviceId,
      name,
      channels,
    });
    res.status(201).json(device.toJSON());
  } catch (err) {
    const status = PROVISION_ERROR_STATUS[err.code];
    if (status) {
      return res.status(status).json({ error: err.message, code: err.code });
    }
    console.error('Provision device error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Whether a device has been observed on the MQTT broker within the recent
// window. Used by the wizard's WAIT phase to know when the physical device has
// joined the configured network and is eligible for registration. Only answers
// about the deviceId the authenticated caller provides - it never enumerates
// devices and never reveals anything about other users.
router.get('/seen', async (req, res) => {
  try {
    const mac = normalizeMac(String(req.query.deviceId || ''));
    if (!mac) {
      return res.status(400).json({ error: 'Invalid deviceId', code: 'INVALID_MAC' });
    }
    res.json({ seen: mqttGateway.hasRecent(mac) });
  } catch (err) {
    console.error('Device seen check error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Best-effort read-only pre-flight duplicate check for the provisioning wizard.
// Given a canonical MAC, reports whether it is already registered to the current
// user ('mine'), to another account ('others', ownership never disclosed), or
// not registered at all ('not_found'). This is ONLY a UX optimization - it is
// NON-authoritative. The authoritative duplicate/ownership/possession check
// remains POST /api/devices/provision, which the wizard always runs after the
// device restarts and establishes MQTT presence.
router.get('/check', async (req, res) => {
  try {
    const mac = normalizeMac(String(req.query.deviceId || ''));
    if (!mac) {
      return res.status(400).json({ error: 'Invalid deviceId', code: 'INVALID_MAC' });
    }
    const result = await deviceProvisioningService.preflightCheck({
      ownerId: req.userId,
      deviceId: mac,
    });
    res.json(result);
  } catch (err) {
    console.error('Device preflight check error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

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

// Send arbitrary Tasmota command via MQTT (e.g., SetOption128, Restart)
// Body: { command: "SetOption128 1" } or { command: "Restart 1" }
router.post('/:deviceId/mqtt-command', authMiddleware, async (req, res) => {
  try {
    const device = await Device.findOne({ deviceId: req.params.deviceId });
    if (!device || !device.ownerId || device.ownerId.toString() !== req.userId) {
      return res.status(403).json({ error: 'You do not own this device' });
    }
    const { command } = req.body;
    if (!command || typeof command !== 'string') {
      return res.status(400).json({ error: 'command is required' });
    }
    await mqttGateway.publishTasmotaCommand(device.deviceId, command);
    res.json({ ok: true });
  } catch (err) {
    console.error('MQTT command error:', err);
    res.status(500).json({ error: 'Failed to send MQTT command' });
  }
});

module.exports = router;
