const express = require('express');
const jwt = require('jsonwebtoken');
const Device = require('../models/Device');
const PushToken = require('../models/PushToken');
const { getAdmin, getFirebaseInitStatus, tokenPreview } = require('../services/weatherNotifyService');
const { JWT_SECRET } = require('../middleware/auth');

const router = express.Router();

// Diagnostic auth: accepts EITHER the owner's JWT (same as all /api routes)
// OR the operator service key (WEATHER_CRON_KEY via x-service-key) so the
// endpoint can be curled on Render without minting a JWT. If WEATHER_CRON_KEY
// is not configured, JWT is the only accepted credential.
function debugAuth(req, res, next) {
  const serviceKey = process.env.WEATHER_CRON_KEY;
  const provided = req.headers['x-service-key'];
  if (serviceKey && provided && provided === serviceKey) {
    req.debugAuthMode = 'service-key';
    return next();
  }
  const header = req.headers.authorization;
  if (header && header.startsWith('Bearer ')) {
    try {
      const decoded = jwt.verify(header.split(' ')[1], JWT_SECRET);
      req.userId = decoded.userId;
      req.debugAuthMode = 'jwt';
      return next();
    } catch (_) {
      // fall through to 401 below
    }
  }
  return res.status(401).json({
    error: 'Unauthorized: provide Bearer JWT or x-service-key',
    usage: 'POST /debug/test-push?deviceId=<id> with Authorization: Bearer <jwt>',
  });
}

router.use(debugAuth);

