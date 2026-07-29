const express = require('express');
const cors = require('cors');
const http = require('http');
const { Server } = require('socket.io');
const mqtt = require('mqtt');

const app = express();
const PORT = process.env.PORT || 3001;
const BROKER_URL = process.env.MQTT_BROKER_URL || 'mqtt://localhost:1883';
const DEVICE_NAME = process.env.DEVICE_NAME || 'smarthome';

const server = http.createServer(app);
const io = new Server(server, {
  cors: { origin: '*' },
});

app.use(cors());
app.use(express.json());

const deviceState = { 1: 'OFF', 2: 'OFF', 3: 'OFF', 4: 'OFF' };

const mqttClient = mqtt.connect(BROKER_URL);

mqttClient.on('connect', () => {
  console.log(`Backend connected to MQTT broker at ${BROKER_URL}`);
  mqttClient.subscribe(`stat/${DEVICE_NAME}/+/RESULT`);
  mqttClient.subscribe(`tele/${DEVICE_NAME}/+/STATE`);
});

mqttClient.on('error', (err) => {
  console.error('MQTT error:', err.message);
});

mqttClient.on('message', (topic, message) => {
  const topicStr = topic.toString();
  const payload = message.toString();

  try {
    const data = JSON.parse(payload);
    for (let i = 1; i <= 4; i++) {
      const key = `POWER${i}`;
      if (data[key]) {
        deviceState[i] = data[key];
        io.emit('device_update', { channel: i, state: data[key] });
      }
    }
  } catch {
    // Ignore non-JSON payloads
  }
});

io.on('connection', (socket) => {
  console.log(`Client connected: ${socket.id}`);
  socket.on('disconnect', () => {
    console.log(`Client disconnected: ${socket.id}`);
  });
});

app.post('/api/control', (req, res) => {
  const { channel, state } = req.body;

  if (!channel || !state) {
    return res.status(400).json({ error: 'channel and state are required' });
  }

  if (channel < 1 || channel > 4) {
    return res.status(400).json({ error: 'channel must be between 1 and 4' });
  }

  const validStates = ['ON', 'OFF', 'TOGGLE'];
  if (!validStates.includes(state.toUpperCase())) {
    return res.status(400).json({ error: 'state must be ON, OFF, or TOGGLE' });
  }

  const commandTopic = `cmnd/${DEVICE_NAME}/POWER${channel}`;
  mqttClient.publish(commandTopic, state.toUpperCase());

  const key = `POWER${channel}`;
  const response = {};
  response[key] = state.toUpperCase();
  res.json(response);
});

app.get('/api/status', (req, res) => {
  const status = {};
  for (let i = 1; i <= 4; i++) {
    status[`POWER${i}`] = deviceState[i];
  }
  res.json(status);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Backend server running on port ${PORT}`);
});