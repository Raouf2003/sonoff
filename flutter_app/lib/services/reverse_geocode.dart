import 'dart:convert';

import 'package:http/http.dart' as http;

// Best-effort reverse geocoding via OpenStreetMap Nominatim. Optional: the
// coordinates are always authoritative, the place name is display only.
// Returns a short precise label at village/hamlet level (zoom 16) – e.g.
// "Ouled Sidi Brahim, M'Sila, Algeria" – so the picker badge is farm-level
// rather than city-level. Falls back to display_name when address is missing.
Future<String?> reverseGeocode(double lat, double lon,
    {http.Client? client, String language = 'en'}) async {
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=jsonv2&zoom=16&addressdetails=1&accept-language=$language');
    final res = await httpClient.get(uri, headers: {
      'User-Agent': 'STEES/1.0 (smart irrigation advisory)',
    }).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body);
    if (body is! Map) return null;
    // Prefer structured address for village-level precision. At zoom 16
    // Nominatim returns hamlet/village/suburb/road when available.
    final addr = body['address'];
    if (addr is Map) {
      final parts = <String>[];
      String? local = (addr['village'] ??
              addr['hamlet'] ??
              addr['suburb'] ??
              addr['neighbourhood'] ??
              addr['town'] ??
              addr['city'] ??
              addr['municipality'] ??
              addr['county'] ??
              addr['road']) as String?;
      if (local != null && local.trim().isNotEmpty) {
        parts.add(local.trim());
      }
      final county = (addr['county'] ??
              addr['state_district'] ??
              addr['district'] ??
              addr['municipality']) as String?;
      if (county != null &&
          county.trim().isNotEmpty &&
          (parts.isEmpty || county.trim() != parts.first)) {
        parts.add(county.trim());
      }
      final state = (addr['state'] ?? addr['region'] ?? addr['province']) as String?;
      if (state != null &&
          state.trim().isNotEmpty &&
          !parts.contains(state.trim())) {
        parts.add(state.trim());
      }
      final country = addr['country'] as String?;
      if (country != null &&
          country.trim().isNotEmpty &&
          !parts.contains(country.trim())) {
        parts.add(country.trim());
      }
      if (parts.length >= 2) {
        return parts.take(3).join(', ');
      }
      if (parts.isNotEmpty) return parts.first;
    }
    final display = body['display_name'];
    if (display is! String || display.isEmpty) return null;
    // At zoom 16 display_name starts at road/hamlet — keep 4 parts for
    // precision instead of the old city-level 3.
    return display.split(',').take(4).join(',').trim();
  } catch (_) {
    return null;
  } finally {
    if (owned) httpClient.close();
  }
}
