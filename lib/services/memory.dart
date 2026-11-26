import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Person {
  final String name;
  final String phone;
  final String role; // 'emergency' | 'friend'
  const Person(this.name, this.phone, {this.role = 'emergency'});

  Map<String, dynamic> toJson() => {'name': name, 'phone': phone, 'role': role};
  factory Person.fromJson(Map<String, dynamic> j) =>
      Person(j['name'] as String, j['phone'] as String, role: (j['role'] as String?) ?? 'emergency');
}

class Place {
  final String name;
  final double lat;
  final double lon;
  const Place(this.name, this.lat, this.lon);

  Map<String, dynamic> toJson() => {'name': name, 'lat': lat, 'lon': lon};
  factory Place.fromJson(Map<String, dynamic> j) =>
      Place(j['name'] as String, (j['lat'] as num).toDouble(), (j['lon'] as num).toDouble());
}

/// Everything Hadaq remembers about the user.
/// Stored only on the phone, encrypted (Android Keystore / iOS Keychain via
/// flutter_secure_storage). Never uploaded.
class MemoryData {
  double speechRate; // multiplier, 1.0 = normal
  double volume; // 0..1
  bool strongVibration;
  bool onboarded; // finished the first-launch voice setup
  bool? shareData; // consent to share data with the Hadaq team (null = not asked yet)
  String? name;
  List<Person> people;
  List<Place> places;

  MemoryData({
    this.speechRate = 1.0,
    this.volume = 1.0,
    this.strongVibration = false,
    this.onboarded = false,
    this.shareData,
    this.name,
    List<Person>? people,
    List<Place>? places,
  })  : people = people ?? [],
        places = places ?? [];

  Map<String, dynamic> toJson() => {
        'speechRate': speechRate,
        'volume': volume,
        'strongVibration': strongVibration,
        'onboarded': onboarded,
        'shareData': shareData,
        'name': name,
        'people': people.map((p) => p.toJson()).toList(),
        'places': places.map((p) => p.toJson()).toList(),
      };

  factory MemoryData.fromJson(Map<String, dynamic> j) => MemoryData(
        speechRate: (j['speechRate'] as num?)?.toDouble() ?? 1.0,
        volume: (j['volume'] as num?)?.toDouble() ?? 1.0,
        strongVibration: j['strongVibration'] as bool? ?? false,
        onboarded: j['onboarded'] as bool? ?? false,
        shareData: j['shareData'] as bool?,
        name: j['name'] as String?,
        people: ((j['people'] as List?) ?? [])
            .map((e) => Person.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        places: ((j['places'] as List?) ?? [])
            .map((e) => Place.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );

  MemoryData copy() => MemoryData.fromJson(jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);

  /// Number of remembered items (shown as «ذاكرة 12» in the status bar).
  int get itemCount {
    var n = people.length + places.length;
    if (name != null) n++;
    if (speechRate != 1.0) n++;
    if (volume != 1.0) n++;
    if (strongVibration) n++;
    return n;
  }

  List<Person> get emergencyContacts => people.where((p) => p.role == 'emergency').toList();
}

class MemoryStore {
  static const _key = 'hadaq_memory_v1';
  final FlutterSecureStorage _storage;
  MemoryData data = MemoryData();
  MemoryData? _undo; // snapshot before the last change («تراجع»)

  MemoryStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  Future<void> load() async {
    try {
      final s = await _storage.read(key: _key);
      if (s != null) data = MemoryData.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      data = MemoryData();
    }
  }

  /// Called after every change (used to re-sync the shared profile).
  void Function()? onChange;

  Future<void> _save() async {
    await _storage.write(key: _key, value: jsonEncode(data.toJson()));
    onChange?.call();
  }

  /// Applies [change] to the memory, keeping a snapshot for «تراجع».
  Future<void> update(void Function(MemoryData d) change) async {
    _undo = data.copy();
    change(data);
    await _save();
  }

  bool get canUndo => _undo != null;

  Future<bool> undo() async {
    if (_undo == null) return false;
    data = _undo!;
    _undo = null;
    await _save();
    return true;
  }

  Future<void> wipe() async {
    _undo = data.copy();
    data = MemoryData();
    await _storage.delete(key: _key);
  }
}
