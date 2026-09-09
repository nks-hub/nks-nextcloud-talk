import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'location_map.dart';

/// Why a place search produced no usable answer.
enum PlaceSearchError {
  /// The caller asked again too soon; the geocoder allows one query a second.
  rateLimited,

  /// The geocoder could not be reached, or answered with something unusable.
  unavailable,

  /// The geocoder answered, and nothing matched.
  noResults,
}

final class PlaceSearchException implements Exception {
  const PlaceSearchException(this.code);
  final PlaceSearchError code;
}

/// One place the geocoder proposes for a typed name.
final class PlaceSuggestion {
  const PlaceSuggestion({
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  final String name;
  final double latitude;
  final double longitude;
}

abstract interface class PlaceSearchSource {
  Future<List<PlaceSuggestion>> search(String query);
}

/// Looks names up in OpenStreetMap's Nominatim geocoder.
///
/// Nominatim is the one geocoder this app can use without an API key it does
/// not have, and its usage policy is what shapes the code below: one request
/// at a time, at most one per second, only when a person submits a query (no
/// per-keystroke completion), and a User-Agent that names the application.
/// The results carry OpenStreetMap data, so whatever shows them also shows
/// the attribution.
final class NominatimPlaceSearch implements PlaceSearchSource {
  NominatimPlaceSearch({http.Client? client})
    : _client = client ?? http.Client();

  static const minimumInterval = Duration(seconds: 1);
  static const timeout = Duration(seconds: 10);
  static const maximumResults = 5;

  /// Nominatim answers a five-result query in a few kilobytes. The bound is
  /// checked after the body arrives, which is enough for a response this
  /// small; a streaming bound would only matter for a much larger endpoint.
  static const maximumResponseBytes = 256 * 1024;

  final http.Client _client;
  DateTime? _lastRequest;
  var _inFlight = false;

  @override
  Future<List<PlaceSuggestion>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      throw const PlaceSearchException(PlaceSearchError.noResults);
    }
    final last = _lastRequest;
    if (_inFlight ||
        (last != null &&
            DateTime.now().difference(last).abs() < minimumInterval)) {
      throw const PlaceSearchException(PlaceSearchError.rateLimited);
    }
    _inFlight = true;
    _lastRequest = DateTime.now();
    try {
      final response = await _client
          .get(
            Uri.https('nominatim.openstreetmap.org', '/search', {
              'q': trimmed,
              'format': 'jsonv2',
              'limit': '$maximumResults',
              'addressdetails': '0',
            }),
            headers: const {
              'User-Agent': locationMapUserAgent,
              'Accept': 'application/json',
            },
          )
          .timeout(timeout);
      if (response.statusCode != 200 ||
          response.headers['content-type']?.split(';').first.trim() !=
              'application/json' ||
          response.bodyBytes.length > maximumResponseBytes) {
        throw const PlaceSearchException(PlaceSearchError.unavailable);
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! List) {
        throw const PlaceSearchException(PlaceSearchError.unavailable);
      }
      final suggestions = <PlaceSuggestion>[];
      for (final entry in decoded.take(maximumResults)) {
        final suggestion = _suggestion(entry);
        if (suggestion != null) {
          suggestions.add(suggestion);
        }
      }
      if (suggestions.isEmpty) {
        throw const PlaceSearchException(PlaceSearchError.noResults);
      }
      return List.unmodifiable(suggestions);
    } on PlaceSearchException {
      rethrow;
    } on Object {
      throw const PlaceSearchException(PlaceSearchError.unavailable);
    } finally {
      _lastRequest = DateTime.now();
      _inFlight = false;
    }
  }

  PlaceSuggestion? _suggestion(Object? entry) {
    if (entry is! Map) {
      return null;
    }
    final latitude = _coordinate(entry['lat'], 90);
    final longitude = _coordinate(entry['lon'], 180);
    final name = sanitizedLocationName(entry['display_name']);
    if (latitude == null || longitude == null || name == null) {
      return null;
    }
    return PlaceSuggestion(
      name: name,
      latitude: latitude,
      longitude: longitude,
    );
  }

  double? _coordinate(Object? value, double bound) {
    final parsed = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value)
        : null;
    if (parsed == null || !parsed.isFinite || parsed.abs() > bound) {
      return null;
    }
    return parsed;
  }
}

/// Trims a place name down to what the share request accepts: no control
/// characters, no surrounding space, at most 256 characters.
String? sanitizedLocationName(Object? value) {
  if (value is! String) {
    return null;
  }
  final cleaned = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  if (cleaned.isEmpty) {
    return null;
  }
  final bounded = cleaned.length > 256
      ? cleaned.substring(0, 256).trim()
      : cleaned;
  return bounded.isEmpty ? null : bounded;
}
