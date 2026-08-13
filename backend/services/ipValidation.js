// Shared IP validation for everything that learns a device's LAN address.
//
// Tasmota publishes `"IPAddress":"0.0.0.0"` in `tele/<id>/STATE` during boot,
// STA reconnect and pre-DHCP — and `net.isIP` (like Dart's
// InternetAddress.tryParse) accepts `0.0.0.0` because it is *syntactically*
// valid. Those transient addresses must never be persisted as a device's
// lastIp: the app uses lastIp as a local-first discovery hint, so an invalid
// value sends HTTP probes into nowhere.
//
// An address is "valid" for storage when it is a well-formed IPv4/IPv6 address
// that is NOT the unspecified address (`0.0.0.0` / `::`), NOT loopback, and NOT
// multicast. Such addresses can never identify a real LAN device.

const net = require('net');

// Returns 'valid' | 'unspecified' | 'loopback' | 'multicast' | 'invalid'.
function classifyIp(raw) {
  if (typeof raw !== 'string') return 'invalid';
  const s = raw.trim();
  if (!s) return 'invalid';
  const family = net.isIP(s);
  if (family === 4) return classifyIpv4(s);
  if (family === 6) return classifyIpv6(s);
  return 'invalid';
}

function classifyIpv4(s) {
  const firstOctet = Number(s.split('.')[0]);
  if (firstOctet === 0) return 'unspecified'; // 0.0.0.0 and friends
  if (firstOctet === 127) return 'loopback';
  if (firstOctet >= 224 && firstOctet <= 239) return 'multicast';
  return 'valid';
}

function classifyIpv6(s) {
  const lower = s.toLowerCase();
  if (isAllZerosV6(lower)) return 'unspecified';
  if (isLoopbackV6(lower)) return 'loopback';
  if (lower.startsWith('ff')) return 'multicast'; // ff00::/8
  return 'valid';
}

// True for every all-zero form of :: (e.g. '::', '0:0:0:0:0:0:0:0').
function isAllZerosV6(s) {
  if (s === '::') return true;
  const parts = s.split(':');
  for (const p of parts) {
    if (p === '') continue;
    if (!/^0+$/.test(p)) return false;
  }
  return true;
}

function isLoopbackV6(s) {
  if (s === '::1') return true;
  // Expanded all-zero form ending in ':1', e.g. 0:0:0:0:0:0:0:1.
  if (!s.endsWith(':1')) return false;
  return isAllZerosV6(s.slice(0, -1));
}

function isValidLocalIp(raw) {
  return classifyIp(raw) === 'valid';
}

module.exports = {
  classifyIp,
  isValidLocalIp,
};
