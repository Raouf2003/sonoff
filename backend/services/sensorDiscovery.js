const deviceRegistry = require('./deviceRegistry');

class SensorDiscovery {
  constructor() {
    this.entries = new Map();
  }

  _key(deviceId, sensorId) {
    return `${deviceId}:${sensorId}`;
  }

  observe(deviceId, sensorId, value) {
    const key = this._key(deviceId, sensorId);
    this.entries.set(key, {
      sensorId,
      deviceId,
      lastValue: value,
      lastSeen: new Date().toISOString(),
    });
  }

  all() {
    return Array.from(this.entries.values());
  }

  forOwner(ownerId) {
    return this.all().filter((e) => deviceRegistry.ownerOf(e.deviceId) === ownerId);
  }

  size() {
    return this.entries.size;
  }
}

module.exports = new SensorDiscovery();
