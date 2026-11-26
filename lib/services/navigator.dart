import 'dart:async';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import '../core/arabic.dart';
import 'backend.dart';
import 'location.dart';

/// Turn-by-turn walking guidance that "stays with you":
/// - announces each turn before you reach it («بعد 30 مترًا انعطف يمينًا…») and again at the corner,
/// - notices when you walk the wrong way or leave the route, and re-plans,
/// - reassures you periodically with the remaining distance, and tells you when you arrive.
class WalkGuide {
  final String targetName;
  final (double, double) target;
  final Future<void> Function(String text) say;
  final Future<WalkingRoute?> Function((double, double) from) replan;
  final void Function() onArrived;

  WalkGuide({
    required this.targetName,
    required this.target,
    required this.say,
    required this.replan,
    required this.onArrived,
  });

  WalkingRoute? _route;
  List<double> _cum = []; // cumulative distance along geometry
  int _next = 1; // index of the upcoming step
  final Set<int> _warned = {};
  int _offCount = 0;
  DateTime _lastSpoke = DateTime.now();
  DateTime _lastReplan = DateTime(2000);
  DateTime _lastWrongWay = DateTime(2000);
  bool _busy = false;
  bool active = true;
  double remaining = 0;
  Position? last;

  static const _turnNow = 14.0; // metres: "now" radius at a corner
  static const _turnSoon = 45.0; // metres: pre-announce radius
  static const _arrive = 15.0;
  static const _offRoute = 32.0;

  /// Sets the route and speaks the overview + first instruction.
  /// [heading] is the phone's compass heading; with it the first direction is
  /// said relative to the user («الطريق يبدأ على يمينك»), else as a compass word.
  Future<void> start(WalkingRoute route, Position here, {double? heading}) async {
    _setRoute(route);
    last = here;
    final mins = math.max(1, (route.duration / 60).round());
    final first = route.steps.isNotEmpty ? route.steps.first.text : 'ابدأ السير';
    final b = _routeBearingAt(0);
    final dir = heading != null ? 'الطريق يبدأ ${directionFrom(b, heading)}' : 'متجهًا ${bearingToArabic(b)}';
    final nextTurn = route.steps.length > 2
        ? ' بعد ${formatDistance(route.steps.first.distance)}: ${route.steps[1].text}.'
        : '';
    await _say('إلى $targetName: ${formatDistance(route.distance)}، $mins ${mins <= 10 ? 'دقائق' : 'دقيقة'}. '
        '$first، $dir.$nextTurn');
  }

  void _setRoute(WalkingRoute r) {
    _route = r;
    _next = r.steps.length > 1 ? 1 : 0;
    _warned.clear();
    _offCount = 0;
    _cum = [0];
    for (var i = 1; i < r.geometry.length; i++) {
      _cum.add(_cum.last + _d(r.geometry[i - 1], r.geometry[i]));
    }
    remaining = r.distance;
  }

  Future<void> _say(String text) async {
    _lastSpoke = DateTime.now();
    await say(text);
  }

