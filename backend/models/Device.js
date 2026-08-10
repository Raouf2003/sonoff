const mongoose = require('mongoose');

const deviceSchema = new mongoose.Schema({
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
  // Immutable hardware identifier (Tasmota MAC) captured during provisioning.
  // Informational + de-duplication; never the lookup key. Null for legacy
  // devices claimed before this field existed.
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
