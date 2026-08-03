const express = require('express');
const Device = require('../models/Device');
const deviceRegistry = require('../services/deviceRegistry');

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
      const { deviceId, name, channels } = req.body;

      if (!deviceId || !name) {
        return res.status(400).json({ error: 'deviceId and name are required' });
      }

      const tid = deviceId.trim();
      const ch = channels === undefined ? 4 : Number(channels);
      if (!Number.isInteger(ch) || ch < 1 || ch > 16) {
        return res.status(400).json({ error: 'channels must be an integer between 1 and 16' });
      }
      const type = ch === 1 ? 'sonoff-1ch' : `sonoff-${ch}ch`;

      let device = await Device.findOne({ deviceId: tid });

      if (device && device.ownerId) {
        return res.status(409).json({ error: 'Device is already claimed by another user' });
      }

      if (device) {
        device.ownerId = req.userId;
        device.name = name.trim();
        device.type = type;
        device.channels = ch;
        device.claimedAt = new Date();
      } else {
        device = await Device.create({
          deviceId: tid,
          name: name.trim(),
          ownerId: req.userId,
          type,
          channels: ch,
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

    await device.deleteOne();
    deviceRegistry.remove(device.deviceId);
    res.json({ ok: true });
  } catch (err) {
    console.error('Delete device error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
