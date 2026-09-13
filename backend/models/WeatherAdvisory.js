const mongoose = require('mongoose');

// Deduplication record for one rain-vs-schedule advisory. Advisory content
// itself is always recomputed from (cached forecast + Mongo schedules); this
// collection exists ONLY so the same (device, schedule, rain day) never
// notifies twice. No relay/schedule/Tasmota side effects hang off it.
// V1.1: locationKey preserves history when device moves and prevents
// new-location rain on same rainDate from being suppressed by old-location dedup.
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
    // Location identity at advisory creation: "lat,lon,timezone" (4dp). Old
    // records have null; new records have string. Changing lat/lon creates a
    // distinct key, so new-location advisories are not deduped against old-location history.
    locationKey: { type: String, default: null, trim: true },
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
// V1.1 location-aware dedup: new advisories use this; old records (locationKey null) remain valid via previous index.
weatherAdvisorySchema.index(
  { deviceId: 1, scheduleId: 1, rainDate: 1, locationKey: 1 },
  { unique: true, sparse: true },
);
weatherAdvisorySchema.index({ ownerId: 1, createdAt: -1 });

weatherAdvisorySchema.set('toJSON', {
  transform: (doc, ret) => {
    delete ret.__v;
    return ret;
  },
});

module.exports = mongoose.model('WeatherAdvisory', weatherAdvisorySchema);
