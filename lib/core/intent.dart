import 'arabic.dart';

/// The four routes from the design (سؤال/طلب، إعداد، طوارئ، غير واضح)
/// plus a few quick voice controls that act on the current conversation.
enum IntentType {
  emergency,
  question, // general question -> assistant
  vision, // needs the camera
  nearby, // "أقرب صيدلية"
  whereAmI,
  savedPlace, // "أين بيتي"
  startGuidance,
  stopGuidance,
  remaining, // «كم باقي؟» during guidance
  nextResult, // «التالي» — the next place from the last search
  call, // «اتصل بأحمد» — phonebook
  setup, // «أعد الإعداد»
  message, // «ارسل لأحمد واتساب …» — options: ['whatsapp'] or ['sms']
  enableAutoSend, // «فعّل الإرسال التلقائي»
  openApp, // «افتح يوتيوب»
  dataWithdraw, // «احذف بياناتي»
  dataShare, // «شارك بياناتي»
  setting,
  memoryShow,
  memoryForget,
  memoryWipe,
  undo,
  repeat,
  stop,
  yes,
  no,
  choiceFirst,
  choiceSecond,
  choiceThird,
  ride, // «اطلب سيارة / أوبر / كريم»
  walkAnyway, // «امشيني» after a «far» warning
  unclear,
}

/// A setting change extracted from speech. [key] is one of the [SettingKey] values.
class SettingChange {
  final String key;
  final dynamic value;
  const SettingChange(this.key, this.value);

  @override
  String toString() => 'SettingChange($key, $value)';
}

abstract class SettingKey {
  static const speechRate = 'speechRate'; // value: 'slower' | 'faster' | 'normal'
  static const volume = 'volume'; // 'up' | 'down'
  static const vibration = 'vibration'; // 'stronger' | 'weaker'
  static const name = 'name'; // String
  static const place = 'place'; // String (save current location under this name)
  static const contact = 'contact'; // {name, phone}
}

class Intent {
  final IntentType type;
  final double confidence;
  final String text; // original text
  final List<SettingChange> settings;
  final String? arg; // place category, place name, forget target...
  final List<String> options; // for clarification

  const Intent(
    this.type, {
    this.confidence = 1,
    this.text = '',
    this.settings = const [],
    this.arg,
    this.options = const [],
  });

  @override
  String toString() => 'Intent($type, ${confidence.toStringAsFixed(2)}, arg=$arg, $settings)';
}

/// Nearby categories -> Arabic display name. Keys are normalized spellings.
const nearbyCategories = <String, String>{
  'مسجد': 'مسجد',
  'جامع': 'مسجد',
  'صيدليه': 'صيدلية',
  'مستشفي': 'مستشفى',
  'مستوصف': 'مستشفى',
  'عياده': 'مستشفى',
  'مطعم': 'مطعم',
  'صراف': 'صراف آلي',
  'بنك': 'بنك',
  'بقاله': 'بقالة',
  'سوبرماركت': 'بقالة',
  'محطه': 'محطة وقود',
  'بنزين': 'محطة وقود',
  'مقهي': 'مقهى',
  'كافيه': 'مقهى',
  'كوفي': 'مقهى',
};

/// Lightweight rule-based intent classifier (design: «مصنّف نية خفيف»).
/// Works offline; anything it can't place confidently either goes to the
/// assistant (if it looks like a question) or triggers a clarification.
class IntentClassifier {
  /// Names of places the user saved, so "أين البيت؟" can be resolved locally.
  final Iterable<String> savedPlaceNames;

  IntentClassifier({this.savedPlaceNames = const []});

