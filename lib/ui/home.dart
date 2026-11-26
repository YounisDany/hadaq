import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../app/controller.dart';
import 'orb.dart';
import 'theme.dart';

/// The one and only screen. The whole surface is a single touch target:
/// tap = talk, double tap = repeat, long press on the bottom edge = SOS.
class HomeScreen extends StatefulWidget {
  final HadaqController c;
  const HomeScreen({super.key, required this.c});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  HadaqController get c => widget.c;

  @override
  void initState() {
    super.initState();
    c.init();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        body: Stack(children: [
          const _Backdrop(),
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: Semantics(
                    button: true,
                    label: _semanticLabel(),
                    hint: 'المس للتحدّث',
                    excludeSemantics: true,
                    onTap: c.onTap,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: c.onTap,
                      onDoubleTap: c.onDoubleTap,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Column(
                          children: [
                            _TopBar(memoryCount: c.memoryCount, guiding: c.guiding),
                            const SizedBox(height: 14),
                            Expanded(child: _body()),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                _SosBar(c: c),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  String _semanticLabel() => switch (c.phase) {
        Phase.listening => 'أستمع إليك',
        Phase.sos => 'طوارئ. المس للإلغاء',
        Phase.update => 'يلزم تحديث حدق. المس لفتح صفحة التحديث',
        Phase.setup => 'الإعداد. ${c.setupQuestion}',
        _ => c.answer.isNotEmpty ? c.answer : 'حدق. كيف أساعدك؟',
      };

  Widget _body() {
    final phase = c.phase;
    final orbSize = switch (phase) {
      Phase.idle || Phase.listening || Phase.sos || Phase.saved => 180.0,
      Phase.camera => 170.0,
      _ => 120.0,
    };

    return LayoutBuilder(builder: (context, box) {
      return SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _StatusChip(phase: phase),
              const SizedBox(height: 12),
              ..._header(),
              const SizedBox(height: 8),
              VoiceOrb(phase: phase, sosCount: c.sosCount, camera: c.camera.controller, size: orbSize),
              const SizedBox(height: 8),
              ..._footer(),
            ],
          ),
        ),
      );
    });
  }

  /// Text above the orb.
  List<Widget> _header() {
    switch (c.phase) {
      case Phase.idle:
        return [
          Text(c.greeting, style: const TextStyle(color: HC.textDim, fontSize: 18)),
          const SizedBox(height: 4),
          const Text('كيف أساعدك؟',
              style: TextStyle(color: HC.text, fontSize: 40, fontWeight: FontWeight.w800)),
        ];
      case Phase.listening:
      case Phase.setup:
        return const [];
      case Phase.sos:
        return [_quote('النجدة!')];
      default:
        return c.heard.isEmpty
            ? []
            : [
                Text(c.phase == Phase.saved ? 'طلبك' : 'سؤالك',
                    style: const TextStyle(color: HC.textDim, fontSize: 15)),
                const SizedBox(height: 4),
                _quote(c.heard, size: 22),
              ];
    }
  }

  /// Text and cards below the orb.
  List<Widget> _footer() {
    switch (c.phase) {
      case Phase.idle:
        return [
          const Text('اضغط في أي مكان وتحدّث',
              style: TextStyle(color: HC.text, fontSize: 22, fontWeight: FontWeight.w700)),
          const Text('أو قل «يا حَدَق»، أو زر رفع الصوت', style: TextStyle(color: HC.textDim, fontSize: 15)),
          const SizedBox(height: 18),
          _card(
            child: Column(
              children: [
                const Text('جرّب أن تقول', style: TextStyle(color: HC.textDim, fontSize: 15)),
                const SizedBox(height: 8),
                for (final s in ['«ما الذي أمامي؟»', '«أين أقرب صيدلية؟»', '«اجعل الصوت أبطأ»'])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(s, style: const TextStyle(color: HC.text, fontSize: 20, fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
          ),
        ];
      case Phase.listening:
        return [
          const Text('ما سمعته الآن', style: TextStyle(color: HC.textDim, fontSize: 15)),
          const SizedBox(height: 6),
          _quote(c.heard.isEmpty ? '…' : c.heard, size: 30),
          const SizedBox(height: 16),
          _card(
            child: const Text('أتوقف تلقائيًا عندما تصمت، ثم أحلّل كلامك',
                textAlign: TextAlign.center, style: TextStyle(color: HC.textDim, fontSize: 16)),
          ),
        ];
      case Phase.thinking:
        return [const Text('لحظة…', style: TextStyle(color: HC.textDim, fontSize: 22))];
      case Phase.saved:
        return [
          if (c.savedRows.isNotEmpty) _savedCard(),
          const SizedBox(height: 12),
          _answerCard(),
        ];
      case Phase.memory:
        return [
          _savedCard(title: 'ذاكرتي · ${c.memoryCount} عناصر'),
          const SizedBox(height: 10),
          const Text('للحذف قل «انسَ اسمي» · وللمسح الكامل «امسح ذاكرتك»',
              textAlign: TextAlign.center, style: TextStyle(color: HC.textDim, fontSize: 15)),
        ];
      case Phase.clarify:
        return [
          const Text('هل تقصد:', style: TextStyle(color: HC.text, fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          for (var i = 0; i < c.clarifyOptions.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _card(
                child: Row(children: [
                  CircleAvatar(radius: 16, backgroundColor: HC.amber, child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.black))),
                  const SizedBox(width: 12),
                  Text(c.clarifyOptions[i], style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
          const Text('قل «الأول» أو «الثاني»', style: TextStyle(color: HC.textDim, fontSize: 16)),
        ];
      case Phase.sos:
        return [
          Text(c.sosCount > 0 ? 'سأرسل موقعك إلى ${c.sosTargets}' : 'جارٍ الإرسال…',
              textAlign: TextAlign.center,
              style: const TextStyle(color: HC.text, fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('قل «لا» أو المس الشاشة للإلغاء', style: TextStyle(color: HC.textDim, fontSize: 17)),
          const SizedBox(height: 14),
          const Text('رسالة SMS + رابط GPS · يعمل دون إنترنت', style: TextStyle(color: HC.textDim, fontSize: 14)),
        ];
      case Phase.setup:
        return [
          Text('الخطوة ${c.setupStep} من ${HadaqController.setupTotal}',
              style: const TextStyle(color: HC.textDim, fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: c.setupStep / HadaqController.setupTotal,
              minHeight: 6,
              backgroundColor: HC.card,
              color: HC.green,
            ),
          ),
          const SizedBox(height: 18),
          Text(c.setupQuestion,
              textAlign: TextAlign.center,
              style: TextStyle(color: HC.text, fontSize: fitFont(c.setupQuestion, 26), fontWeight: FontWeight.w800, height: 1.5)),
          if (c.heard.isNotEmpty) ...[
            const SizedBox(height: 16),
            _quote(c.heard, size: 24),
          ],
          const SizedBox(height: 16),
          const Text('قل «تخطَّ» لتجاوز السؤال', style: TextStyle(color: HC.textDim, fontSize: 15)),
        ];
      case Phase.update:
        return [
          const Text('يلزم تحديث حَدَق',
              style: TextStyle(color: HC.text, fontSize: 30, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Text(c.answer,
              textAlign: TextAlign.center,
              style: const TextStyle(color: HC.textDim, fontSize: 19, height: 1.6)),
          const SizedBox(height: 18),
          _card(
            child: const Text('المس الشاشة لفتح صفحة التحديث',
                textAlign: TextAlign.center,
                style: TextStyle(color: HC.text, fontSize: 21, fontWeight: FontWeight.w800)),
          ),
        ];
      case Phase.answer:
      case Phase.camera:
        return [
          if (c.answer.isNotEmpty) _answerCard(),
          if (c.answer.isEmpty && c.phase == Phase.camera)
            const Text('أنظر الآن…', style: TextStyle(color: HC.textDim, fontSize: 22)),
          if (c.suggestions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [for (final s in c.suggestions) _pill('«$s»')],
            ),
          ],
        ];
    }
  }

  Widget _answerCard() => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.visibility_outlined, size: 16, color: HC.textDim),
              const SizedBox(width: 6),
              Text(c.objectLabel ?? 'حَدَق يجيب', style: const TextStyle(color: HC.textDim, fontSize: 14)),
            ]),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.42),
              child: SingleChildScrollView(
                child: Text(c.answer,
                    style: TextStyle(color: HC.text, fontSize: fitFont(c.answer, 24), height: 1.5, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      );

  Widget _savedCard({String? title}) => Glass(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        radius: 20,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(title, style: const TextStyle(color: HC.text, fontSize: 18, fontWeight: FontWeight.w800)),
              ),
            for (final r in c.savedRows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  const Icon(Icons.check_circle, color: HC.green, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(r.label, style: const TextStyle(color: HC.textDim, fontSize: 13)),
                      Text(r.value, style: TextStyle(color: HC.text, fontSize: fitFont(r.value, 19), fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ]),
              ),
          ],
        ),
      );

  Widget _quote(String s, {double size = 26}) => Text('«$s»',
      textAlign: TextAlign.center,
      style: TextStyle(color: HC.text, fontSize: fitFont(s, size), fontWeight: FontWeight.w800, height: 1.4));

  Widget _pill(String s) => Glass(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        radius: 30,
        child: Text(s, style: const TextStyle(color: HC.text, fontSize: 16, fontWeight: FontWeight.w600)),
      );

  Widget _card({required Widget child}) => Glass(width: double.infinity, child: child);
}

class _TopBar extends StatelessWidget {
  final int memoryCount;
  final bool guiding;
  const _TopBar({required this.memoryCount, required this.guiding});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          const Text('حَدَق', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: Colors.white)),
          const Spacer(),
          if (guiding) ...[_chip(Icons.navigation_rounded, 'إرشاد'), const SizedBox(width: 6)],
          _chip(Icons.lock_outline_rounded, 'محلي'),
          const SizedBox(width: 6),
          _chip(Icons.memory_rounded, 'ذاكرة $memoryCount'),
        ],
      ),
    );
  }

  Widget _chip(IconData i, String t) => Glass(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        radius: 20,
        child: Row(children: [
          Icon(i, size: 14, color: HC.textDim),
          const SizedBox(width: 4),
          Text(t, style: const TextStyle(fontSize: 13, color: HC.textDim)),
        ]),
      );
}

class _StatusChip extends StatelessWidget {
  final Phase phase;
  const _StatusChip({required this.phase});

  @override
  Widget build(BuildContext context) {
    final (String? label, Color color) = switch (phase) {
      Phase.idle => (null, HC.blue),
      Phase.listening => ('أستمع إليك…', HC.red),
      Phase.thinking => ('أفكّر…', HC.purple),
      Phase.answer => ('سؤال · إجابة', HC.purple),
      Phase.saved => ('إعداد · حُفظ في الذاكرة', HC.green),
      Phase.camera => ('طلب · الكاميرا', HC.blue),
      Phase.memory => ('ذاكرتي', HC.purple),
      Phase.clarify => ('لم أتأكد بعد', HC.amber),
      Phase.sos => ('الطوارئ', HC.red),
      Phase.update => ('تحديث مطلوب', HC.amber),
      Phase.setup => ('الإعداد', HC.green),
    };
    if (label == null) return const SizedBox(height: 0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(30)),
      child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
    );
  }
}

/// Bottom-edge SOS zone: long press = emergency.
class _SosBar extends StatelessWidget {
  final HadaqController c;
  const _SosBar({required this.c});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'طوارئ. اضغط مطوّلًا لإرسال موقعك لجهات الطوارئ',
      onLongPress: c.triggerSos,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () {
          SemanticsService.sendAnnouncement(View.of(context), 'طوارئ', TextDirection.rtl);
          c.triggerSos();
        },
        onTap: c.phase == Phase.sos ? c.cancelSos : c.onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Glass(
            tint: HC.red,
            radius: 22,
            padding: EdgeInsets.zero,
            child: const SizedBox(
              height: 64,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.warning_amber_rounded, color: Color(0xFFFFD2D4)),
                  SizedBox(width: 8),
                  Text('الطوارئ · اضغط مطوّلًا هنا',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Deep navy background with three soft colour glows, so the glass cards have
/// something to blur and read as glass.
class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) {
    Widget glow(Color c, double size) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [c.withValues(alpha: 0.55), c.withValues(alpha: 0)]),
          ),
        );
    return Positioned.fill(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [HC.bgTop, HC.bgBottom]),
        ),
        child: Stack(children: [
          Positioned(top: -120, right: -100, child: glow(HC.blue, 380)),
          Positioned(top: 260, left: -140, child: glow(HC.purple, 360)),
          Positioned(bottom: -80, right: -60, child: glow(const Color(0xFF1FB6C9), 300)),
        ]),
      ),
    );
  }
}
