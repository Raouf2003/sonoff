const mongoose = require('mongoose');

// A provisioning session is the ONLY way to claim a device. It binds:
//   - the authenticated user (ownerId),
//   - a one-time claim token (stored hashed) that must be presented again,
//   - the exact device identity the wizard will burn into the physical device.
//
// The identity is the normalized Tasmota MAC (canonical form, e.g.
// "34987AC30304"), which is also the MQTT topic the device announces under.
// The MAC is only readable while the phone is on the Tasmota SoftAP (offline),
// while the session must be created online beforehand - so expectedDeviceId is
// null at creation and filled by the wizard's first ONLINE step after the
// device restarts (POST /sessions/:id/hardware), *before* any claim.
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
  // The canonical MAC-derived deviceId (== MQTT topic) for this provisioning
  // attempt. Unknown at session creation (the MAC is read later, offline);
  // set by the identity-attach step before any claim. Sparse-unique so two
  // sessions can never target the same physical identity once anchored.
  expectedDeviceId: {
    type: String,
    default: null,
    unique: true,
    sparse: true,
    trim: true,
  },
  // Canonical MAC of the physical device, as read during the SoftAP step and
  // anchored online. Informational and identical to expectedDeviceId for
  // current devices; kept as a separate field for legacy compatibility.
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