  /// Feed every GPS fix here.
  Future<void> update(Position p) async {
    final r = _route;
    if (!active || r == null || _busy) return;
    _busy = true;
    try {
      last = p;
      final here = (p.latitude, p.longitude);

      // Arrived?
      if (_d(here, target) < _arrive || (r.geometry.isNotEmpty && _d(here, r.geometry.last) < _arrive)) {
        active = false;
        await _say('وصلت تقريبًا إلى $targetName. ستكون الوجهة قريبة منك جدًا، تحسّس طريقك بحذر.');
        onArrived();
        return;
      }

      // Where are we on the route?
      final (segIdx, offDist, along) = _project(here);
      remaining = math.max(0, r.distance - along);

      // Off the route -> re-plan (needs 2 bad fixes in a row; ignore very inaccurate fixes).
      if (offDist > _offRoute && p.accuracy < 30) {
        _offCount++;
        if (_offCount >= 2 && DateTime.now().difference(_lastReplan).inSeconds > 25) {
          _lastReplan = DateTime.now();
          await _say('ابتعدت عن الطريق. أعيد حساب المسار.');
          final nr = await replan(here);
          if (nr != null) {
            _setRoute(nr);
            final s = nr.steps.length > 1 ? nr.steps[1] : null;
            await _say('${nr.steps.first.text}، متجهًا ${bearingToArabic(_routeBearingAt(0))}.'
                '${s != null ? ' بعد ${formatDistance(nr.steps.first.distance)}: ${s.text}.' : ''}');
          }
          return;
        }
      } else {
        _offCount = 0;
      }

      // Skip steps we've already passed (e.g. a missed corner point).
      while (_next < r.steps.length - 1 && _d(here, _pt(r.steps[_next + 1])) < _d(here, _pt(r.steps[_next])) &&
          _d(here, _pt(r.steps[_next])) > _turnNow) {
        _next++;
      }

      if (_next < r.steps.length) {
        final step = r.steps[_next];
        final dNext = _d(here, _pt(step));
        if (step.type == 'arrive') {
          if (dNext < _turnSoon && !_warned.contains(_next)) {
            _warned.add(_next);
            await _say('الوجهة بعد ${formatDistance(dNext)} تقريبًا.');
          }
        } else if (dNext <= _turnNow) {
          final after = _next + 1 < r.steps.length ? r.steps[_next + 1] : null;
          await _say('الآن ${step.text}.'
              '${after != null && after.type != 'arrive' ? ' ثم بعد ${formatDistance(step.distance)}: ${after.text}.' : ''}');
          _next++;
          return;
        } else if (dNext <= _turnSoon && !_warned.contains(_next)) {
          _warned.add(_next);
          await _say('بعد ${formatDistance(dNext)}، ${step.text}.');
          return;
        }
      }

      // Walking the wrong way? (GPS course is only meaningful while moving.)
      if (p.speed > 0.7 && p.heading > 0 && DateTime.now().difference(_lastWrongWay).inSeconds > 20) {
        final want = _routeBearingAt(segIdx);
        final diff = (want - p.heading + 540) % 360 - 180; // + = turn right
        if (diff.abs() > 120) {
          _lastWrongWay = DateTime.now();
          await _say('أنت تمشي في الاتجاه المعاكس. استدر للخلف.');
          return;
        } else if (diff.abs() > 50) {
          _lastWrongWay = DateTime.now();
          await _say('انحرف قليلًا إلى ${diff > 0 ? 'اليمين' : 'اليسار'}.');
          return;
        }
      }

      // Reassurance every ~50 s of silence.
      if (DateTime.now().difference(_lastSpoke).inSeconds > 50) {
        final step = _next < r.steps.length ? r.steps[_next] : null;
        final dNext = step != null ? _d(here, _pt(step)) : remaining;
        await _say(step != null && step.type != 'arrive'
            ? 'استمر للأمام. المنعطف القادم بعد ${formatDistance(dNext)}. باقٍ ${formatDistance(remaining)}.'
            : 'استمر للأمام. باقٍ ${formatDistance(remaining)}.');
      }
    } finally {
      _busy = false;
    }
  }

  /// Spoken status for «كم باقي؟».
  String status() {
    final r = _route;
    if (r == null) return 'لم يبدأ الإرشاد بعد.';
    final mins = math.max(1, (remaining / 1.3 / 60).round());
    final step = _next < r.steps.length ? r.steps[_next] : null;
    final here = last != null ? (last!.latitude, last!.longitude) : null;
    final turn = step != null && step.type != 'arrive' && here != null
        ? ' المنعطف القادم بعد ${formatDistance(_d(here, _pt(step)))}: ${step.text}.'
        : '';
    return 'باقٍ ${formatDistance(remaining)} إلى $targetName، حوالي $mins ${mins <= 10 ? 'دقائق' : 'دقيقة'}.$turn';
  }

  // ---------------------------------------------------------------- geometry
  (double, double) _pt(RouteStep s) => (s.lat, s.lon);

  double _d((double, double) a, (double, double) b) => LocationService.distance(a.$1, a.$2, b.$1, b.$2);

  /// Bearing of the route a few metres ahead of geometry index [i].
  double _routeBearingAt(int i) {
    final g = _route?.geometry ?? const [];
    if (g.length < 2) return 0;
    i = i.clamp(0, g.length - 2);
    var j = i + 1;
    while (j < g.length - 1 && _d(g[i], g[j]) < 15) {
      j++;
    }
    return LocationService.bearing(g[i].$1, g[i].$2, g[j].$1, g[j].$2);
  }

  /// Nearest route segment: (segment index, distance from route, distance travelled along it).
  (int, double, double) _project((double, double) p) {
    final g = _route!.geometry;
    if (g.length < 2) return (0, _d(p, g.isEmpty ? target : g.first), 0);
    final cosLat = math.cos(p.$1 * math.pi / 180);
    (double, double) xy((double, double) q) => ((q.$2 - p.$2) * 111320 * cosLat, (q.$1 - p.$1) * 110540);
    var best = (0, double.infinity, 0.0);
    for (var i = 0; i < g.length - 1; i++) {
      final a = xy(g[i]), b = xy(g[i + 1]);
      final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
      final len2 = dx * dx + dy * dy;
      final t = len2 == 0 ? 0.0 : ((-a.$1) * dx + (-a.$2) * dy) / len2;
      final tc = t.clamp(0.0, 1.0);
      final px = a.$1 + tc * dx, py = a.$2 + tc * dy;
      final dist = math.sqrt(px * px + py * py);
      if (dist < best.$2) best = (i, dist, _cum[i] + tc * math.sqrt(len2));
    }
    return best;
  }
}
