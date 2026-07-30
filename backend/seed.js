const mongoose = require('mongoose');

const MONGO_URI = process.env.MONGO_URI;

if (!MONGO_URI) {
  console.error('MONGO_URI env var is required');
  process.exit(1);
}

async function seed() {
  await mongoose.connect(MONGO_URI);
  console.log('Connected to MongoDB');

  const Device = require('./models/Device');

  const devices = [
    { deviceId: 'smarthome', name: 'Smarthome Controller' },
    { deviceId: 'sonoff_8F9BC4', name: 'Garden Controller' },
    { deviceId: 'sonoff_A1B2C3', name: 'Greenhouse Controller' },
  ];

  for (const d of devices) {
    const exists = await Device.findOne({ deviceId: d.deviceId });
    if (!exists) {
      await Device.create(d);
      console.log(`Created device: ${d.deviceId}`);
    } else {
      console.log(`Device already exists: ${d.deviceId}`);
    }
  }

  console.log('Seed complete');
  await mongoose.disconnect();
}

seed().catch(console.error);
