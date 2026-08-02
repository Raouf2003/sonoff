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

setInterval(() => {
  const teleState = {
    Time: new Date().toISOString(),
    POWER1: relays[1],
    POWER2: relays[2],
    POWER3: relays[3],
    POWER4: relays[4],
  };
  client.publish(`tele/${DEVICE_ID}/STATE`, JSON.stringify(teleState));
  console.log(`[${DEVICE_ID}] tele -> ${JSON.stringify(teleState)}`);
}, 10000);
