const mongoose = require('mongoose');

const sensorDiscoverySchema = new mongoose.Schema({
  ownerId: {
    type: mongoose.Schema.Types.ObjectId,
    ref: 'User',
    required: true,
  },
  deviceId: {
    type: String,
    required: true,
    trim: true,
    maxlength: 60,
  },
  sensorId: {
    type: String,
    required: true,
    trim: true,
    maxlength: 40,
  },
  lastValue: {
    type: mongoose.Schema.Types.Mixed,
    default: null,
  },
  lastSeen: {
    type: Date,
    default: Date.now,
  },
});

sensorDiscoverySchema.index({ ownerId: 1, deviceId: 1, sensorId: 1 }, { unique: true });

sensorDiscoverySchema.set('toJSON', {
  transform: (doc, ret) => {
    delete ret.__v;
    return ret;
  },
});

module.exports = mongoose.model('SensorDiscovery', sensorDiscoverySchema);
