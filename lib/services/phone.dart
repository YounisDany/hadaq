import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/arabic.dart';

class ContactMatch {
  final String name;
  final String number;
  final int score;
  const ContactMatch(this.name, this.number, this.score);
}

/// Phonebook lookup + placing calls, for «اتصل بأحمد» and «أضف أمي جهة طوارئ».
/// Contacts are read on the phone only; nothing is uploaded.
class PhoneService {
  static const _ch = MethodChannel('hadaq/native');
  List<(String, String, String)>? _cache; // (display name, normalized name, number)
  DateTime _cachedAt = DateTime(2000);

  /// Family words people say vs. how they're often saved in the phonebook.
  static const _synonyms = <String, List<String>>{
    'امي': ['امي', 'ماما', 'الوالده', 'والدتي', 'ام'],
    'ماما': ['ماما', 'امي', 'الوالده'],
    'الوالده': ['الوالده', 'امي', 'ماما', 'والدتي'],
    'ابوي': ['ابوي', 'بابا', 'الوالد', 'ابي', 'والدي', 'ابو'],
    'ابي': ['ابي', 'ابوي', 'بابا', 'الوالد', 'والدي'],
    'بابا': ['بابا', 'ابوي', 'الوالد', 'ابي'],
    'الوالد': ['الوالد', 'ابوي', 'بابا', 'ابي', 'والدي'],
    'اخوي': ['اخوي', 'اخي'],
    'اختي': ['اختي', 'اخيتي'],
    'زوجتي': ['زوجتي', 'حرمي', 'ام العيال', 'حياتي'],
    'زوجي': ['زوجي', 'ابو العيال', 'حياتي'],
  };

  Future<bool> ensureContactsPermission() async => (await Permission.contacts.request()).isGranted;

  Future<List<(String, String, String)>> _contacts() async {
    if (_cache != null && DateTime.now().difference(_cachedAt).inMinutes < 2) return _cache!;
    if (!await ensureContactsPermission()) return const [];
    final all = await FlutterContacts.getAll(properties: {ContactProperty.name, ContactProperty.phone});
    _cache = [
      for (final c in all)
        for (final p in c.phones.take(1)) // first number per contact
          if ((c.displayName ?? '').trim().isNotEmpty && p.number.trim().isNotEmpty)
            (c.displayName!.trim(), normalizeAr(c.displayName!), p.number.replaceAll(RegExp(r'[^\d+]'), '')),
    ];
    _cachedAt = DateTime.now();
    return _cache!;
  }

  /// The spoken name cleaned up into the forms worth trying.
  Set<String> _queries(String spoken) {
    final q = normalizeAr(spoken)
        .replaceFirst(RegExp(r'^(?:رقم|علي|الي|ل) '), '')
        .replaceAll(RegExp(r'\s+(?:الحين|الان|لو سمحت|من فضلك|يا حدق)$'), '')
        .trim();
    if (q.isEmpty) return {};
    // «اتصل بأحمد» arrives as «باحمد»: try with and without the leading ب / ل.
    final queries = <String>{q, if (RegExp(r'^[بل]\S{2,}').hasMatch(q)) q.substring(1)};
    for (final x in [...queries]) {
      queries.addAll(_synonyms[x] ?? const []);
      if (x.startsWith('ال') && x.length > 4) queries.add(x.substring(2)); // «الوالد» / «والد»
    }
    return queries;
  }

  /// Best phonebook matches for a spoken name, highest score first.
  /// Names saved in English match too: «هادي» finds «Hadi», «محمد» finds «Mohammed».
  Future<List<ContactMatch>> find(String spoken) async {
    final queries = _queries(spoken);
    if (queries.isEmpty) return const [];
    final contacts = await _contacts();
    final out = <ContactMatch>[];
    for (final (name, norm, number) in contacts) {
      var best = 0;
      final words = norm.split(' ');
      for (final x in queries) {
        final s = norm == x
            ? 4
            : words.first == x || sameSound(words.first, x) && x.split(' ').length == 1
                ? 3
                : (norm.startsWith('$x ') || words.contains(x) || sameSound(norm, x))
                    ? 2
                    : (x.length >= 3 && norm.contains(x)) || words.any((w) => sameSound(w, x))
                        ? 1
                        : 0;
        if (s > best) best = s;
      }
      if (best > 0) out.add(ContactMatch(name, number, best));
    }
    out.sort((a, b) => b.score - a.score);
    return out;
  }

