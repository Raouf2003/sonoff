const crypto = require('crypto');
const Device = require('../models/Device');
const ProvisioningSession = require('../models/ProvisioningSession');
const deviceRegistry = require('./deviceRegistry');
const mqttGateway = require('./mqttGateway');

const SESSION_TTL_MS = 2 * 60 * 60 * 1000; // 2 hours

function randomHex(bytes) {
  return crypto.randomBytes(bytes).toString('hex');
}

function hashToken(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}

// Denylist to make sure the issued deviceId can never look like a hand-made
// legacy id or an empty/invalid topic. deviceId is also the MQTT topic, so it
// must be topic-safe (Tasmota topics allow [A-Za-z0-9_-]).
const DEVICE_ID_RE = /^stees_[0-9a-f]{16}$/;

class ProvisioningService {
  constructor() {
    // Optional post-claim notification hook (Socket.IO fast path). Wired by
    // server.js so this service stays decoupled from io.
    this.onClaimed = null; // (deviceId) => void
    // In-memory re-entrancy guard. The DB's atomic status flip is the real
    // serialization point, but a concurrent duplicate (double-tap / retry) is
    // rejected here early instead of racing through the expensive checks.
    this._claimBusy = new Set();
  }

  async create(ownerId) {
    const token = randomHex(16); // 128-bit one-time claim token
    const deviceId = `stees_${randomHex(8)}`; // 64-bit, secret, unique topic
    const now = new Date();
    const session = await ProvisioningSession.create({
      sessionId: randomHex(12),
      ownerId,
      claimTokenHash: hashToken(token),
      expectedDeviceId: deviceId,
      expiresAt: new Date(now.getTime() + SESSION_TTL_MS),
    });
    // Never echo the token hash to the caller; the plain token is the one and
    // only copy the app receives (create response only).
    return {
      sessionId: session.sessionId,
      claimToken: token,
      deviceId,
      expiresAt: session.expiresAt,
    };
  }

  async getForOwner(sessionId, ownerId) {
    const session = await ProvisioningSession.findOne({ sessionId });
    if (!session || session.ownerId.toString() !== ownerId.toString()) {
      return null;
    }
    return session;
  }

  async claim({ sessionId, ownerId, claimToken, name, channels, hardwareId }) {
    // Early re-entrancy guard: only one claim in flight per session at a time.
    // The DB's atomic status flip below is the real serialization point; this
    // only avoids redundant work for genuinely concurrent duplicates.
    if (this._claimBusy.has(sessionId)) {
      const err = new Error('Provisioning session claim already in progress');
      err.code = 'SESSION_BUSY';
      throw err;
    }
    this._claimBusy.add(sessionId);
    try {
      return await this._claim({ sessionId, ownerId, claimToken, name, channels, hardwareId });
    } finally {
      this._claimBusy.delete(sessionId);
    }
  }

