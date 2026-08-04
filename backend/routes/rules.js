const express = require('express');
const Rule = require('../models/Rule');
const Sensor = require('../models/Sensor');
const Device = require('../models/Device');
const ruleEngine = require('../services/ruleEngine');

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
      rules.map((r) => {
        const json = r.toJSON();
        // Backward compat: ensure `channels` is always present in the response.
        if (!json.channels || json.channels.length === 0) {
          json.channels = typeof json.channel === 'number' ? [json.channel] : [];
        }
        delete json.channel;
        json.sensorName = sensorMap.get(r.sensorId) || null;
        json.deviceName = deviceMap.get(r.deviceId) || null;
        return json;
      }),
    );
  } catch (err) {
    console.error('List rules error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.post('/', async (req, res) => {
  try {
    const { name, sensorId, channels, channel, condition, threshold, action } = req.body;

    if (!name || !sensorId) {
      return res.status(400).json({ error: 'name and sensorId are required' });
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

    // Normalize channels: accept `channels` (array) or `channel` (single number).
    let channelList;
    if (Array.isArray(channels) && channels.length > 0) {
      channelList = channels.map(Number);
    } else if (typeof channel === 'number' && channel >= 1) {
      channelList = [channel];
    } else {
      return res.status(400).json({ error: 'channels must be a non-empty array of positive integers' });
    }

    // Validate: all integers, all >= 1, no duplicates.
    if (!channelList.every((n) => Number.isInteger(n) && n >= 1)) {
      return res.status(400).json({ error: 'channels must contain only positive integers' });
    }
    if (new Set(channelList).size !== channelList.length) {
      return res.status(400).json({ error: 'channels must not contain duplicates' });
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

    const maxCh = device.channels || 4;
    const invalid = channelList.filter((ch) => ch > maxCh);
    if (invalid.length > 0) {
      return res.status(400).json({ error: `channels ${invalid.join(',')} exceed device max of ${maxCh}` });
    }

    const rule = await Rule.create({
      ownerId: req.userId,
      name: String(name).trim(),
      sensorId: sensor.sensorId,
      deviceId: device.deviceId,
      channels: channelList,
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

router.patch('/:id', async (req, res) => {
  try {
    const rule = await Rule.findOne({ _id: req.params.id, ownerId: req.userId });
    if (!rule) {
      return res.status(404).json({ error: 'Rule not found' });
    }

    const { name, channels, channel, condition, threshold, action } = req.body;

    if (name !== undefined) rule.name = String(name).trim();
    if (condition !== undefined) {
      if (condition !== 'above' && condition !== 'below') {
        return res.status(400).json({ error: 'condition must be above or below' });
      }
      rule.condition = condition;
    }
    if (threshold !== undefined) {
      if (typeof threshold !== 'number') {
        return res.status(400).json({ error: 'threshold must be a number' });
      }
      rule.threshold = threshold;
    }
    if (action !== undefined) {
      if (action !== 'ON' && action !== 'OFF') {
        return res.status(400).json({ error: 'action must be ON or OFF' });
      }
      rule.action = action;
    }

    // Normalize channels if provided.
    if (channels !== undefined || channel !== undefined) {
      let channelList;
      if (Array.isArray(channels) && channels.length > 0) {
        channelList = channels.map(Number);
      } else if (typeof channel === 'number' && channel >= 1) {
        channelList = [channel];
      } else {
        return res.status(400).json({ error: 'channels must be a non-empty array of positive integers' });
      }

      if (!channelList.every((n) => Number.isInteger(n) && n >= 1)) {
        return res.status(400).json({ error: 'channels must contain only positive integers' });
      }
      if (new Set(channelList).size !== channelList.length) {
        return res.status(400).json({ error: 'channels must not contain duplicates' });
      }

      const device = await Device.findOne({ deviceId: rule.deviceId, ownerId: req.userId });
      if (device) {
        const maxCh = device.channels || 4;
        const invalid = channelList.filter((ch) => ch > maxCh);
        if (invalid.length > 0) {
          return res.status(400).json({ error: `channels ${invalid.join(',')} exceed device max of ${maxCh}` });
        }
      }

      rule.channels = channelList;
    }

    await rule.save();
    ruleEngine.invalidate(rule._id);
    res.json(rule.toJSON());
  } catch (err) {
    console.error('Update rule error:', err);
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
    // Clear the engine's in-memory edge-state cache so the next tick re-reads
    // the persisted lastConditionState from DB instead of reusing a stale value.
    ruleEngine.invalidate(rule._id);
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
    // Clear the engine's cache entry for this rule to keep memory clean.
    ruleEngine.invalidate(rule._id);
    await rule.deleteOne();
    res.json({ ok: true });
  } catch (err) {
    console.error('Delete rule error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
