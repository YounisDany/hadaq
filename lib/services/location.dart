import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import 'assistant.dart' show OfflineException;

class NearbyPlace {
  final String name;
  final double lat;
  final double lon;
  final double distance; // meters
  final double bearing; // degrees from north
  const NearbyPlace(this.name, this.lat, this.lon, this.distance, this.bearing);
}

/// GPS position, nearby places (OpenStreetMap, no API key), and reverse geocoding.
class LocationService {
  static const _ua = 'HadaqAssistant/1.0';

  /// Overpass filters for each Arabic category from the intent classifier.
  static const _filters = <String, List<String>>{
    'مسجد': ['["amenity"="place_of_worship"]["religion"="muslim"]'],
    'صيدلية': ['["amenity"="pharmacy"]'],
    'مستشفى': ['["amenity"="hospital"]', '["amenity"="clinic"]'],
    'مطعم': ['["amenity"="restaurant"]', '["amenity"="fast_food"]'],
    'صراف آلي': ['["amenity"="atm"]'],
    'بنك': ['["amenity"="bank"]'],
    'بقالة': ['["shop"="supermarket"]', '["shop"="convenience"]'],
    'محطة وقود': ['["amenity"="fuel"]'],
    'مقهى': ['["amenity"="cafe"]'],
  };

  Future<bool> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    return p == LocationPermission.always || p == LocationPermission.whileInUse;
  }

  /// An accurate fix: listens to GPS for up to [wait] and returns the first fix
  /// within [goodMeters], else the best one seen (never a stale cached one if a
  /// fresh fix arrives). The first fix is often a rough network/cell estimate.
  Future<Position?> current({Duration wait = const Duration(seconds: 3), double goodMeters = 30}) async {
    if (!await ensurePermission()) return null;
    Position? best;
    final done = Completer<void>();
    StreamSubscription<Position>? sub;
    try {
      sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 0),
      ).listen((p) {
        if (best == null || p.accuracy < best!.accuracy) best = p;
        if (p.accuracy <= goodMeters && !done.isCompleted) done.complete();
      }, onError: (_) {
        if (!done.isCompleted) done.complete();
      });
      await done.future.timeout(wait, onTimeout: () {});
    } catch (_) {
      // fall through
    } finally {
      await sub?.cancel();
    }
    return best ?? await Geolocator.getLastKnownPosition();
  }

  /// True when the user allowed only «approximate» location (Android 12+ / iOS 14+).
  Future<bool> isApproximateOnly() async {
    try {
      return await Geolocator.getLocationAccuracy() == LocationAccuracyStatus.reduced;
    } catch (_) {
      return false;
    }
  }

  Future<void> openAppSettings() => Geolocator.openAppSettings();

  Stream<Position> track() => Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 5),
      );

  static double distance(double lat1, double lon1, double lat2, double lon2) =>
      Geolocator.distanceBetween(lat1, lon1, lat2, lon2);

  static double bearing(double lat1, double lon1, double lat2, double lon2) {
    final b = Geolocator.bearingBetween(lat1, lon1, lat2, lon2);
    return (b + 360) % 360;
  }

  Future<NearbyPlace?> nearest(String category, Position pos, {int radius = 2500}) async {
    final filters = _filters[category];
    if (filters == null) return null;
    final around = '(around:$radius,${pos.latitude},${pos.longitude})';
    final q = '[out:json][timeout:15];(${filters.map((f) => 'nwr$f$around;').join()});out center 40;';
    final j = await _getJson(Uri.https('overpass-api.de', '/api/interpreter', {'data': q}));
    final els = (j['elements'] as List?) ?? [];
    NearbyPlace? best;
    for (final e in els.cast<Map>()) {
      final lat = (e['lat'] ?? e['center']?['lat']) as num?;
      final lon = (e['lon'] ?? e['center']?['lon']) as num?;
      if (lat == null || lon == null) continue;
      final d = distance(pos.latitude, pos.longitude, lat.toDouble(), lon.toDouble());
      if (best == null || d < best.distance) {
        final tags = (e['tags'] as Map?) ?? {};
        final name = (tags['name:ar'] ?? tags['name'] ?? category) as String;
        best = NearbyPlace(name, lat.toDouble(), lon.toDouble(), d,
            bearing(pos.latitude, pos.longitude, lat.toDouble(), lon.toDouble()));
      }
    }
    return best;
  }

  /// Street / district name for «أين أنا؟».
  Future<String?> describe(Position pos) async {
    final j = await _getJson(Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'format': 'jsonv2',
      'lat': '${pos.latitude}',
      'lon': '${pos.longitude}',
      'accept-language': 'ar',
      'zoom': '18',
    }));
    final a = (j['address'] as Map?) ?? {};
    final parts = <String>[
      if (a['road'] != null) '${a['road']}',
      if (a['suburb'] != null || a['neighbourhood'] != null) '${a['suburb'] ?? a['neighbourhood']}',
      if (a['city'] != null || a['town'] != null) '${a['city'] ?? a['town']}',
    ];
    return parts.isEmpty ? (j['display_name'] as String?) : parts.join('، ');
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    try {
      final res = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return {};
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } on SocketException {
      throw OfflineException();
    } on http.ClientException {
      throw OfflineException();
    } on TimeoutException {
      return {};
    }
  }

  static String mapsLink(double lat, double lon) =>
      'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';

  /// Degrees -> radians helper kept for completeness of geo math.
  static double rad(double d) => d * math.pi / 180;
}
