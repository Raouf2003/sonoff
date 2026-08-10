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
  channels: {
    type: [Number],
    required: true,
    validate: {
      validator(v) {
        return Array.isArray(v) && v.length > 0 && v.every((n) => Number.isInteger(n) && n >= 1) && new Set(v).size === v.length;
      },
      message: 'channels must be a non-empty array of unique positive integers',
    },
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
  // Internal edge-trigger state: true when the condition last evaluated true
  // (and the command was fired). Persisted so a server restart never loses the
  // false->true transition history. Not part of the public API contract.
  lastConditionState: {
    type: Boolean,
    default: false,
  },
  createdAt: {
    type: Date,
    default: Date.now,
  },
});

// Backward compat: if an old document has `channel` (Number) but no `channels`,
// expose it as a single-element array via a virtual getter.
ruleSchema.virtual('channelsCompat').get(function () {
  if (this.channels && this.channels.length > 0) return this.channels;
  if (typeof this.channel === 'number') return [this.channel];
  return [];
});

ruleSchema.set('toJSON', {
  virtuals: true,
  transform: (doc, ret) => {
    delete ret.__v;
    // Ensure old `channel` field is stripped from output; clients use `channels`.
    delete ret.channel;
    return ret;
  },
});

// Migration hook: before saving, if `channels` is missing but `channel` exists,
// copy it into `channels`.
ruleSchema.pre('save', function (next) {
  if ((!this.channels || this.channels.length === 0) && typeof this.channel === 'number') {
    this.channels = [this.channel];
  }
  next();
});

module.exports = mongoose.model('Rule', ruleSchema);