  Intent classify(String raw) {
    // Drop the wake phrase ("يا حدق، ...") so it doesn't affect matching.
    final t = normalizeAr(raw).replaceFirst(RegExp(r'^(يا )?حدق\s*'), '');
    if (t.isEmpty) return Intent(IntentType.unclear, confidence: 0, text: raw);
    final words = t.split(' ');

    // 1) Emergency — always first, always confident.
    if (hasAny(t, ['النجده', 'ساعدوني', 'انقذوني', 'استغاثه', 'نجده']) ||
        t == 'الحقوني') {
      return Intent(IntentType.emergency, text: raw);
    }

    // 2) Short conversational controls.
    if (words.length <= 3) {
      if (hasAny(t, ['تراجع'])) return Intent(IntentType.undo, text: raw);
      if ((RegExp(r'(^| )(كرر|كررها|اعد|اعدها|عيد|عيدها)( |$)').hasMatch(t) && !t.contains('الاعداد')) ||
          hasAny(t, ['مره ثانيه', 'مره اخري'])) {
        return Intent(IntentType.repeat, text: raw);
      }
      if (RegExp(r'^(الاول|الخيار الاول|رقم 1|1|واحد)$').hasMatch(t)) {
        return Intent(IntentType.choiceFirst, text: raw);
      }
      if (RegExp(r'^(الثاني|الخيار الثاني|رقم 2|2|اثنين)$').hasMatch(t)) {
        return Intent(IntentType.choiceSecond, text: raw);
      }
      if (RegExp(r'^(الثالث|الخيار الثالث|رقم 3|3|ثلاثه)$').hasMatch(t)) {
        return Intent(IntentType.choiceThird, text: raw);
      }
      if (RegExp(r'^(نعم|ايوه|اي|اكيد|تمام|طيب|موافق|ابدا|نعم ابدا|اقرا|اقراها|اقرا النشره)$')
          .hasMatch(t)) {
        return Intent(IntentType.yes, text: raw);
      }
      if (RegExp(r'^(لا|لا شكرا|شكرا|الغ|الغاء|لا تفعل|لا ترسل)$').hasMatch(t)) {
        return Intent(IntentType.no, text: raw);
      }
      if (hasAny(t, ['اسكت', 'توقف', 'كفي', 'اصمت']) && !t.contains('ارشاد')) {
        return Intent(IntentType.stop, text: raw);
      }
      if (t == 'ابطي' || t == 'ابطا') {
        return Intent(IntentType.setting,
            text: raw, settings: const [SettingChange(SettingKey.speechRate, 'slower')]);
      }
      if (t == 'اسرع') {
        return Intent(IntentType.setting,
            text: raw, settings: const [SettingChange(SettingKey.speechRate, 'faster')]);
      }
    }

    if (RegExp(r'^(اعد|ابدا|افتح|اعاده) (الاعداد|التهيئه|الاعدادات من جديد)').hasMatch(t) || t == 'الاعداد من جديد') {
      return Intent(IntentType.setup, text: raw);
    }

    if (RegExp(r'(فعل|شغل|تفعيل) (الارسال التلقائي|ارسال الواتساب|الارسال)').hasMatch(t)) {
      return Intent(IntentType.enableAutoSend, text: raw);
    }

    if (RegExp(r'(احذف|امسح) بياناتي|(اوقف|الغ|وقف) (مشاركه )?(بياناتي|المشاركه)|(الغ|اسحب) الموافقه').hasMatch(t)) {
      return Intent(IntentType.dataWithdraw, text: raw);
    }
    if (RegExp(r'(شارك|ارسل) بياناتي|اوافق علي المشاركه|وافقت علي المشاركه').hasMatch(t)) {
      return Intent(IntentType.dataShare, text: raw);
    }

    // Open an app: «افتح يوتيوب»، «ادخل على توكلنا»، «شغل سناب».
    final appM = RegExp(r'^(?:افتح|افتحي|ادخل|ادخلي|شغل|شغلي|روح|ودني|خش)(?: لي)?(?: علي| الي| ل)?(?: تطبيق| برنامج)?\s+(.+)$').firstMatch(t);
    if (appM != null && !RegExp(r'^(الكاميرا وصف|الارشاد)').hasMatch(appM.group(1)!)) {
      final name = appM.group(1)!.replaceAll(RegExp(r'\s+(لو سمحت|من فضلك|يا حدق)$'), '').trim();
      if (name.isNotEmpty) return Intent(IntentType.openApp, text: raw, arg: _originalSlice(raw, name));
    }

    // Messages: «ارسل لأحمد واتساب قل له إني في الطريق»، «ابعث رسالة نصية لأمي…»، «واتساب أحمد».
    final msgM = RegExp(
            r'^(?:(?:ارسل|ارسلي|ارسلوا|ارسلو|ابعث|ابعثي|ابعثوا|راسل|رسل|اكتب|ابعتلي|ارسللي)(?: لي)?(?: رساله| مسج)?(?: نصيه| sms| عاديه)?(?: (?:علي |ب|عبر )?(?:الواتساب|الواتس|واتساب|واتس))?|(?:واتساب|واتس))\s+(.+)$')
        .firstMatch(t);
    if (msgM != null) {
      final sms = RegExp(r'(نصيه|sms|عاديه)').hasMatch(t.split(' ').take(4).join(' '));
      // Remove a trailing/inline «واتساب» from the rest, then map back to the user's spelling.
      final rest = msgM.group(1)!.replaceAll(RegExp(r'(^| )(?:علي |ب|عبر )?(?:الواتساب|الواتس|واتساب|واتس)(?= |$)'), ' ').trim();
      if (rest.isNotEmpty) {
        return Intent(IntentType.message, text: raw, arg: _originalSlice(raw, rest), options: [sms ? 'sms' : 'whatsapp']);
      }
    }

    // 3) Phone calls: «اتصل بأحمد»، «كلم أمي»، «اتصل على 0551234567».
    final callM = RegExp(r'^(?:اتصل|اتصلي|اتصلوا|اتصال|كلم|كلمي|كلموا|دق|دقي|اضرب)(?: لي)?(?: علي| الي| ب| ل)?\s+(.+)$').firstMatch(t);
    if (callM != null) {
      final who = callM.group(1)!.replaceAll(RegExp(r'\s+(?:الحين|الان|لو سمحت|من فضلك|يا حدق)$'), '').trim();
      if (who.isNotEmpty) {
        final digits = who.replaceAll(' ', '');
        return Intent(IntentType.call,
            text: raw, arg: RegExp(r'^\+?\d{3,}$').hasMatch(digits) ? digits : _originalSlice(raw, who));
      }
    }

    // 4) Memory management.
    if (hasAny(t, ['ماذا تتذكر', 'ماذا تعرف عني', 'وش تعرف عني', 'ايش تتذكر', 'اعرض ذاكرتك', 'ماذا تحفظ'])) {
      return Intent(IntentType.memoryShow, text: raw);
    }
    if (hasAny(t, ['امسح ذاكرتك', 'امسح الذاكره', 'احذف كل شيء', 'امسح كل شيء', 'احذف ذاكرتك'])) {
      return Intent(IntentType.memoryWipe, text: raw);
    }
    final forget = RegExp(r'^(انس|انسي|احذف|امسح)\s+(.+)$').firstMatch(t);
    if (forget != null) {
      return Intent(IntentType.memoryForget, text: raw, arg: forget.group(2)!.trim());
    }

    // 4) Navigation.
    if (hasAny(t, ['اوقف الارشاد', 'اوقف التوجيه', 'انهي الارشاد', 'الغ الارشاد', 'توقف عن الارشاد'])) {
      return Intent(IntentType.stopGuidance, text: raw);
    }
    if (hasAny(t, ['كم باقي', 'كم بقي', 'كم متبقي', 'كم المسافه المتبقيه', 'باقي كثير', 'كم ظل', 'كم باقي لي'])) {
      return Intent(IntentType.remaining, text: raw);
    }
    if (RegExp(r'^(التالي|غيره|غيرها|غير هذا|غير هذا المكان|واحد ثاني|واحد غيره|مكان ثاني|مكان اخر|اللي بعده|الي بعده)$').hasMatch(t)) {
      return Intent(IntentType.nextResult, text: raw);
    }
    if (hasAny(t, ['اين انا', 'وين انا', 'ما موقعي', 'موقعي الحالي', 'في اي شارع'])) {
      return Intent(IntentType.whereAmI, text: raw);
    }

    // Ride: «اطلب سيارة»، «اطلب لي أوبر»، «ابغى كريم».
    final rideM = RegExp(r'(?:^| )(?:اطلب|اطلبي|ابي|ابغي|احجز|احتاج|اريد)(?: لي)? (?:سياره|تاكسي|توصيل|مشوار|اوبر|كريم|جيني|uber|careem)').firstMatch(t);
    if (rideM != null || RegExp(r'^(?:نعم |ايوه |اي |طيب )?(اوبر|كريم|سياره|تاكسي)$').hasMatch(t)) {
      final app = t.contains('كريم') || t.contains('careem')
          ? 'careem'
          : (t.contains('اوبر') || t.contains('uber'))
              ? 'uber'
              : null;
      return Intent(IntentType.ride, text: raw, arg: app);
    }
    if (RegExp(r'^(?:لا )?(?:امشيني|مشيني|مشني|ابي امشي|ابغي امشي|بمشي|امشي|خلني امشي|راح امشي)(?: .*)?$').hasMatch(t)) {
      return Intent(IntentType.walkAnyway, text: raw);
    }

    const goVerbs = r'(?:خذني|خدني|وديني|ودني|وصلني|دلني|وجهني|ابي اروح|ابغي اروح|اريد الذهاب|اريد ان اذهب|ابي اروح)';
    final wantsToGo = RegExp('(^| )$goVerbs').hasMatch(t);

    // Saved places: «أين البيت؟» / «خذني إلى البيت».
    if (wantsToGo || hasAny(t, ['اين', 'وين', 'كم يبعد', 'كم تبعد'])) {
      for (final name in savedPlaceNames) {
        final n = normalizeAr(name);
        if (n.isNotEmpty && (t.contains(n) || t.contains(n.replaceFirst('ال', '')))) {
          return Intent(wantsToGo ? IntentType.startGuidance : IntentType.savedPlace, text: raw, arg: name);
        }
      }
    }

    // Any place: «وين أقرب محل شاورما»، «ابحث عن صيدلية»، «خذني إلى أقرب مسجد».
    final place = RegExp('(?:اقرب|ابحث عن|دور لي|دورلي|دور علي|$goVerbs(?: (?:الي|ل|علي|عند))?(?: اقرب)?)\\s+(.+)\$')
        .firstMatch(t);
    if (place != null) {
      var q = place.group(1)!
          .replaceAll(RegExp(r'\s+(?:و?كم يبعد(?: عني)?|و?كم تبعد(?: عني)?|مني|لي|من هنا|هنا|قريب(?: مني)?|يا حدق)$'), '')
          .replaceAll(RegExp(r'^(?:الي|ل|علي) '), '')
          .trim();
      if (q.isNotEmpty && !RegExp(r'^(الارشاد|التوجيه)$').hasMatch(q)) {
        return Intent(wantsToGo ? IntentType.startGuidance : IntentType.nearby, text: raw, arg: _originalSlice(raw, q));
      }
    }
    if (hasAny(t, ['ابدا الارشاد', 'ابدا التوجيه']) || RegExp('^$goVerbs\$').hasMatch(t)) {
      return Intent(IntentType.startGuidance, text: raw);
    }

    // 5) Settings / preferences.
    final settings = _extractSettings(t, raw);
    if (settings != null) return settings;

    // 6) Vision (needs the camera).
    if (_looksVisual(t)) {
      return Intent(IntentType.vision, text: raw, confidence: 0.9);
    }

    // 7) General question / request -> assistant.
    final questionWords = ['ما ', 'ماذا', 'كيف', 'متي', 'لماذا', 'هل', 'من ', 'كم', 'اين', 'وش', 'ايش', 'ليش', 'اخبرني', 'احكي', 'اشرح', 'قل لي', 'ابغي', 'اريد'];
    final isQuestion = raw.contains('؟') || raw.contains('?') || questionWords.any((q) => '$t '.startsWith(q) || t.contains(' $q'));
    if (isQuestion) return Intent(IntentType.question, text: raw, confidence: 0.85);

    // Only fillers / a lone syllable are "unclear" (design: ثقة أقل من 70%).
    // Anything else goes to the assistant, which understands free phrasing far
    // better than these rules — speech recognisers rarely add «؟».
    const fillers = {'امم', 'ام', 'اه', 'اها', 'ها', 'يعني', 'طيب', 'اوه', 'هم'};
    final letters = t.replaceAll(RegExp(r'[^ء-يa-z]'), '');
    if (letters.length < 3 || (words.length == 1 && fillers.contains(t))) {
      return Intent(IntentType.unclear, text: raw, confidence: 0.4);
    }
    return Intent(IntentType.question, text: raw, confidence: 0.72);
  }

