const express = require('express');
const bonjour = require('bonjour')();

const app = express();
const PORT = parseInt(process.env.PORT || '1880', 10);

const TOPIC = process.env.TOPIC || 'tasmota_C30304';
const FRIENDLY_NAME = process.env.FRIENDLY_NAME || 'Mock Garden Controller';

const relays = { 1: 'OFF', 2: 'OFF', 3: 'OFF', 4: 'OFF' };

function buildStatusPayload() {
  const state = {};
  for (let i = 1; i <= 4; i++) state[`POWER${i}`] = relays[i];
  return {
    Status: {
      Module: 23,
      FriendlyName: [FRIENDLY_NAME],
      Topic: TOPIC,
      WebServer: 2,
      Hostname: `${TOPIC}-mock`,
      IPAddress: '127.0.0.1',
    },
    StatusSTS: {
      Time: new Date().toISOString(),
      Uptime: '0T00:00:01',
      ...state,
    },
  };
}

function applyPower1(state) {
  const m = state.match(/^POWER(\d)$/i);
  if (!m) return null;
  const ch = parseInt(m[1], 10);
  return ch >= 1 && ch <= 4 ? ch : null;
}

function runCommand(cmnd) {
  const parts = String(cmnd || '').trim().split(/\s+/);
  const [cmd, arg] = parts;

  if (!cmd) return { error: 'Unknown command' };

  if (/^status$/i.test(cmd)) {
    return buildStatusPayload();
  }

  const ch = applyPower1(cmd);
  if (ch) {
    const state = arg ? arg.toUpperCase() : 'TOGGLE';
    if (state === 'ON' || state === 'OFF') {
      relays[ch] = state;
    } else if (state === 'TOGGLE') {
      relays[ch] = relays[ch] === 'ON' ? 'OFF' : 'ON';
    }
    return { [`POWER${ch}`]: relays[ch] };
  }

  return { error: 'Unknown command' };
}

app.get('/cm', (req, res) => {
  const result = runCommand(req.query.cmnd);
  console.log(`Mock Tasmota: cmnd=${req.query.cmnd} ->`, JSON.stringify(result));
  res.json(result);
});

app.get('/', (req, res) => {
  res.send(`<html><head><title>${TOPIC}</title></head><body><h2>${FRIENDLY_NAME} (mock Tasmota)</h2></body></html>`);
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Mock Tasmota listening on 0.0.0.0:${PORT}`);
  console.log(`  Topic: ${TOPIC} | FriendlyName: ${FRIENDLY_NAME}`);
  console.log(`  Test:  http://localhost:${PORT}/cm?cmnd=Status`);
  console.log(`  Power: http://localhost:${PORT}/cm?cmnd=Power1%20ON`);

  const svc = bonjour.publish({
    name: TOPIC,
    type: 'tasmota',
    port: PORT,
  });
  svc.on('up', () => console.log('  mDNS _tasmota._tcp advertised'));
  svc.on('error', (err) => console.error('  mDNS error:', err.message));
});

process.on('SIGINT', () => {
  bonjour.unpublishAll();
  bonjour.destroy();
  process.exit(0);
});
