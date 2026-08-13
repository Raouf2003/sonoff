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

    if (!Number.isInteger(channel) || channel < 1 || channel > (device.channels || 4)) {
      return res.status(400).json({ error: `channel must be between 1 and ${device.channels || 4}` });
    }

    if (!runtimeState.isOnline(deviceId)) {
      return res.status(409).json({ error: 'Device is not connected or is powered off' });
    }

    if (!mqttGateway.isConnected()) {
      return res.status(503).json({ error: 'MQTT broker not connected' });
    }

    let outcome;
    try {
      outcome = await mqttGateway.publishCommand(device.deviceId, channel, state.toUpperCase());
    } catch (err) {
      if (err.code === 'ACK_TIMEOUT') {
        return res.status(504).json({ error: 'Device did not acknowledge the command' });
      }
      if (err.code === 'SUPERSEDED') {
        return res.status(409).json({ error: 'A newer command superseded this one', code: 'SUPERSEDED' });
      }
      if (err.code === 'MQTT_DISCONNECTED' || /not connected|connection closed|connection reset/i.test(err.message || '')) {
        return res.status(503).json({ error: 'MQTT broker not connected' });
      }
      return res.status(500).json({ error: `Failed to publish command: ${err.message}` });
    }

    // The device report that resolved the ACK is the authoritative state: the
    // actual reported value (which may differ from the request), whether it
    // matched, and the runtimeState timestamp of that report.
    const reported = outcome.observed || state.toUpperCase();
    const key = `POWER${channel}`;
    const entry = runtimeState.getDeviceState(device.deviceId);
    const chEntry = entry ? entry.channels[channel] : null;
    res.json({
      [key]: reported,
      acked: !!outcome.acked,
      // The device's last-known LAN IP (learned via MQTT telemetry) so the app
      // can seed a local discovery candidate even if it only ever talks to the
      // cloud — identity is still verified with `Status 5` before use.
      lastIp: device.lastIp || null,
      channels: {
        [String(channel)]: {
          state: reported,
          updatedAt: chEntry && chEntry.updatedAt
            ? new Date(chEntry.updatedAt).toISOString()
            : null,
        },
      },
    });
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

    const count = device.channels || 4;
    const deviceStatus = runtimeState.getDeviceStatus(deviceId);
    const channels = deviceStatus.channels || {};

    // Per-channel `{ state, updatedAt }` — the authoritative shape. Channels
    // never observed report UNKNOWN (not a fabricated OFF).
    const status = {};
    status.channels = {};
    for (let i = 1; i <= count; i++) {
      const c = channels[String(i)] || { state: 'UNKNOWN', updatedAt: null };
      status.channels[String(i)] = { state: c.state || 'UNKNOWN', updatedAt: c.updatedAt || null };
    }
    // Legacy flat keys preserved for backward compatibility.
    for (let i = 1; i <= count; i++) {
      status[`POWER${i}`] = status.channels[String(i)].state;
    }
    status.online = deviceStatus.online;
    // Last-known LAN IP (MQTT telemetry) so the app can seed a local discovery
    // candidate during normal online status polling.
    status.lastIp = device.lastIp || null;
    res.json(status);
  } catch (err) {
    console.error('Status error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
