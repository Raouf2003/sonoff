const mongoose = require('mongoose');

const ruleSchema = new mongoose.Schema({
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
  },
  deviceId: {
    type: String,
    required: true,
    trim: true,
  },
  channel: {
    type: Number,
    required: true,
    min: 1,
    max: 4,
  },
  condition: {
    type: String,
    enum: ['above', 'below'],
    required: true,
  },
  threshold: {
    type: Number,
    required: true,
  },
  action: {
    type: String,
    enum: ['ON', 'OFF'],
    required: true,
  },
  enabled: {
    type: Boolean,
    default: true,
  },
  createdAt: {
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
