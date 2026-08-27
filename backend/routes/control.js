const express = require('express');
const Device = require('../models/Device');
const deviceRegistry = require('../services/deviceRegistry');
const mqttGateway = require('../services/mqttGateway');
const runtimeState = require('../services/runtimeState');
const { timeline } = require('../services/timeline');

const router = express.Router();

router.post('/control', async (req, res) => {
  try {
    const { deviceId, channel, state, opId } = req.body;
    timeline(deviceId, channel, opId, 'Backend request received');

    if (!deviceId || !channel || !state) {
      return res.status(400).json({ error: 'deviceId, channel, and state are required' });
    }

    const validStates = ['ON', 'OFF', 'TOGGLE'];
    if (!validStates.includes(state.toUpperCase())) {
      return res.status(400).json({ error: 'state must be ON, OFF, or TOGGLE' });
    }

    // P3: deviceRegistry-first lookup (in-memory, ~0ms) with DB fallback on miss.
    // Registry is kept in sync on provision/delete/unclaim; ownership transfer
    // is authoritative via DB unique index, so a registry miss always falls
    // back to the DB to avoid stale 404/403.
    let device = deviceRegistry.get(deviceId);
    if (!device) {
      device = await Device.findOne({ deviceId });
      if (!device) {
        return res.status(404).json({ error: 'Device not found' });
      }
    }

    const ownerIdStr = device.ownerId ? device.ownerId.toString() : null;
    if (!ownerIdStr || ownerIdStr !== req.userId) {
      return res.status(403).json({ error: 'You do not own this device' });
    }

    const channels = device.channels || 4;
    if (!Number.isInteger(channel) || channel < 1 || channel > channels) {
      return res.status(400).json({ error: `channel must be between 1 and ${channels}` });
    }

    if (!runtimeState.isOnline(deviceId)) {
      return res.status(409).json({ error: 'Device is not connected or is powered off' });
    }

    if (!mqttGateway.isConnected()) {
      return res.status(503).json({ error: 'MQTT broker not connected' });
    }

    let ack;
    try {
      ack = await mqttGateway.publishCommand(
        device.deviceId,
        channel,
        state.toUpperCase(),
        opId,
      );
    } catch (err) {
      if (err.code === 'ACK_TIMEOUT') {
        timeline(device.deviceId, channel, opId, 'ACK_TIMEOUT');
        return res.status(504).json({ error: 'Device did not acknowledge the command' });
      }
      if (err.code === 'SUPERSEDED') {
        timeline(device.deviceId, channel, opId, 'SUPERSEDED');
        return res.status(409).json({ error: 'A newer command superseded this one', code: 'SUPERSEDED' });
      }
      if (err.code === 'MQTT_DISCONNECTED' || /not connected|connection closed|connection reset/i.test(err.message || '')) {
        timeline(device.deviceId, channel, opId, 'MQTT_DISCONNECTED');
        return res.status(503).json({ error: 'MQTT broker not connected' });
      }
      return res.status(500).json({ error: `Failed to publish command: ${err.message}` });
    }

    timeline(device.deviceId, channel, opId, 'HTTP 202 sent');
    return res.status(202).json({
      status: 'pending',
      opId: opId || null,
      acked: false,
      pending: true,
      deviceId: device.deviceId,
      channel,
      expected: state.toUpperCase(),
      online: true,
      lastIp: device.lastIp || null,
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
