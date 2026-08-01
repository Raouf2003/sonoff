const express = require('express');
const User = require('../models/User');
const runtimeState = require('../services/runtimeState');

const router = express.Router();

router.get('/emergency-stop', async (req, res) => {
  try {
    const user = await User.findById(req.userId);
    res.json({ emergencyStop: !!(user && user.emergencyStop) });
  } catch (err) {
    console.error('Get emergency stop error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

router.post('/emergency-stop', async (req, res) => {
  try {
    const on = !!req.body.on;
    await User.updateOne({ _id: req.userId }, { emergencyStop: on });
    runtimeState.setEmergencyStop(req.userId, on);
    res.json({ emergencyStop: on });
  } catch (err) {
    console.error('Set emergency stop error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;