  /// Closest-sounding contacts when nothing matched («هادى» → «Hadi»، «احمد» → «أحمد علي»).
  Future<List<ContactMatch>> suggest(String spoken, {int max = 2}) async {
    final queries = _queries(spoken);
    if (queries.isEmpty) return const [];
    final contacts = await _contacts();
    final scored = <(ContactMatch, double)>[];
    for (final (name, norm, number) in contacts) {
      var best = 0.0;
      for (final x in queries) {
        for (final w in [norm, ...norm.split(' ')]) {
          final a = _skeleton(w), b = _skeleton(x);
          if (a.isEmpty || b.isEmpty) continue;
          final sim = 1 - _distance(a, b) / (a.length > b.length ? a.length : b.length);
          if (sim > best) best = sim;
        }
      }
      if (best >= 0.6) scored.add((ContactMatch(name, number, 0), best));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final s in scored.take(max)) s.$1];
  }

  /// Same name in different spellings or scripts? Compares consonant skeletons:
  /// «هادي» and «hadi» → «hd»; «محمد» and «mohammed» → «mhmd».
  static bool sameSound(String a, String b) {
    final x = _skeleton(a), y = _skeleton(b);
    if (x.length < 2 || y.length < 2) return false;
    if (x == y) return true;
    return x.length >= 4 && y.length >= 4 && _distance(x, y) <= 1;
  }

  static const _ar = {
    'ا': '', 'ب': 'b', 'ت': 't', 'ث': 't', 'ج': 'j', 'ح': 'h', 'خ': 'k', 'د': 'd', 'ذ': 'd', 'ر': 'r',
    'ز': 'z', 'س': 's', 'ش': 's', 'ص': 's', 'ض': 'd', 'ط': 't', 'ظ': 'z', 'ع': '', 'غ': 'g', 'ف': 'f',
    'ق': 'k', 'ك': 'k', 'ل': 'l', 'م': 'm', 'ن': 'n', 'ه': 'h', 'و': '', 'ي': '', 'ء': '',
  };

  /// Consonant skeleton in Latin letters, so Arabic and English spellings meet.
  static String _skeleton(String s) {
    final out = StringBuffer();
    for (final ch in normalizeAr(s).split('')) {
      if (_ar.containsKey(ch)) {
        out.write(_ar[ch]);
      } else if (RegExp('[a-z]').hasMatch(ch)) {
        out.write(const {'a': '', 'e': '', 'i': '', 'o': '', 'u': '', 'y': '', 'w': '', 'c': 'k', 'q': 'k', 'g': 'j', 'p': 'b', 'v': 'f', 'x': 'ks'}[ch] ?? ch);
      }
    }
    // «sh/th/kh/gh» collapse to one sound; doubled letters («mm») count once.
    return out.toString().replaceAll('sh', 's').replaceAll('th', 't').replaceAll('kh', 'k').replaceAllMapped(RegExp(r'(.)\1+'), (m) => m[1]!);
  }

  static int _distance(String a, String b) {
    final d = List.generate(a.length + 1, (i) => List.filled(b.length + 1, 0));
    for (var i = 0; i <= a.length; i++) {
      d[i][0] = i;
    }
    for (var j = 0; j <= b.length; j++) {
      d[0][j] = j;
    }
    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        final c = a[i - 1] == b[j - 1] ? 0 : 1;
        d[i][j] = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + c].reduce((x, y) => x < y ? x : y);
      }
    }
    return d[a.length][b.length];
  }

  /// Places the call directly (blind users can't hunt for the dial button);
  /// falls back to opening the dialer.
  Future<bool> call(String number) async {
    final n = number.replaceAll(RegExp(r'[^\d+]'), '');
    if (n.isEmpty) return false;
    try {
      if ((await Permission.phone.request()).isGranted) {
        final ok = await _ch.invokeMethod<bool>('call', {'number': n});
        if (ok == true) return true;
      }
    } catch (_) {}
    return launchUrl(Uri.parse('tel:$n'));
  }

  /// Spoken form of a number's last digits, e.g. «ينتهي بـ 4567».
  static String tail(String number) {
    final d = number.replaceAll(RegExp(r'\D'), '');
    return d.length <= 4 ? d : d.substring(d.length - 4);
  }
}
