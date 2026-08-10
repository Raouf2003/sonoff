const mongoose = require('mongoose');

// A provisioning session is the ONLY way to claim a device. It binds:
//   - the authenticated user (ownerId),
//   - a one-time claim token (stored hashed) that must be presented again,
//   - the exact deviceId the wizard will burn into the physical device (which
//     doubles as the possession secret: only the owner of the session and the
//     physical device ever see it, so "the device announced under this topic
//     on MQTT" proves physical possession without any Tasmota-specific write).
//
// Sessions are short-lived and disposable. They are never the device record.
const provisioningSessionSchema = new mongoose.Schema({
  sessionId: {
    type: String,
    required: true,
    unique: true,
    trim: true,
  },
  ownerId: {
    type: mongoose.Schema.Types.ObjectId,
    ref: 'User',
    required: true,
    index: true,
  },
  // sha256 hex of the one-time claim token. The plain token is returned to the
  // app exactly once, at creation, and is never persisted.
  claimTokenHash: {
    type: String,
    required: true,
  },
  // The deviceId (== MQTT topic) issued for this provisioning attempt. Unique
  // so two sessions can never target the same physical identity.
  expectedDeviceId: {
    type: String,
    required: true,
    unique: true,
    trim: true,
  },
  // Immutable hardware identifier (Tasmota MAC) read during the SoftAP step.
  // Stored here so a claim can be checked against the reported MAC and later
  // used to de-duplicate re-provisioning. Optional/backfilled.
  hardwareId: {
    type: String,
    default: null,
    trim: true,
    maxlength: 64,
  },
  status: {
    type: String,
    enum: ['pending', 'claimed', 'expired'],
    default: 'pending',
    index: true,
  },
  expiresAt: {
    type: Date,
    required: true,
  },
  claimedAt: {
    type: Date,
    default: null,
  },
  createdAt: {
    type: Date,
    default: Date.now,
  },
});

provisioningSessionSchema.set('toJSON', {
  transform: (doc, ret) => {
    delete ret.claimTokenHash;
    delete ret.__v;
    return ret;
  },
});

module.exports = mongoose.model('ProvisioningSession', provisioningSessionSchema);