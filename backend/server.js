const express = require('express');
const cors = require('cors');
const http = require('http');
const { Server } = require('socket.io');
const mongoose = require('mongoose');

const authRoutes = require('./routes/auth');
const deviceRoutes = require('./routes/devices');
const controlRoutes = require('./routes/control');
const ruleRoutes = require('./routes/rules');
const sensorRoutes = require('./routes/sensors');
const runtimeRoutes = require('./routes/runtime');
const { authMiddleware } = require('./middleware/auth');

const User = require('./models/User');
const deviceRegistry = require('./services/deviceRegistry');
const runtimeState = require('./services/runtimeState');
const commandRouter = require('./services/commandRouter');
const ruleEngine = require('./services/ruleEngine');
const mqttGateway = require('./services/mqttGateway');

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
  ruleEngine.init({ runtimeState, commandRouter });
  commandRouter.init({ mqttGateway, deviceRegistry, runtimeState });
  mqttGateway.init({ io, deviceRegistry, runtimeState, engine: ruleEngine });
}

async function loadFromDb() {
  for (let i = 0; i < 60 && mongoose.connection.readyState !== 1; i++) {
    await delay(1000);
  }
  if (mongoose.connection.readyState !== 1) {
    console.error('Database unavailable; device ownership and rules will not be loaded');
    return;
  }
  await deviceRegistry.init();
  await ruleEngine.rebuildAll();
  const stops = await User.find({ emergencyStop: true }, '_id');
  for (const u of stops) runtimeState.setEmergencyStop(u._id.toString(), true);
  if (stops.length) console.log(`RuntimeState: restored ${stops.length} emergency-stop flag(s)`);
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
  res.json({
    status: 'ok',
    mqtt: mqttGateway.isConnected() ? 'connected' : 'disconnected',
    db: mongoose.connection.readyState === 1 ? 'connected' : 'disconnected',
    claimedDevices: deviceRegistry.size(),
  });
});

app.use('/api/auth', authRoutes);
app.use('/api/devices', authMiddleware, deviceRoutes);
app.use('/api/rules', authMiddleware, ruleRoutes);
app.use('/api/sensors', authMiddleware, sensorRoutes);
app.use('/api/runtime', authMiddleware, runtimeRoutes);
app.use('/api', authMiddleware, controlRoutes);

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Backend server running on port ${PORT}`);
});
