const mqtt = require('mqtt');

const BROKER_URL = process.env.MQTT_BROKER_URL || 'mqtt://localhost:1883';
const USERNAME = process.env.MQTT_USERNAME;
const PASSWORD = process.env.MQTT_PASSWORD;
const DEVICE_NAME = process.env.DEVICE_NAME || 'smarthome';

const relays = { 1: 'OFF', 2: 'OFF', 3: 'OFF', 4: 'OFF' };

const client = mqtt.connect(BROKER_URL, { username: USERNAME, password: PASSWORD });

client.on('connect', () => {
  console.log(`Virtual Sonoff connected to ${BROKER_URL}`);
  client.subscribe(`cmnd/${DEVICE_NAME}/#`, (err) => {
    if (!err) console.log(`Subscribed to cmnd/${DEVICE_NAME}/#`);
  });
});

client.on('message', (topic, message) => {
  const topicStr = topic.toString();
  const payload = message.toString().trim().toUpperCase();

  const match = topicStr.match(new RegExp(`^cmnd/${DEVICE_NAME}/POWER(\\d)$`));
  if (!match) return;

  const channel = parseInt(match[1], 10);
  if (channel < 1 || channel > 4) return;
  if (payload !== 'ON' && payload !== 'OFF') return;

  relays[channel] = payload;
  console.log(`Relay ${channel} turned ${payload}`);

  const resultTopic = `stat/${DEVICE_NAME}/POWER${channel}/RESULT`;
  const resultPayload = JSON.stringify({ [`POWER${channel}`]: payload });
  client.publish(resultTopic, resultPayload);
});