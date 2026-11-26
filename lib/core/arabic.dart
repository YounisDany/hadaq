/// Arabic text helpers used by the intent classifier.
library;

final _diacritics = RegExp('[ً-ْٰـ]'); // tashkeel + tatweel
final _punct = RegExp(r'''[؟?!.,،؛:«»"'()\-]''');

/// Normalizes Arabic so keyword matching is robust to spelling variants:
/// removes tashkeel/tatweel, unifies alef/yaa/taa-marbuta, converts Arabic-Indic digits.
String normalizeAr(String input) {
  var s = input.trim().toLowerCase();
  s = s.replaceAll(_diacritics, '');
  s = s.replaceAll(_punct, ' ');
  s = s
      .replaceAll(RegExp('[أإآٱ]'), 'ا')
      .replaceAll('ى', 'ي')
      .replaceAll('ة', 'ه')
      .replaceAll('ؤ', 'و')
      .replaceAll('ئ', 'ي');
  s = toLatinDigits(s);
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String toLatinDigits(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  const fa = '۰۱۲۳۴۵۶۷۸۹';
  final b = StringBuffer();
  for (final ch in s.split('')) {
    final i = ar.indexOf(ch);
    final j = fa.indexOf(ch);
    b.write(i >= 0 ? '$i' : (j >= 0 ? '$j' : ch));
  }
  return b.toString();
}

bool hasAny(String norm, List<String> keys) => keys.any(norm.contains);

/// "240" -> "240 مترًا", "1400" -> "1.4 كم".
String formatDistance(double meters) {
  if (meters >= 1000) {
    final km = (meters / 1000);
    return '${km.toStringAsFixed(km >= 10 ? 0 : 1)} كم';
  }
  final m = (meters / 10).round() * 10;
  if (m <= 10) return 'أقل من 10 أمتار';
  return '$m مترًا';
}

/// Direction of [bearing] relative to where the user is facing ([heading], from the
/// compass): «أمامك»، «على يمينك»، «خلفك إلى اليسار»… Falls back to compass words.
String directionFrom(double bearing, double? heading) {
  if (heading == null) return bearingToArabic(bearing);
  final d = (bearing - heading + 540) % 360 - 180; // -180..180, + = right
  final a = d.abs();
  final side = d > 0 ? 'اليمين' : 'اليسار';
  if (a <= 22) return 'أمامك مباشرة';
  if (a <= 67) return 'أمامك إلى $side';
  if (a <= 112) return d > 0 ? 'على يمينك' : 'على يسارك';
  if (a <= 157) return 'خلفك إلى $side';
  return 'خلفك';
}

/// Rough walking time, e.g. «12 دقيقة مشيًا».
String walkingTime(double meters) {
  final m = (meters * 1.3 / 1.25 / 60).round(); // streets are ~30% longer than a straight line
  if (m < 1) return 'أقل من دقيقة مشيًا';
  if (m == 1) return 'دقيقة مشيًا';
  if (m == 2) return 'دقيقتان مشيًا';
  return '$m ${m <= 10 ? 'دقائق' : 'دقيقة'} مشيًا';
}

/// Compass bearing (0..360) to an Arabic direction word.
String bearingToArabic(double bearing) {
  const dirs = [
    'شمالًا',
    'شمال شرق',
    'شرقًا',
    'جنوب شرق',
    'جنوبًا',
    'جنوب غرب',
    'غربًا',
    'شمال غرب',
  ];
  final i = (((bearing % 360) + 22.5) ~/ 45) % 8;
  return dirs[i];
}
