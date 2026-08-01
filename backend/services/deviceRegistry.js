const Device = require('../models/Device');

class DeviceRegistry {
  constructor() {
    this.devices = new Map();
  }

  async init() {
    const docs = await Device.find({ ownerId: { $ne: null } });
    this.devices.clear();
    for (const d of docs) {
      this.devices.set(d.deviceId, this._map(d));
    }
    console.log(`DeviceRegistry: loaded ${this.devices.size} claimed device(s)`);
  }

  _map(d) {
    return {
      deviceId: d.deviceId,
      ownerId: d.ownerId ? d.ownerId.toString() : null,
      name: d.name,
      type: d.type || 'sonoff-4ch',
      channels: d.channels || 4,
    };
  }

  get(deviceId) {
    return this.devices.get(deviceId) || null;
  }

  ownerOf(deviceId) {
    const d = this.get(deviceId);
    return d ? d.ownerId : null;
  }

  isOwned(deviceId) {
    return !!this.ownerOf(deviceId);
  }

  size() {
    return this.devices.size;
  }

  all() {
    return Array.from(this.devices.values());
  }

  update(device) {
    this.devices.set(device.deviceId, this._map(device));
  }

  remove(deviceId) {
    this.devices.delete(deviceId);
  }
}

module.exports = new DeviceRegistry();
