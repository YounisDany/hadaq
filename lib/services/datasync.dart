import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'backend.dart';
import 'memory.dart';

/// Shares the user's data with the Hadaq team — only after they said yes in the
/// app («هل توافق…؟»). Sends: profile (name, emergency contacts, saved places),
/// conversation turns as text, and location while the app is in use.
/// Photos and voice recordings are never sent. «احذف بياناتي» withdraws consent and
/// deletes the stored data on the server.
class DataSync {
  final BackendService backend;
  final MemoryStore memory;
  DataSync(this.backend, this.memory);

  final List<Map<String, dynamic>> _events = [];
  Map<String, dynamic>? _open; // the latest turn, still collecting replies
  Map<String, dynamic>? _location;
  Timer? _timer;
  bool _profileDirty = true;

  bool get enabled => backend.enabled && memory.data.shareData == true;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => flush());
  }

  void stop() => _timer?.cancel();

  Future<bool> setConsent(bool yes) async {
    await memory.update((d) => d.shareData = yes);
    _events.clear();
    _open = null;
    _profileDirty = true;
    if (!backend.enabled) return true;
    try {
      final r = await http
          .post(Uri.parse('${BackendService.baseUrl}/api/app/consent'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'device_id': await backend.id(), 'consent': yes}))
          .timeout(const Duration(seconds: 15));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// A new user utterance; replies spoken right after it are attached to it.
  void logTurn(String userText, String intent) {
    if (!enabled) return;
    _open = {'at': DateTime.now().toUtc().toIso8601String(), 'user': userText, 'intent': intent, 'reply': ''};
    _events.add(_open!);
  }

  void logReply(String reply) {
    if (!enabled || reply.trim().isEmpty) return;
    final o = _open;
    if (o == null || DateTime.now().toUtc().difference(DateTime.parse(o['at'] as String)).inSeconds > 90) {
      // Spoken without a request (guidance, greetings…): log it on its own.
      _events.add({'at': DateTime.now().toUtc().toIso8601String(), 'user': '', 'intent': 'system', 'reply': reply});
      return;
    }
    o['reply'] = (o['reply'] as String).isEmpty ? reply : '${o['reply']} / $reply';
  }

  void location(double lat, double lon, double accuracy) {
    if (!enabled) return;
    _location = {'lat': lat, 'lon': lon, 'accuracy': accuracy, 'at': DateTime.now().toUtc().toIso8601String()};
  }

  void profileChanged() => _profileDirty = true;

  Future<void> flush() async {
    if (!enabled) return;
    if (_events.isEmpty && _location == null && !_profileDirty) return;
    // Keep the open turn a little longer so its replies get attached.
    final ready = _events.where((e) => !identical(e, _open) ||
        DateTime.now().toUtc().difference(DateTime.parse(e['at'] as String)).inSeconds > 30).toList();
    final d = memory.data;
    final body = {
      'device_id': await backend.id(),
      'events': ready,
      if (_location != null) 'location': _location,
      if (_profileDirty)
        'profile': {
          'name': d.name,
          'speech_rate': d.speechRate,
          'strong_vibration': d.strongVibration,
          'emergency_contacts': [for (final p in d.people) {'name': p.name, 'phone': p.phone}],
          'places': [for (final p in d.places) {'name': p.name, 'lat': p.lat, 'lon': p.lon}],
        },
    };
    try {
      final r = await http
          .post(Uri.parse('${BackendService.baseUrl}/api/app/sync'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        _events.removeWhere((e) => ready.any((x) => identical(x, e)));
        if (identical(_open, null) || !_events.contains(_open)) _open = null;
        _location = null;
        _profileDirty = false;
      }
    } catch (_) {
      // Offline: keep the queue (capped) and retry on the next tick.
      if (_events.length > 200) _events.removeRange(0, _events.length - 200);
    }
  }
}
