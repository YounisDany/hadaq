import 'package:flutter_test/flutter_test.dart';
import 'package:hadaq/core/apps.dart';
import 'package:hadaq/core/intent.dart';

void main() {
  const apps = [
    AppEntry('YouTube', 'com.google.android.youtube'),
    AppEntry('واتساب', 'com.whatsapp'),
    AppEntry('WhatsApp Business', 'com.whatsapp.w4b'),
    AppEntry('Snapchat', 'com.snapchat.android'),
    AppEntry('توكلنا', 'sa.gov.nic.tawakkalna'),
    AppEntry('الكاميرا', 'com.sec.android.app.camera'),
    AppEntry('الإعدادات', 'com.android.settings'),
    AppEntry('Hungerstation', 'com.hungerstation.android.web'),
  ];

  String? first(String q) {
    final r = AppMatcher.find(q, apps);
    return r.isEmpty ? null : r.first.package;
  }

  test('finds apps by Arabic label, alias, or Latin name', () {
    expect(first('يوتيوب'), 'com.google.android.youtube');
    expect(first('واتساب'), 'com.whatsapp');
    expect(first('واتساب بزنس'), 'com.whatsapp.w4b');
    expect(first('سناب'), 'com.snapchat.android');
    expect(first('تطبيق توكلنا'), 'sa.gov.nic.tawakkalna');
    expect(first('الكاميرا'), 'com.sec.android.app.camera');
    expect(first('الإعدادات'), 'com.android.settings');
    expect(first('هنقرستيشن'), 'com.hungerstation.android.web');
    expect(first('تطبيق غير موجود'), isNull);
  });

  test('open-app intents', () {
    final c = IntentClassifier();
    var i = c.classify('افتح يوتيوب');
    expect(i.type, IntentType.openApp);
    expect(i.arg, 'يوتيوب');
    i = c.classify('ادخل على تطبيق توكلنا');
    expect(i.type, IntentType.openApp);
    expect(i.arg, 'توكلنا');
    i = c.classify('شغل سناب');
    expect(i.type, IntentType.openApp);
    // Not app requests:
    expect(c.classify('افتح الإعداد').type, IntentType.setup);
    expect(c.classify('أعد الإعداد').type, IntentType.setup);
    expect(c.classify('أعد').type, IntentType.repeat);
    expect(c.classify('احذف بياناتي').type, IntentType.dataWithdraw);
    expect(c.classify('أوقف مشاركة بياناتي').type, IntentType.dataWithdraw);
    expect(c.classify('انسَ اسمي').type, IntentType.memoryForget);
  });
}
