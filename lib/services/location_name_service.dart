import 'dart:convert';

import 'package:http/http.dart' as http;

/// Free, no-API-key reverse geocoding (same "no key needed" spirit as the
/// map tiles and weather already used in this app).
class LocationNameService {
  LocationNameService._();

  static Future<String?> reverseGeocode(double lat, double lon) async {
    final uri = Uri.parse(
      'https://api.bigdatacloud.net/data/reverse-geocode-client'
      '?latitude=$lat&longitude=$lon&localityLanguage=en',
    );
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final city = body['city'] as String?;
      final locality = body['locality'] as String?;
      final subdivision = body['principalSubdivision'] as String?;
      final name = (city != null && city.isNotEmpty)
          ? city
          : (locality != null && locality.isNotEmpty ? locality : subdivision);
      return name;
    } catch (_) {
      return null;
    }
  }
}
