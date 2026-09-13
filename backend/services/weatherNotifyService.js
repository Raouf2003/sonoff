const Device = require('../models/Device');
const Schedule = require('../models/Schedule');
const WeatherAdvisory = require('../models/WeatherAdvisory');
const PushToken = require('../models/PushToken');
const weatherService = require('./weatherService');
const { analyzeSchedules } = require('./weatherScheduleAnalyzer');
const { APP_TIMEZONE } = require('./weatherConfig');

function locationKeyFor(device) {
  const lat = typeof device.lat === 'number' ? device.lat.toFixed(4) : 'null';
  const lon = typeof device.lon === 'number' ? device.lon.toFixed(4) : 'null';
  const tz = device.timezone || APP_TIMEZONE;
  return `${lat},${lon},${tz}`;
}

function advisoryText({ farmName, advisory }) {
  const farm = farmName ? `${farmName}\n` : '';
  return (
    `\u{1F327} Rain expected during irrigation\n\n${farm}` +
    `Schedule: ${advisory.scheduleStart}\u2013${advisory.scheduleEnd}\n` +
    `Rain: ${advisory.rainStart}\u2013${advisory.rainEnd} (${advisory.rainDate})\n` +
    `Expected: ${advisory.precipitationMm} mm\n` +
    `Probability: ${advisory.probability}%\n\n` +
    `Consider reviewing today's irrigation schedule.`
  );
}

let _admin = null;
let _firebaseStatus = null;

function firebaseEnvSource() {
  if (process.env.FIREBASE_SERVICE_ACCOUNT_JSON) return 'FIREBASE_SERVICE_ACCOUNT_JSON';
  if (process.env.FIREBASE_SERVICE_ACCOUNT_BASE64) return 'FIREBASE_SERVICE_ACCOUNT_BASE64';
  return null;
}

function parseFirebaseCreds() {
  const b64 = process.env.FIREBASE_SERVICE_ACCOUNT_JSON || process.env.FIREBASE_SERVICE_ACCOUNT_BASE64;
  if (!b64) return { creds: null, source: null, parseError: null };
  const source = firebaseEnvSource();
  const jsonStr = b64.trim().startsWith('{') ? b64 : Buffer.from(b64, 'base64').toString('utf8');
  try {
    return { creds: JSON.parse(jsonStr), source, parseError: null };
  } catch (e) {
    return { creds: null, source, parseError: e.message };
  }
}

function getAdmin() {
  if (_admin) return _admin;
  const { creds, parseError } = parseFirebaseCreds();
  if (!creds) {
    if (parseError) console.warn(`[weather] Firebase Admin init failed: ${parseError}`);
    return null;
  }
  try {
    const admin = require('firebase-admin');
    if (admin.apps.length === 0) {
      admin.initializeApp({ credential: admin.credential.cert(creds) });
    }
    _admin = admin;
    return _admin;
  } catch (e) {
    console.warn(`[weather] Firebase Admin init failed: ${e.message}`);
    return null;
  }
}

// DIAGNOSTIC (step 3): report Firebase Admin init status without leaking the
// service-account secret. Safe to call at server startup and from debug routes.
// Never throws; returns a plain object and logs one summary line.
function getFirebaseInitStatus() {
  if (_firebaseStatus) return _firebaseStatus;
  const source = firebaseEnvSource();
  const rawLen = source ? String(process.env[source] || '').length : 0;
  const { creds, parseError } = parseFirebaseCreds();
  const status = {
    configured: !!creds,
    source,
    envPresent: !!source,
    envLength: rawLen,
    projectId: (creds && creds.project_id) || null,
    clientEmail: (creds && creds.client_email) || null,
    parseError,
    initialized: false,
    appsCount: 0,
    initError: null,
  };
  if (!creds) {
    _firebaseStatus = status;
    return status;
  }
  try {
    const admin = require('firebase-admin');
    if (admin.apps.length === 0) {
      admin.initializeApp({ credential: admin.credential.cert(creds) });
    }
    _admin = admin;
    status.initialized = true;
    status.appsCount = admin.apps.length;
    try {
      status.projectId = status.projectId || admin.apps[0].options.projectId || null;
    } catch (_) {}
  } catch (e) {
    status.initError = e.message;
  }
  _firebaseStatus = status;
  return status;
}

