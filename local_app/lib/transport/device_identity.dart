final RegExp _canonicalMacRe = RegExp(r'^[0-9A-F]{12}$');

String? normalizeMac(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final cleaned = raw
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(':', '')
      .replaceAll('-', '')
      .toUpperCase();
  if (!_canonicalMacRe.hasMatch(cleaned)) return null;
  return cleaned;
}

bool isCanonicalDeviceId(String value) {
  return _canonicalMacRe.hasMatch(value);
}

class ClaimDeviceSnapshot {
  ClaimDeviceSnapshot._(this.macs);

  final Set<String> macs;

  factory ClaimDeviceSnapshot.fromDevices(List<dynamic> devices) {
    final normalized = <String>{};
    for (final device in devices) {
      if (device is! Map) continue;
      final mac = device['deviceId'];
      if (mac is String) {
        final canonical = normalizeMac(mac);
        if (canonical != null) normalized.add(canonical);
      }
    }
    return ClaimDeviceSnapshot._(Set.unmodifiable(normalized));
  }

  factory ClaimDeviceSnapshot.fromMacs(Iterable<String> macs) {
    final normalized = <String>{};
    for (final mac in macs) {
      final canonical = normalizeMac(mac);
      if (canonical != null) normalized.add(canonical);
    }
    return ClaimDeviceSnapshot._(Set.unmodifiable(normalized));
  }

  factory ClaimDeviceSnapshot.empty() => ClaimDeviceSnapshot._(const {});

  bool containsMac(String? mac) {
    final canonical = normalizeMac(mac);
    return canonical != null && macs.contains(canonical);
  }
}
