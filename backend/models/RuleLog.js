const mongoose = require('mongoose');

const ruleLogSchema = new mongoose.Schema({
  ruleId: {
    type: mongoose.Schema.Types.ObjectId,
    ref: 'Rule',
    index: true,
  },
  ownerId: {
    type: mongoose.Schema.Types.ObjectId,
    ref: 'User',
    required: true,
    index: true,
  },
  deviceId: {
    type: String,
    trim: true,
    default: null,
  },
  channel: {
    type: Number,
    default: null,
  },
  action: {
    type: String,
    default: null,
  },
  status: {
    type: String,
    enum: ['executed', 'error', 'blocked', 'stale', 'emergency_stop'],
    required: true,
  },
  reason: {
    type: String,
    default: null,
  },
  ruleVersion: {
    type: Number,
    default: 1,
  },
  acked: {
    type: Boolean,
    default: false,
  },
  ts: {
    type: Date,
    default: Date.now,
  },
});

ruleLogSchema.index({ ownerId: 1, ts: -1 });
ruleLogSchema.index({ ts: 1 }, { expireAfterSeconds: 2592000 });

ruleLogSchema.set('toJSON', {
  transform: (doc, ret) => {
    delete ret.__v;
    return ret;
  },
});

module.exports = mongoose.model('RuleLog', ruleLogSchema);
