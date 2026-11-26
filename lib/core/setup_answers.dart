import 'arabic.dart';

/// Reads the user's spoken answers during the first-launch setup.
abstract class SetupAnswers {
  static bool isSkip(String raw) => RegExp(
          r'(^| )(تخط|تخطي|تخطا|تجاوز|بعدين|لاحقا|ليس الان|مو الحين|مب الحين|ما ابي|مابي|لا اريد|ما ابغي|مابغي|التالي|خلاص)( |$)')
      .hasMatch(normalizeAr(raw));

  static bool isYes(String raw) =>
      RegExp(r'^(نعم|ايوه|ايوا|اي|ايه|اكيد|صح|صحيح|تمام|طيب|موافق|بلى|اجل|يب|اوكي|ok|yes)( |$)').hasMatch(normalizeAr(raw));

  static bool isNo(String raw) =>
      RegExp(r'^(لا|لاء|غلط|خطا|مو|مب|ليس|كلا|no)( |$)').hasMatch(normalizeAr(raw));

  /// «اسمي أحمد» / «ناديني أبو خالد» / «أحمد» -> the name as the user said it.
  static String? name(String raw) {
    var words = raw
        .replaceAll(RegExp(r'''[؟?!.,،؛:«»"']'''), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    const lead = {'اسمي', 'ناديني', 'نادني', 'سمني', 'ادعني', 'انا', 'نادي', 'يا', 'اسم', 'هو', 'بس', 'ناديني:'};
    while (words.isNotEmpty && lead.contains(normalizeAr(words.first))) {
      words = words.sublist(1);
    }
    const tail = {'شكرا', 'لو', 'سمحت', 'من', 'فضلك', 'يا', 'حدق'};
    while (words.isNotEmpty && tail.contains(normalizeAr(words.last))) {
      words = words.sublist(0, words.length - 1);
    }
    // «يونس عمري 23 أعيش في جدة» -> «يونس»: stop where the sentence moves on.
    const stops = {'عمري', 'عمر', 'من', 'اعيش', 'ساكن', 'اسكن', 'وعمري', 'واعيش', 'وانا', 'انا', 'في', 'و'};
    final cut = words.indexWhere((w) => stops.contains(normalizeAr(w)) || RegExp(r'\d').hasMatch(w));
    if (cut > 0) words = words.sublist(0, cut);
    if (words.length > 3) words = words.sublist(0, 3);
    if (words.isEmpty) return null;
    return words.join(' ');
  }

  /// 'slower' | 'faster' | 'ok' | null
  static String? speed(String raw) {
    final t = normalizeAr(raw);
    if (hasAny(t, ['ابطا', 'ابطي', 'بطيء', 'بطء', 'على مهل', 'شوي شوي', 'اهدا'])) return 'slower';
    if (hasAny(t, ['اسرع', 'سريع', 'بسرعه'])) return 'faster';
    if (hasAny(t, ['مناسب', 'زين', 'تمام', 'ممتاز', 'كويس', 'حلو', 'جيد', 'اوكي', 'ok', 'ممتازه', 'مضبوط']) || isYes(raw)) {
      return 'ok';
    }
    return null;
  }

  /// A spoken phone number («0 5 5 1 2 3…» or «0551234567»), digits only, or null.
  static String? number(String raw) {
    final d = toLatinDigits(raw).replaceAll(RegExp(r'[^\d+]'), '');
    return d.replaceAll('+', '').length >= 7 ? d : null;
  }

  /// «اسمه أحمد» / «اتصل بأمي» / «أمي» -> the contact name to look up.
  static String contactName(String raw) {
    var s = raw.replaceAll(RegExp(r'''[؟?!.,،؛:«»"']'''), ' ').trim();
    s = s.replaceFirst(RegExp(r'^(اسمها|اسمه|هو|هي|اتصل ب|اتصل على|اتصل علي|كلم|رقم)\s*'), '');
    return s.trim();
  }
}