// POST /debug/test-push?deviceId=<id>  (also GET for easy curl)
// DIRECT FCM TEST-SEND — bypasses weatherScheduleAnalyzer + dedup entirely.
// Looks up the stored FCM token(s) for the device's owner, calls
// admin.messaging().send() once per token with a trivial payload, and returns
// the FULL raw Firebase response/error per token (messageId on success;
// error.code + error.message on failure). Nothing here changes any
// notification-sending logic; this is pure diagnostics.
//
// Interpretation:
//   - test ping does NOT arrive  -> token/FCM/device-side issue, not trigger logic
//   - test ping DOES arrive       -> issue is in weatherScheduler trigger path
//                                   (dedup, token-lookup mismatch, etc.)
async function handleTestPush(req, res) {
  const startedAt = new Date().toISOString();
  const deviceId = String((req.query && req.query.deviceId) || (req.body && req.body.deviceId) || '').trim();
  if (!deviceId) {
    return res.status(400).json({ ok: false, error: 'deviceId is required, e.g. POST /debug/test-push?deviceId=<id>' });
  }
  try {
    const device = await Device.findOne({ deviceId });
    if (!device) {
      console.log(`[debug][test-push] deviceId=${deviceId} -> DEVICE_NOT_FOUND`);
      return res.status(404).json({ ok: false, deviceId, reason: 'DEVICE_NOT_FOUND' });
    }
    // JWT callers may only test their own devices; service-key is operator-wide.
    if (req.debugAuthMode === 'jwt' && (!device.ownerId || device.ownerId.toString() !== String(req.userId))) {
      return res.status(403).json({ ok: false, deviceId, error: 'You do not own this device' });
    }
    const ownerId = device.ownerId;

    // STEP 4 — token freshness: what is stored RIGHT NOW + timestamps.
    let tokenRows = [];
    try {
      tokenRows = ownerId ? await PushToken.find({ ownerId }).lean() : [];
    } catch (e) {
      console.error(`[debug][test-push] token lookup failed for owner=${String(ownerId)}: ${e.message}`);
    }
    const tokens = tokenRows.map((t) => ({
      preview: tokenPreview(t.token),
      length: String(t.token || '').length,
      platform: t.platform || null,
      createdAt: t.createdAt ? new Date(t.createdAt).toISOString() : null,
      updatedAt: t.updatedAt ? new Date(t.updatedAt).toISOString() : null,
    }));
    console.log(
      `[debug][test-push] deviceId=${deviceId} owner=${ownerId ? String(ownerId) : 'none'} ` +
        `auth=${req.debugAuthMode} tokens=${tokenRows.length} freshness=${JSON.stringify(tokens)}`,
    );

    // STEP 3 context — Firebase Admin init status (no secrets logged).
    const firebase = getFirebaseInitStatus();
    console.log(
      `[debug][test-push] firebase configured=${firebase.configured} source=${firebase.source || 'none'} ` +
        `project_id=${firebase.projectId || 'unknown'} initError=${firebase.initError || 'none'}`,
    );

    if (!ownerId || tokenRows.length === 0) {
      return res.json({
        ok: false,
        startedAt,
        deviceId,
        ownerId: ownerId ? String(ownerId) : null,
        reason: 'NO_TOKENS',
        detail: 'No FCM tokens stored for this device owner. Open the app on the device (grants permission + registers token via POST /api/weather/push-tokens), then retry.',
        firebase: { configured: firebase.configured, projectId: firebase.projectId, source: firebase.source },
        tokens,
        results: [],
      });
    }
    const admin = getAdmin();
    if (!admin) {
      console.error(
        `[debug][test-push] FCM_NOT_CONFIGURED project_id=${firebase.projectId || 'unknown'} parseError=${firebase.parseError || 'none'}`,
      );
      return res.json({
        ok: false,
        startedAt,
        deviceId,
        ownerId: String(ownerId),
        reason: 'FCM_NOT_CONFIGURED',
        detail: 'FIREBASE_SERVICE_ACCOUNT_JSON/BASE64 missing or invalid on the server. Check Render env + startup log line [weather][firebase].',
        firebase: {
          configured: firebase.configured,
          projectId: firebase.projectId,
          source: firebase.source,
          parseError: firebase.parseError || null,
          initError: firebase.initError || null,
        },
        tokens,
        results: [],
      });
    }

    // STEP 1 — direct send, one admin.messaging().send() per token so each
    // token yields its own RAW Firebase response/error (no multicast summary).
    const results = [];
    for (const row of tokenRows) {
      const preview = tokenPreview(row.token);
      const message = {
        token: row.token,
        notification: { title: 'Test', body: 'diagnostic ping' },
        data: { diagnostic: 'true', deviceId: String(deviceId), at: startedAt },
        android: { priority: 'high' },
      };
      try {
        // eslint-disable-next-line no-await-in-loop
        const messageId = await admin.messaging().send(message);
        console.log(`[debug][test-push] SEND OK token=${preview} messageId=${messageId}`);
        results.push({ tokenPreview: preview, success: true, messageId, raw: messageId });
      } catch (err) {
        const code = (err && (err.code || (err.errorInfo && err.errorInfo.code))) || null;
        const errMsg = (err && err.message) || String(err);
        console.error(`[debug][test-push] SEND FAIL token=${preview} code=${code} message=${errMsg}`);
        results.push({
          tokenPreview: preview,
          success: false,
          errorCode: code,
          errorMessage: errMsg,
          raw: { code, message: errMsg, errorInfo: (err && err.errorInfo) || null, stack: err && err.stack ? String(err.stack).split('\n').slice(0, 5).join('\n') : null },
        });
      }
    }
    const delivered = results.filter((r) => r.success).length;
    return res.json({
      ok: delivered > 0,
      startedAt,
      finishedAt: new Date().toISOString(),
      deviceId,
      ownerId: String(ownerId),
      firebase: { configured: true, projectId: firebase.projectId, source: firebase.source },
      tokens,
      summary: { attempted: results.length, delivered, failed: results.length - delivered },
      results,
    });
  } catch (err) {
    console.error(`[debug][test-push] internal error deviceId=${deviceId}: ${err.message}`);
    return res.status(500).json({ ok: false, deviceId, error: err.message });
  }
}

router.post('/test-push', handleTestPush);
router.get('/test-push', handleTestPush);

module.exports = router;
