const express = require('express');
const Device = require('../models/Device');

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
    res.json(device.toJSON());
  } catch (err) {
    console.error('Claim device error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