  bool _looksVisual(String t) {
    const visual = [
      'امامي', 'قدامي', 'في يدي', 'بيدي', 'ما هذا', 'وش هذا', 'ايش هذا', 'ما هذه', 'وش هذي', 'هذا الشي', 'هذه الورقه', 'هذي الورقه', 'الورقه',
      'اقرا', 'مكتوب', 'لون', 'الكاميرا', 'صوره', 'شوف', 'انظر', 'ماذا تري', 'وش تشوف',
      'العمله', 'كم هذه', 'الدواء', 'هذا الدواء', 'النشره', 'الباب', 'مفتوح', 'مغلق',
      'عايق', 'درج', 'الاشاره', 'التقاطع', 'المنتج', 'مكونات', 'صلاحيه', 'تاريخ الانتهاء',
      'القميص', 'الملابس', 'من هذا', 'من هذه', 'من امامي', 'صف لي', 'صف المكان',
    ];
    return hasAny(t, visual);
  }

  Intent? _extractSettings(String t, String raw) {
    final out = <SettingChange>[];

    // Name: "ناديني أبا خالد" / "اسمي أحمد" / "غيّر اسمي إلى محمد"
    final nameRe = RegExp(r'(?:ناديني|نادني|سمني|اسمي|غير اسمي (?:الي|ل)|ادعني)\s+(.+?)(?:\s+و(?:اجعل|خل|خلي)\b.*)?$');
    final isAsking = RegExp(r'^(ما|هل|ماذا|كيف|وش|ايش|من)\s').hasMatch(t);
    final nm = isAsking ? null : nameRe.firstMatch(t);
    // Keep only the name itself: «ناديني يونس عمري 23…» -> «يونس».
    String trimName(String n) {
      var w = n.split(' ');
      final cut = w.indexWhere((x) => {'عمري', 'عمر', 'من', 'اعيش', 'ساكن', 'وعمري', 'واعيش', 'وانا', 'في'}.contains(x) || RegExp(r'\d').hasMatch(x));
      if (cut > 0) w = w.sublist(0, cut);
      return w.take(3).join(' ');
    }
    if (nm != null) {
      final name = _originalSlice(raw, trimName(nm.group(1)!));
      if (name.isNotEmpty) out.add(SettingChange(SettingKey.name, name));
    }

    // Speech rate
    final aboutVoice = hasAny(t, ['صوت', 'كلام', 'تكلم', 'الكلام', 'سرعه']);
    if (aboutVoice && hasAny(t, ['ابطا', 'ابطي', 'ببطء', 'بطيء', 'اهدا', 'على مهل'])) {
      out.add(const SettingChange(SettingKey.speechRate, 'slower'));
    } else if (aboutVoice && hasAny(t, ['اسرع', 'بسرعه', 'سريع'])) {
      out.add(const SettingChange(SettingKey.speechRate, 'faster'));
    } else if (hasAny(t, ['تكلم ببطء', 'تكلم بشويش'])) {
      out.add(const SettingChange(SettingKey.speechRate, 'slower'));
    }

    // Volume
    if (hasAny(t, ['ارفع الصوت', 'صوت اعلي', 'اعلي صوت', 'علي الصوت', 'زد الصوت'])) {
      out.add(const SettingChange(SettingKey.volume, 'up'));
    } else if (hasAny(t, ['اخفض الصوت', 'وطي الصوت', 'صوت اخفض', 'قلل الصوت'])) {
      out.add(const SettingChange(SettingKey.volume, 'down'));
    }

    // Vibration
    if (t.contains('اهتزاز')) {
      if (hasAny(t, ['اقوي', 'ارفع', 'زد', 'قوي'])) {
        out.add(const SettingChange(SettingKey.vibration, 'stronger'));
      } else if (hasAny(t, ['اخف', 'اضعف', 'قلل', 'خفيف'])) {
        out.add(const SettingChange(SettingKey.vibration, 'weaker'));
      }
    }

    // Save place: "احفظ هذا المكان باسم البيت"
    final placeRe = RegExp(r'احفظ (?:هذا المكان|موقعي|المكان|هنا)(?: الحالي)?\s*(?:باسم|بإسم|ك|على انه)\s*(.+)$');
    final pm = placeRe.firstMatch(t);
    if (pm != null) {
      out.add(SettingChange(SettingKey.place, _originalSlice(raw, pm.group(1)!)));
    }

    // Emergency contact: "أضف أمي جهة طوارئ رقمها 0551234567"
    if (hasAny(t, ['اضف', 'احفظ', 'سجل']) && RegExp(r'\d[\d\s]{6,}').hasMatch(t)) {
      final phone = RegExp(r'\+?\d[\d\s]{6,}\d').firstMatch(t)!.group(0)!.replaceAll(' ', '');
      final nameMatch = RegExp(r'(?:اضف|احفظ|سجل)\s+(?:رقم\s+)?(?:جهه طواري\s+)?([^\d]+?)\s+(?:جهه طواري|رقمه|رقمها|رقم|علي الرقم|\d)').firstMatch(t);
      final cname = nameMatch != null ? _originalSlice(raw, nameMatch.group(1)!.trim()) : 'جهة طوارئ';
      out.add(SettingChange(SettingKey.contact, {'name': cname, 'phone': phone}));
    } else if (t.contains('طواري')) {
      // No number spoken: «أضف أمي جهة طوارئ» / «اجعل أحمد من جهات الطوارئ» → look it up in the phonebook.
      final m = RegExp(
              r'(?:اضف|احفظ|سجل|اجعل|خل|خلي|حط)\s+(.+?)\s+(?:جهه طواري|كجهه طواري|الي جهات الطواري|لجهات الطواري|في جهات الطواري|من جهات الطواري|رقم طواري)')
          .firstMatch(t);
      if (m != null) {
        final who = m.group(1)!.replaceFirst(RegExp(r'^رقم '), '').trim();
        out.add(SettingChange(SettingKey.contact, {'name': _originalSlice(raw, who), 'phone': null}));
      }
    }

    // Ambiguous "اجعله أعلى / أقوى" without a subject -> clarification
    if (out.isEmpty &&
        RegExp(r'^(اجعله|خله|خليه|خليها|اجعلها|ارفعه|ارفعها)\s+(اعلي|اقوي|اكثر)$').hasMatch(t)) {
      return Intent(
        IntentType.unclear,
        confidence: 0.5,
        text: raw,
        options: const ['رفع مستوى الصوت', 'رفع قوة الاهتزاز'],
        settings: const [
          SettingChange(SettingKey.volume, 'up'),
          SettingChange(SettingKey.vibration, 'stronger'),
        ],
      );
    }

    if (out.isEmpty) return null;
    return Intent(IntentType.setting, text: raw, settings: out);
  }

  /// Maps a slice of the normalized text back to the user's original spelling
  /// (so we save "أبو خالد" not "ابو خالد") when word counts line up.
  String _originalSlice(String raw, String normSlice) {
    final rawWords = raw
        .replaceAll(RegExp(r'''[؟?!.,،؛:«»"']'''), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final sliceWords = normSlice.trim().split(' ');
    for (var i = 0; i + sliceWords.length <= rawWords.length; i++) {
      final cand = rawWords.sublist(i, i + sliceWords.length);
      if (normalizeAr(cand.join(' ')) == normSlice.trim()) return cand.join(' ');
    }
    return normSlice.trim();
  }
}
