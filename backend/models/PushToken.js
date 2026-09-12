const mongoose = require('mongoose');

// One push endpoint per (owner, token). Tokens are opaque strings supplied
// by the app after login; the backend never mints them and never embeds
// provider secrets client-side. FCM/server credentials stay in env.
const pushTokenSchema = new mongoose.Schema(
  {
    ownerId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: 'User',
      required: true,
    },
    token: { type: String, required: true, trim: true, maxlength: 512 },
    platform: { type: String, default: 'android', trim: true, maxlength: 20 },
  },
  { timestamps: true },
);

pushTokenSchema.index({ ownerId: 1, token: 1 }, { unique: true });

pushTokenSchema.set('toJSON', {
  transform: (doc, ret) => {
    delete ret.__v;
    return ret;
  },
});

module.exports = mongoose.model('PushToken', pushTokenSchema);
