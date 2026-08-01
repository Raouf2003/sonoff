const mongoose = require('mongoose');

const telemetrySchema = new mongoose.Schema({
  ownerId: {
    type: mongoose.Schema.Types.ObjectId,
    ref: 'User',
    required: true,
    index: true,
  },
  sensorId: {
    type: String,
    required: true,
    index: true,
  },
  deviceId: {
    type: String,
    trim: true,
    default: null,
  },
  value: {
    type: mongoose.Schema.Types.Mixed,
    required: true,
  },
  ts: {
    type: Date,
    default: Date.now,
  },
});

telemetrySchema.index({ sensorId: 1, ts: -1 });
telemetrySchema.index({ ts: 1 }, { expireAfterSeconds: 7776000 });

telemetrySchema.set('toJSON', {
  transform: (doc, ret) => {
    delete ret.__v;
    return ret;
  },
});

module.exports = mongoose.model('Telemetry', telemetrySchema);
