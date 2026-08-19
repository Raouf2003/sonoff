// Resolves the MQTT broker host/port that devices must be provisioned to use.
// The URL format matches MQTT_BROKER_URL (what the backend gateway connects
// to), so the address the provisioning wizard writes into Tasmota can never
// drift from the broker the backend itself talks to: editing the broker means
// editing ONE env var, and every consumer observes the result.
function resolveBrokerInfo(urlString) {
  if (!urlString) return null;
  let parsed;
  try {
    parsed = new URL(urlString);
  } catch {
    return null;
  }
  if (parsed.protocol !== 'mqtt:' && parsed.protocol !== 'mqtts:') return null;
  const host = parsed.hostname;
  if (!host) return null;
  const fallbackPort =
    parsed.protocol === 'mqtts:' ? 8883 : 1883;
  const port = parsed.port ? Number(parsed.port) : fallbackPort;
  if (Number.isNaN(port)) return null;
  return { host, port };
}

function configuredBrokerInfo() {
  return resolveBrokerInfo(process.env.MQTT_BROKER_URL);
}

module.exports = { resolveBrokerInfo, configuredBrokerInfo };