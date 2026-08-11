const crypto = require('crypto');
const Device = require('../models/Device');
const ProvisioningSession = require('../models/ProvisioningSession');
const deviceRegistry = require('./deviceRegistry');
const mqttGateway = require('./mqttGateway');
const { normalizeMac, MAC_ID_RE } = require('./macIdentity');

const SESSION_TTL_MS = 2 * 60 * 60 * 1000; // 2 hours

// Prefix every legacy deviceId uses. Legacy records (claimed before the
// MAC-based identity model) keep `stees_<random>` as both their deviceId and
// their burned-in MQTT topic. New records are ALWAYS canonical MACs.
const LEGACY_DEVICE_ID_RE = /^stees_[0-9a-f]{16}$/;

function randomHex(bytes) {
  return crypto.randomBytes(bytes).toString('hex');
}

function hashToken(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}

class ProvisioningService {
  // Dependencies are injectable so service-level tests run without a broker or
  // a live database. The singleton (module.exports) uses the real ones only.
  constructor({ deviceModel, sessionModel, mqtt, registry } = {}) {
    this.DeviceModel = deviceModel || Device;
    this.SessionModel = sessionModel || ProvisioningSession;
    this.mqtt = mqtt || mqttGateway;
    this.registry = registry || deviceRegistry;
    // Optional post-claim notification hook (Socket.IO fast path). Wired by
    // server.js so this service stays decoupled from io.
    this.onClaimed = null; // (deviceId) => void
    // In-memory re-entrancy guard. The DB's atomic status flip is the real
    // serialization point, but a concurrent duplicate (double-tap / retry) is
    // rejected here early instead of racing through the expensive checks.
    this._claimBusy = new Set();
  }

  // PHASE 0 (ONLINE): create a provisioning session. The physical device
  // identity is NOT known yet (the MAC is only readable on the SoftAP), so no
  // deviceId can be issued here: the wizard anchors the MAC-derived identity to
  // the session later via attachIdentity(). A one-time claim token is returned
  // exactly once - it is never persisted in plain form.
  async create(ownerId) {
    const token = randomHex(16); // 128-bit one-time claim token
    const now = new Date();
    const session = await this.SessionModel.create({
      sessionId: randomHex(12),
      ownerId,
      claimTokenHash: hashToken(token),
      expectedDeviceId: null,
      expiresAt: new Date(now.getTime() + SESSION_TTL_MS),
    });
    // Never echo the token hash to the caller; the plain token is the one and
    // only copy the app receives (create response only).
    return {
      sessionId: session.sessionId,
      claimToken: token,
      expiresAt: session.expiresAt,
    };
  }

  async getForOwner(sessionId, ownerId) {
    const session = await this.SessionModel.findOne({ sessionId });
    if (!session || session.ownerId.toString() !== String(ownerId)) {
      return null;
    }
    return session;
  }

