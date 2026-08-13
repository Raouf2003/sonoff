const mongoose = require('mongoose');

const deviceSchema = new mongoose.Schema({
  // The physical identity. For every device claimed since the MAC-based model,
  // this is the normalized Tasmota MAC (e.g. "34987AC30304") and doubles as the
  // MQTT topic the firmware publishes under. Legacy devices (claimed before the
  // MAC-based model) carry a `stees_<random>` deviceId unchanged so their live
  // MQTT topics never desync. deviceId is NEVER rewritten after creation and is
  // unique, so two Devices can never represent the same physical MAC.
  deviceId: {
    type: String,
    required: true,
    unique: true,
    trim: true,
  },
  name: {
    type: String,
    required: true,
    trim: true,
    maxlength: 50,
  },
  ownerId: {
    type: mongoose.Schema.Types.ObjectId,
    ref: 'User',
    default: null,
  },
  type: {
    type: String,
    default: 'sonoff-4ch',
    trim: true,
    maxlength: 30,
  },
  channels: {
    type: Number,
    default: 4,
    min: 1,
    max: 32,
  },
  claimedAt: {
    type: Date,
    default: null,
  },
  // Last LAN IP the device reported through MQTT telemetry
  // (`tele/<deviceId>/STATE` carries `IPAddress`). It is ONLY a discovery
  // hint for the app's local-first path: the app re-verifies identity via
  // `Status 5` before trusting it, and the backend never uses it for anything
  // other than letting the app find the device on the LAN.
  lastIp: {
    type: String,
    default: null,
    trim: true,
  },
  // LEGACY/COMPATIBILITY ONLY. deviceId is the single identity; hardwareId is
  // kept so devices that predate the MAC-based model (stees_* deviceIds) can
  // still be recognized by their physical MAC for duplicate detection. For
  // devices claimed under the MAC-based model hardwareId == deviceId.
  // It must never be treated as a second identity.
  hardwareId: {
    type: String,
    default: null,
    trim: true,
    maxlength: 64,
  },
  createdAt: {
    type: Date,
    default: Date.now,
  },
});

deviceSchema.set('toJSON', {
  transform: (doc, ret) => {
    delete ret.__v;
    return ret;
  },
});

module.exports = mongoose.model('Device', deviceSchema);