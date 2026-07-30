const express = require('express');
const Device = require('../models/Device');

const router = express.Router();

router.post('/control', async (req, res) => {
  try {
    const { deviceId, channel, state } = req.body;

    if (!deviceId || !channel || !state) {
      return res.status(400).json({ error: 'deviceId, channel, and state are required' });
    }

    if (channel < 1 || channel > 4) {
      return res.status(400).json({ error: 'channel must be between 1 and 4' });
    }

    const validStates = ['ON', 'OFF', 'TOGGLE'];
    if (!validStates.includes(state.toUpperCase())) {
      return res.status(400).json({ error: 'state must be ON, OFF, or TOGGLE' });
    }

    const device = await Device.findOne({ deviceId });
    if (!device) {
      return res.status(404).json({ error: 'Device not found' });
    }

    if (!device.ownerId || device.ownerId.toString() !== req.userId) {
      return res.status(403).json({ error: 'You do not own this device' });
    }

    const mqttClient = req.app.get('mqttClient');
    if (!mqttClient) {
      return res.status(503).json({ error: 'MQTT broker not configured' });
    }

    const commandTopic = `cmnd/${deviceId}/POWER${channel}`;
    mqttClient.publish(commandTopic, state.toUpperCase());

    const key = `POWER${channel}`;
    const response = {};
    response[key] = state.toUpperCase();
    res.json(response);
  } catch (err) {
    console.error('Control error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.get('/status', async (req, res) => {
  try {
    const { deviceId } = req.query;

    if (!deviceId) {
      return res.status(400).json({ error: 'deviceId query parameter is required' });
    }

    const device = await Device.findOne({ deviceId });
    if (!device) {
      return res.status(404).json({ error: 'Device not found' });
    }

    if (!device.ownerId || device.ownerId.toString() !== req.userId) {
      return res.status(403).json({ error: 'You do not own this device' });
    }

    const deviceStates = req.app.get('deviceStates') || {};
    const state = deviceStates[deviceId] || {};

    const status = {};
    for (let i = 1; i <= 4; i++) {
      status[`POWER${i}`] = state[i] || 'OFF';
    }
    res.json(status);
  } catch (err) {
    console.error('Status error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
