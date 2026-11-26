import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// What the admin dashboard controls (see server/server.js → publicConfig).
class AppConfig {
  final bool forceUpdate;
  final bool updateAvailable;
  final String latestVersion;
  final String updateUrl;
  final String updateMessage;
  final bool maintenance;
  final String maintenanceMessage;
  final String announcement;
  final bool blocked;
  final bool assistant, vision, navigation, sos;
  final bool assistantAvailable;
  final String emergencyNumber;
  final String sttEngine; // 'openai' | 'device'
  final String ttsEngine; // 'openai' | 'device'

  const AppConfig({
    this.forceUpdate = false,
    this.updateAvailable = false,
    this.latestVersion = '',
    this.updateUrl = '',
    this.updateMessage = '',
    this.maintenance = false,
    this.maintenanceMessage = '',
    this.announcement = '',
    this.blocked = false,
    this.assistant = true,
    this.vision = true,
    this.navigation = true,
    this.sos = true,
    this.assistantAvailable = true,
    this.emergencyNumber = '911',
    this.sttEngine = 'device',
    this.ttsEngine = 'device',
  });

  factory AppConfig.fromJson(Map<String, dynamic> j) {
    final f = (j['features'] as Map?) ?? {};
    return AppConfig(
      forceUpdate: j['force_update'] == true,
      updateAvailable: j['update_available'] == true,
      latestVersion: '${j['latest_version'] ?? ''}',
      updateUrl: '${j['update_url'] ?? ''}',
      updateMessage: '${j['update_message'] ?? ''}',
      maintenance: j['maintenance'] == true,
      maintenanceMessage: '${j['maintenance_message'] ?? ''}',
      announcement: '${j['announcement'] ?? ''}',
      blocked: j['blocked'] == true,
      assistant: f['assistant'] != false,
      vision: f['vision'] != false,
      navigation: f['navigation'] != false,
      sos: f['sos'] != false,
      assistantAvailable: j['assistant_available'] != false,
      emergencyNumber: '${j['emergency_number'] ?? '911'}',
      sttEngine: '${j['stt_engine'] ?? 'device'}',
      ttsEngine: '${j['tts_engine'] ?? 'device'}',
    );
  }
}

/// Talks to the Hadaq server. Base URL comes from
/// `--dart-define=HADAQ_API=https://hadaq.example.com`. Without it the app runs
/// standalone (defaults, direct Gemini key if one was compiled in).
class BackendService {
  static const baseUrl = String.fromEnvironment('HADAQ_API');
  static const _idKey = 'hadaq_device_id';
  static const _annKey = 'hadaq_last_announcement';

  final _storage = const FlutterSecureStorage();
  String? deviceId;
  AppConfig config = const AppConfig();
  bool get enabled => baseUrl.isNotEmpty;

  Future<String> _deviceId() async {
    if (deviceId != null) return deviceId!;
    var id = await _storage.read(key: _idKey);
    if (id == null) {
      final r = Random.secure();
      id = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await _storage.write(key: _idKey, value: id);
    }
    return deviceId = id;
  }

  /// This install's anonymous device id.
  Future<String> id() => _deviceId();

  /// Registers this launch and fetches the config. Never throws.
  Future<AppConfig> hello() async {
    if (!enabled) return config;
    try {
      final info = await PackageInfo.fromPlatform();
      final (platform, model, os) = await _device();
      final res = await http
          .post(Uri.parse('$baseUrl/api/app/hello'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'device_id': await _deviceId(),
                'platform': platform,
                'app_version': info.version,
                'build': int.tryParse(info.buildNumber) ?? 0,
                'device_model': model,
                'os_version': os,
                'locale': 'ar',
              }))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        config = AppConfig.fromJson(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
      }
    } catch (_) {
      // Offline: keep defaults so memory, SOS and local features still work.
    }
    return config;
  }

  Future<(String, String, String)> _device() async {
    try {
      final d = DeviceInfoPlugin();
      if (kIsWeb) return ('web', 'Browser', '');
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final a = await d.androidInfo;
          return ('android', '${a.manufacturer} ${a.model}', 'Android ${a.version.release}');
        case TargetPlatform.iOS:
          final i = await d.iosInfo;
          return ('ios', i.utsname.machine, 'iOS ${i.systemVersion}');
        default:
          return (defaultTargetPlatform.name, '', '');
      }
    } catch (_) {
      return ('unknown', '', '');
    }
  }

  /// Returns the announcement only if it hasn't been spoken before.
  Future<String?> newAnnouncement() async {
    final a = config.announcement.trim();
    if (a.isEmpty) return null;
    final last = await _storage.read(key: _annKey);
    if (last == a) return null;
    await _storage.write(key: _annKey, value: a);
    return a;
  }

  /// AI proxy call. Returns the model's raw text, or throws [BackendError].
  Future<String> ask({
    required String question,
    String? imageB64,
    String? userContext,
    List<(String, String)> history = const [],
    bool actions = false,
  }) async {
    final res = await http
        .post(Uri.parse('$baseUrl/api/ai/ask'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'device_id': await _deviceId(),
              'question': question,
              if (imageB64 != null) 'image_b64': imageB64,
              if (userContext != null && userContext.isNotEmpty) 'user_context': userContext,
              'history': [for (final (u, a) in history) [u, a]],
              if (actions) 'actions': true,
            }))
        .timeout(const Duration(seconds: 30));
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode == 200) return '${j['text'] ?? ''}';
    throw BackendError('${j['error'] ?? res.statusCode}');
  }
}

