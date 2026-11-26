import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/controller.dart';
import 'ui/home.dart';
import 'ui/theme.dart';

/// The screen gallery opens only with `--dart-define=DEMO=true` or, on web, `?demo`.
/// Otherwise web and mobile both run the real app.
const _demoDefine = bool.fromEnvironment('DEMO');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final demo = _demoDefine || (kIsWeb && Uri.base.queryParameters.containsKey('demo'));
  // `?shot=answer` (web): one screen state, full-bleed, for marketing screenshots.
  final shot = kIsWeb ? Uri.base.queryParameters['shot'] : null;
  final c = HadaqController()..demoMode = demo || shot != null;
  runApp(HadaqApp(controller: c, shot: shot));
  if (shot != null) {
    Future.delayed(const Duration(milliseconds: 1200), () {
      final p = Phase.values.where((x) => x.name == shot).firstOrNull;
      if (p != null) c.showDemo(p);
      // `&text=…`: a custom answer, to check how long text fits on screen.
      final t = Uri.base.queryParameters['text'];
      if (t != null) c.demoAnswer(t);
    });
  }
}

/// On a wide browser window, keep the app phone-shaped in the middle of the screen.
class _WebAppFrame extends StatelessWidget {
  final Widget child;
  const _WebAppFrame({required this.child});

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return child;
    return ColoredBox(
      color: HC.bgBottom,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: child,
        ),
      ),
    );
  }
}

class HadaqApp extends StatelessWidget {
  final HadaqController controller;
  final String? shot;
  const HadaqApp({super.key, required this.controller, this.shot});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'حَدَق',
      debugShowCheckedModeBanner: false,
      theme: hadaqTheme(),
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: shot != null
          ? HomeScreen(c: controller)
          : controller.demoMode
              ? DemoShell(c: controller)
              : _WebAppFrame(child: HomeScreen(c: controller)),
    );
  }
}

/// Web gallery: the real app inside a phone frame, with buttons that jump to
/// each of the design's screen states. Tapping the phone still uses live voice
/// (Chrome's speech recognition) for a quick try.
class DemoShell extends StatelessWidget {
  final HadaqController c;
  const DemoShell({super.key, required this.c});

  static const _states = <(Phase, String, String)>[
    (Phase.idle, '1 · جاهز', 'كرة هادئة وتحية وأمثلة'),
    (Phase.listening, '2 · أستمع', 'موجات حية ونص ما سُمع'),
    (Phase.answer, '3 · سؤال ← إجابة', 'مسار المساعد الذكي'),
    (Phase.saved, '4 · إعداد ← حفظ', 'مسار الذاكرة'),
    (Phase.camera, 'طلب ← الكاميرا', 'سؤال بصري'),
    (Phase.memory, 'عرض الذاكرة', '«ماذا تتذكر عني؟»'),
    (Phase.clarify, 'طلب توضيح', 'خياران بالصوت'),
    (Phase.sos, 'طوارئ ← SOS', 'عدّ تنازلي ثم إرسال'),
    (Phase.update, 'تحديث إجباري', 'من لوحة التحكم'),
    (Phase.setup, 'الإعداد الأول', 'أسئلة بالصوت عند أول تشغيل'),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 820;
    final phone = _PhoneFrame(child: HomeScreen(c: c));
    final panel = ListenableBuilder(
      listenable: c,
      builder: (context, _) => _panel(wide),
    );
    return Scaffold(
      backgroundColor: const Color(0xFFEEF1FA),
      body: SafeArea(
        child: wide
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [phone, const SizedBox(width: 48), SizedBox(width: 320, child: panel)],
              )
            : Column(children: [panel, Expanded(child: phone)]),
      ),
    );
  }

  Widget _panel(bool wide) {
    final buttons = [
      for (final (p, title, sub) in _states)
        Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 4),
          child: Material(
            color: c.phase == p ? HC.navy : Colors.white,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => c.showDemo(p),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: c.phase == p ? Colors.white : HC.navy)),
                    if (wide)
                      Text(sub,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: c.phase == p ? HC.textDim : const Color(0xFF5B678F))),
                  ],
                ),
              ),
            ),
          ),
        ),
    ];
    if (!wide) {
      return SizedBox(
        height: 52,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.all(6), children: buttons),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('حَدَق', style: TextStyle(fontSize: 44, fontWeight: FontWeight.w900, color: HC.navy)),
        const Text('حالات الشاشة الواحدة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: HC.navy)),
        const SizedBox(height: 4),
        const Text('اختر حالة لعرضها، أو المس الهاتف وتحدّث لتجربة الصوت مباشرة.',
            style: TextStyle(fontSize: 13, color: Color(0xFF5B678F))),
        const SizedBox(height: 16),
        ...buttons,
      ],
    );
  }
}

class _PhoneFrame extends StatelessWidget {
  final Widget child;
  const _PhoneFrame({required this.child});

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      child: Container(
        width: 402,
        height: 860,
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF0A0F24),
          borderRadius: BorderRadius.circular(56),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 40, offset: Offset(0, 20))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(46),
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: const Size(382, 840),
              padding: const EdgeInsets.only(top: 34, bottom: 8),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
