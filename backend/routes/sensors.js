const express = require('express');
const Sensor = require('../models/Sensor');
const Device = require('../models/Device');
const Rule = require('../models/Rule');
const detectedSensors = require('../services/detectedSensors');

const router = express.Router();

const SENSOR_ID_RE = /^[A-Za-z0-9_.-]{1,40}$/;

const ONLINE_WINDOW = 5 * 60 * 1000;

// "status" is never stored in the database. It is derived on every response
// from lastSeen.
function statusOf(lastSeen) {
  const t = lastSeen ? new Date(lastSeen).getTime() : 0;
  return t && Date.now() - t < ONLINE_WINDOW ? 'online' : 'offline';
}

router.get('/', async (req, res) => {
  try {
    const sensors = await Sensor.find({ ownerId: req.userId }).sort({ createdAt: -1 });
    res.json(sensors.map((s) => ({ ...s.toJSON(), status: statusOf(s.lastSeen) })));
  } catch (err) {
    console.error('List sensors error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.post('/', async (req, res) => {
  try {
    const { name, sensorId, deviceId } = req.body;

    if (!name || !sensorId || !deviceId) {
      return res.status(400).json({ error: 'name, sensorId, and deviceId are required' });
    }

    const tid = String(sensorId).trim();
    if (!SENSOR_ID_RE.test(tid)) {
      return res.status(400).json({ error: 'sensorId must be 1-40 characters (letters, numbers, _ . -)' });
    }

    const did = String(deviceId).trim();
    const device = await Device.findOne({ deviceId: did, ownerId: req.userId });
    if (!device) {
      return res.status(400).json({ error: 'Device not found or not owned by you' });
    }

    const existing = await Sensor.findOne({ sensorId: tid });
    if (existing) {
      return res.status(409).json({ error: 'This Sensor ID is already added' });
    }

    const sensor = await Sensor.create({
      ownerId: req.userId,
      name: String(name).trim(),
      sensorId: tid,
      deviceId: did,
    });

    res.status(201).json({ ...sensor.toJSON(), status: statusOf(sensor.lastSeen) });
  } catch (err) {
    if (err && err.code === 11000) {
      return res.status(409).json({ error: 'This Sensor ID is already added' });
    }
    console.error('Create sensor error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Detected sensors: in-memory list of sensor IDs seen on MQTT. It only helps
// the user fill the Sensor ID field and never creates relationships.
router.get('/discovered', async (req, res) => {
  try {
    const discovered = detectedSensors.all();
    res.json(discovered.map((d) => ({ ...d, status: statusOf(d.lastSeen) })));
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
    await Rule.deleteMany({ ownerId: req.userId, sensorId: req.params.sensorId });
    res.json({ ok: true });
  } catch (err) {
    console.error('Delete sensor error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
