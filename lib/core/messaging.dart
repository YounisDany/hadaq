import 'arabic.dart';

/// Helpers for «ارسل لأحمد واتساب إني في الطريق».
abstract class Messaging {
  /// Words that link the recipient to the message: «قل له»، «إن»…
  static final _connector = RegExp(
      r'^(?:و?(?:قل|قول|قولي|اقول|تقول|يقول|اكتب|اخبر|خبر|بلغ)(?: له| لها| لهم)?|ان|انه|انها|اني|بان|بانه|بانها|:)\s+');

  /// Splits what followed the verb into (recipient words, message) candidates:
  /// the first 1..3 words may be the name; the rest is the message.
  /// The caller picks the candidate whose name best matches the phonebook.
  static List<(String name, String message)> candidates(String rest) {
    final words = rest
        .replaceAll(RegExp(r'[«»"]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    // Drop «إلى» / «لـ» before the name.
    while (words.isNotEmpty && RegExp(r'^(الي|إلى|الى|ل|لـ|على|علي)$').hasMatch(words.first)) {
      words.removeAt(0);
    }
    final out = <(String, String)>[];
    for (var k = 1; k <= 3 && k <= words.length; k++) {
      final name = words.sublist(0, k).join(' ').replaceAll(RegExp(r'[،,:]$'), '');
      out.add((name, cleanMessage(words.sublist(k).join(' '))));
    }
    return out;
  }

  /// «قل له إني في الطريق» -> «إني في الطريق» (keeps the user's own words).
  static String cleanMessage(String m) {
    var s = m.trim().replaceFirst(RegExp(r'^[،,:]\s*'), '');
    for (var i = 0; i < 2; i++) {
      final n = normalizeAr(s);
      final c = _connector.firstMatch('$n ');
      if (c == null) break;
      // Remove the same number of words from the original text.
      final drop = c.group(0)!.trim().split(' ').length;
      final ws = s.split(RegExp(r'\s+'));
      // Keep «إني/إنه…» as part of the message: they carry meaning («إني وصلت»).
      if (RegExp(r'^(اني|انه|انها)$').hasMatch(normalizeAr(ws.first))) break;
      s = ws.skip(drop).join(' ');
    }
    return s.trim();
  }

  /// WhatsApp wants international digits without «+». Local Saudi numbers
  /// («05xxxxxxxx») get the 966 country code.
  static String whatsappNumber(String raw, {String defaultCountry = '966'}) {
    var d = toLatinDigits(raw).replaceAll(RegExp(r'[^\d+]'), '');
    if (d.startsWith('+')) return d.substring(1);
    if (d.startsWith('00')) return d.substring(2);
    if (d.startsWith('0')) return '$defaultCountry${d.substring(1)}';
    if (d.length == 9 && d.startsWith('5')) return '$defaultCountry$d';
    return d;
  }
}
