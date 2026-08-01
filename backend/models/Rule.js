const mongoose = require('mongoose');

const ruleSchema = new mongoose.Schema({
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
  enabled: {
    type: Boolean,
    default: true,
  },
  priority: {
    type: Number,
    default: 0,
    min: 0,
    max: 100,
  },
  sensorId: {
    type: String,
    required: true,
    index: true,
  },
  condition: {
    band: {
      min: { type: Number, default: null },
      max: { type: Number, default: null },
      hysteresis: { type: Number, default: 0, min: 0 },
    },
  },
  action: {
    deviceId: { type: String, required: true, trim: true },
    channel: { type: Number, required: true, min: 1 },
    state: { type: String, required: true, enum: ['ON', 'OFF', 'TOGGLE'] },
  },
  cooldownS: {
    type: Number,
    default: 0,
    min: 0,
  },
  freshnessS: {
    type: Number,
    default: 3600,
    min: 0,
  },
  version: {
    type: Number,
    default: 1,
  },
  createdAt: {
    type: Date,
    default: Date.now,
  },
  updatedAt: {
    type: Date,
    default: Date.now,
  },
});

ruleSchema.set('toJSON', {
  transform: (doc, ret) => {
    delete ret.__v;
    return ret;
  },
});

module.exports = mongoose.model('Rule', ruleSchema);
