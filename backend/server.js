const express = require('express');
const cors = require('cors');
const http = require('http');
const jwt = require('jsonwebtoken');
const { Server } = require('socket.io');
const mongoose = require('mongoose');

const authRoutes = require('./routes/auth');
const deviceRoutes = require('./routes/devices');
const controlRoutes = require('./routes/control');
const sensorRoutes = require('./routes/sensors');
const ruleRoutes = require('./routes/rules');
const scheduleRoutes = require('./routes/schedules');
const { authMiddleware, JWT_SECRET } = require('./middleware/auth');
const { normalizeMac } = require('./services/macIdentity');
const Device = require('./models/Device');

const deviceRegistry = require('./services/deviceRegistry');
const runtimeState = require('./services/runtimeState');
const mqttGateway = require('./services/mqttGateway');
const ruleEngine = require('./services/ruleEngine');
const scheduleEngine = require('./services/scheduleEngine');

const app = express();
const PORT = process.env.PORT || 3001;
const MONGO_URI = process.env.MONGO_URI;
const CORS_ORIGIN = process.env.CORS_ORIGIN || '*';

const server = http.createServer(app);
const io = new Server(server, {
  cors: { origin: CORS_ORIGIN },
});

app.use(cors({ origin: CORS_ORIGIN }));
app.use(express.json());

app.set('io', io);

mongoose
  .connect(MONGO_URI)
  .then(() => console.log('Connected to MongoDB'))
  .catch((err) => {
    console.error('MongoDB connection error:', err.message);
    console.log('Server will start without database. Auth and device ownership will not work.');
  });

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

function initRuntime() {
  mqttGateway.init({ io, deviceRegistry, runtimeState });
  ruleEngine.init({ mqttGateway });
  scheduleEngine.init({ mqttGateway });
}

async function loadFromDb() {
  for (let i = 0; i < 60 && mongoose.connection.readyState !== 1; i++) {
    await delay(1000);
  }
  if (mongoose.connection.readyState !== 1) {
    console.error('Database unavailable; device ownership will not be loaded');
    return;
  }
  await deviceRegistry.init();
  // The registry now knows every claimed device — request their current STATE
  // so runtimeState recovers fast even if MQTT connected before the DB loaded.
  mqttGateway.requestStateSync();
}

initRuntime();
loadFromDb().catch((err) => console.error('Service init error:', err.message));

// Build the socket room name for a user. Rooms are namespaced so they never
// collide with any other Socket.IO concept.
const userRoom = (userId) => `user:${userId}`;

// Expose the room naming helper to services (e.g. mqttGateway) that only hold
// a reference to `io`, so they can target the correct owner room.
io.userRoom = userRoom;

// Authenticate every socket using the same JWT as the REST API. The token is
// read from the Socket.IO handshake (app sends it via the `auth` field) and
// verified against JWT_SECRET. The resulting userId is used to assign the
// socket to that user's private room so events only reach that user's clients.
io.use((socket, next) => {
  const token = socket.handshake.auth && socket.handshake.auth.token;
  if (!token) {
    return next(new Error('Missing token'));
  }
  try {
    const decoded = jwt.verify(token, JWT_SECRET);
    socket.data.userId = decoded.userId;
    next();
  } catch (err) {
    return next(new Error('Invalid or expired token'));
  }
});

io.on('connection', (socket) => {
  const room = userRoom(socket.data.userId);
  socket.join(room);
  console.log(`Client connected: ${socket.id} -> room ${room}`);
  // Private fast-path room for one provisioning attempt, keyed by the device's
  // canonical MAC (which the client itself read from the physical device).
  // Access is verified against the DB before the socket may listen: a device
  // that belongs to ANOTHER account is never watched, so the device_seen wake
  // up can never leak another user's device presence. Polling the /seen
  // endpoint remains the source of truth; this is a wake-up only.
  socket.on('provision_watch', async (payload, ack) => {
    const deviceId = payload && payload.deviceId;
    if (!deviceId || typeof deviceId !== 'string') {
      if (typeof ack === 'function') ack({ ok: false, error: 'missing deviceId' });
      return;
    }
    const mac = normalizeMac(deviceId);
    if (!mac) {
      if (typeof ack === 'function') ack({ ok: false, error: 'invalid deviceId' });
      return;
    }
    try {
      const existing = await Device.findOne({ deviceId: mac });
      if (
        existing &&
        existing.ownerId &&
        existing.ownerId.toString() !== String(socket.data.userId)
      ) {
        // Owned by another account - never expose its presence.
        if (typeof ack === 'function') ack({ ok: false, error: 'not authorized' });
        return;
      }
      socket.join(`provision:${mac}`);
      console.log(`[provision] ${socket.id} watching device ${mac}`);
      if (typeof ack === 'function') ack({ ok: true });
    } catch (err) {
      console.error(`provision_watch error: ${err.message}`);
      if (typeof ack === 'function') ack({ ok: false, error: 'internal' });
    }
  });
  socket.on('disconnect', () => {
    console.log(`Client disconnected: ${socket.id}`);
  });
});

app.get('/api/health', (req, res) => {
  const seen = mqttGateway.snapshot();
  res.json({
    status: 'ok',
    mqtt: mqttGateway.isConnected() ? 'connected' : 'disconnected',
    db: mongoose.connection.readyState === 1 ? 'connected' : 'disconnected',
    claimedDevices: deviceRegistry.size(),
    seenOnMqtt: seen.sensors.length + seen.devices.length,
  });
});

// Devices and sensors currently observed on the MQTT broker - no auth so it's
// easy to curl from anywhere for debugging.
app.get('/api/mqtt/snapshot', (req, res) => {
  res.json(mqttGateway.snapshot());
});

app.use('/api/auth', authRoutes);
app.use('/api/devices', authMiddleware, deviceRoutes);
app.use('/api/sensors', authMiddleware, sensorRoutes);
app.use('/api/rules', authMiddleware, ruleRoutes);
app.use('/api/schedules', authMiddleware, scheduleRoutes);
app.use('/api', authMiddleware, controlRoutes);

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Backend server running on port ${PORT}`);
});