  // The wizard's FIRST ONLINE step after the device restarts: anchors the MAC
  // read on the SoftAP to this session. Normalizes + strictly validates the MAC
  // (INVALID_MAC if malformed) and checks for an existing Device on that exact
  // canonical identity so duplicates get a clear, machine-readable answer and
  // the wizard can stop before it ever waits for the device. Ownership is never
  // disclosed to third parties.
  async attachIdentity(sessionId, ownerId, rawMac) {
    const session = await this.SessionModel.findOne({ sessionId });
    if (!session || session.ownerId.toString() !== String(ownerId)) {
      const err = new Error('Provisioning session not found');
      err.code = 'SESSION_NOT_FOUND';
      throw err;
    }
    const mac = normalizeMac(rawMac);
    if (!mac) {
      const err = new Error('Invalid MAC address');
      err.code = 'INVALID_MAC';
      throw err;
    }

    const conflict = await this._findConflict(mac, ownerId);
    if (conflict && conflict.code) {
      throw conflict.err;
    }

    session.hardwareId = mac;
    session.expectedDeviceId = mac;
    try {
      await session.save();
    } catch (err) {
      // The sparse-unique index on expectedDeviceId means a MAC can only ever
      // be targeted by one session. A collision is another (possibly the same)
      // user's in-flight attempt at this exact identity - never disclosed.
      if (err && err.code === 11000) {
        const dup = new Error('This device is already being provisioned');
        dup.code = 'DEVICE_ALREADY_REGISTERED';
        throw dup;
      }
      throw err;
    }
    return true;
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
    const session = await this.SessionModel.findOne({ sessionId });
    if (!session) {
      const err = new Error('Provisioning session not found');
      err.code = 'SESSION_NOT_FOUND';
      throw err;
    }
    if (session.ownerId.toString() !== String(ownerId)) {
      const err = new Error('Provisioning session not found');
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

    // The expected identity MUST be a canonical MAC. It is set by
    // attachIdentity() during the online phase; the client never supplies a
    // hand-made deviceId past strict canonical validation.
    const deviceId = session.expectedDeviceId;
    if (!deviceId || typeof deviceId !== 'string' || !MAC_ID_RE.test(deviceId)) {
      const err = new Error('Expected device identity was not set or is invalid');
      err.code = 'INVALID_MAC';
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

    // A physical MAC can only ever belong to ONE account. Checked here both on
    // the canonical identity and against legacy records (stees_* deviceId whose
    // hardwareId holds this MAC). Ownership is never disclosed cross-user.
    const conflict = await this._findConflict(deviceId, ownerId);
    if (conflict && conflict.existing && conflict.existing.ownerId == null) {
      // Unowned record for this exact MAC (from an explicit unclaim) is re-claimed.
    } else if (conflict && conflict.code) {
      throw conflict.err;
    }

    // Mark the session claimed FIRST. This is the atomic guard that makes two
    // simultaneous claims for the same session resolve to exactly one winner.
    const claimed = await this.SessionModel.findOneAndUpdate(
      { _id: session._id, status: 'pending' },
      { $set: { status: 'claimed', claimedAt: new Date() } },
    );
    if (!claimed) {
      const err = new Error('Provisioning session already used');
      err.code = 'SESSION_USED';
      throw err;
    }

    // The physical device must actually have announced itself on MQTT under
    // the expected identity (possession gate: "the device is physically here",
    // not merely "this MAC is in the database"). A MAC that never connected
    // here never appears.
    if (!this.mqtt.hasRecent(deviceId)) {
      const err = new Error('Device has not connected to MQTT yet');
      err.code = 'DEVICE_NOT_SEEN';
      // Keep the session pending so the wizard can retry after the device
      // eventually connects (the claim is currently rolled back silently).
      await this.SessionModel.updateOne(
        { _id: session._id },
        { $set: { status: 'pending', claimedAt: null } },
      );
      throw err;
    }

    let device = conflict && conflict.existing ? conflict.existing : null;
    try {
      if (device) {
        // Re-claim the existing record for this MAC. A legacy (stees_*) record
        // is renamed to the canonical identity so one physical MAC never leaves
        // two Device documents behind.
        device = await this.DeviceModel.findOneAndUpdate(
          { _id: device._id, ownerId: null },
          {
            $set: {
              deviceId,
              ownerId,
              name: cleanName,
              type,
              channels: ch,
              claimedAt: new Date(),
              hardwareId: deviceId,
            },
          },
          { new: true },
        );
      } else {
        device = await this.DeviceModel.create({
          deviceId,
          name: cleanName,
          ownerId,
          type,
          channels: ch,
          claimedAt: new Date(),
          hardwareId: deviceId,
        });
      }
    } catch (err) {
      // Roll the atomic session claim back so a genuine retry can still win.
      await this.SessionModel.updateOne(
        { _id: session._id },
        { $set: { status: 'pending', claimedAt: null } },
      );
      if (err && err.code === 11000) {
        // Lost the race: another claim (or a stray record) took this MAC first.
        const loser = new Error('This device is already registered');
        loser.code = 'DEVICE_ALREADY_REGISTERED';
        throw loser;
      }
      throw err;
    }

    if (!device || !device.ownerId) {
      const err = new Error('This device is already registered');
      err.code = 'DEVICE_ALREADY_REGISTERED';
      throw err;
    }

    this.registry.update(device);

    if (this.onClaimed) {
      try {
        await this.onClaimed(deviceId);
      } catch (_) {
        // fast-path notification is non-fatal
      }
    }
    return device;
  }

  // Resolves an existing Device for a canonical MAC without ever disclosing
  // ownership. Never trusts the MAC as possession - this is identity only.
  async _findConflict(mac, ownerId) {
    const byId = await this.DeviceModel.findOne({ deviceId: mac });
    // Legacy records: deviceId stays stees_*, so match their stored hardwareId.
    const existing = byId || (await this.DeviceModel.findOne({ hardwareId: mac }));
    if (!existing) return { existing: null };
    if (existing.ownerId == null) return { existing };
    if (existing.ownerId.toString() === String(ownerId)) {
      const err = new Error('This device is already in your account');
      err.code = 'DEVICE_ALREADY_EXISTS';
      return { code: 'DEVICE_ALREADY_EXISTS', existing, err };
    }
    const err = new Error('This device is already registered');
    err.code = 'DEVICE_ALREADY_REGISTERED';
    return { code: 'DEVICE_ALREADY_REGISTERED', existing, err };
  }

  // Housekeeping for abandoned wizard attempts. Pending sessions past their
  // TTL are dropped immediately (expired sessions are never claimable). Claimed
  // sessions are ALSO cleaned up once they are old enough per [claimedAt] - a
  // finished claim no longer needs its session row, and leaving it forever
  // would let the collection grow unboundedly.
  async expireStale() {
    const now = new Date();
    const res = await this.SessionModel.deleteMany({
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
module.exports.ProvisioningService = ProvisioningService;
module.exports.LEGACY_DEVICE_ID_RE = LEGACY_DEVICE_ID_RE;