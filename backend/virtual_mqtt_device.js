const mqtt = require('mqtt');

const BROKER_URL = process.env.MQTT_BROKER_URL || 'mqtt://localhost:1883';
const USERNAME = process.env.MQTT_USERNAME;
const PASSWORD = process.env.MQTT_PASSWORD;
const DEVICE_ID = process.env.DEVICE_ID || process.env.DEVICE_NAME || 'smarthome';

const relays = { 1: 'OFF', 2: 'OFF', 3: 'OFF', 4: 'OFF' };

const client = mqtt.connect(BROKER_URL, { username: USERNAME, password: PASSWORD });

client.on('connect', () => {
  console.log(`Virtual device [${DEVICE_ID}] connected to ${BROKER_URL}`);
  client.subscribe(`cmnd/${DEVICE_ID}/#`, (err) => {
    if (!err) console.log(`Subscribed to cmnd/${DEVICE_ID}/#`);
  });
});

client.on('message', (topic, message) => {
  const topicStr = topic.toString();
  const payload = message.toString().trim().toUpperCase();

  const match = topicStr.match(new RegExp(`^cmnd/${DEVICE_ID}/POWER(\\d)$`));
  if (!match) return;

  const channel = parseInt(match[1], 10);
  if (channel < 1 || channel > 4) return;
  if (payload !== 'ON' && payload !== 'OFF' && payload !== 'TOGGLE') return;

  if (payload === 'TOGGLE') {
    relays[channel] = relays[channel] === 'ON' ? 'OFF' : 'ON';
  } else {
    relays[channel] = payload;
  }

  console.log(`[${DEVICE_ID}] Relay ${channel} turned ${relays[channel]}`);

  const resultPayload = JSON.stringify({
    [`POWER${channel}`]: relays[channel],
  });
  client.publish(`stat/${DEVICE_ID}/RESULT`, resultPayload);
});

const state = { temp_1: 24, soil_1: 40 };

setInterval(() => {
  state.temp_1 = 24 + Math.sin(Date.now() / 60000) * 2 + (Math.random() * 0.5 - 0.25);
  state.soil_1 = Math.max(5, Math.min(95, state.soil_1 + (Math.random() * 4 - 2)));
  const now = new Date().toISOString();
  const teleState = {
    Time: now,
    POWER1: relays[1],
    POWER2: relays[2],
    POWER3: relays[3],
    POWER4: relays[4],
  };
  client.publish(`tele/${DEVICE_ID}/STATE`, JSON.stringify(teleState));
  const sensorPayload = {
    Time: now,
    temp_1: Number(state.temp_1.toFixed(1)),
    soil_1: Number(state.soil_1.toFixed(1)),
  };
  client.publish(`tele/${DEVICE_ID}/SENSOR`, JSON.stringify(sensorPayload));
  console.log(`[${DEVICE_ID}] tele -> ${JSON.stringify(sensorPayload)}`);
}, 10000);
