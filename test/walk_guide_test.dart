import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hadaq/services/backend.dart';
import 'package:hadaq/services/location.dart';
import 'package:hadaq/services/navigator.dart';

/// Simulates walking a real route (saved from the server) at ~1.3 m/s with a GPS
/// fix every 4 m, and checks what the guide says.
Position fix((double, double) p, {double heading = 0, double speed = 1.3}) => Position(
      latitude: p.$1,
      longitude: p.$2,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: heading,
      headingAccuracy: 0,
      speed: speed,
      speedAccuracy: 0,
    );

List<(double, double)> densify(List<(double, double)> g, double stepM) {
  final out = <(double, double)>[];
  for (var i = 0; i < g.length - 1; i++) {
    final a = g[i], b = g[i + 1];
    final d = LocationService.distance(a.$1, a.$2, b.$1, b.$2);
    final n = math.max(1, (d / stepM).ceil());
    for (var k = 0; k < n; k++) {
      out.add((a.$1 + (b.$1 - a.$1) * k / n, a.$2 + (b.$2 - a.$2) * k / n));
    }
  }
  out.add(g.last);
  return out;
}

void main() {
  final route = WalkingRoute.fromJson(
      jsonDecode(File('test/fixtures/route_jeddah.json').readAsStringSync()) as Map<String, dynamic>);

  test('walks the whole route: announces every turn before and at it, then arrival', () async {
    final said = <String>[];
    var arrived = false;
    final g = WalkGuide(
      targetName: 'شاورما صج',
      target: route.geometry.last,
      say: (t) async => said.add(t),
      replan: (_) async => null,
      onArrived: () => arrived = true,
    );
    final path = densify(route.geometry, 4);
    await g.start(route, fix(path.first));
    for (var i = 1; i < path.length; i++) {
      final h = LocationService.bearing(path[i - 1].$1, path[i - 1].$2, path[i].$1, path[i].$2);
      await g.update(fix(path[i], heading: h));
      if (arrived) break;
    }
    // ignore: avoid_print
    print(said.join('\n'));

    expect(arrived, isTrue);
    expect(said.first, startsWith('إلى شاورما صج'));
    expect(said.last, contains('وصلت'));
    // Every real turn is announced "now" at the corner.
    final turns = route.steps.where((s) => s.type != 'depart' && s.type != 'arrive').length;
    expect(said.where((s) => s.startsWith('الآن')).length, greaterThanOrEqualTo(turns - 2));
    // No wrong-way or off-route warnings when following the route exactly.
    expect(said.any((s) => s.contains('المعاكس') || s.contains('ابتعدت')), isFalse);
  });

  test('walking away from the route triggers a re-plan', () async {
    final said = <String>[];
    var replans = 0;
    final g = WalkGuide(
      targetName: 'X',
      target: route.geometry.last,
      say: (t) async => said.add(t),
      replan: (_) async {
        replans++;
        return route;
      },
      onArrived: () {},
    );
    final start = route.geometry.first;
    await g.start(route, fix(start));
    // Walk 80 m due south-west, away from the route.
    for (var m = 10; m <= 80; m += 10) {
      await g.update(fix((start.$1 - m / 111000, start.$2 - m / 111000)));
    }
    expect(replans, greaterThanOrEqualTo(1));
    expect(said.any((s) => s.contains('أعيد حساب المسار')), isTrue);
  });

  test('«كم باقي» reports remaining distance and next turn', () async {
    final g = WalkGuide(
      targetName: 'شاورما صج',
      target: route.geometry.last,
      say: (_) async {},
      replan: (_) async => null,
      onArrived: () {},
    );
    await g.start(route, fix(route.geometry.first));
    await g.update(fix(route.geometry[1]));
    final s = g.status();
    expect(s, contains('باقٍ'));
    expect(s, contains('شاورما صج'));
  });
}