function logFirebaseInitStatus(logger) {
  const log = logger || console;
  try {
    const s = getFirebaseInitStatus();
    if (!s.configured) {
      log.warn(
        `[weather][firebase] NOT CONFIGURED source=${s.source || 'none'} ` +
          `parseError=${s.parseError || 'none'} — FCM sends will return FCM_NOT_CONFIGURED`,
      );
    } else if (s.initError) {
      log.warn(`[weather][firebase] INIT FAILED source=${s.source} project_id=${s.projectId || 'unknown'} error=${s.initError}`);
    } else {
      log.log(
        `[weather][firebase] OK source=${s.source} project_id=${s.projectId || 'unknown'} ` +
          `client_email=${s.clientEmail || 'unknown'} apps=${s.appsCount}`,
      );
    }
    return s;
  } catch (e) {
    log.warn(`[weather][firebase] status check failed: ${e.message}`);
    return { configured: false, initError: e.message };
  }
}

// DIAGNOSTIC (step 4): truncated token preview for logs/responses — never
// print a full FCM registration token to stdout or JSON responses.
function tokenPreview(token) {
  const t = String(token || '');
  if (t.length <= 20) return `${t.slice(0, 6)}...(${t.length})`;
  return `${t.slice(0, 12)}...${t.slice(-4)}(${t.length})`;
}

// Server-side push hook. FCM via Firebase Admin SDK HTTP v1, credentials stay backend-only.
// Always emits Socket.IO live update; FCM is best-effort. Never touches MQTT/Tasmota.
async function sendPush({ ownerId, title, body, data, io } = {}) {
  let tokens = [];
  try {
    tokens = await PushToken.find({ ownerId }).lean();
  } catch (_) {
    tokens = [];
  }
  if (io) {
    io.to(`user:${String(ownerId)}`).emit('weather_advisory', {
      title,
      body,
      data: data || null,
      at: new Date().toISOString(),
    });
  }
  // DIAGNOSTIC (step 4): token freshness — which tokens exist for this owner
  // and how old they are. Preview only, never full tokens. Diagnostic-only;
  // does not change send behavior.
  try {
    const freshness = (tokens || []).map((t) => ({
      preview: tokenPreview(t.token),
      platform: t.platform || 'unknown',
      createdAt: t.createdAt ? new Date(t.createdAt).toISOString() : null,
      updatedAt: t.updatedAt ? new Date(t.updatedAt).toISOString() : null,
    }));
    console.log(`[weather][push] owner=${String(ownerId)} tokens=${tokens.length} freshness=${JSON.stringify(freshness)}`);
  } catch (_) {}
  if (tokens.length === 0) {
    return { delivered: false, reason: 'NO_TOKENS', tokens: 0, socketEmitted: !!io };
  }
  const admin = getAdmin();
  if (!admin) {
    return { delivered: false, reason: 'FCM_NOT_CONFIGURED', tokens: tokens.length, socketEmitted: !!io };
  }
  const tokenStrings = tokens.map((t) => t.token).slice(0, 500);
  try {
    const res = await admin.messaging().sendEachForMulticast({
      tokens: tokenStrings,
      notification: { title, body },
      data: Object.fromEntries(Object.entries(data || {}).map(([k, v]) => [k, String(v)])),
      android: { priority: 'high' },
    });
    // Prune invalid tokens (NotRegistered / InvalidRegistration)
    const toDelete = [];
    (res.responses || []).forEach((r, i) => {
      if (!r.success && r.error && /not-registered|invalid-registration|invalid-argument/i.test(r.error.code || r.error.message || '')) {
        toDelete.push(tokenStrings[i]);
      }
    });
    if (toDelete.length) {
      try {
        await PushToken.deleteMany({ ownerId, token: { $in: toDelete } });
      } catch (_) {}
    }
    const successCount = res.successCount || 0;
    return {
      delivered: successCount > 0,
      successCount,
      failureCount: res.failureCount || 0,
      tokens: tokens.length,
      pruned: toDelete.length,
      socketEmitted: !!io,
    };
  } catch (err) {
    console.warn(`[weather] FCM send failed: ${err.message}`);
    return { delivered: false, reason: 'FCM_ERROR', error: err.message, socketEmitted: !!io };
  }
}

