const express = require('express');
const Device = require('../models/Device');
const scheduleSyncService = require('../services/scheduleSyncService');

const router = express.Router();

// DEV-ONLY manual sync trigger (Phase 6.5). Mounted only in non-production
// environments by server.js. Returns the FULL dry-run/sync report from
// scheduleSyncService so the operator can inspect the compiled plan, the
// logical->physical allocation, the protected/unmanaged resources, the
// intended writes, and (after an enabled sync) the readback verification with
// actual vs desired configuration.
//
// Ownership rules still apply: the caller must own the device, exactly like the
// control routes. Timer3, Rule1 and Rule3 are never touched (see
// scheduleSyncService protectedResources/allocateSlots).
router.post('/sync/:deviceId', async (req, res) => {
  if (process.env.NODE_ENV === 'production') {
    return res.status(404).json({ error: 'Not found' });
  }
  try {
    const deviceId = String(req.params.deviceId || '').trim();
    if (!deviceId) {
      return res.status(400).json({ error: 'deviceId is required' });
    }

    const device = await Device.findOne({ deviceId });
    if (!device) {
      return res.status(404).json({ error: 'Device not found' });
    }
    if (!device.ownerId || device.ownerId.toString() !== req.userId) {
      return res.status(403).json({ error: 'You do not own this device' });
    }

    const report = await scheduleSyncService.manualSync(deviceId);
    res.json(report);
  } catch (err) {
    console.error('Dev manual sync error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

module.exports = router;