const mongoose = require('mongoose');

const TIME_RE = /^([01]\d|2[0-3]):([0-5]\d)$/;

function validateTimeFormat(value) {
  return TIME_RE.test(value);
}

const timeRangeSchema = new mongoose.Schema(
  {
    start: {
      type: String,
      required: true,
      validate: {
        validator: validateTimeFormat,
        message: 'start must be in HH:mm format',
      },
    },
    end: {
      type: String,
      required: true,
      validate: {
        validator: validateTimeFormat,
        message: 'end must be in HH:mm format',
      },
    },
  },
  { _id: false },
);

function toMinutes(hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  return h * 60 + m;
}

timeRangeSchema.path('end').validate(function (end) {
  // Same-day ranges only: end must be strictly after start. Reject
  // overnight-spanning ranges (e.g. 22:00-02:00) in this version.
  return toMinutes(end) > toMinutes(this.start);
}, 'end must be after start (same-day ranges only)');

const scheduleSchema = new mongoose.Schema(
  {
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
    deviceId: {
      type: String,
      required: true,
      trim: true,
    },
    channels: {
      type: [Number],
      required: true,
      validate: {
        validator: (v) => Array.isArray(v) && v.length > 0,
        message: 'channels must not be empty',
      },
    },
    recurrence: {
      type: {
        type: String,
        enum: ['daily', 'custom'],
        required: true,
      },
      daysOfWeek: {
        type: [Number],
        default: [],
      },
    },
    timeRanges: {
      type: [timeRangeSchema],
      required: true,
      validate: {
        validator: (v) => Array.isArray(v) && v.length > 0,
        message: 'timeRanges must not be empty',
      },
    },
    enabled: {
      type: Boolean,
      default: true,
    },
    // Internal per-channel applied state, e.g. { "1": "ON", "2": "OFF" }.
    // Not part of the public API contract.
    lastAppliedState: {
      type: Map,
      of: String,
      default: {},
    },
    // ADDITIVE PHASE 6 SYNC METADATA (hidden from JSON via the toJSON
    // transform below). Owned by scheduleSyncService only. Backward-
    // compatible: existing schedule reads/writes never touch these fields.
    syncStatus: {
      type: String,
      default: 'pending',
      select: false,
    },
    lastSyncedAt: {
      type: Date,
      default: null,
      select: false,
    },
    syncError: {
      type: String,
      default: null,
      select: false,
    },
  },
  { timestamps: true },
);

scheduleSchema.pre('validate', function (next) {
  // Recurrence-level validation: custom requires daysOfWeek, daily ignores it.
  if (this.recurrence && this.recurrence.type === 'custom') {
    if (!Array.isArray(this.recurrence.daysOfWeek) || this.recurrence.daysOfWeek.length === 0) {
      return next(new Error('daysOfWeek is required when recurrence is custom'));
    }
  }
  next();
});

scheduleSchema.set('toJSON', {
  transform: (doc, ret) => {
    delete ret.__v;
    // Strip internal state from all API responses.
    delete ret.lastAppliedState;
    delete ret.syncStatus;
    delete ret.lastSyncedAt;
    delete ret.syncError;
    return ret;
  },
});

module.exports = mongoose.model('Schedule', scheduleSchema);