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

    await device.deleteOne();
    deviceRegistry.remove(device.deviceId);
    res.json({ ok: true });
  } catch (err) {
    console.error('Delete device error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
