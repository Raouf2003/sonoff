const express = require('express');
const Device = require('../models/Device');
const Rule = require('../models/Rule');
const Sensor = require('../models/Sensor');
const deviceRegistry = require('../services/deviceRegistry');
const ruleEngine = require('../services/ruleEngine');

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

router.post('/claim', async (req, res) => {
  try {
    const { deviceId, name } = req.body;

    if (!deviceId || !name) {
      return res.status(400).json({ error: 'deviceId and name are required' });
    }

    const tid = deviceId.trim();
    let device = await Device.findOne({ deviceId: tid });

    if (device && device.ownerId) {
      return res.status(409).json({ error: 'Device is already claimed by another user' });
    }

    if (device) {
      device.ownerId = req.userId;
      device.name = name.trim();
      device.claimedAt = new Date();
    } else {
      device = await Device.create({
        deviceId: tid,
        name: name.trim(),
        ownerId: req.userId,
        claimedAt: new Date(),
      });
    }

    await device.save();
    deviceRegistry.update(device);
    res.json(device.toJSON());
  } catch (err) {
    console.error('Claim device error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

async function guardEnabledRules(userId, deviceId) {
  const enabled = await Rule.findOne({ ownerId: userId, enabled: true, 'action.deviceId': deviceId });
  if (enabled) {
    return { error: `Device is referenced by enabled rule "${enabled.name}". Disable or delete it first.` };
  }
  return null;
}

router.post('/unclaim', async (req, res) => {
  try {
    const { deviceId } = req.body;
    if (!deviceId) return res.status(400).json({ error: 'deviceId is required' });

    const device = await Device.findOne({ deviceId });
    if (!device || !device.ownerId || device.ownerId.toString() !== req.userId) {
      return res.status(403).json({ error: 'You do not own this device' });
    }

    const guard = await guardEnabledRules(req.userId, device.deviceId);
    if (guard) return res.status(409).json({ error: guard.error });

    await Rule.updateMany(
      { ownerId: req.userId, 'action.deviceId': device.deviceId },
      { $set: { enabled: false, updatedAt: new Date() } },
    );

    device.ownerId = null;
    device.claimedAt = null;
    await device.save();

    deviceRegistry.remove(device.deviceId);
    await ruleEngine.onDeviceUnclaimed(device.deviceId);
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

    const guard = await guardEnabledRules(req.userId, device.deviceId);
    if (guard) return res.status(409).json({ error: guard.error });

    const sensors = await Sensor.find({ ownerId: req.userId, deviceId: device.deviceId });
    const sensorIds = sensors.map((s) => s.sensorId);
    await Rule.deleteMany({ ownerId: req.userId, sensorId: { $in: sensorIds } });
    await Sensor.deleteMany({ ownerId: req.userId, deviceId: device.deviceId });

    await device.deleteOne();
    deviceRegistry.remove(device.deviceId);
    await ruleEngine.rebuildAll();
    res.json({ ok: true });
  } catch (err) {
    console.error('Delete device error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
