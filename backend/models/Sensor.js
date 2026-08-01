const mongoose = require('mongoose');

const sensorSchema = new mongoose.Schema({
  sensorId: {
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
  name: {
    type: String,
    required: true,
    trim: true,
    maxlength: 50,
  },
  type: {
    type: String,
    default: 'generic',
    trim: true,
    maxlength: 30,
  },
  deviceId: {
    type: String,
    default: null,
    trim: true,
    index: true,
  },
  field: {
    type: String,
    required: true,
    trim: true,
    maxlength: 100,
  },
  persistence: {
    mode: {
      type: String,
      default: 'change_or_interval',
      enum: ['change_or_interval', 'change_only', 'interval_only'],
    },
    intervalSeconds: {
      type: Number,
      default: 300,
      min: 10,
    },
    epsilon: {
      type: Number,
      default: 0,
      min: 0,
    },
  },
  createdAt: {
    type: Date,
    default: Date.now,
  },
});

sensorSchema.set('toJSON', {
  transform: (doc, ret) => {
    delete ret.__v;
    return ret;
  },
});

module.exports = mongoose.model('Sensor', sensorSchema);
