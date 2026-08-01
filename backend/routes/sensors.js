const express = require('express');
const Sensor = require('../models/Sensor');
const Rule = require('../models/Rule');
const Telemetry = require('../models/Telemetry');
const Device = require('../models/Device');
const ruleEngine = require('../services/ruleEngine');
const runtimeState = require('../services/runtimeState');

const router = express.Router();

const SENSOR_ID_RE = /^[a-zA-Z0-9_][a-zA-Z0-9_-]{0,39}$/;

function validateSensorId(id) {
  if (!id || !SENSOR_ID_RE.test(String(id).trim())) {
    return 'Sensor ID must be 1-40 characters (letters, numbers, _ or -)';
  }
  return null;
}

function enrich(sensor) {
  const out = sensor.toJSON();
  const ownerId = out.ownerId.toString();
  const live = runtimeState.getSensorValue(ownerId, out.sensorId);
  out.lastValue = live ? live.value : null;
  out.lastSeen = live ? live.lastSeen : null;
  return out;
}

router.get('/', async (req, res) => {
  try {
    const sensors = await Sensor.find({ ownerId: req.userId }).sort({ createdAt: -1 });
    res.json(sensors.map(enrich));
  } catch (err) {
    console.error('List sensors error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.get('/discovered', async (req, res) => {
  try {
    const sensors = await Sensor.find({ ownerId: req.userId }, 'sensorId');
    const registered = new Set(sensors.map((s) => s.sensorId));
    const devices = await Device.find({ ownerId: req.userId }, 'deviceId name');
    const nameByDevice = new Map(devices.map((d) => [d.deviceId, d.name]));

    const discovered = runtimeState
      .getSensorObservations(req.userId)
      .filter((obs) => !registered.has(obs.sensorId))
      .map((obs) => ({
        sensorId: obs.sensorId,
        deviceId: obs.deviceId,
        deviceName: nameByDevice.get(obs.deviceId) || obs.deviceId,
        value: obs.value,
        ts: obs.ts,
        count: obs.count,
      }));

    res.json(discovered);
  } catch (err) {
    console.error('List discovered sensors error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.post('/', async (req, res) => {
  try {
    const { name, sensorId } = req.body;

    if (!name || !String(name).trim()) {
      return res.status(400).json({ error: 'name is required' });
    }
    const idError = validateSensorId(sensorId);
    if (idError) return res.status(400).json({ error: idError });

    const sensor = await Sensor.create({
      ownerId: req.userId,
      sensorId: String(sensorId).trim(),
      name: String(name).trim(),
      type: 'generic',
      persistence: {
        mode: 'change_or_interval',
        intervalSeconds: 300,
        epsilon: 0,
      },
    });

    await ruleEngine.onSensorChanged(sensor);
    res.status(201).json(sensor.toJSON());
  } catch (err) {
    if (err && err.code === 11000) {
      return res.status(409).json({ error: 'That Sensor ID is already in use' });
    }
    console.error('Create sensor error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.put('/:sensorId', async (req, res) => {
  try {
    const sensor = await Sensor.findOne({ sensorId: req.params.sensorId, ownerId: req.userId });
    if (!sensor) return res.status(404).json({ error: 'Sensor not found' });

    const { name } = req.body;
    if (name !== undefined) {
      if (!String(name).trim()) {
        return res.status(400).json({ error: 'name is required' });
      }
      sensor.name = String(name).trim();
    }

    await sensor.save();
    await ruleEngine.onSensorChanged(sensor);
    res.json(enrich(sensor));
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
