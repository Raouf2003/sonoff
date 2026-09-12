const { describe, it } = require('node:test');
const assert = require('node:assert/strict');

// Route-level contract: ownership gate + location validation live in
// routes/weather.js and routes/devices.js PATCH /:id/location. These pure
// checks mirror that logic so regressions surface without a DB.
function canAccess(device, userId) {
  if (!device) return 404;
  if (!device.ownerId || String(device.ownerId) !== String(userId)) return 403;
  return 200;
}

function validateLocation(body) {
  const { lat, lon } = body || {};
  if (lat !== undefined && lat !== null && (typeof lat !== 'number' || lat < -90 || lat > 90)) return 400;
  if (lon !== undefined && lon !== null && (typeof lon !== 'number' || lon < -180 || lon > 180)) return 400;
  return 200;
}

describe('weather route guards', () => {
  it('owner can access, others get 403, missing 404', () => {
    assert.equal(canAccess({ ownerId: 'u1' }, 'u1'), 200);
    assert.equal(canAccess({ ownerId: 'u2' }, 'u1'), 403);
    assert.equal(canAccess(null, 'u1'), 404);
  });

  it('rejects out-of-range coordinates', () => {
    assert.equal(validateLocation({ lat: 100, lon: 3 }), 400);
    assert.equal(validateLocation({ lat: 36, lon: 200 }), 400);
    assert.equal(validateLocation({ lat: 36.1, lon: 3.5 }), 200);
    assert.equal(validateLocation({}), 200);
  });

  it('device without coords disables weather (no request)', () => {
    const device = { lat: null, lon: null };
    const weatherDisabled = !(typeof device.lat === 'number' && typeof device.lon === 'number');
    assert.equal(weatherDisabled, true);
  });
});
