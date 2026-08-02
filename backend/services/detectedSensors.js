// In-memory list of sensor IDs currently seen on the MQTT broker.
// It is only a helper for the "Detected Sensors" list in the app: it
// autofills the Sensor ID field and never creates any relationship.
// No persistence, no owner, no device mapping.
class DetectedSensors {
  constructor() {
    this.map = new Map();
  }

  observe(sensorId, value) {
    this.map.set(sensorId, {
      sensorId,
      lastValue: value,
      lastSeen: new Date().toISOString(),
    });
  }

  get(sensorId) {
    return this.map.get(sensorId) || null;
  }

  all() {
    return Array.from(this.map.values());
  }
}

module.exports = new DetectedSensors();
