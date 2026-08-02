const express = require('express');
const Sensor = require('../models/Sensor');
const sensorDiscovery = require('../services/sensorDiscovery');

const router = express.Router();

const SENSOR_ID_RE = /^[A-Za-z0-9_.-]{1,40}$/;

router.get('/', async (req, res) => {
  try {
    const sensors = await Sensor.find({ ownerId: req.userId }).sort({ createdAt: -1 });
    res.json(sensors);
  } catch (err) {
    console.error('List sensors error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.post('/', async (req, res) => {
  try {
    const { name, sensorId } = req.body;

    if (!name || !sensorId) {
      return res.status(400).json({ error: 'name and sensorId are required' });
    }

    const tid = String(sensorId).trim();
    if (!SENSOR_ID_RE.test(tid)) {
      return res.status(400).json({ error: 'sensorId must be 1-40 characters (letters, numbers, _ . -)' });
    }

    const existing = await Sensor.findOne({ ownerId: req.userId, sensorId: tid });
    if (existing) {
      return res.status(409).json({ error: 'This Sensor ID is already added' });
    }

    const sensor = await Sensor.create({
      ownerId: req.userId,
      name: String(name).trim(),
      sensorId: tid,
    });

    res.status(201).json(sensor.toJSON());
  } catch (err) {
    if (err && err.code === 11000) {
      return res.status(409).json({ error: 'This Sensor ID is already added' });
    }
    console.error('Create sensor error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.get('/discovered', async (req, res) => {
  try {
    const discovered = sensorDiscovery.forOwner(req.userId);
    res.json(discovered);
  } catch (err) {
    console.error('Discovered sensors error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.delete('/:sensorId', async (req, res) => {
  try {
    const sensor = await Sensor.findOne({ ownerId: req.userId, sensorId: req.params.sensorId });
    if (!sensor) {
      return res.status(404).json({ error: 'Sensor not found' });
    }
    await sensor.deleteOne();
    res.json({ ok: true });
  } catch (err) {
    console.error('Delete sensor error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
