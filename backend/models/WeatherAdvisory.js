const mongoose = require('mongoose');

// Deduplication record for one rain-vs-schedule advisory. Advisory content
// itself is always recomputed from (cached forecast + Mongo schedules); this
// collection exists ONLY so the same (device, schedule, rain day) never
// notifies twice. No relay/schedule/Tasmota side effects hang off it.
const weatherAdvisorySchema = new mongoose.Schema(
  {
    ownerId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'User',
      required: true,
    },
    deviceId: { type: String, required: true, trim: true },
    scheduleId: { type: String, required: true, trim: true },
    rainDate: { type: String, required: true, trim: true },
    type: { type: String, enum: ['overlap', 'adjacent'], default: 'overlap' },
    severity: { type: String, enum: ['HIGH', 'MEDIUM'], default: 'HIGH' },
    status: {
      type: String,
      enum: ['pending', 'sent', 'dismissed', 'expired'],
      default: 'sent',
    },
    payload: { type: mongoose.Schema.Types.Mixed, default: null },
  },
  { timestamps: true },
);

weatherAdvisorySchema.index(
  { deviceId: 1, scheduleId: 1, rainDate: 1 },
  { unique: true },
);
weatherAdvisorySchema.index({ ownerId: 1, createdAt: -1 });

weatherAdvisorySchema.set('toJSON', {
  transform: (doc, ret) => {
    delete ret.__v;
    return ret;
  },
});

module.exports = mongoose.model('WeatherAdvisory', weatherAdvisorySchema);
