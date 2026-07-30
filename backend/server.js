const express = require('express');
const cors = require('cors');
const http = require('http');
const { Server } = require('socket.io');
const mongoose = require('mongoose');
const mqtt = require('mqtt');

const authRoutes = require('./routes/auth');
const deviceRoutes = require('./routes/devices');
const controlRoutes = require('./routes/control');
const { authMiddleware } = require('./middleware/auth');

const app = express();
const PORT = process.env.PORT || 3001;
const BROKER_URL = process.env.MQTT_BROKER_URL;
const MONGO_URI = process.env.MONGO_URI;

const server = http.createServer(app);
const io = new Server(server, {
  cors: { origin: '*' },
});

app.use(cors());
app.use(express.json());

const deviceStates = {};
let mqttClient = null;

app.set('deviceStates', deviceStates);
app.set('mqttClient', null);

mongoose.connect(MONGO_URI)
  .then(() => console.log('Connected to MongoDB'))
  .catch((err) => {
    console.error('MongoDB connection error:', err.message);
    console.log('Server will start without database. Auth and device ownership will not work.');
  });

function connectMQTT() {
  if (!BROKER_URL || !BROKER_URL.startsWith('mqtt')) {
    console.log(`MQTT broker not configured. Set MQTT_BROKER_URL env var.`);
    return;
  }

  const options = {
    username: process.env.MQTT_USERNAME,
    password: process.env.MQTT_PASSWORD,
  };

  mqttClient = mqtt.connect(BROKER_URL, options);
  app.set('mqttClient', mqttClient);

  mqttClient.on('connect', () => {
    console.log(`Backend connected to MQTT broker at ${BROKER_URL}`);

    mqttClient.subscribe('stat/+/RESULT');
    mqttClient.subscribe('stat/+/POWER+');
    mqttClient.subscribe('tele/+/STATE');
  });

  mqttClient.on('error', (err) => {
    console.error('MQTT error:', err.message);
  });

  mqttClient.on('message', (topic, message) => {
    const topicStr = topic.toString();
    const parts = topicStr.split('/');
    const deviceId = parts[1];
    const payload = message.toString();

    if (!deviceStates[deviceId]) {
      deviceStates[deviceId] = { 1: 'OFF', 2: 'OFF', 3: 'OFF', 4: 'OFF' };
    }

    try {
      const data = JSON.parse(payload);
      for (let i = 1; i <= 4; i++) {
        const key = `POWER${i}`;
        if (data[key]) {
          deviceStates[deviceId][i] = data[key];
          io.emit('device_update', { deviceId, channel: i, state: data[key] });
        }
      }
    } catch {
      const powerMatch = topicStr.match(/POWER(\d)$/);
      if (powerMatch) {
        const ch = parseInt(powerMatch[1]);
        const state = payload.trim().toUpperCase();
        if (state === 'ON' || state === 'OFF') {
          deviceStates[deviceId][ch] = state;
          io.emit('device_update', { deviceId, channel: ch, state });
        }
      }
    }
  });
}

connectMQTT();

io.on('connection', (socket) => {
  console.log(`Client connected: ${socket.id}`);
  socket.on('disconnect', () => {
    console.log(`Client disconnected: ${socket.id}`);
  });
});

app.use('/api/auth', authRoutes);
app.use('/api/devices', authMiddleware, deviceRoutes);
app.use('/api', authMiddleware, controlRoutes);

app.get('/api/health', (req, res) => {
  res.json({
    status: 'ok',
    mqtt: mqttClient ? (mqttClient.connected ? 'connected' : 'disconnected') : 'not configured',
    db: mongoose.connection.readyState === 1 ? 'connected' : 'disconnected',
    devices: Object.keys(deviceStates),
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Backend server running on port ${PORT}`);
});
