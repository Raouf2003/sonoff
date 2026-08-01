const express = require('express');
const Rule = require('../models/Rule');
const RuleLog = require('../models/RuleLog');
const Sensor = require('../models/Sensor');
const Device = require('../models/Device');
const ruleEngine = require('../services/ruleEngine');

const router = express.Router();

function normalizeRuleInput(body) {
  const { name, sensorId, condition, action, cooldownS, freshnessS, priority } = body;
  if (!name || !sensorId || !condition || !action) {
    return { error: 'name, sensorId, condition, and action are required' };
  }

  const band = condition.band || condition;
  const min = band.min !== undefined && band.min !== null ? Number(band.min) : null;
  const max = band.max !== undefined && band.max !== null ? Number(band.max) : null;
  if (min === null && max === null) {
    return { error: 'condition band needs at least one of min or max' };
  }
  if (min !== null && max !== null && min >= max) {
    return { error: 'min must be less than max' };
  }

  const { deviceId, channel, state } = action;
  if (!deviceId || !channel || !state) {
    return { error: 'action needs deviceId, channel, and state' };
  }
  const st = String(state).toUpperCase();
  if (!['ON', 'OFF', 'TOGGLE'].includes(st)) {
    return { error: 'action state must be ON, OFF, or TOGGLE' };
  }

  return {
    value: {
      name: String(name).trim(),
      sensorId: String(sensorId).trim(),
      condition: {
        band: {
          min,
          max,
          hysteresis: band.hysteresis !== undefined && band.hysteresis !== null ? Number(band.hysteresis) : 0,
        },
      },
      action: {
        deviceId: String(deviceId).trim(),
        channel: Number(channel),
        state: st,
      },
      cooldownS: cooldownS !== undefined && cooldownS !== null ? Number(cooldownS) : 0,
      freshnessS: freshnessS !== undefined && freshnessS !== null ? Number(freshnessS) : 3600,
      priority: priority !== undefined && priority !== null ? Number(priority) : 0,
    },
  };
}

async function validateOwnership(userId, input) {
  if (input.error) return input;
  const sensor = await Sensor.findOne({ sensorId: input.value.sensorId, ownerId: userId });
  if (!sensor) return { error: 'Sensor not found or not owned by you' };
  const device = await Device.findOne({
    deviceId: input.value.action.deviceId,
    ownerId: userId,
  });
  if (!device) return { error: 'Action device not found or not owned by you' };
  const ch = input.value.action.channel;
  if (ch < 1 || ch > (device.channels || 4)) {
    return { error: `Channel must be between 1 and ${device.channels || 4}` };
  }
  return input;
}

router.get('/', async (req, res) => {
  try {
    const rules = await Rule.find({ ownerId: req.userId }).sort({ createdAt: -1 });
    res.json(rules);
  } catch (err) {
    console.error('List rules error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.get('/logs', async (req, res) => {
  try {
    const limit = Math.min(parseInt(req.query.limit || '50', 10), 200);
    const logs = await RuleLog.find({ ownerId: req.userId }).sort({ ts: -1 }).limit(limit);
    res.json(logs);
  } catch (err) {
    console.error('List rule logs error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.post('/', async (req, res) => {
  try {
    const input = await validateOwnership(req.userId, normalizeRuleInput(req.body));
    if (input.error) return res.status(400).json({ error: input.error });

    const rule = await Rule.create({ ownerId: req.userId, ...input.value });
    await ruleEngine.onRuleChanged(rule);
    res.status(201).json(rule.toJSON());
  } catch (err) {
    console.error('Create rule error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.put('/:id', async (req, res) => {
  try {
    const rule = await Rule.findOne({ _id: req.params.id, ownerId: req.userId });
    if (!rule) return res.status(404).json({ error: 'Rule not found' });

    const input = await validateOwnership(req.userId, normalizeRuleInput(req.body));
    if (input.error) return res.status(400).json({ error: input.error });

    const updated = input.value;
    rule.name = updated.name;
    rule.sensorId = updated.sensorId;
    rule.condition = updated.condition;
    rule.action = updated.action;
    rule.cooldownS = updated.cooldownS;
    rule.freshnessS = updated.freshnessS;
    rule.priority = updated.priority;
    rule.version = (rule.version || 1) + 1;
    rule.updatedAt = new Date();

    await rule.save();
    await ruleEngine.onRuleChanged(rule);
    res.json(rule.toJSON());
  } catch (err) {
    console.error('Update rule error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.post('/:id/toggle', async (req, res) => {
  try {
    const rule = await Rule.findOne({ _id: req.params.id, ownerId: req.userId });
    if (!rule) return res.status(404).json({ error: 'Rule not found' });

    rule.enabled = !rule.enabled;
    rule.version = (rule.version || 1) + 1;
    rule.updatedAt = new Date();
    await rule.save();
    await ruleEngine.onRuleChanged(rule);
    res.json(rule.toJSON());
  } catch (err) {
    console.error('Toggle rule error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.delete('/:id', async (req, res) => {
  try {
    const rule = await Rule.findOne({ _id: req.params.id, ownerId: req.userId });
    if (!rule) return res.status(404).json({ error: 'Rule not found' });

    await rule.deleteOne();
    await ruleEngine.onRuleDeleted(rule);
    res.json({ ok: true });
  } catch (err) {
    console.error('Delete rule error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
