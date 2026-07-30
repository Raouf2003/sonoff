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

    const device = await Device.findOne({ deviceId: deviceId.trim() });

    if (!device) {
      return res.status(404).json({ error: 'Device not found. Ensure the device ID is correct.' });
    }

    if (device.ownerId) {
      return res.status(409).json({ error: 'Device is already claimed by another user' });
    }

    device.ownerId = req.userId;
    device.name = name.trim();
    device.claimedAt = new Date();
    await device.save();

    res.json(device.toJSON());
  } catch (err) {
    console.error('Claim device error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