  async _claim({ sessionId, ownerId, claimToken, name, channels, hardwareId }) {
    const session = await ProvisioningSession.findOne({ sessionId });
    if (!session) {
      const err = new Error('Provisioning session not found');
      err.code = 'SESSION_NOT_FOUND';
      throw err;
    }
    if (session.ownerId.toString() !== ownerId.toString()) {
      const err = new Error('Provisioning session belongs to another account');
      err.code = 'SESSION_NOT_FOUND';
      throw err;
    }
    if (session.status === 'claimed') {
      const err = new Error('Provisioning session already used');
      err.code = 'SESSION_USED';
      throw err;
    }
    if (session.status !== 'pending') {
      const err = new Error('Provisioning session is not pending');
      err.code = 'SESSION_NOT_PENDING';
      throw err;
    }
    if (new Date(session.expiresAt).getTime() < Date.now()) {
      const err = new Error('Provisioning session expired');
      err.code = 'SESSION_EXPIRED';
      throw err;
    }

    const tokenOk =
      claimToken &&
      typeof claimToken === 'string' &&
      crypto.timingSafeEqual(
        Buffer.from(hashToken(claimToken), 'hex'),
        Buffer.from(session.claimTokenHash, 'hex'),
      );
    if (!tokenOk) {
      const err = new Error('Invalid claim token');
      err.code = 'INVALID_TOKEN';
      throw err;
    }

    const deviceId = session.expectedDeviceId;
    if (!DEVICE_ID_RE.test(deviceId)) {
      const err = new Error('Malformed expected device identity');
      err.code = 'BAD_DEVICE_ID';
      throw err;
    }

const ch = channels === undefined ? 4 : Number(channels);
    if (!Number.isInteger(ch) || ch < 1 || ch > 16) {
      const err = new Error('channels must be an integer between 1 and 16');
      err.code = 'BAD_CHANNELS';
      throw err;
    }
    const cleanName = String(name || '').trim();
    if (!cleanName) {
      const err = new Error('name is required');
      err.code = 'BAD_NAME';
      throw err;
    }
    const type = ch === 1 ? 'sonoff-1ch' : `sonoff-${ch}ch`;
    // Prefer the hardwareId already attached to the session during the SoftAP
    // step; fall back to the value (re)sent on the claim request.
    const anchorHardwareId = session.hardwareId || hardwareId || null;
    if (anchorHardwareId) {
      if (typeof anchorHardwareId !== 'string' || anchorHardwareId.length > 64) {
        const err = new Error('hardwareId must be a short string');
        err.code = 'BAD_HARDWARE';
        throw err;
      }
      // A MAC that is already owned must not be silently re-claimed under a new
      // identity (re-provisioned device): it would leave a duplicate/orphaned
      // record. Block with a clear, replayable error so the app can explain.
      const owned = await Device.findOne({
        hardwareId: anchorHardwareId,
        ownerId: { $ne: null },
      });
      if (owned) {
        const err = new Error('This physical device is already linked to an account');
        err.code = 'ALREADY_CLAIMED';
        throw err;
      }
    }

    // Mark the session claimed FIRST. This is the atomic guard that makes two
    // simultaneous claims for the same session resolve to exactly one winner.
    const claimed = await ProvisioningSession.findOneAndUpdate(
      { _id: session._id, status: 'pending' },
      { $set: { status: 'claimed', claimedAt: new Date() } },
    );
    if (!claimed) {
      const err = new Error('Provisioning session already used');
      err.code = 'SESSION_USED';
      throw err;
    }

    // The physical device must actually have announced itself on MQTT under
    // the issued topic (possession gate). A deviceId that was issued but never
    // written to a real device never appears here.
    if (!mqttGateway.hasRecent(deviceId)) {
      const err = new Error('Device has not connected to MQTT yet');
      err.code = 'DEVICE_NOT_SEEN';
      // Keep the session pending so the wizard can retry after the device
      // eventually connects (the claim is currently rolled back silently).
      await ProvisioningSession.updateOne(
        { _id: session._id },
        { $set: { status: 'pending', claimedAt: null } },
      );
      throw err;
    }

    // Atomic ownership guard: the unique deviceId index + the ownerId:null
    // filter mean exactly one of N concurrent claims can win.
    let device = await Device.findOne({ deviceId });
    if (device && device.ownerId) {
      const err = new Error('Device is already claimed by another user');
      err.code = 'ALREADY_CLAIMED';
      throw err;
    }

    try {
      if (device) {
        device = await Device.findOneAndUpdate(
          { deviceId, ownerId: null },
          {
            $set: {
              ownerId,
              name: cleanName,
              type,
              channels: ch,
              claimedAt: new Date(),
              hardwareId: anchorHardwareId,
            },
          },
          { new: true },
        );
      } else {
        device = await Device.create({
          deviceId,
          name: cleanName,
          ownerId,
          type,
          channels: ch,
          claimedAt: new Date(),
          hardwareId: anchorHardwareId,
        });
      }
    } catch (err) {
      if (err && err.code === 11000) {
        // Lost the race (or a doc was created between findOne and create).
        const loser = new Error('Device is already claimed by another user');
        loser.code = 'ALREADY_CLAIMED';
        await ProvisioningSession.updateOne(
          { _id: session._id },
          { $set: { status: 'pending', claimedAt: null } },
        );
        throw loser;
      }
      await ProvisioningSession.updateOne(
        { _id: session._id },
        { $set: { status: 'pending', claimedAt: null } },
      );
      throw err;
    }

    if (!device || !device.ownerId) {
      const err = new Error('Device is already claimed by another user');
      err.code = 'ALREADY_CLAIMED';
      throw err;
    }

    deviceRegistry.update(device);

if (this.onClaimed) {
      try {
        await this.onClaimed(deviceId);
      } catch (_) {
        // fast-path notification is non-fatal
      }
    }
    return device;
  }

  // Housekeeping for abandoned wizard attempts. Pending sessions past their
  // TTL are dropped immediately (expired sessions are never claimable). Claimed
  // sessions are ALSO cleaned up once they are old enough per [claimedAt] - a
  // finished claim no longer needs its session row, and leaving it forever
  // would let the collection grow unboundedly.
  async expireStale() {
    const now = new Date();
    const res = await ProvisioningSession.deleteMany({
      $or: [
        // Never-used sessions: drop as soon as the TTL has passed.
        { status: 'pending', expiresAt: { $lt: now } },
        // Used sessions: keep the row long enough to detect `SESSION_USED`
        // replays / audit, then purge.
        {
          status: 'claimed',
          claimedAt: { $lt: new Date(now.getTime() - SESSION_TTL_MS) },
        },
      ],
    });
    return res.deletedCount || 0;
  }
}

module.exports = new ProvisioningService();
