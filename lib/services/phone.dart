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

  /// Best phonebook matches for a spoken name, highest score first.
  Future<List<ContactMatch>> find(String spoken) async {
    var q = normalizeAr(spoken).replaceFirst(RegExp(r'^(?:رقم|علي|الي|ل) '), '').trim();
    if (q.isEmpty) return const [];
    // «اتصل بأحمد» arrives as «باحمد»: try with and without the leading ب / ل.
    final queries = <String>{q, if (RegExp(r'^[بل]\S{2,}').hasMatch(q)) q.substring(1)};
    for (final x in [...queries]) {
      queries.addAll(_synonyms[x] ?? const []);
    }
    final contacts = await _contacts();
    final out = <ContactMatch>[];
    for (final (name, norm, number) in contacts) {
      var best = 0;
      for (final x in queries) {
        final words = norm.split(' ');
        final s = norm == x
            ? 4
            : words.first == x
                ? 3
                : (norm.startsWith('$x ') || words.contains(x))
                    ? 2
                    : (x.length >= 3 && norm.contains(x))
                        ? 1
                        : 0;
        if (s > best) best = s;
      }
      if (best > 0) out.add(ContactMatch(name, number, best));
    }
    out.sort((a, b) => b.score - a.score);
    return out;
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
