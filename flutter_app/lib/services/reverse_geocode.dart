import 'dart:convert';

import 'package:http/http.dart' as http;

// Best-effort reverse geocoding via OpenStreetMap Nominatim. Optional: the
// coordinates are always authoritative, the place name is display only.
// Returns a short "Town, Region, Country" label, or null when unavailable.
Future<String?> reverseGeocode(double lat, double lon,
    {http.Client? client}) async {
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=jsonv2&zoom=10&accept-language=en');
    final res = await httpClient.get(uri, headers: {
      'User-Agent': 'STEES/1.0 (smart irrigation advisory)',
    }).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body);
    if (body is! Map) return null;
    final display = body['display_name'];
    if (display is! String || display.isEmpty) return null;
    return display.split(',').take(3).join(',').trim();
  } catch (_) {
    return null;
  } finally {
    if (owned) httpClient.close();
  }
}
