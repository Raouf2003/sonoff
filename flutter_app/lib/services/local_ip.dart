import 'dart:io';

/// Extracts the host part of an endpoint for validation/logging: strips any
/// scheme, a trailing `:port` (IPv4:port), IPv6 brackets, and a zone id.
/// `192.168.1.5:8080` → `192.168.1.5`, `[fe80::1%25wlan0]` → `fe80::1`.
String endpointHost(String endpoint) {
  var s = endpoint.trim();
  final scheme = s.indexOf('://');
  if (scheme >= 0) s = s.substring(scheme + 3);
  if (s.startsWith('[')) {
    final close = s.indexOf(']');
    if (close > 0) return _stripZone(s.substring(1, close));
  }
  final firstColon = s.indexOf(':');
  if (firstColon >= 0 && firstColon == s.lastIndexOf(':')) {
    final after = s.substring(firstColon + 1);
    if (int.tryParse(after) != null) return s.substring(0, firstColon);
  }
  return _stripZone(s);
}

String _stripZone(String s) {
  final zone = s.indexOf('%');
  return zone > 0 ? s.substring(0, zone) : s;
}

/// A LAN IP usable as a DEVICE address: syntactically valid AND not the
/// unspecified address (`0.0.0.0` / `::`), not loopback, and not multicast.
/// Such addresses must never be persisted as a candidate, verified, or warm
/// endpoint.
bool isValidLocalIp(String? raw) {
  final host = raw == null ? '' : endpointHost(raw);
  if (host.isEmpty) return false;
  final addr = InternetAddress.tryParse(host);
  if (addr == null) return false;
  if (_isUnspecified(addr)) return false;
  if (addr.isLoopback) return false;
  if (addr.isMulticast) return false;
  return true;
}

/// Same as [isValidLocalIp] but ALLOWS loopback. Used ONLY as the last-line
/// guard in the HTTP fetcher so a local test server (`127.0.0.1`) still works,
/// while unspecified (`0.0.0.0`) and multicast addresses — which can never be a
/// real device — are blocked before any socket is created. Storage layers
/// reject loopback, so it can never persist in production.
bool isUsableHttpHost(String? raw) {
  final host = raw == null ? '' : endpointHost(raw);
  if (host.isEmpty) return false;
  final addr = InternetAddress.tryParse(host);
  if (addr == null) return false;
  if (_isUnspecified(addr)) return false;
  if (addr.isMulticast) return false;
  return true;
}

/// True for the unspecified address in either family: `0.0.0.0` (IPv4) or an
/// all-zero IPv6 (`::`, `0:0:0:0:0:0:0:0`, ...). Some SDK versions expose this
/// as a getter; this explicit check works across all of them.
bool _isUnspecified(InternetAddress addr) {
  final a = addr.address.toLowerCase();
  if (addr.type == InternetAddressType.IPv4) return a == '0.0.0.0';
  if (a == '::') return true;
  return a
      .split(':')
      .every((part) => part.isEmpty || int.tryParse(part, radix: 16) == 0);
}
