import 'package:flutter_test/flutter_test.dart';
import 'package:hadaq/core/intent.dart';
import 'package:hadaq/services/phone.dart';

/// Phrases taken from a real tester's session (2026-11-26) that the app used to
/// send to the assistant, which then answered «لا يمكنني…».
void main() {
  final c = IntentClassifier();
  Intent k(String s) => c.classify(s);

  test('calling, with or without a name', () {
    expect(k('اتصل.').type, IntentType.call);
    expect(k('اتصل.').arg, '');
    expect(k('قم بالاتصال بجهات اتصالي.').type, IntentType.call);
    expect(k('قم بالاتصال بجهات اتصالي.').arg, '');
    expect(k('اتصل بهادي').arg, 'بهادي');
    expect(k('قم بالاتصال بأحمد').type, IntentType.call);
    expect(k('هل يمكنك الاتصال بأمي؟').type, IntentType.call);
    expect(k('اتصل بالطوارئ').arg, '__emergency__');
    expect(k('كلم الإسعاف').arg, '__emergency__');
  });

  test('WhatsApp messages: recipient and text may come later', () {
    final a = k('أريد أن أرسل رسالة عبر الواتساب.');
    expect(a.type, IntentType.message);
    expect(a.arg, '');
    expect(k('قم بإرسال رسالة واتساب.').type, IntentType.message);
    expect(k('هل يمكنك إرسال رسالتي إلى جهات الاتصال في الواتساب؟').arg, '');
    // «اكتب لي رسالة صباح الخير»: the words are the message, not a contact called «صباح».
    final w = k('اكتب لي رسالة صباح الخير.');
    expect(w.type, IntentType.message);
    expect(w.options, contains('textOnly'));
    expect(w.arg, 'صباح الخير');
    // A real recipient is still a recipient.
    expect(k('ارسل لأحمد واتساب قل له إني في الطريق').options, isNot(contains('textOnly')));
  });

  test('«نعم» heard in another language', () {
    expect(k('Nam').type, IntentType.yes);
    expect(k('Ναι.').type, IntentType.yes);
    expect(k('نعم ارسل').type, IntentType.yes);
    expect(k('ايه').type, IntentType.yes);
  });

  test('camera requests take a picture instead of looking for an app', () {
    expect(k('افتح الكاميرا لترى كم معي من النقود.').type, IntentType.vision);
    expect(k('افتح الكاميرا حتى تتعرف على النص.').type, IntentType.vision);
    expect(k('ما الذي تراه أمامك من النقود؟').type, IntentType.vision);
    expect(k('تعرف على هذا النقود.').type, IntentType.vision);
    expect(k('أريد أن تقرأ هذا النص.').type, IntentType.vision);
  });

  test('apps, maps and rides', () {
    expect(k('هل يمكنك فتح تطبيق وصلني؟').type, IntentType.openApp);
    expect(k('قم بفتح تطبيق شراء.').type, IntentType.openApp);
    final m = k('افتح خرائط جوجل');
    expect(m.type, IntentType.startGuidance);
    expect(m.options, contains('gmaps'));
    expect(k('اطلب لي سيارة').type, IntentType.ride);
    expect(k('اطلب من وصلني').arg, 'wasalni');
    expect(k('اطلب بولت').arg, 'bolt');
    final r = k('اطلب سيارة إلى المستشفى');
    expect(r.type, IntentType.ride);
    expect(r.options, ['المستشفى']);
  });

  test('places by name, with directions', () {
    final a = k('حدد لي موقع تموينات الصفا.');
    expect(a.type, IntentType.nearby);
    expect(a.arg, 'تموينات الصفا');
    expect(k('قم بإرشادي إلى صيدلية الدواء.').type, IntentType.startGuidance);
    expect(k('قم بتوجيهه لمحل ملك البطاطس.').type, IntentType.startGuidance);
    expect(k('وين محل ملك البطاطس').type, IntentType.nearby);
    expect(k('وين انا').type, IntentType.whereAmI);
  });

  test('memory', () {
    expect(k('ما تتذكر عني?').type, IntentType.memoryShow);
    expect(k('امسح ذاكرتك').type, IntentType.memoryWipe);
  });

  test('contact names in Arabic match names saved in English', () {
    expect(PhoneService.sameSound('هادي', 'hadi'), isTrue);
    expect(PhoneService.sameSound('محمد', 'mohammed'), isTrue);
    expect(PhoneService.sameSound('احمد', 'ahmed'), isTrue);
    expect(PhoneService.sameSound('خالد', 'khaled'), isTrue);
    expect(PhoneService.sameSound('هادي', 'hamad'), isFalse);
  });
}
