import 'package:flutter_test/flutter_test.dart';
import 'package:hadaq/core/arabic.dart';
import 'package:hadaq/core/intent.dart';

void main() {
  final c = IntentClassifier(savedPlaceNames: ['البيت', 'صيدلية الحي']);
  IntentType type(String s) => c.classify(s).type;

  group('design sample phrases', () {
    test('emergency', () {
      expect(type('النجدة!'), IntentType.emergency);
      expect(type('ساعدوني'), IntentType.emergency);
    });

    test('nearby places', () {
      final i = c.classify('ما هو أقرب مسجد، وكم يبعد عني؟');
      expect(i.type, IntentType.nearby);
      expect(i.arg, 'مسجد');
      expect(c.classify('أين أقرب صيدلية؟').arg, 'صيدلية');
    });

    test('vision questions go to the camera', () {
      expect(type('يا حدق، ما الذي أمامي؟'), IntentType.vision);
      expect(type('ما هذا الذي في يدي؟'), IntentType.vision);
      expect(type('كم فئة هذه الورقة؟'), IntentType.vision);
      expect(type('ما هذا الدواء؟ ومتى ينتهي؟'), IntentType.vision);
      expect(type('كيف حالة الإشارة أمامي؟'), IntentType.vision);
    });

    test('combined setting: slower voice + name', () {
      final i = c.classify('اجعل صوتك أبطأ، وناديني أبا خالد');
      expect(i.type, IntentType.setting);
      final keys = {for (final s in i.settings) s.key: s.value};
      expect(keys[SettingKey.speechRate], 'slower');
      expect(keys[SettingKey.name], 'أبا خالد');
    });

    test('ambiguous "make it higher" asks to clarify with two options', () {
      final i = c.classify('اجعله أعلى');
      expect(i.type, IntentType.unclear);
      expect(i.options, hasLength(2));
      expect(i.settings.first.key, SettingKey.volume);
      expect(i.settings.last.key, SettingKey.vibration);
    });

    test('saved place', () {
      final i = c.classify('أين البيت؟');
      expect(i.type, IntentType.savedPlace);
      expect(i.arg, 'البيت');
    });

    test('memory commands', () {
      expect(type('ماذا تتذكر عني؟'), IntentType.memoryShow);
      expect(type('امسح ذاكرتك'), IntentType.memoryWipe);
      final f = c.classify('انسَ اسمي');
      expect(f.type, IntentType.memoryForget);
      expect(f.arg, 'اسمي');
      expect(type('تراجع'), IntentType.undo);
    });

    test('quick replies', () {
      expect(type('نعم، ابدأ'), IntentType.yes);
      expect(type('كرّر'), IntentType.repeat);
      expect(type('أبطئ'), IntentType.setting);
      expect(type('لا شكرًا'), IntentType.no);
      expect(type('الثاني'), IntentType.choiceSecond);
      expect(type('الأول'), IntentType.choiceFirst);
    });
  });

  test('vibration and volume settings', () {
    expect(c.classify('اجعل الاهتزاز أقوى').settings.single.value, 'stronger');
    expect(c.classify('ارفع الصوت').settings.single.key, SettingKey.volume);
  });

  test('save place and emergency contact', () {
    final p = c.classify('احفظ هذا المكان باسم العمل');
    expect(p.settings.single.key, SettingKey.place);
    expect(p.settings.single.value, 'العمل');

    final ct = c.classify('أضف أمي جهة طوارئ رقمها ٠٥٥١٢٣٤٥٦٧');
    final v = ct.settings.single.value as Map;
    expect(v['name'], 'أمي');
    expect(v['phone'], '0551234567');
  });

  test('name from a long sentence keeps only the name', () {
    final i = c.classify('ناديني يونس عمري 23 اعيش في السعوديه');
    expect(i.settings.firstWhere((x) => x.key == SettingKey.name).value, 'يونس');
  });

  test('real transcripts from the server recogniser', () {
    var i = c.classify('ارسلوا لأمي واتساب وقول لها إني بتأخر شوية.');
    expect(i.type, IntentType.message);
    expect(type('وشو الشيء اللي قدامي؟'), IntentType.vision);
    i = c.classify('يا أحد قوين أقرب صيدلية مني؟');
    expect(i.type, IntentType.nearby);
    expect(i.arg, 'صيدلية');
  });

  test('«ما هذا» goes to the camera (fresh photo)', () {
    expect(type('ما هذا'), IntentType.vision);
  });

  test('asking about the name is a question, not a setting', () {
    expect(type('ما اسمي؟'), isNot(IntentType.setting));
  });

  test('general questions go to the assistant', () {
    expect(type('كم الساعة الآن في مكة؟'), IntentType.question);
    expect(type('أخبرني عن الطقس اليوم'), IntentType.question);
  });

  test('ride requests, walk anyway, third choice', () {
    expect(type('اطلب سيارة'), IntentType.ride);
    expect(c.classify('اطلب لي أوبر').arg, 'uber');
    expect(c.classify('ابغى كريم').arg, 'careem');
    expect(c.classify('نعم، أوبر').arg, 'uber');
    expect(c.classify('كريم').arg, 'careem');
    expect(type('امشيني'), IntentType.walkAnyway);
    expect(type('لا، بمشي'), IntentType.walkAnyway);
    expect(type('الثالث'), IntentType.choiceThird);
  });

  test('directions relative to the user', () {
    expect(directionFrom(90, 90), 'أمامك مباشرة');
    expect(directionFrom(180, 90), 'على يمينك');
    expect(directionFrom(0, 90), 'على يسارك');
    expect(directionFrom(270, 90), 'خلفك');
    expect(directionFrom(135, 90), 'أمامك إلى اليمين');
    expect(directionFrom(45, null), 'شمال شرق');
    expect(walkingTime(1400), '24 دقيقة مشيًا');
  });

  test('calls and emergency contacts from the phonebook', () {
    var i = c.classify('اتصل بأحمد');
    expect(i.type, IntentType.call);
    expect(i.arg, 'بأحمد'); // PhoneService also tries it without the leading ب
    i = c.classify('كلم أمي');
    expect(i.type, IntentType.call);
    expect(i.arg, 'أمي');
    i = c.classify('اتصل على 0551234567');
    expect(i.type, IntentType.call);
    expect(i.arg, '0551234567');
    i = c.classify('اتصل على خالد الحين');
    expect(i.arg, 'خالد');

    i = c.classify('أضف أمي جهة طوارئ');
    expect(i.type, IntentType.setting);
    final v = i.settings.single.value as Map;
    expect(v['name'], 'أمي');
    expect(v['phone'], isNull);
    i = c.classify('اجعل أخوي محمد من جهات الطوارئ');
    expect((i.settings.single.value as Map)['name'], 'أخوي محمد');

    expect(type('تكلم ببطء'), IntentType.setting); // «كلم» inside «تكلم» is not a call
  });

  test('any place, not just a fixed list', () {
    var i = c.classify('وين اقرب محل شاورما');
    expect(i.type, IntentType.nearby);
    expect(i.arg, 'محل شاورما');
    i = c.classify('ابحث عن مغسلة ملابس');
    expect(i.type, IntentType.nearby);
    expect(i.arg, 'مغسلة ملابس');
    i = c.classify('خذني إلى أقرب صيدلية');
    expect(i.type, IntentType.startGuidance);
    expect(i.arg, 'صيدلية');
    i = c.classify('وديني البيت');
    expect(i.type, IntentType.startGuidance);
    expect(i.arg, 'البيت');
    expect(type('ابدأ الإرشاد'), IntentType.startGuidance);
    expect(c.classify('ابدأ الإرشاد').arg, isNull);
    expect(type('كم باقي'), IntentType.remaining);
    expect(type('التالي'), IntentType.nextResult);
    expect(type('أوقف الإرشاد'), IntentType.stopGuidance);
  });

  test('free phrasing without «؟» goes to the assistant, not «لم أفهم»', () {
    // What speech recognisers actually return: no punctuation, any wording.
    expect(type('حدثني عن مكة'), IntentType.question);
    expect(type('الطقس اليوم'), IntentType.question);
    expect(type('عدد أيام الأسبوع'), IntentType.question);
    expect(type('شكرا لك يا صديقي'), IntentType.question);
  });

  test('gibberish is unclear', () {
    expect(type('امم'), IntentType.unclear);
  });

  test('arabic helpers', () {
    expect(normalizeAr('أَبْطَأ'), 'ابطا');
    expect(formatDistance(240), '240 مترًا');
    expect(formatDistance(1400), '1.4 كم');
    expect(bearingToArabic(0), 'شمالًا');
    expect(bearingToArabic(92), 'شرقًا');
  });
}
