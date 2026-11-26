import 'arabic.dart';

class AppEntry {
  final String label;
  final String package;
  const AppEntry(this.label, this.package);
}

/// Finds the app the user named («افتح يوتيوب»، «ادخل توكلنا») among the phone's apps.
/// Labels may be Arabic or English, so common names map to package hints too.
abstract class AppMatcher {
  /// Spoken (normalized) name -> package-name fragments.
  static const aliases = <String, List<String>>{
    'يوتيوب': ['com.google.android.youtube'],
    'واتساب': ['com.whatsapp'],
    'واتس': ['com.whatsapp'],
    'واتساب بزنس': ['com.whatsapp.w4b'],
    'واتس بزنس': ['com.whatsapp.w4b'],
    'سناب': ['com.snapchat.android'],
    'سناب شات': ['com.snapchat.android'],
    'انستقرام': ['com.instagram.android'],
    'انستا': ['com.instagram.android'],
    'تيك توك': ['com.zhiliaoapp.musically', 'com.ss.android.ugc'],
    'تويتر': ['com.twitter.android'],
    'اكس': ['com.twitter.android'],
    'تيليجرام': ['org.telegram'],
    'تلقرام': ['org.telegram'],
    'تلجرام': ['org.telegram'],
    'فيسبوك': ['com.facebook.katana'],
    'ماسنجر': ['com.facebook.orca'],
    'خرائط': ['com.google.android.apps.maps'],
    'خرائط قوقل': ['com.google.android.apps.maps'],
    'قوقل ماب': ['com.google.android.apps.maps'],
    'جوجل ماب': ['com.google.android.apps.maps'],
    'قوقل': ['com.google.android.googlequicksearchbox'],
    'جوجل': ['com.google.android.googlequicksearchbox'],
    'كروم': ['com.android.chrome'],
    'المتصفح': ['com.android.chrome', 'com.sec.android.app.sbrowser'],
    'جيميل': ['com.google.android.gm'],
    'الايميل': ['com.google.android.gm'],
    'البريد': ['com.google.android.gm'],
    'المتجر': ['com.android.vending'],
    'بلاي ستور': ['com.android.vending'],
    'سوق بلاي': ['com.android.vending'],
    'الكاميرا': ['camera'],
    'الصور': ['com.google.android.apps.photos', 'gallery'],
    'المعرض': ['gallery'],
    'الاستديو': ['gallery'],
    'الرسائل': ['messaging', 'mms'],
    'الهاتف': ['dialer', 'contacts'],
    'الاتصال': ['dialer'],
    'جهات الاتصال': ['contacts'],
    'الاعدادات': ['com.android.settings'],
    'الساعه': ['clock', 'deskclock'],
    'المنبه': ['clock', 'deskclock'],
    'الحاسبه': ['calculator'],
    'التقويم': ['calendar'],
    'المسجل': ['voicenote', 'recorder', 'soundrecorder'],
    'سبوتيفاي': ['com.spotify.music'],
    'نتفليكس': ['com.netflix'],
    'شاهد': ['net.mbc.shahid'],
    'توكلنا': ['sa.gov.nic.tawakkalna'],
    'ابشر': ['sa.gov.moi', 'absher'],
    'صحتي': ['com.lean.sehhaty', 'sehhaty'],
    'نفاذ': ['nafath'],
    'الراجحي': ['alrajhi'],
    'الاهلي': ['com.alahli', 'snb'],
    'stc pay': ['stcpay'],
    'اس تي سي باي': ['stcpay'],
    'هنقرستيشن': ['hungerstation'],
    'جاهز': ['jahez'],
    'مرسول': ['marsool'],
    'كيتا': ['keeta', 'sankuai'],
    'طلبات': ['talabat'],
    'كريم': ['com.careem'],
    'اوبر': ['com.ubercab'],
    'نون': ['com.noon'],
    'امازون': ['com.amazon'],
    'شي ان': ['shein'],
    'زووم': ['us.zoom'],
    'تيمز': ['com.microsoft.teams'],
    'القران': ['quran', 'ayah', 'muslim'],
    'المصحف': ['quran', 'ayah'],
    'حدق': ['dev.waal.hadaq'],
  };

  /// Returns the best matches (best first). Empty if nothing fits.
  static List<AppEntry> find(String spoken, List<AppEntry> apps) {
    var q = normalizeAr(spoken)
        .replaceFirst(RegExp(r'^(تطبيق|برنامج|ابلكيشن|ابليكيشن) '), '')
        .replaceAll(RegExp(r' (لو سمحت|من فضلك|يا حدق)$'), '')
        .trim();
    if (q.isEmpty) return const [];
    final scored = <(AppEntry, int)>[];
    final hints = aliases[q] ?? aliases[q.replaceFirst(RegExp(r'^ال'), '')] ?? const [];
    for (final a in apps) {
      final label = normalizeAr(a.label);
      final pkg = a.package.toLowerCase();
      var s = 0;
      if (label == q) {
        s = 5;
      } else if (hints.any((h) => pkg.contains(h))) {
        s = 4;
      } else if (label.startsWith(q) || label.split(' ').contains(q)) {
        s = 3;
      } else if (q.length >= 3 && label.contains(q)) {
        s = 2;
      } else if (q.length >= 4 && pkg.contains(q.replaceAll(' ', ''))) {
        s = 1; // Latin names spoken/recognised in Latin letters
      }
      if (s > 0) scored.add((a, s));
    }
    scored.sort((x, y) => y.$2 - x.$2);
    return [for (final (a, _) in scored) a];
  }
}
