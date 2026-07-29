const express = require('express');
const app = express();
const PORT = 8088;

const relays = {
  1: 'OFF',
  2: 'OFF',
  3: 'OFF',
  4: 'OFF',
};

app.get('/cmnd', (req, res) => {
  const cmnd = req.query.cmnd;
  if (!cmnd) {
    return res.status(400).json({ error: 'Missing cmnd parameter' });
  }

  const match = cmnd.match(/^Power(\d)\s+(ON|OFF|TOGGLE)$/i);
  if (!match) {
    return res.status(400).json({ error: 'Invalid command format' });
  }

  const channel = parseInt(match[1], 10);
  const action = match[2].toUpperCase();

  if (action === 'TOGGLE') {
    relays[channel] = relays[channel] === 'ON' ? 'OFF' : 'ON';
  } else {
    relays[channel] = action;
  }

  const key = `POWER${channel}`;
  const response = {};
  response[key] = relays[channel];
  res.json(response);
});

app.get('/cmnd/status', (req, res) => {
  const status = {};
  for (let i = 1; i <= 4; i++) {
    status[`POWER${i}`] = relays[i];
  }
  res.json(status);
});

app.listen(PORT, () => {
  console.log(`Virtual Sonoff 4CH Pro R3 running on http://localhost:${PORT}`);
});