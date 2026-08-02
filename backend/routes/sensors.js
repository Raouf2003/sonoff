const express = require('express');
const Sensor = require('../models/Sensor');
const Device = require('../models/Device');
const Rule = require('../models/Rule');
const mqttGateway = require('../services/mqttGateway');

const router = express.Router();

const SENSOR_ID_RE = /^[A-Za-z0-9_.-]{1,40}$/;

const ONLINE_WINDOW = 5 * 60 * 1000;

// A sensor is considered verified only if it reported on MQTT within this window.
const VERIFY_FRESH_MS = 15 * 1000;

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

    // Verify the sensor is live on MQTT by reading the in-memory cache. No
    // waiting, no promises, no blocking. A sensor with no fresh reading is
    // never created.
    const reading = mqttGateway.getSensorReading(tid, VERIFY_FRESH_MS);
    if (!reading) {
      return res.status(404).json({
        success: false,
        message: 'Sensor not found. Make sure the ESP32 is online and the Sensor ID is correct.',
      });
    }

    const sensor = await Sensor.create({
      ownerId: req.userId,
      name: String(name).trim(),
      sensorId: tid,
      deviceId: did,
      lastValue: reading.value,
      lastSeen: reading.lastSeen,
    });

    res.status(200).json({ success: true, sensor: { ...sensor.toJSON(), status: statusOf(sensor.lastSeen) } });
  } catch (err) {
    if (err && err.code === 11000) {
      return res.status(409).json({ error: 'This Sensor ID is already added' });
    }
    console.error('Create sensor error:', err);
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
