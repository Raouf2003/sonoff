const Device = require('../models/Device');
const deviceRegistry = require('./deviceRegistry');
const mqttGateway = require('./mqttGateway');
const { normalizeMac } = require('./macIdentity');

// Registers a physical device directly from its canonical MAC. There is no
// provisioning session, claim token or backend-issued identity: the MAC read
// from the physical device (offline, on its setup AP) IS the deviceId and the
// MQTT topic the firmware was configured with. The device must be physically
// present on the broker right now (possession gate) and must not already
// belong to any account. The unique Device.deviceId index is the final
// serialization point, so two concurrent registrations of one MAC resolve to
// exactly one Device document.
class DeviceProvisioningService {
  // Dependencies are injectable so service-level tests run without a broker or
  // a live database. The singleton (module.exports) uses the real ones only.
  constructor({ deviceModel, mqtt, registry } = {}) {
    this.DeviceModel = deviceModel || Device;
    this.mqtt = mqtt || mqttGateway;
    this.registry = registry || deviceRegistry;
    // Optional post-provision notification hook (Socket.IO fast path). Not wired
    // by default - the wizard relies on the mqttGateway device_seen room +
    // polling. Kept injectable so the service stays decoupled from io.
    this.onProvisioned = null; // (deviceId) => void
  }

  async provision({ ownerId, deviceId, name, channels }) {
    // The device identity is a canonical MAC, strictly validated: anything that
    // is not exactly 12 hex digits (after stripping separators) is rejected.
    const mac = normalizeMac(deviceId);
    if (!mac) {
      const err = new Error('deviceId must be a canonical MAC address');
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

    // Duplicate identity checks happen BEFORE possession: if the MAC is already
    // in this user's account (or another's), say so immediately - there is
    // nothing to wait for. Ownership of another user's device is never
    // disclosed, only a generic "already registered".
    const conflict = await this._findConflict(mac, ownerId);
    if (conflict && conflict.code) {
      throw conflict.err;
    }

    // Possession gate: the physical device must actually be talking to the
    // broker right now under this exact identity. An arbitrary MAC can never be
    // claimed - only hardware that is physically here can be registered.
    if (!this.mqtt.hasRecent(mac)) {
      const err = new Error('Device has not connected to MQTT yet');
      err.code = 'DEVICE_NOT_SEEN';
      throw err;
    }

    let device = conflict && conflict.existing ? conflict.existing : null;
    try {
      if (device) {
        // Re-claim an unowned legacy (stees_*) record whose hardwareId is this
        // MAC: rename it to the canonical identity so one physical MAC never
        // leaves two Device documents behind.
        device = await this.DeviceModel.findOneAndUpdate(
          { _id: device._id, ownerId: null },
          {
            $set: {
              deviceId: mac,
              ownerId,
              name: cleanName,
              type: ch === 1 ? 'sonoff-1ch' : `sonoff-${ch}ch`,
              channels: ch,
              claimedAt: new Date(),
              hardwareId: mac,
            },
          },
          { new: true },
        );
      } else {
        device = await this.DeviceModel.create({
          deviceId: mac,
          name: cleanName,
          ownerId,
          type: ch === 1 ? 'sonoff-1ch' : `sonoff-${ch}ch`,
          channels: ch,
          claimedAt: new Date(),
          hardwareId: mac,
        });
      }
    } catch (err) {
      // Lost the unique-deviceId race: another (possibly the same) user's
      // attempt registered this MAC first. Never disclose who.
      if (err && err.code === 11000) {
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

    if (this.onProvisioned) {
      try {
        await this.onProvisioned(mac);
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
}

module.exports = new DeviceProvisioningService();
module.exports.DeviceProvisioningService = DeviceProvisioningService;
