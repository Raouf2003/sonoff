const express = require('express');
const Rule = require('../models/Rule');
const Sensor = require('../models/Sensor');
const Device = require('../models/Device');

const router = express.Router();

router.get('/', async (req, res) => {
  try {
    const rules = await Rule.find({ ownerId: req.userId }).sort({ createdAt: -1 });

    const sensorIds = [...new Set(rules.map((r) => r.sensorId))];
    const sensors = await Sensor.find({ ownerId: req.userId, sensorId: { $in: sensorIds } });
    const sensorMap = new Map(sensors.map((s) => [s.sensorId, s.name]));

    const deviceIds = [...new Set(rules.map((r) => r.deviceId))];
    const devices = await Device.find({ ownerId: req.userId, deviceId: { $in: deviceIds } });
    const deviceMap = new Map(devices.map((d) => [d.deviceId, d.name]));

    res.json(
      rules.map((r) => ({
        ...r.toJSON(),
        sensorName: sensorMap.get(r.sensorId) || null,
        deviceName: deviceMap.get(r.deviceId) || null,
      })),
    );
  } catch (err) {
    console.error('List rules error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.post('/', async (req, res) => {
  try {
    const { name, sensorId, channel, condition, threshold, action } = req.body;

    if (!name || !sensorId) {
      return res.status(400).json({ error: 'name and sensorId are required' });
    }
    if (!channel || channel < 1 || channel > 4) {
      return res.status(400).json({ error: 'channel must be between 1 and 4' });
    }
    if (condition !== 'above' && condition !== 'below') {
      return res.status(400).json({ error: 'condition must be above or below' });
    }
    if (typeof threshold !== 'number') {
      return res.status(400).json({ error: 'threshold must be a number' });
    }
    if (action !== 'ON' && action !== 'OFF') {
      return res.status(400).json({ error: 'action must be ON or OFF' });
    }

    const sensor = await Sensor.findOne({ sensorId: String(sensorId).trim(), ownerId: req.userId });
    if (!sensor) {
      return res.status(404).json({ error: 'Sensor not found' });
    }

    // deviceId always comes from the sensor, never from the client.
    const device = await Device.findOne({ deviceId: sensor.deviceId, ownerId: req.userId });
    if (!device) {
      return res.status(400).json({ error: 'The sensor device is not available' });
    }

    const rule = await Rule.create({
      ownerId: req.userId,
      name: String(name).trim(),
      sensorId: sensor.sensorId,
      deviceId: device.deviceId,
      channel,
      condition,
      threshold,
      action,
    });

    res.status(201).json(rule.toJSON());
  } catch (err) {
    console.error('Create rule error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.patch('/:id/enable', async (req, res) => {
  try {
    const rule = await Rule.findOne({ _id: req.params.id, ownerId: req.userId });
    if (!rule) {
      return res.status(404).json({ error: 'Rule not found' });
    }
    rule.enabled = !rule.enabled;
    await rule.save();
    res.json(rule.toJSON());
  } catch (err) {
    console.error('Toggle rule error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.delete('/:id', async (req, res) => {
  try {
    const rule = await Rule.findOne({ _id: req.params.id, ownerId: req.userId });
    if (!rule) {
      return res.status(404).json({ error: 'Rule not found' });
    }
    await rule.deleteOne();
    res.json({ ok: true });
  } catch (err) {
    console.error('Delete rule error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
