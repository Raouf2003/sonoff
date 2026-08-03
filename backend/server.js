const express = require('express');
const cors = require('cors');
const http = require('http');
const { Server } = require('socket.io');
const mongoose = require('mongoose');

const authRoutes = require('./routes/auth');
const deviceRoutes = require('./routes/devices');
const controlRoutes = require('./routes/control');
const sensorRoutes = require('./routes/sensors');
const ruleRoutes = require('./routes/rules');
const { authMiddleware } = require('./middleware/auth');

const deviceRegistry = require('./services/deviceRegistry');
const runtimeState = require('./services/runtimeState');
const mqttGateway = require('./services/mqttGateway');
const ruleEngine = require('./services/ruleEngine');

const app = express();
const PORT = process.env.PORT || 3001;
const MONGO_URI = process.env.MONGO_URI;

const server = http.createServer(app);
const io = new Server(server, {
  cors: { origin: '*' },
});

app.use(cors());
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
}

initRuntime();
loadFromDb().catch((err) => console.error('Service init error:', err.message));

io.on('connection', (socket) => {
  console.log(`Client connected: ${socket.id}`);
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
app.use('/api', authMiddleware, controlRoutes);

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Backend server running on port ${PORT}`);
});
