const express = require('express');
const crypto = require('crypto');
const Sensor = require('../models/Sensor');
const Rule = require('../models/Rule');
const Telemetry = require('../models/Telemetry');
const Device = require('../models/Device');
const ruleEngine = require('../services/ruleEngine');

const router = express.Router();

function generateSensorId() {
  return `sensor_${crypto.randomBytes(4).toString('hex')}`;
}

async function validateDeviceOwnership(userId, deviceId) {
  if (!deviceId) return null;
  const device = await Device.findOne({ deviceId, ownerId: userId });
  if (!device) return { error: 'Device not found or not owned by you' };
  return device;
}

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
    const { name, type, deviceId, field, persistence } = req.body;

    if (!name || !field) {
      return res.status(400).json({ error: 'name and field are required' });
    }

    const device = await validateDeviceOwnership(req.userId, deviceId);
    if (device && device.error) return res.status(400).json({ error: device.error });

    const sensor = await Sensor.create({
      sensorId: generateSensorId(),
      ownerId: req.userId,
      name: String(name).trim(),
      type: (type || 'generic').trim(),
      deviceId: deviceId || null,
      field: String(field).trim(),
      persistence: {
        mode: (persistence && persistence.mode) || 'change_or_interval',
        intervalSeconds: (persistence && persistence.intervalSeconds) || 300,
        epsilon: (persistence && persistence.epsilon) || 0,
      },
    });

    await ruleEngine.onSensorChanged(sensor);
    res.status(201).json(sensor.toJSON());
  } catch (err) {
    console.error('Create sensor error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.put('/:sensorId', async (req, res) => {
  try {
    const sensor = await Sensor.findOne({ sensorId: req.params.sensorId, ownerId: req.userId });
    if (!sensor) return res.status(404).json({ error: 'Sensor not found' });

    const { name, type, deviceId, field, persistence } = req.body;

    const device = await validateDeviceOwnership(req.userId, deviceId);
    if (device && device.error) return res.status(400).json({ error: device.error });

    if (name !== undefined) sensor.name = String(name).trim();
    if (type !== undefined) sensor.type = String(type).trim();
    if (field !== undefined) sensor.field = String(field).trim();
    if (deviceId !== undefined) sensor.deviceId = deviceId || null;
    if (persistence) {
      if (persistence.mode !== undefined) sensor.persistence.mode = persistence.mode;
      if (persistence.intervalSeconds !== undefined) sensor.persistence.intervalSeconds = persistence.intervalSeconds;
      if (persistence.epsilon !== undefined) sensor.persistence.epsilon = persistence.epsilon;
    }

    await sensor.save();
    await ruleEngine.onSensorChanged(sensor);
    res.json(sensor.toJSON());
  } catch (err) {
    console.error('Update sensor error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.delete('/:sensorId', async (req, res) => {
  try {
    const sensor = await Sensor.findOne({ sensorId: req.params.sensorId, ownerId: req.userId });
    if (!sensor) return res.status(404).json({ error: 'Sensor not found' });

    const referenced = await Rule.findOne({ ownerId: req.userId, sensorId: sensor.sensorId });
    if (referenced) {
      return res.status(409).json({ error: 'Delete rules referencing this sensor first' });
    }

    await sensor.deleteOne();
    await ruleEngine.onSensorDeleted(sensor);
    res.json({ ok: true });
  } catch (err) {
    console.error('Delete sensor error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.get('/:sensorId/telemetry', async (req, res) => {
  try {
    const sensor = await Sensor.findOne({ sensorId: req.params.sensorId, ownerId: req.userId });
    if (!sensor) return res.status(404).json({ error: 'Sensor not found' });

    const limit = Math.min(parseInt(req.query.limit || '50', 10), 500);
    const readings = await Telemetry.find({ ownerId: req.userId, sensorId: sensor.sensorId })
      .sort({ ts: -1 })
      .limit(limit);
    res.json(readings);
  } catch (err) {
    console.error('Get telemetry error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
