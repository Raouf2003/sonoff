const RuleLog = require('../models/RuleLog');

class CommandRouter {
  constructor() {
    this.mqttGateway = null;
    this.deviceRegistry = null;
    this.runtimeState = null;
  }

  init({ mqttGateway, deviceRegistry, runtimeState }) {
    this.mqttGateway = mqttGateway;
    this.deviceRegistry = deviceRegistry;
    this.runtimeState = runtimeState;
  }

  async execute(rule, value, ts) {
    const ownerId = rule.ownerId.toString();
    if (this.runtimeState.isEmergencyStop(ownerId)) {
      this._log(rule, 'emergency_stop', 'owner emergency stop enabled', null);
      return;
    }

    const action = rule.action;
    const device = this.deviceRegistry.get(action.deviceId);
    if (!device) {
      this._log(rule, 'blocked', 'action device not found', null);
      return;
    }
    if (device.ownerId !== ownerId) {
      this._log(rule, 'blocked', 'action device not owned', null);
      return;
    }

    try {
      const acked = await this.mqttGateway.publishCommand(action.deviceId, action.channel, action.state);
      this._log(rule, 'executed', acked ? null : 'published but no device ack', acked);
    } catch (err) {
      this._log(rule, 'error', err.message, null);
    }
  }

  _log(rule, status, reason, acked) {
    RuleLog.create({
      ruleId: rule._id,
      ownerId: rule.ownerId,
      deviceId: rule.action.deviceId,
      channel: rule.action.channel,
      action: rule.action.state,
      status,
      reason,
      ruleVersion: rule.version || 1,
      acked: !!acked,
    }).catch((err) => console.error('RuleLog write error:', err.message));
  }
}

module.exports = new CommandRouter();
