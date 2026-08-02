const express = require('express');
const Device = require('../models/Device');
const mqttGateway = require('../services/mqttGateway');
const runtimeState = require('../services/runtimeState');

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

    if (!mqttGateway.isConnected()) {
      return res.status(503).json({ error: 'MQTT broker not connected' });
    }

    try {
      await mqttGateway.publishCommandNoWait(device.deviceId, channel, state.toUpperCase());
    } catch (err) {
      return res.status(502).json({ error: `Failed to publish command: ${err.message}` });
    }

    const key = `POWER${channel}`;
    res.json({ [key]: state.toUpperCase(), acked: null });
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

    const deviceState = runtimeState.getDeviceState(deviceId);
    const channels = deviceState ? deviceState.channels : {};

    const status = {};
    for (let i = 1; i <= 4; i++) {
      status[`POWER${i}`] = channels[i] || 'OFF';
    }
    res.json(status);
  } catch (err) {
    console.error('Status error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