// Callable job: evaluate every owned device with coordinates, create HIGH
// advisories idempotently, notify once per locationKey+rainDate. Idempotent,
// restart-safe, Render-sleep-safe, V1: never re-notifies on forecast payload fluctuation.
async function runWeatherNotify({ ownerId, deviceId, io, deviceModel, scheduleModel, advisoryModel } = {}) {
  const D = deviceModel || Device;
  const S = scheduleModel || Schedule;
  const A = advisoryModel || WeatherAdvisory;
  const q = {};
  if (ownerId) q.ownerId = ownerId;
  if (deviceId) q.deviceId = deviceId;
  const devices = await D.find(q);
  const result = { checked: 0, advisories: 0, notified: 0, skipped: 0, errors: [] };
  for (const device of devices) {
    if (typeof device.lat !== 'number' || typeof device.lon !== 'number') {
      result.skipped++;
      continue;
    }
    const forecast = await weatherService.getForecast({
      lat: device.lat,
      lon: device.lon,
      timezone: device.timezone || APP_TIMEZONE,
    });
    if (!forecast) {
      result.skipped++;
      continue;
    }
    const schedules = await S.find({
      deviceId: device.deviceId,
      enabled: true,
      pendingDelete: { $ne: true },
    });
    if (device.ownerId) {
      const owned = schedules.filter((s) => !s.ownerId || String(s.ownerId) === String(device.ownerId));
      schedules.length = 0;
      schedules.push(...owned);
    }
    const { advisories } = analyzeSchedules({ schedules, hourly: forecast.hourly, device });
    result.checked++;
    const locKey = locationKeyFor(device);
    for (const adv of advisories) {
      if (adv.type !== 'overlap') continue;
      result.advisories++;
      let existing = null;
      try {
        existing = await A.findOne({
          deviceId: adv.deviceId,
          scheduleId: adv.scheduleId,
          rainDate: adv.rainDate,
          locationKey: locKey,
        });
        // Fallback for legacy records without locationKey (null) — check old triple as well
        if (!existing) {
          existing = await A.findOne({
            deviceId: adv.deviceId,
            scheduleId: adv.scheduleId,
            rainDate: adv.rainDate,
            locationKey: null,
          });
          // Legacy hit counts as already sent for same location only if locKey was historically null (preserve)
          // But if locKey is new, legacy with null should NOT block new-location notify — so only block if locKey equals historical null key's implied location?
          // V1.1: legacy null is treated as distinct from new locKey, so do NOT block when locKey !== null.
          if (existing && locKey !== null) existing = null;
        }
      } catch (err) {
        result.errors.push(err.message);
        continue;
      }
      // DIAGNOSTIC (step 2): print the REAL dedup key string + whether an
      // entry already exists, right before the send-or-skip decision. Do not
      // assume the key changed when location changed — this line proves it.
      // Diagnostic-only; the skip logic below is unchanged.
      const dedupKey = `${adv.deviceId}|${adv.scheduleId}|${adv.rainDate}|${locKey}`;
      console.log(
        `[weatherScheduler][dedup] key="${dedupKey}" exists=${!!existing} ` +
          `status=${existing ? existing.status : 'none'} -> ` +
          `${existing && existing.status === 'sent' ? 'SKIP (already sent)' : 'SEND path'}`,
      );
      if (existing && existing.status === 'sent') continue;
      const payload = { ...adv, farmName: device.farmName || null, timezone: device.timezone || APP_TIMEZONE, locationKey: locKey };
      try {
        await A.findOneAndUpdate(
          { deviceId: adv.deviceId, scheduleId: adv.scheduleId, rainDate: adv.rainDate, locationKey: locKey },
          {
            $setOnInsert: {
              ownerId: device.ownerId,
              deviceId: adv.deviceId,
              scheduleId: adv.scheduleId,
              rainDate: adv.rainDate,
              locationKey: locKey,
            },
            $set: { type: adv.type, severity: adv.severity, status: 'sent', payload },
          },
          { upsert: true, new: true },
        );
      } catch (err) {
        if (err && err.code === 11000) continue;
        result.errors.push(err.message);
        continue;
      }
      // V1: no re-notify on payload change — if existing payload differs, update silently without push
      if (existing && existing.payload) {
        const prev = existing.payload;
        const changed = prev.precipitationMm !== adv.precipitationMm || prev.probability !== adv.probability || prev.rainStart !== adv.rainStart;
        if (changed) {
          try {
            await A.updateOne(
              { deviceId: adv.deviceId, scheduleId: adv.scheduleId, rainDate: adv.rainDate, locationKey: locKey },
              { $set: { payload } },
            );
          } catch (_) {}
          continue;
        }
      }
      const body = advisoryText({ farmName: device.farmName, advisory: adv });
      try {
        await sendPush({
          ownerId: device.ownerId,
          title: '\u{1F327} Rain expected during irrigation',
          body,
          data: { deviceId: adv.deviceId, scheduleId: adv.scheduleId, rainDate: adv.rainDate, locationKey: locKey },
          io,
        });
        result.notified++;
      } catch (err) {
        result.errors.push(err.message);
      }
    }
  }
  return result;
}

module.exports = { runWeatherNotify, sendPush, advisoryText, locationKeyFor, getAdmin, getFirebaseInitStatus, logFirebaseInitStatus, tokenPreview };
