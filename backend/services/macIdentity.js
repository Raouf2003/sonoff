// Canonical device identity: the physical Tasmota MAC address IS the device.
//
// Every NEW device is identified by a single canonical string derived from its
// MAC, which is also the MQTT topic burned into the firmware:
//
//   "34:98:7A:C3:03:04"  →  "34987AC30304"
//   "34-98-7A-C3-03-04"  →  "34987AC30304"
//   "34987AC30304"       →  "34987AC30304"
//
// Normalization is deterministic (same MAC always maps to the same deviceId),
// case-insensitive and tolerance-free afterwards: separators `:`, `-` and
// whitespace are stripped, the remainder must be exactly 12 hex digits.
//
// Tasmota MQTT topics allow [A-Za-z0-9_-], so the canonical form is a valid
// topic with no escaping needed.

// 12 uppercase hex digits, no separators. Enforced on every stored identity.
const MAC_ID_RE = /^[0-9A-F]{12}$/;

function normalizeMac(raw) {
  if (typeof raw !== 'string') return null;
  const cleaned = raw
    .replace(/\s+/g, '')
    .replace(/[:\-]/g, '')
    .toUpperCase();
  if (!MAC_ID_RE.test(cleaned)) return null;
  return cleaned;
}

module.exports = {
  MAC_ID_RE,
  normalizeMac,
};