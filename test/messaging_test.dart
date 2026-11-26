import 'package:flutter_test/flutter_test.dart';
import 'package:hadaq/core/intent.dart';
import 'package:hadaq/core/messaging.dart';

void main() {
  test('recipient / message candidates', () {
    final c = Messaging.candidates('لأحمد قل له إني في الطريق');
    expect(c.first, ('لأحمد', 'إني في الطريق'));
    final c2 = Messaging.candidates('إلى أخوي محمد إني وصلت البيت');
    expect(c2[1], ('أخوي محمد', 'إني وصلت البيت'));
    final c3 = Messaging.candidates('أمي');
    expect(c3.single, ('أمي', ''));
  });

  test('message cleanup keeps the meaning', () {
    expect(Messaging.cleanMessage('قل له أنا جاي بعد شوي'), 'أنا جاي بعد شوي');
    expect(Messaging.cleanMessage('وقل لها السلام عليكم'), 'السلام عليكم');
    expect(Messaging.cleanMessage('إني وصلت'), 'إني وصلت');
  });

  test('WhatsApp number format', () {
    expect(Messaging.whatsappNumber('0551234567'), '966551234567');
    expect(Messaging.whatsappNumber('+966 55 123 4567'), '966551234567');
    expect(Messaging.whatsappNumber('00971501234567'), '971501234567');
    expect(Messaging.whatsappNumber('551234567'), '966551234567');
  });

  test('message intents', () {
    final c = IntentClassifier();
    var i = c.classify('ارسل لأحمد واتساب قل له إني في الطريق');
    expect(i.type, IntentType.message);
    expect(i.options, ['whatsapp']);
    i = c.classify('ابعث رسالة نصية لأمي إني وصلت');
    expect(i.type, IntentType.message);
    expect(i.options, ['sms']);
    i = c.classify('واتساب أخوي محمد');
    expect(i.type, IntentType.message);
    expect(i.arg, 'أخوي محمد');
    i = c.classify('راسل خالد');
    expect(i.type, IntentType.message);
  });
}
