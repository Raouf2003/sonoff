const mongoose = require('mongoose');

const sensorSchema = new mongoose.Schema({
  ownerId: {
    type: mongoose.Schema.Types.ObjectId,
    ref: 'User',
    required: true,
  },
  name: {
    type: String,
    required: true,
    trim: true,
    maxlength: 50,
  },
  sensorId: {
    type: String,
    required: true,
    trim: true,
    maxlength: 40,
  },
  deviceId: {
    type: String,
    default: null,
  },
  lastValue: {
    type: mongoose.Schema.Types.Mixed,
    default: null,
  },
  lastSeen: {
    type: Date,
    default: null,
  },
  status: {
    type: String,
    enum: ['online', 'offline'],
    default: 'offline',
  },
  createdAt: {
    type: Date,
    default: Date.now,
  },
});

sensorSchema.index({ ownerId: 1, sensorId: 1 }, { unique: true });

sensorSchema.set('toJSON', {
  transform: (doc, ret) => {
    delete ret.__v;
    return ret;
  },
});

module.exports = mongoose.model('Sensor', sensorSchema);