/// A place returned by the server's search («أقرب محل شاورما»).
class PlaceResult {
  final String name;
  final double lat, lon;
  final double distance, bearing;
  final String address;
  final bool? openNow;
  const PlaceResult(this.name, this.lat, this.lon, this.distance, this.bearing, this.address, this.openNow);

  factory PlaceResult.fromJson(Map<String, dynamic> j) => PlaceResult(
        '${j['name']}',
        (j['lat'] as num).toDouble(),
        (j['lon'] as num).toDouble(),
        (j['distance'] as num?)?.toDouble() ?? 0,
        (j['bearing'] as num?)?.toDouble() ?? 0,
        '${j['address'] ?? ''}',
        j['open_now'] as bool?,
      );
}

/// One manoeuvre of a walking route, with its Arabic instruction.
class RouteStep {
  final double lat, lon;
  final double distance; // metres of this step (until the next manoeuvre)
  final String text;
  final String type;
  const RouteStep(this.lat, this.lon, this.distance, this.text, this.type);
}

class WalkingRoute {
  final double distance, duration;
  final List<RouteStep> steps;
  final List<(double, double)> geometry;
  const WalkingRoute(this.distance, this.duration, this.steps, this.geometry);

  factory WalkingRoute.fromJson(Map<String, dynamic> j) => WalkingRoute(
        (j['distance'] as num).toDouble(),
        (j['duration'] as num).toDouble(),
        [
          for (final s in (j['steps'] as List).cast<Map>())
            RouteStep((s['lat'] as num).toDouble(), (s['lon'] as num).toDouble(),
                (s['distance'] as num?)?.toDouble() ?? 0, '${s['text'] ?? ''}', '${s['type'] ?? ''}'),
        ],
        [
          for (final p in (j['geometry'] as List).cast<List>())
            ((p[0] as num).toDouble(), (p[1] as num).toDouble()),
        ],
      );
}

extension BackendMaps on BackendService {
  /// Server transcription (OpenAI) of a recorded utterance. [hint] adds names
  /// (contacts, places) the transcriber should expect.
  Future<String> transcribe(Uint8List audio, {String? hint}) async {
    final j = await _post('/api/stt', {'audio_b64': base64Encode(audio), if (hint != null) 'hint': hint});
    return '${j['text'] ?? ''}'.trim();
  }

  Future<List<PlaceResult>> searchPlaces(String query, double lat, double lon) async {
    final j = await _post('/api/places/search', {'query': query, 'lat': lat, 'lon': lon});
    return [for (final p in (j['places'] as List? ?? []).cast<Map>()) PlaceResult.fromJson(Map<String, dynamic>.from(p))];
  }

  Future<WalkingRoute> route((double, double) from, (double, double) to) async {
    final j = await _post('/api/route', {
      'from': [from.$1, from.$2],
      'to': [to.$1, to.$2],
    });
    return WalkingRoute.fromJson(j);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final res = await http
        .post(Uri.parse('${BackendService.baseUrl}$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'device_id': await _deviceId(), ...body}))
        .timeout(const Duration(seconds: 25));
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode != 200) throw BackendError('${j['error'] ?? res.statusCode}');
    return j;
  }
}

class BackendError implements Exception {
  final String code;
  BackendError(this.code);

  /// Spoken explanation for each server error.
  String get message => switch (code) {
        'blocked' => 'تم إيقاف المساعد الذكي على هذا الجهاز. الطوارئ والذاكرة تعمل كالمعتاد.',
        'daily_limit' => 'وصلت إلى الحد اليومي لأسئلة المساعد. حاول غدًا.',
        'rate' => 'أسئلة كثيرة في وقت قصير. انتظر لحظة ثم حاول.',
        'feature_off' => 'هذه الميزة متوقفة مؤقتًا.',
        'no_key' => 'المساعد الذكي غير مُفعّل بعد على الخادم.',
        _ => 'تعذّر الوصول إلى المساعد الآن. حاول بعد قليل.',
      };
}
