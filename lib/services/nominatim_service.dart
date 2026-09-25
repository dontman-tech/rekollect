import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class NominatimService {
  const NominatimService({http.Client? client}) : _client = client;

  final http.Client? _client;

  http.Client get client => _client ?? http.Client();

  // Nominatim's usage policy requires a descriptive UA and throttles heavy
  // clients; a 10s timeout keeps a dead network from hanging the form.
  static const Map<String, String> _headers = {
    'User-Agent': 'Re-kollect/1.0 (waste pickup marketplace, Buea Cameroon)',
  };
  static const Duration _timeout = Duration(seconds: 10);

  Future<LatLng> searchLocation(String query) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': query,
      'format': 'json',
      'limit': '1',
    });
    final response = await client
        .get(uri, headers: _headers)
        .timeout(_timeout, onTimeout: () => throw TimeoutException('Location lookup timed out.'));
    if (response.statusCode == 429) {
      throw const LookupException('Location service is busy — try again in a moment.');
    }
    if (response.statusCode != 200) {
      throw const LookupException('Location lookup failed. Check your connection.');
    }
    final results = jsonDecode(response.body) as List<dynamic>;
    if (results.isEmpty) {
      throw const LookupException('Location not found — try adding "Buea" to your search.');
    }
    final first = results.first as Map<String, dynamic>;
    return LatLng(
      double.parse(first['lat'] as String),
      double.parse(first['lon'] as String),
    );
  }

  Future<String> reverseLocation(LatLng point) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'lat': point.latitude.toString(),
      'lon': point.longitude.toString(),
      'format': 'json',
    });
    final response = await client
        .get(uri, headers: _headers)
        .timeout(_timeout, onTimeout: () => throw TimeoutException('Location lookup timed out.'));
    if (response.statusCode != 200) {
      return '${point.latitude}, ${point.longitude}';
    }
    final result = jsonDecode(response.body) as Map<String, dynamic>;
    return result['display_name'] as String? ?? '${point.latitude}, ${point.longitude}';
  }
}

class LookupException implements Exception {
  const LookupException(this.message);
  final String message;
  @override
  String toString() => message;
}
