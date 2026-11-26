import 'package:flutter_test/flutter_test.dart';
import 'package:hadaq/core/setup_answers.dart';

void main() {
  test('name answers', () {
    expect(SetupAnswers.name('اسمي أحمد'), 'أحمد');
    expect(SetupAnswers.name('ناديني أبو خالد'), 'أبو خالد');
    expect(SetupAnswers.name('أنا محمد يا حدق'), 'محمد');
    expect(SetupAnswers.name('سارة'), 'سارة');
    expect(SetupAnswers.name('اسمي'), isNull);
    expect(SetupAnswers.name('يونس عمري 23 اعيش في السعوديه من جده'), 'يونس');
    expect(SetupAnswers.name('اسمي خلود وعمري عشرين'), 'خلود');
  });

  test('yes / no / skip', () {
    expect(SetupAnswers.isYes('نعم صحيح'), isTrue);
    expect(SetupAnswers.isYes('ايوه'), isTrue);
    expect(SetupAnswers.isNo('لا مو هذا'), isTrue);
    expect(SetupAnswers.isSkip('تخطَّ'), isTrue);
    expect(SetupAnswers.isSkip('بعدين'), isTrue);
    expect(SetupAnswers.isSkip('أمي'), isFalse);
  });

  test('voice speed answers', () {
    expect(SetupAnswers.speed('أبطأ شوي'), 'slower');
    expect(SetupAnswers.speed('أسرع'), 'faster');
    expect(SetupAnswers.speed('مناسبة'), 'ok');
    expect(SetupAnswers.speed('تمام'), 'ok');
    expect(SetupAnswers.speed('ما أدري'), isNull);
  });

  test('contacts: name or spoken number', () {
    expect(SetupAnswers.number('0 5 5 1 2 3 4 5 6 7'), '0551234567');
    expect(SetupAnswers.number('٠٥٥١٢٣٤٥٦٧'), '0551234567');
    expect(SetupAnswers.number('أمي'), isNull);
    expect(SetupAnswers.contactName('اسمها أمي'), 'أمي');
    expect(SetupAnswers.contactName('اتصل بأخوي محمد'), 'أخوي محمد');
  });
}
