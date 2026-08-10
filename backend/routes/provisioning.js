const express = require('express');
const provisioningService = require('../services/provisioningService');

const router = express.Router();

const CLAIM_ERROR_STATUS = {
  SESSION_NOT_FOUND: 404,
  SESSION_USED: 409,
  SESSION_NOT_PENDING: 409,
  SESSION_EXPIRED: 410,
  INVALID_TOKEN: 403,
  BAD_DEVICE_ID: 400,
  BAD_CHANNELS: 400,
  BAD_NAME: 400,
  DEVICE_NOT_SEEN: 409,
  ALREADY_CLAIMED: 409,
};

// Create a provisioning session: issues a secret deviceId (== the MQTT topic
// the wizard will burn into the physical device) and a one-time claim token.
// The token is returned exactly once here.
router.post('/sessions', async (req, res) => {
  try {
    const data = await provisioningService.create(req.userId);
    res.status(201).json(data);
  } catch (err) {
    console.error('Create provisioning session error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Session status used by the wizard to poll for device visibility. Optional
// hardwareId may be attached (from the SoftAP read) so the claim can verify it.
router.post('/sessions/:sessionId/hardware', async (req, res) => {
  try {
    const session = await provisioningService.getForOwner(
      req.params.sessionId,
      req.userId,
    );
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }
    const hardwareId = String(req.body.hardwareId || '').trim();
    if (!hardwareId) {
      return res.status(400).json({ error: 'hardwareId is required' });
    }
    session.hardwareId = hardwareId;
    await session.save();
    res.json({ ok: true });
  } catch (err) {
    console.error('Attach hardwareId error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Session status (never exposes the claim token).
router.get('/sessions/:sessionId', async (req, res) => {
  try {
    const session = await provisioningService.getForOwner(
      req.params.sessionId,
      req.userId,
    );
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }
    res.json({
      sessionId: session.sessionId,
      deviceId: session.expectedDeviceId,
      hardwareId: session.hardwareId || null,
      status: session.status,
      deviceSeen: mqttGateway().hasRecent(session.expectedDeviceId),
      expiresAt: session.expiresAt,
    });
  } catch (err) {
    console.error('Get session error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Claim the device via its provisioning session. The token must match, the
// session must be pending + unexpired + owned by this user, the device must
// have announced on MQTT, and the claim itself is atomic (one winner).
router.post('/sessions/:sessionId/claim', async (req, res) => {
  try {
    const { claimToken, name, channels, hardwareId } = req.body;
    const device = await provisioningService.claim({
      sessionId: req.params.sessionId,
      ownerId: req.userId,
      claimToken,
      name,
      channels,
      hardwareId,
    });
    res.json(device.toJSON());
  } catch (err) {
    const status = CLAIM_ERROR_STATUS[err.code];
    if (status) {
      return res.status(status).json({ error: err.message, code: err.code });
    }
    console.error('Claim device error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;

// late require to avoid a circular import at module load time
function mqttGateway() {
  // eslint-disable-next-line global-require
  return require('../services/mqttGateway');
}