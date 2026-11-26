import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/arabic.dart';
import '../core/intent.dart';
import '../core/apps.dart';
import '../core/messaging.dart';
import '../core/setup_answers.dart';
import '../services/assistant.dart';
import '../services/backend.dart';
import '../services/datasync.dart';
import '../services/device.dart';
import '../services/feedback.dart';
import '../services/location.dart';
import '../services/memory.dart';
import '../services/navigator.dart';
import '../services/phone.dart';
import '../services/voice.dart';

/// The single screen's states (design pages 5–6).
enum Phase { idle, listening, thinking, answer, saved, camera, memory, clarify, sos, update, setup }

/// A row shown on the "saved" card, e.g. («سرعة الصوت», «أبطأ (×0.8)»).
typedef MemRow = ({String label, String value});

/// A question waiting for «نعم / لا».
class _Pending {
  final String kind; // 'guide' | 'wipe' | 'followup'
  final Object? data;
  const _Pending(this.kind, [this.data]);
}

/// A message waiting for «نعم».
class _Draft {
  final String name, number, text, channel; // channel: 'whatsapp' | 'sms'
  const _Draft(this.name, this.number, this.text, this.channel);
}

/// Built for Google Play (`--dart-define=PLAY=true`): no SMS permission there.
const _playBuild = bool.fromEnvironment('PLAY');

class HadaqController extends ChangeNotifier {
  final voice = VoiceService();
  final memory = MemoryStore();
  final backend = BackendService();
  late final assistant = AssistantService()..backend = backend;
  late final sync = DataSync(backend, memory);
  Timer? _locTimer;
  final location = LocationService();
  final camera = CameraService();
  final phone = PhoneService();
  final fx = FeedbackService();
  final _shake = ShakeDetector();

  // ---- What the screen shows ----
  Phase phase = Phase.idle;
  String heard = '';
  String answer = '';
  String? objectLabel; // chip above the answer, e.g. «علبة دواء»
  List<String> suggestions = [];
  List<MemRow> savedRows = [];
  List<String> clarifyOptions = [];
  int sosCount = 0;
  String sosTargets = '';
  bool ready = false;
  bool guiding = false;

  String get greeting {
    final h = DateTime.now().hour;
    final part = h < 12 ? 'صباح الخير' : 'مساء الخير';
    final n = memory.data.name;
    return n == null ? part : '$part يا $n';
  }

  int get memoryCount => demoMode ? 12 : memory.data.itemCount;

  // ---- Conversation state ----
  String _lastSpoken = '';
  _Pending? _pending;
  List<SettingChange> _clarifySettings = [];
  Uint8List? _lastImage;
  DateTime _lastImageAt = DateTime(2000);
  final List<(String, String)> _history = [];
  NearbyPlace? _lastTarget;
  WalkGuide? _guide;
  List<ContactMatch> _callChoices = [];
  _Draft? _sentDraft;
  bool _choosingPlace = false;
  double? _heading; // compass, degrees from north (null if the phone has no compass)
  StreamSubscription<CompassEvent>? _compassSub;

  /// Walking limits for the «far → take a car» advice (straight-line metres).
  static const _walkEasy = 1500.0;
  static const _walkMax = 3000.0;
  List<NearbyPlace> _results = [];
  Map<String, String> _resultNotes = {};
  int _resultIdx = 0;
  String _lastQuery = '';
  StreamSubscription<Position>? _guideSub;
  String? _queuedQuestion;
  Timer? _netRetry;
  bool _busy = false;
  bool _sosCancelled = false;

  // ================= Lifecycle =================

  Future<void> init() async {
    await memory.load();
    fx.strongVibration = memory.data.strongVibration;
    // Each platform piece is optional so the app still runs on web / emulators.
    try {
      await voice.init(rateMultiplier: memory.data.speechRate);
    } catch (_) {}
    // Explain the microphone window by voice before it appears.
    try {
      if (!(await Permission.microphone.status).isGranted && !demoMode) {
        await voice.speak('أحتاج الميكروفون لأسمعك. اضغط: سماح.');
        await Permission.microphone.request();
      }
    } catch (_) {}
    NativeBridge.onVolumeUp(onTap);
    NativeBridge.onWhatsAppSent((ok) {
      final d = _sentDraft;
      _sentDraft = null;
      if (d == null) return;
      fx.cue(ok ? Cue.saved : Cue.error);
      _say(ok ? 'أرسلت رسالتك إلى ${d.name} على واتساب.' : 'لم أتمكن من ضغط زر الإرسال. الرسالة مكتوبة في واتساب، اضغط إرسال.',
          phase: Phase.answer);
    });
    try {
      _compassSub = FlutterCompass.events?.listen((e) {
        final h = e.heading;
        if (h != null) _heading = (h + 360) % 360;
      });
    } catch (_) {}
    try {
      _shake.start(triggerSos);
    } catch (_) {}
    ready = true;
    final cfg = await backend.hello();
    // GPT voice for replies (streamed from the server); the phone's voice otherwise.
    if (cfg.ttsEngine == 'openai' && backend.enabled && !kIsWeb) {
      final id = await backend.id();
      voice.cloudUrl = (t) => '${BackendService.baseUrl}/api/tts.mp3?d=$id&t=${Uri.encodeQueryComponent(t)}';
    }
    if (cfg.forceUpdate) return _showForceUpdate();
    if (demoMode) {
      notifyListeners();
      return; // no greeting in the screen gallery
    }
    notifyListeners();
    memory.onChange = sync.profileChanged;
    sync.start();
    _locTimer = Timer.periodic(const Duration(minutes: 5), (_) => _pingLocation());
    unawaited(_pingLocation());
    if (!memory.data.onboarded) {
      await runSetup();
      return;
    }
    if (memory.data.shareData == null && backend.enabled) await _askConsent();
    final hint = memoryCount == 0 ? 'المس الشاشة وتحدّث.' : '';
    await _say('$greeting. كيف أساعدك؟ $hint', phase: Phase.idle, show: false);
    if (cfg.maintenance && cfg.maintenanceMessage.isNotEmpty) await voice.speak(cfg.maintenanceMessage);
    final ann = await backend.newAnnouncement();
    if (ann != null) await voice.speak(ann);
    if (cfg.updateAvailable) await voice.speak('يتوفر تحديث جديد لحدق، الإصدار ${cfg.latestVersion}.');
  }

  // ================= Force update (from the admin dashboard) =================

  Future<void> _showForceUpdate() async {
    phase = Phase.update;
    answer = backend.config.updateMessage;
    notifyListeners();
    await voice.speak('$answer المس الشاشة لفتح صفحة التحديث. ويبقى زر الطوارئ يعمل.');
  }

  Future<void> openUpdate() async {
    final url = backend.config.updateUrl;
    if (url.isEmpty) {
      await voice.speak('رابط التحديث غير متوفر بعد. حدّث التطبيق من المتجر.');
      return;
    }
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// Returns a spoken reason if the dashboard switched this feature off.
  String? _featureOff(IntentType t) {
    final c = backend.config;
    if (c.maintenance && const {IntentType.question, IntentType.vision, IntentType.nearby}.contains(t)) {
      return c.maintenanceMessage;
    }
    return switch (t) {
      IntentType.question when !c.assistant => 'المساعد الذكي متوقف مؤقتًا.',
      IntentType.vision when !c.vision || !c.assistant => 'أسئلة الكاميرا متوقفة مؤقتًا.',
      IntentType.nearby || IntentType.startGuidance || IntentType.savedPlace when !c.navigation =>
        'الإرشاد متوقف مؤقتًا.',
      _ => null,
    };
  }

  @override
  void dispose() {
    _shake.stop();
    _locTimer?.cancel();
    sync.stop();
    _compassSub?.cancel();
    _guideSub?.cancel();
    _netRetry?.cancel();
    fx.stopThinking();
    camera.close();
    super.dispose();
  }

  // ================= Demo (screen gallery for web / presentations) =================

  /// True in the web screen gallery: `flutter run -d chrome` or --dart-define=DEMO=true.
  bool demoMode = false;

  /// Fills the screen with the design's sample content for [p], without speaking.
  void showDemo(Phase p) {
    fx.stopThinking();
    heard = '';
    answer = '';
    objectLabel = null;
    suggestions = [];
    savedRows = [];
    clarifyOptions = [];
    sosCount = 0;
    switch (p) {
      case Phase.idle:
        break;
      case Phase.listening:
        heard = 'ما هو أقرب مسجد، وكم يبعد عني؟';
      case Phase.thinking:
        heard = 'ما هو أقرب مسجد، وكم يبعد عني؟';
      case Phase.answer:
        heard = 'ما هو أقرب مسجد، وكم يبعد عني؟';
        answer = 'أقرب مسجد: مسجد الرحمة، على بعد 240 مترًا شمالًا. الطريق آمن، وفيه إشارة مرور بعد 120 مترًا. هل أبدأ الإرشاد؟';
        suggestions = const ['نعم، ابدأ', 'كرّر', 'أبطئ'];
      case Phase.saved:
        heard = 'اجعل صوتك أبطأ، وناديني أبا خالد';
        savedRows = const [(label: 'سرعة الصوت', value: 'أبطأ (×0.8)'), (label: 'الاسم المفضّل', value: 'أبو خالد')];
        answer = 'تم يا أبا خالد. صوت أبطأ، وسأتذكر ذلك دائمًا. للتراجع قل: تراجع.';
      case Phase.camera:
        heard = 'ما هذا الذي في يدي؟';
        objectLabel = 'علبة دواء · 96%';
        answer = 'هذه علبة باراسيتامول 500 ملغ. صالحة حتى 03/2027. هل أقرأ لك النشرة؟';
        suggestions = const ['اقرأ النشرة', 'لا شكرًا'];
      case Phase.memory:
        heard = 'ماذا تتذكر عني؟';
        savedRows = const [
          (label: 'سرعة الصوت', value: 'أبطأ'),
          (label: 'الاسم', value: 'أبو خالد'),
          (label: 'الاهتزاز', value: 'قوي عند الخطر'),
          (label: 'جهة طوارئ', value: 'أمي'),
          (label: 'متطوع وصديق', value: 'محمد'),
          (label: 'مكان', value: 'البيت · حي الروضة'),
          (label: 'مكان', value: 'صيدلية الحي · المفضّلة'),
        ];
      case Phase.clarify:
        heard = 'اجعله أعلى';
        clarifyOptions = const ['رفع مستوى الصوت', 'رفع قوة الاهتزاز'];
      case Phase.sos:
        heard = 'النجدة!';
        sosCount = 5;
        sosTargets = 'أمي ومحمد';
      case Phase.update:
        answer = 'يتوفر إصدار جديد من حدق فيه تحسينات مهمة. حدّث التطبيق للمتابعة.';
      case Phase.setup:
        setupStep = 4;
        setupQuestion = 'من الشخص الذي أراسله في الطوارئ إذا احتجت مساعدة؟ قل اسمه أو رقمه.';
        heard = 'أمي';
    }
    phase = p;
    notifyListeners();
  }

  // ================= Gestures =================

  /// One tap anywhere = talk. Tap during SOS = cancel. Tap while listening = finish.
  Future<void> onTap() async {
    if (inSetup && phase != Phase.sos) {
      if (voice.isListening) await voice.cancelListening();
      return;
    }
    if (phase == Phase.sos) return cancelSos();
    if (phase == Phase.update) return openUpdate();
    if (phase == Phase.listening) {
      await voice.cancelListening();
      return;
    }
    if (_busy) return;
    await voice.stopSpeaking();
    await _listenAndHandle();
  }

  /// Two taps = repeat the last answer.
  Future<void> onDoubleTap() async {
    if (_lastSpoken.isEmpty) return;
    await voice.speak(_lastSpoken);
  }

  Future<void> _listenAndHandle() async {
    _busy = true;
    try {
      phase = Phase.listening;
      heard = '';
      notifyListeners();
      await fx.cue(Cue.listen);
      await Future.delayed(const Duration(milliseconds: 250)); // don't record our own beep
      if (!voice.sttReady) {
        await _say('لا يتوفر التعرف على الكلام في هذا الجهاز. ثبّت خدمة Google للتعرف على الكلام بالعربية.',
            phase: Phase.answer);
        return;
      }
      final text = await _hear();
      heard = text;
      if (text.trim().isEmpty) {
        await fx.cue(Cue.error);
        await _say('لم أسمع.', phase: Phase.idle, show: false);
        return;
      }
      fx.startThinking(); // keeps ticking until the reply starts (_say stops it)
      await handle(text);
    } finally {
      fx.stopThinking();
      _busy = false;
    }
  }

  // ================= Routing =================

  Future<void> handle(String text) async {
    heard = text;
    final places = memory.data.places.map((p) => p.name);
    final intent = IntentClassifier(savedPlaceNames: places).classify(text);
    debugPrint('[hadaq] "$text" -> $intent'); // local logcat only, for diagnosing recognition

    sync.logTurn(text, intent.type.name);
    if (intent.type != IntentType.unclear) fx.cue(Cue.understood);
    final off = _featureOff(intent.type);
    if (off != null) return await _say(off, phase: Phase.answer);

    switch (intent.type) {
      case IntentType.emergency:
        return triggerSos();
      case IntentType.repeat:
        return onDoubleTap();
      case IntentType.stop:
        await voice.stopSpeaking();
        phase = Phase.idle;
        notifyListeners();
        return;
      case IntentType.yes:
        return _onYes(text);
      case IntentType.no:
        _pending = null;
        return await _say('حسنًا.', phase: Phase.idle, show: false);
      case IntentType.choiceFirst:
      case IntentType.choiceSecond:
      case IntentType.choiceThird:
        return _onChoice(intent.type == IntentType.choiceFirst
            ? 0
            : intent.type == IntentType.choiceSecond
                ? 1
                : 2);
      case IntentType.ride:
        return _ride(intent.arg, destName: intent.options.firstOrNull);
      case IntentType.walkAnyway:
        final t = (_pending?.data is NearbyPlace ? _pending!.data as NearbyPlace : null) ?? _lastTarget;
        _pending = null;
        if (t == null) return await _say('إلى أين؟ قل مثلًا: أين أقرب صيدلية؟', phase: Phase.answer);
        return _startGuidance(t, force: true);
      case IntentType.undo:
        return _undo();
      case IntentType.setting:
        return _applySettings(intent.settings);
      case IntentType.memoryShow:
        return _showMemory();
      case IntentType.memoryForget:
        return _forget(intent.arg ?? '');
      case IntentType.memoryWipe:
        _pending = const _Pending('wipe');
        return await _say('هل تريد أن أمسح كل ما أتذكره عنك؟ قل نعم أو لا.', phase: Phase.answer);
      case IntentType.vision:
        return _visionAsked(text);
      case IntentType.nearby:
        return _nearby(intent.arg!);
      case IntentType.whereAmI:
        return _whereAmI();
      case IntentType.savedPlace:
        return _toSavedPlace(intent.arg!);
      case IntentType.startGuidance:
        if (intent.options.contains('gmaps')) return _openGoogleMaps(intent.arg);
        return _startGuidanceFromText(intent.arg);
      case IntentType.remaining:
        return _remaining();
      case IntentType.nextResult:
        return _nextResult();
      case IntentType.call:
        return _call(intent.arg ?? '', service: intent.options.firstOrNull);
      case IntentType.setup:
        return runSetup();
      case IntentType.message:
        return _message(intent.arg ?? '', intent.options.isNotEmpty ? intent.options.first : 'whatsapp',
            textOnly: intent.options.contains('textOnly'));
      case IntentType.enableAutoSend:
        return _enableAutoSend();
      case IntentType.openApp:
        return _openApp(intent.arg ?? '');
      case IntentType.dataWithdraw:
        await sync.setConsent(false);
        await fx.cue(Cue.saved);
        return await _say('أوقفت مشاركة بياناتك وحذفت ما كان محفوظًا منها على الخادم. ذاكرتك على جوالك لم تُمس.',
            phase: Phase.answer);
      case IntentType.dataShare:
        await sync.setConsent(true);
        await fx.cue(Cue.saved);
        return await _say('شكرًا. سأشارك فريق حدق بمحادثاتك وموقعك أثناء الاستخدام. وللإيقاف قل: احذف بياناتي.',
            phase: Phase.answer);
      case IntentType.stopGuidance:
        _stopGuidance();
        return await _say('أوقفت الإرشاد.', phase: Phase.answer);
      case IntentType.question:
        return _question(text);
      case IntentType.unclear:
        if (intent.options.length == 2) return _clarify(intent.options, intent.settings);
        await fx.cue(Cue.error);
        return await _say('لم أفهم جيدًا. أعد قولها بطريقة أخرى.', phase: Phase.answer);
    }
  }

  bool get _imageFresh =>
      _lastImage != null && DateTime.now().difference(_lastImageAt) < const Duration(minutes: 2);

  // ================= Assistant (questions) =================

  String _userContext() {
    final d = memory.data;
    final parts = <String>[
      if (d.name != null) 'يحب أن يُنادى: ${d.name}',
      if (d.places.isNotEmpty) 'أماكنه المحفوظة: ${d.places.map((p) => p.name).join('، ')}',
    ];
    return parts.join('. ');
  }

  Future<void> _question(String text) async {
    _thinking();
    AssistantReply r;
    try {
      // actions: the assistant may answer with something to DO (call, message, camera…)
      // for requests the rules above didn't recognise, instead of «لا يمكنني».
      r = await assistant.ask(text, userContext: _userContext(), history: _history, actions: true);
    } on OfflineException {
      fx.stopThinking();
      return _queueOffline(text);
    }
    fx.stopThinking();
    final a = r.action;
    if (a != null) {
      debugPrint('[hadaq] assistant action: $a');
      if (await _runAction(a, text)) return;
    }
    _remember(text, r.answer);
    await _reply(r);
  }

  /// Carries out an action the assistant chose. false = not something the app can do.
  Future<bool> _runAction(Map<String, dynamic> a, String text) async {
    String s(String k) => '${a[k] ?? ''}'.trim();
    switch (a['type']) {
      case 'call':
        await _call(s('who'));
      case 'emergency_call':
        await _call('__emergency__', service: s('service').isEmpty ? null : normalizeAr(s('service')).replaceFirst('ال', ''));
      case 'message':
        final who = s('who'), msg = s('text');
        final channel = s('channel') == 'sms' ? 'sms' : 'whatsapp';
        if (who.isEmpty) {
          await _message(msg, channel, textOnly: true);
        } else {
          await _message(msg.isEmpty ? who : '$who قل له $msg', channel);
        }
      case 'open_app':
        if (s('app').isEmpty) return false;
        await _openApp(s('app'));
      case 'places':
        if (s('place').isEmpty) return false;
        if (a['go'] == true) {
          await _startGuidanceFromText(s('place'));
        } else {
          await _nearby(s('place'));
        }
      case 'maps':
        await _openGoogleMaps(s('place').isEmpty ? null : s('place'));
      case 'ride':
        final app = normalizeAr(s('app'));
        final key = app.contains('كريم') || app.contains('careem')
            ? 'careem'
            : app.contains('بولت') || app.contains('bolt')
                ? 'bolt'
                : app.contains('جيني')
                    ? 'jeeny'
                    : app.contains('وصلني')
                        ? 'wasalni'
                        : null;
        await _ride(key, destName: s('place').isEmpty ? null : s('place'));
      case 'camera':
        final ok = await _confirm('أفتح الكاميرا وأصوّر ما أمامك؟');
        if (ok == true) {
          await _vision(s('question').isEmpty ? text : s('question'));
        } else {
          await _say('حسنًا.', phase: Phase.answer);
        }
      case 'memory':
        await _showMemory();
      case 'where_am_i':
        await _whereAmI();
      default:
        return false;
    }
    return true;
  }

  Future<void> _vision(String text, {bool reuseImage = false}) async {
    Uint8List? img = reuseImage && _imageFresh ? _lastImage : null;
    if (img == null) {
      phase = Phase.camera;
      objectLabel = null;
      answer = '';
      notifyListeners();
      final ok = await camera.open();
      notifyListeners();
      if (!ok) {
        await camera.close();
        return await _say('لم أستطع فتح الكاميرا. تأكد من السماح لحدق باستخدامها.', phase: Phase.answer);
      }
      try {
        img = await camera.capture();
      } finally {
        await camera.close(); // camera is never left on
        notifyListeners();
      }
      if (img == null) return await _say('لم ألتقط صورة واضحة. حاول مرة أخرى.', phase: Phase.answer);
      _lastImage = img;
      _lastImageAt = DateTime.now();
    }
    _thinking(keepPhase: Phase.camera);
    try {
      final r = await assistant.ask(text, imageJpeg: img, history: _history);
      _remember(text, r.answer);
      objectLabel = r.label;
      if (r.suggestions.isNotEmpty) _pending = _Pending('followup', r.suggestions.first);
      await _reply(r, phase: Phase.camera);
    } on OfflineException {
      _queueOffline(text);
    } finally {
      fx.stopThinking();
    }
  }

  void _remember(String q, String a) {
    _history.add((q, a));
    if (_history.length > 6) _history.removeAt(0);
  }

  Future<void> _reply(AssistantReply r, {Phase phase = Phase.answer}) async {
    suggestions = r.suggestions;
    await _say(r.answer, phase: phase);
  }

  void _queueOffline(String text) {
    _queuedQuestion = text;
    _say('هذا السؤال يحتاج إنترنت، وسأجيب عنه عند عودته.', phase: Phase.answer);
    _netRetry?.cancel();
    _netRetry = Timer.periodic(const Duration(seconds: 20), (t) async {
      try {
        final r = await InternetAddress.lookup('generativelanguage.googleapis.com');
        if (r.isEmpty || _queuedQuestion == null || _busy || phase == Phase.sos) return;
        t.cancel();
        final q = _queuedQuestion!;
        _queuedQuestion = null;
        await _say('عاد الاتصال. بخصوص سؤالك: $q', phase: Phase.thinking);
        await _question(q);
      } catch (_) {}
    });
  }

  // ================= Yes / choices =================

  Future<void> _onYes(String text) async {
    final p = _pending;
    _pending = null;
    if (p == null) return await _say('حسنًا.', phase: Phase.idle, show: false);
    switch (p.kind) {
      case 'guide':
        return _startGuidance(p.data as NearbyPlace);
      case 'sendMsg':
        return _sendDraft(p.data as _Draft);
      case 'smsInstead':
        final d = p.data as _Draft;
        return _sendDraft(_Draft(d.name, d.number, d.text, 'sms'));
      case 'ride':
        return _ride(null, target: p.data as NearbyPlace);
      case 'farChoice':
        _pending = p;
        return await _say('قل: امشيني، أو: اطلب سيارة.', phase: Phase.answer);
      case 'wipe':
        await memory.wipe();
        await _applyVoiceSettings();
        await fx.cue(Cue.saved);
        return await _say('مسحت ذاكرتي بالكامل. لم أعد أتذكر شيئًا عنك.', phase: Phase.answer);
      case 'followup':
        final q = normalizeAr(text).length > 6 ? text : (p.data as String);
        return _imageFresh ? _vision(q, reuseImage: true) : _question(q);
    }
  }

  Future<void> _clarify(List<String> options, List<SettingChange> settings) async {
    clarifyOptions = options;
    _clarifySettings = settings;
    await fx.cue(Cue.error);
    await _say('هل تقصد ${options[0]}، أم ${options[1]}؟ قل الأول أو الثاني.', phase: Phase.clarify, show: false);
  }

  Future<void> _onChoice(int i) async {
    if (_choosingPlace && _results.length > i) return _announcePlace(i);
    if (_callChoices.length > i) {
      final m = _callChoices[i];
      _callChoices = [];
      clarifyOptions = [];
      return _placeCall(m.name, m.number);
    }
    if (_clarifySettings.length > i) {
      final s = _clarifySettings[i];
      _clarifySettings = [];
      clarifyOptions = [];
      return _applySettings([s]);
    }
    // «الأول/الثاني» as an answer to a list of suggestions.
    if (suggestions.length > i) return handle(suggestions[i]);
    return await _say('لا توجد خيارات الآن.', phase: Phase.answer);
  }

  // ================= Settings & memory =================

  Future<void> _applySettings(List<SettingChange> changes) async {
    final rows = <MemRow>[];
    final spoken = <String>[];
    var saved = false;
    Position? pos;

    for (final c in changes) {
      switch (c.key) {
        case SettingKey.volume:
          await _adjustSystemVolume(c.value == 'up');
          spoken.add(c.value == 'up' ? 'رفعت الصوت' : 'خفضت الصوت');
          rows.add((label: 'مستوى الصوت', value: c.value == 'up' ? 'أعلى' : 'أخفض'));
        case SettingKey.place:
          pos ??= await location.current();
          if (pos == null) {
            spoken.add('لم أستطع تحديد موقعك لحفظه');
            continue;
          }
          final p = pos;
          final name = c.value as String;
          await memory.update((d) {
            d.places.removeWhere((x) => normalizeAr(x.name) == normalizeAr(name));
            d.places.add(Place(name, p.latitude, p.longitude));
          });
          saved = true;
          rows.add((label: 'مكان محفوظ', value: name));
          spoken.add('حفظت هذا المكان باسم $name');
        case SettingKey.contact:
          final m = c.value as Map;
          var number = m['phone'] as String?;
          var cname = '${m['name']}';
          if (number == null) {
            final found = await phone.find(cname);
            if (found.isEmpty) {
              spoken.add('لم أجد $cname في جهات اتصالك. قل مثلًا: أضف $cname جهة طوارئ رقمها، ثم الرقم');
              continue;
            }
            number = found.first.number;
            if (normalizeAr(found.first.name) != normalizeAr(cname)) cname = '$cname (${found.first.name})';
          }
          final person = Person(cname, number);
          await memory.update((d) {
            d.people.removeWhere((x) => x.phone == person.phone);
            d.people.add(person);
          });
          saved = true;
          rows.add((label: 'جهة طوارئ', value: '${person.name} · ${person.phone}'));
          spoken.add('أضفت ${person.name}، الرقم المنتهي بـ ${PhoneService.tail(person.phone)}، إلى جهات الطوارئ');
          await NativeBridge.ensureSmsPermission();
        default:
          await memory.update((d) {
            switch (c.key) {
              case SettingKey.speechRate:
                d.speechRate = switch (c.value) {
                  'slower' => (d.speechRate * 0.8).clamp(0.5, 2.0),
                  'faster' => (d.speechRate * 1.25).clamp(0.5, 2.0),
                  _ => 1.0,
                };
              case SettingKey.vibration:
                d.strongVibration = c.value == 'stronger';
              case SettingKey.name:
                d.name = c.value as String;
            }
          });
          saved = true;
          switch (c.key) {
            case SettingKey.speechRate:
              final r = memory.data.speechRate;
              final slower = c.value == 'slower';
              final rs = r.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
              rows.add((label: 'سرعة الصوت', value: '${slower ? 'أبطأ' : 'أسرع'} (×$rs)'));
              spoken.add(slower ? 'صوت أبطأ' : 'صوت أسرع');
            case SettingKey.vibration:
              rows.add((label: 'الاهتزاز', value: memory.data.strongVibration ? 'قوي' : 'خفيف'));
              spoken.add(memory.data.strongVibration ? 'اهتزاز أقوى' : 'اهتزاز أخف');
            case SettingKey.name:
              rows.add((label: 'الاسم المفضّل', value: '${c.value}'));
          }
      }
    }

    await _applyVoiceSettings();
    savedRows = rows;
    if (saved) await fx.cue(Cue.saved);
    final n = memory.data.name;
    final head = n != null ? 'تم يا $n.' : 'تم.';
    final body = spoken.isEmpty ? '' : ' ${spoken.join('، ')}.';
    final tail = saved ? ' سأتذكر ذلك دائمًا. للتراجع قل: تراجع.' : '';
    await _say('$head$body$tail', phase: saved ? Phase.saved : Phase.answer);
  }

  Future<void> _applyVoiceSettings() async {
    fx.strongVibration = memory.data.strongVibration;
    await voice.applySettings(rateMultiplier: memory.data.speechRate, volume: 1.0);
  }

  Future<void> _adjustSystemVolume(bool up) async {
    try {
      await const MethodChannel('hadaq/native').invokeMethod('adjustVolume', {'up': up});
    } catch (_) {}
  }

  Future<void> _undo() async {
    if (!await memory.undo()) {
      return await _say('لا يوجد تغيير أتراجع عنه.', phase: Phase.answer);
    }
    await _applyVoiceSettings();
    await fx.cue(Cue.saved);
    await _say('تراجعت عن آخر تغيير.', phase: Phase.answer);
  }

  /// Screenshot/testing only: shows [t] as the current answer.
  void demoAnswer(String t) {
    answer = t;
    notifyListeners();
  }

  Future<void> _showMemory() async {
    final d = memory.data;
    final rows = <MemRow>[
      (label: 'سرعة الصوت', value: d.speechRate < 1 ? 'أبطأ' : (d.speechRate > 1 ? 'أسرع' : 'عادية')),
      if (d.name != null) (label: 'الاسم', value: d.name!),
      (label: 'الاهتزاز', value: d.strongVibration ? 'قوي عند الخطر' : 'عادي'),
      for (final p in d.people) (label: p.role == 'emergency' ? 'جهة طوارئ' : 'شخص', value: '${p.name} · ${p.phone}'),
      for (final p in d.places) (label: 'مكان', value: p.name),
    ];
    savedRows = rows;
    final spoken = StringBuffer('أتذكر ${d.itemCount} عناصر. ');
    if (d.name != null) spoken.write('اسمك ${d.name}. ');
    if (d.speechRate != 1) spoken.write('تفضّل صوتًا ${d.speechRate < 1 ? 'أبطأ' : 'أسرع'}. ');
    if (d.people.isNotEmpty) spoken.write('جهات الطوارئ: ${d.people.map((p) => p.name).join('، ')}. ');
    if (d.places.isNotEmpty) spoken.write('أماكنك: ${d.places.map((p) => p.name).join('، ')}. ');
    if (d.itemCount == 0) {
      spoken
        ..clear()
        ..write('لا أتذكر شيئًا عنك بعد. قل مثلًا: ناديني أبا خالد، أو: احفظ هذا المكان باسم البيت. ');
    }
    spoken.write('للحذف قل: انسَ اسمي، وللمسح الكامل قل: امسح ذاكرتك.');
    await _say(spoken.toString(), phase: Phase.memory);
  }

  Future<void> _forget(String what) async {
    final w = normalizeAr(what);
    final d = memory.data;
    String? done;
    if (hasAny(w, ['اسمي', 'الاسم'])) {
      if (d.name != null) {
        await memory.update((m) => m.name = null);
        done = 'نسيت اسمك';
      }
    } else if (hasAny(w, ['سرعه', 'السرعه'])) {
      await memory.update((m) => m.speechRate = 1.0);
      done = 'أعدت سرعة الصوت إلى الطبيعية';
    } else {
      final place = d.places.where((p) => w.contains(normalizeAr(p.name))).firstOrNull;
      final person = d.people.where((p) => w.contains(normalizeAr(p.name))).firstOrNull;
      if (place != null) {
        await memory.update((m) => m.places.removeWhere((x) => x.name == place.name));
        done = 'حذفت ${place.name} من أماكنك';
      } else if (person != null) {
        await memory.update((m) => m.people.removeWhere((x) => x.phone == person.phone));
        done = 'حذفت ${person.name}';
      }
    }
    if (done == null) return await _say('لم أجد هذا في ذاكرتي.', phase: Phase.answer);
    await _applyVoiceSettings();
    await fx.cue(Cue.saved);
    await _say('$done. للتراجع قل: تراجع.', phase: Phase.answer);
  }

  // ================= Location & guidance =================

  /// «وين أقرب محل شاورما» — searches any place (server: Google/OSM), reads the
  /// nearest, and keeps the others for «التالي». With [go] it starts guidance at once.
  Future<void> _nearby(String query, {bool go = false}) async {
    _thinking();
    try {
      final pos = await location.current();
      if (pos == null) {
        return await _say('لا أستطيع تحديد موقعك. فعّل خدمة الموقع واسمح لحدق باستخدامه.', phase: Phase.answer);
      }
      var results = <NearbyPlace>[];
      if (backend.enabled) {
        try {
          final found = await backend.searchPlaces(query, pos.latitude, pos.longitude);
          results = [for (final f in found) NearbyPlace(f.name, f.lat, f.lon, f.distance, f.bearing)];
          _resultNotes = {for (final f in found) f.name: _placeNote(f)};
        } on BackendError catch (e) {
          return await _say(e.message, phase: Phase.answer);
        }
      } else {
        // Standalone build: fixed categories via OpenStreetMap.
        final key = nearbyCategories.keys.where((k) => normalizeAr(query).contains(k)).firstOrNull;
        final p = key == null ? null : await location.nearest(nearbyCategories[key]!, pos);
        if (p != null) results = [p];
      }
      if (results.isEmpty) {
        return await _say('لم أجد $query قريبًا منك. جرّب كلمة أخرى، أو اسم المحل نفسه.', phase: Phase.answer);
      }
      _results = results;
      _resultIdx = 0;
      _lastQuery = query;
      if (go) {
        fx.stopThinking();
        final p = results.first;
        await _say('أقرب $query: ${p.name}، على بعد ${formatDistance(p.distance)}.', phase: Phase.answer);
        return await _startGuidance(p);
      }
      await _announceResult();
    } on OfflineException {
      await _say('البحث عن الأماكن يحتاج إنترنت.', phase: Phase.answer);
    } catch (_) {
      await _say('تعذّر البحث الآن. حاول بعد قليل.', phase: Phase.answer);
    } finally {
      fx.stopThinking();
    }
  }

  String _placeNote(PlaceResult f) => [
        if (f.address.isNotEmpty) 'في ${f.address}',
        if (f.openNow == true) 'مفتوح الآن',
        if (f.openNow == false) 'مغلق الآن',
      ].join('، ');

  static const _ordinals = ['الأول', 'الثاني', 'الثالث'];

  /// «وجدت 3 أماكن: الأول … 450 مترًا على يمينك …» — or straight to details if only one.
  Future<void> _announceResult() async {
    final list = _results.take(3).toList();
    if (list.length == 1) return _announcePlace(0);
    _choosingPlace = true;
    _pending = null;
    final parts = [
      for (var i = 0; i < list.length; i++)
        '${_ordinals[i]} ${list[i].name}، ${formatDistance(list[i].distance)} ${directionFrom(list[i].bearing, _heading)}',
    ];
    suggestions = [for (var i = 0; i < list.length; i++) _ordinals[i]];
    await _say(
      '${parts.join('. ')}. أيّها؟',
      phase: Phase.answer,
    );
  }

  /// Details for one place, then the right next step for its distance:
  /// walk (near), ask walk-or-car (medium), or advise a car (far).
  Future<void> _announcePlace(int i) async {
    _choosingPlace = false;
    _resultIdx = i;
    final p = _results[i];
    _lastTarget = p;
    final note = _resultNotes[p.name] ?? '';
    final base = '${p.name}، ${formatDistance(p.distance)} ${directionFrom(p.bearing, _heading)}'
        '${note.isNotEmpty ? '، $note' : ''}، ${walkingTime(p.distance)}.';
    if (p.distance <= _walkEasy) {
      _pending = _Pending('guide', p);
      suggestions = const ['نعم، ابدأ', 'التالي', 'كرّر'];
      return await _say('$base أبدأ الإرشاد؟', phase: Phase.answer);
    }
    if (p.distance <= _walkMax) {
      _pending = _Pending('farChoice', p);
      suggestions = const ['امشيني', 'اطلب سيارة'];
      return await _say('$base المشي طويل. امشيك أم أطلب سيارة؟',
          phase: Phase.answer);
    }
    _pending = _Pending('ride', p);
    suggestions = const ['نعم، أوبر', 'كريم', 'امشيني'];
    await _say('$base بعيد على المشي. أفتح أوبر بالوجهة؟',
        phase: Phase.answer);
  }

  Future<void> _nextResult() async {
    if (_results.isEmpty) return await _say('لا توجد نتائج سابقة. قل مثلًا: أين أقرب صيدلية؟', phase: Phase.answer);
    if (_resultIdx + 1 >= _results.length) {
      return await _say('لا توجد أماكن أخرى قريبة. قل كرّر لسماع آخر مكان.', phase: Phase.answer);
    }
    await _announcePlace(_resultIdx + 1);
  }

  Future<void> _whereAmI() async {
    _thinking();
    try {
      final pos = await location.current();
      if (pos == null) return await _say('لا أستطيع تحديد موقعك الآن.', phase: Phase.answer);
      final home = _closestSaved(pos);
      String? addr;
      try {
        addr = await location.describe(pos);
      } on OfflineException {
        addr = null;
      }
      final parts = <String>[
        if (addr != null) 'أنت في $addr',
        if (home != null) home,
      ];
      await _say(parts.isEmpty ? 'حددت موقعك، لكن لا يتوفر اسم الشارع دون إنترنت.' : '${parts.join('. ')}.',
          phase: Phase.answer);
    } finally {
      fx.stopThinking();
    }
  }

  String? _closestSaved(Position pos) {
    Place? best;
    double bestD = double.infinity;
    for (final p in memory.data.places) {
      final d = LocationService.distance(pos.latitude, pos.longitude, p.lat, p.lon);
      if (d < bestD) {
        bestD = d;
        best = p;
      }
    }
    if (best == null) return null;
    if (bestD < 30) return 'أنت عند ${best.name}';
    return '${best.name} على بعد ${formatDistance(bestD)}';
  }

  Future<void> _toSavedPlace(String name) async {
    final place = memory.data.places.firstWhere((p) => p.name == name);
    final pos = await location.current();
    if (pos == null) return await _say('لا أستطيع تحديد موقعك الآن.', phase: Phase.answer);
    final d = LocationService.distance(pos.latitude, pos.longitude, place.lat, place.lon);
    final b = LocationService.bearing(pos.latitude, pos.longitude, place.lat, place.lon);
    final target = NearbyPlace(place.name, place.lat, place.lon, d, b);
    _lastTarget = target;
    _pending = _Pending('guide', target);
    final n = memory.data.name;
    await _say(
      '${place.name} على بعد ${formatDistance(d)} ${bearingToArabic(b)}${n != null ? ' يا $n' : ''}. هل أبدأ الإرشاد؟',
      phase: Phase.answer,
    );
  }

  /// «خذني إلى البيت» / «وديني أقرب صيدلية» / «ابدأ الإرشاد».
  Future<void> _startGuidanceFromText(String? arg) async {
    if (arg != null && arg.isNotEmpty) {
      final a = normalizeAr(arg);
      for (final p in memory.data.places) {
        final n = normalizeAr(p.name);
        if (a.contains(n) || a.contains(n.replaceFirst('ال', ''))) return _toSavedPlaceAndGo(p);
      }
      return _nearby(arg, go: true);
    }
    final pend = _pending;
    if (pend?.kind == 'guide') {
      _pending = null;
      return _startGuidance(pend!.data as NearbyPlace);
    }
    final last = _lastTarget;
    if (last != null) return _startGuidance(last);
    await _say('إلى أين؟ قل مثلًا: خذني إلى أقرب صيدلية.', phase: Phase.answer);
  }

  Future<void> _toSavedPlaceAndGo(Place p) => _startGuidance(NearbyPlace(p.name, p.lat, p.lon, 0, 0));

  /// Turn-by-turn guidance on a real walking route (falls back to straight-line
  /// direction if no route is available). Keeps the screen awake while walking.
  Future<void> _startGuidance(NearbyPlace target, {bool force = false}) async {
    _stopGuidance(silent: true);
    _thinking();
    final pos = await location.current();
    if (pos == null) {
      fx.stopThinking();
      return await _say('لا أستطيع تحديد موقعك لبدء الإرشاد.', phase: Phase.answer);
    }
    final far = LocationService.distance(pos.latitude, pos.longitude, target.lat, target.lon);
    if (!force && far > _walkMax) {
      fx.stopThinking();
      _lastTarget = target;
      _pending = _Pending('ride', target);
      suggestions = const ['نعم، أوبر', 'كريم', 'امشيني'];
      return await _say(
          '${target.name} على بعد ${formatDistance(far)}، حوالي ${walkingTime(far)}. هذا بعيد على المشي، '
          'الأفضل أن تطلب سيارة. أفتح لك أوبر والوجهة جاهزة؟ وإن أردت المشي قل: امشيني.',
          phase: Phase.answer);
    }
    guiding = true;
    _lastTarget = target;
    try {
      await WakelockPlus.enable();
    } catch (_) {}
    notifyListeners();

    WalkingRoute? route;
    if (backend.enabled) {
      try {
        route = await backend.route((pos.latitude, pos.longitude), (target.lat, target.lon));
      } catch (_) {
        route = null;
      }
    }
    fx.stopThinking();

    if (route == null) return _straightLineGuidance(target);

    final guide = WalkGuide(
      targetName: target.name,
      target: (target.lat, target.lon),
      say: _guideSay,
      replan: (from) async {
        try {
          return await backend.route(from, (target.lat, target.lon));
        } catch (_) {
          return null;
        }
      },
      onArrived: () {
        fx.cue(Cue.saved);
        _stopGuidance(silent: true);
      },
    );
    _guide = guide;
    await guide.start(route, pos, heading: _heading);
    _guideSub = location.track().listen((p) {
      sync.location(p.latitude, p.longitude, p.accuracy);
      guide.update(p);
    });
  }

  /// Speaks a guidance instruction without cutting the user off mid-sentence.
  Future<void> _guideSay(String text) async {
    for (var i = 0; i < 40 && voice.isListening; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
    if (!guiding && !text.startsWith('وصلت')) return;
    await _say(text, phase: Phase.answer);
  }

  Future<void> _straightLineGuidance(NearbyPlace target) async {
    await _say('لم أجد مسار مشي مفصّلًا، فسأرشدك بالاتجاه والمسافة. بدأت الإرشاد إلى ${target.name}.',
        phase: Phase.answer);
    var lastSpokeAt = DateTime.now();
    double? lastSpokeDist;
    _guideSub = location.track().listen((pos) async {
      final d = LocationService.distance(pos.latitude, pos.longitude, target.lat, target.lon);
      if (d < 20) {
        _stopGuidance(silent: true);
        await fx.cue(Cue.saved);
        await _say('وصلت تقريبًا إلى ${target.name}.', phase: Phase.answer);
        return;
      }
      final now = DateTime.now();
      final moved = lastSpokeDist == null || (lastSpokeDist! - d).abs() >= 40;
      if (_busy || voice.isListening || (!moved && now.difference(lastSpokeAt).inSeconds < 30)) return;
      lastSpokeAt = now;
      lastSpokeDist = d;
      final b = LocationService.bearing(pos.latitude, pos.longitude, target.lat, target.lon);
      await _say('باقٍ ${formatDistance(d)}. ${_relativeDirection(b, pos)}', phase: Phase.answer);
    });
  }

  /// Uses the walking direction (GPS course) when moving to say «انحرف يمينًا»;
  /// otherwise falls back to compass words.
  String _relativeDirection(double bearing, Position pos) {
    if (pos.speed < 0.6 || pos.heading <= 0) return 'الوجهة ${bearingToArabic(bearing)}.';
    var diff = (bearing - pos.heading + 540) % 360 - 180; // -180..180, + = right
    if (diff.abs() < 25) return 'استمر للأمام.';
    if (diff.abs() > 150) return 'الوجهة خلفك، استدر.';
    final side = diff > 0 ? 'اليمين' : 'اليسار';
    return diff.abs() < 60 ? 'انحرف قليلًا إلى $side.' : 'اتجه إلى $side.';
  }

  Future<void> _remaining() async {
    final g = _guide;
    if (!guiding) return await _say('لا يوجد إرشاد الآن. قل مثلًا: خذني إلى أقرب صيدلية.', phase: Phase.answer);
    if (g == null || !g.active) return await _say('أرشدك بالاتجاه فقط، وسأخبرك بالمسافة أثناء المشي.', phase: Phase.answer);
    await _say(g.status(), phase: Phase.answer);
  }

  void _stopGuidance({bool silent = false}) {
    _guideSub?.cancel();
    _guideSub = null;
    _guide?.active = false;
    _guide = null;
    try {
      WakelockPlus.disable();
    } catch (_) {}
    if (guiding) {
      guiding = false;
      notifyListeners();
    }
  }

  // ================= First-launch voice setup =================

  bool inSetup = false;
  int setupStep = 0;
  static const setupTotal = 6;
  String setupQuestion = '';

  /// Asks the essentials by voice and saves them: permissions (precise
  /// location…), name, voice speed, emergency contacts, home. Every question
  /// can be skipped with «تخطَّ»; it runs again with «أعد الإعداد».
  Future<void> runSetup() async {
    if (inSetup) return;
    inSetup = true;
    _busy = true;
    try {
      // 1) Welcome + permissions.
      _setupShow(1, 'أهلًا بك في حَدَق');
      await voice.speak('أهلًا بك في حَدَق. أسئلة قصيرة لأتعرف عليك، ولتجاوز أي سؤال قل: تخطَّ.');
      await _setupPermissions();

      // 2) Consent to share data with the Hadaq team.
      await _askConsent(step: 2);

      // 2) Name.
      final nameAns = await _ask(3, 'بماذا تحب أن أناديك؟');
      final name = nameAns == null ? null : SetupAnswers.name(nameAns);
      if (name != null) {
        await memory.update((d) => d.name = name);
        await voice.speak('أهلًا يا $name.');
      }

      // 3) Voice speed.
      var q = 'سرعة كلامي مناسبة؟ قل: مناسبة، أو أبطأ، أو أسرع.';
      for (var i = 0; i < 4; i++) {
        final a = await _ask(4, q);
        final sp = a == null ? 'ok' : SetupAnswers.speed(a);
        if (sp == 'ok') break;
        if (sp == null) {
          q = 'لم أفهم. قل: مناسبة، أو: أبطأ، أو: أسرع.';
          continue;
        }
        await memory.update((d) => d.speechRate =
            (sp == 'slower' ? d.speechRate * 0.8 : d.speechRate * 1.25).clamp(0.5, 2.0).toDouble());
        await _applyVoiceSettings();
        q = 'وهكذا؟';
      }

      // 4) Emergency contacts.
      await _setupContacts();

      // 5) Home.
      final homeAns = await _ask(6, 'هل أنت في بيتك الآن؟');
      if (homeAns != null && SetupAnswers.isYes(homeAns)) {
        _setupShow(6, 'أحدد موقع البيت…');
        final pos = await location.current(wait: const Duration(seconds: 12), goodMeters: 15);
        if (pos != null) {
          await memory.update((d) {
            d.places.removeWhere((x) => normalizeAr(x.name) == normalizeAr('البيت'));
            d.places.add(Place('البيت', pos.latitude, pos.longitude));
          });
          await fx.cue(Cue.saved);
          await voice.speak('حفظت موقع البيت${pos.accuracy > 30 ? '، لكن دقة الموقع ضعيفة الآن، ويمكنك حفظه لاحقًا بقول: احفظ هذا المكان باسم البيت' : ''}.');
        } else {
          await voice.speak('لم أستطع تحديد الموقع. يمكنك لاحقًا أن تقول وأنت في البيت: احفظ هذا المكان باسم البيت.');
        }
      } else if (homeAns != null) {
        await voice.speak('حسنًا. عندما تكون في البيت قل: احفظ هذا المكان باسم البيت.');
      }

      // Done.
      await memory.update((d) => d.onboarded = true);
      final d = memory.data;
      final summary = [
        if (d.name != null) 'اسمك ${d.name}',
        if (d.speechRate != 1) 'صوت ${d.speechRate < 1 ? 'أبطأ' : 'أسرع'}',
        if (d.emergencyContacts.isNotEmpty) 'جهات الطوارئ: ${d.emergencyContacts.map((p) => p.name).join(' و')}',
        if (d.places.any((p) => p.name == 'البيت')) 'موقع البيت',
      ];
      await fx.cue(Cue.saved);
      inSetup = false;
      _busy = false;
      await _say(
        'انتهى الإعداد. المس الشاشة في أي مكان وتحدّث.',
        phase: Phase.idle,
        show: false,
      );
    } finally {
      inSetup = false;
      _busy = false;
      if (phase == Phase.setup) {
        phase = Phase.idle;
        notifyListeners();
      }
    }
  }

  void _setupShow(int step, String question) {
    setupStep = step;
    setupQuestion = question;
    heard = '';
    phase = Phase.setup;
    notifyListeners();
  }

  /// Speaks [question], listens, and returns the answer — or null if skipped
  /// / nothing heard twice.
  Future<String?> _ask(int step, String question) async {
    _setupShow(step, question);
    for (var attempt = 0; attempt < 2; attempt++) {
      if (phase == Phase.sos) return null;
      // Ask once; if nothing was heard just say «لم أسمع» and listen again.
      await voice.speak(attempt == 0 ? question : 'لم أسمع.');
      await fx.cue(Cue.listen);
      await Future.delayed(const Duration(milliseconds: 200));
      final text = await _hear();
      heard = text;
      notifyListeners();
      if (text.trim().isEmpty) continue;
      if (SetupAnswers.isSkip(text)) return null;
      return text;
    }
    return null;
  }

  Future<void> _setupPermissions() async {
    // Android only lets the user grant a permission by pressing «سماح» in the system
    // window; Hadaq asks by voice and opens that window right after «نعم».
    final asks = <(String, Future<bool> Function(), Future<void> Function())>[
      ('أسمح لي بموقعك لأرشدك؟', () async => (await Permission.locationWhenInUse.status).isGranted,
          () async => await location.ensurePermission()),
      ('أسمح لي بجهات الاتصال لأتصل وأراسل من تريد؟', () async => (await Permission.contacts.status).isGranted,
          () async => await Permission.contacts.request()),
      ('أسمح لي بإجراء المكالمات؟', () async => (await Permission.phone.status).isGranted,
          () async => await Permission.phone.request()),
      if (!_playBuild)
        ('أسمح لي بإرسال رسائل الطوارئ؟', () async => (await Permission.sms.status).isGranted,
            () async => await Permission.sms.request()),
      ('أسمح لي بالكاميرا لأصف لك ما أمامك؟', () async => (await Permission.camera.status).isGranted,
          () async => await Permission.camera.request()),
    ];
    for (final (q, granted, request) in asks) {
      try {
        if (await granted()) continue;
        final a = await _ask(1, q);
        if (a == null || SetupAnswers.isNo(a)) continue;
        await voice.speak('اضغط: سماح.');
        await request();
      } catch (_) {}
    }
    if (await location.isApproximateOnly()) {
      await voice.speak('اخترت الموقع التقريبي، ولن أستطيع إرشادك بدقة. سأفتح الإعدادات: اختر الأذونات، ثم الموقع، '
          'ثم فعّل: استخدام الموقع الدقيق. ثم ارجع إلى حَدَق.');
      await location.openAppSettings();
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> _setupContacts() async {
    var q = 'من أراسل في الطوارئ؟ قل اسمه أو رقمه.';
    for (var added = 0; added < 3;) {
      final a = await _ask(5, q);
      if (a == null) break;
      Person? person;
      final num = SetupAnswers.number(a);
      if (num != null) {
        person = Person('جهة طوارئ ${added + 1}', num);
      } else {
        final who = SetupAnswers.contactName(a);
        final found = await phone.find(who);
        for (final m in found.take(2)) {
          final ok = await _ask(5, 'وجدت ${m.name}، رقمه ينتهي بـ ${PhoneService.tail(m.number)}. هل هذا صحيح؟');
          if (ok != null && SetupAnswers.isYes(ok)) {
            person = Person(m.name, m.number);
            break;
          }
        }
        if (person == null) {
          q = found.isEmpty
              ? 'لم أجد $who في جهات اتصالك. قل الاسم كما هو محفوظ، أو قل الرقم، أو قل: تخطَّ.'
              : 'حسنًا. قل اسمًا آخر، أو الرقم، أو قل: تخطَّ.';
          continue;
        }
      }
      final pp = person;
      await memory.update((d) {
        d.people.removeWhere((x) => x.phone == pp.phone);
        d.people.add(pp);
      });
      added++;
      await fx.cue(Cue.saved);
      final more = await _ask(5, 'أضفت ${pp.name} إلى جهات الطوارئ. هل تريد إضافة شخص آخر؟');
      if (more == null || !SetupAnswers.isYes(more)) break;
      q = 'من الشخص الآخر؟ قل اسمه أو رقمه.';
    }
  }

  Future<void> _pingLocation() async {
    if (!sync.enabled || guiding) return; // guidance already reports positions
    final p = await location.current(wait: const Duration(seconds: 6));
    if (p != null) sync.location(p.latitude, p.longitude, p.accuracy);
  }

  /// «هل توافق…؟» — asked once (in setup, or on the first launch after an update).
  Future<void> _askConsent({int? step}) async {
    const q = 'هل توافق أن يطّلع فريق حدق على محادثاتك وموقعك أثناء الاستخدام لنساعدك ونحسّن الخدمة؟ '
        'لا نحفظ صورك ولا صوتك، وتلغي متى شئت بقول: احذف بياناتي.';
    String? a;
    if (step != null) {
      a = await _ask(step, q);
    } else {
      final wasBusy = _busy;
      _busy = true;
      try {
        a = await _listenFor(q);
      } finally {
        _busy = wasBusy;
      }
    }
    if (a == null) return; // skipped: ask again next time
    if (SetupAnswers.isYes(a)) {
      await sync.setConsent(true);
      await voice.speak('شكرًا لك.');
      unawaited(_pingLocation());
    } else if (SetupAnswers.isNo(a)) {
      await sync.setConsent(false);
      await voice.speak('حسنًا، لن أشارك شيئًا من بياناتك.');
    }
  }

  // ================= Listening =================

  int _cloudSttFailures = 0;

  bool get _cloudStt =>
      backend.enabled && backend.config.sttEngine == 'openai' && _cloudSttFailures < 3 && !kIsWeb;

  /// Listens for one utterance. Uses server transcription (OpenAI — accurate with
  /// dialects) when enabled, else the phone's recogniser. Returns '' if nothing heard.
  Future<String> _hear() async {
    if (_cloudStt) {
      level = 0;
      final audio = await voice.recordUtterance(onLevel: (l) {
        level = l;
        notifyListeners();
      });
      level = 0;
      if (audio == null) return '';
      heard = '…';
      notifyListeners();
      fx.startThinking(); // waiting tone while the words are transcribed
      try {
        final names = [
          ...memory.data.people.map((p) => p.name),
          ...memory.data.places.map((p) => p.name),
          if (memory.data.name != null) memory.data.name!,
        ].take(15).join('، ');
        final text = await backend.transcribe(audio, hint: names.isEmpty ? null : names);
        fx.stopThinking();
        _cloudSttFailures = 0;
        heard = text;
        notifyListeners();
        return text;
      } catch (_) {
        fx.stopThinking();
        _cloudSttFailures++;
        // Network/server trouble: fall back to the phone's recogniser for this turn.
      }
    }
    return voice.listen(onPartial: (t) {
      heard = t;
      notifyListeners();
    });
  }

  /// Microphone input level 0..1 while recording (drives the orb).
  double level = 0;

  // ================= Ride apps =================

  /// Opens Uber with the destination filled in (or Careem). The user confirms
  /// the ride in that app; Hadaq never books or pays on its own.
  /// Finds a place by name or kind near the user (first result). Speaks the problem itself.
  Future<NearbyPlace?> _findPlace(String query) async {
    final q = normalizeAr(query);
    for (final p in memory.data.places) {
      final n = normalizeAr(p.name);
      if (q.contains(n) || n.contains(q)) return NearbyPlace(p.name, p.lat, p.lon, 0, 0);
    }
    _thinking();
    try {
      final pos = await location.current();
      if (pos == null) {
        await _say('لا أستطيع تحديد موقعك. فعّل خدمة الموقع واسمح لحدق باستخدامه.', phase: Phase.answer);
        return null;
      }
      final found = await backend.searchPlaces(query, pos.latitude, pos.longitude);
      if (found.isEmpty) {
        await _say('لم أجد $query قريبًا منك. قل اسم المكان بطريقة أخرى.', phase: Phase.answer);
        return null;
      }
      final f = found.first;
      return NearbyPlace(f.name, f.lat, f.lon, f.distance, f.bearing);
    } catch (_) {
      await _say('تعذّر البحث عن المكان الآن.', phase: Phase.answer);
      return null;
    } finally {
      fx.stopThinking();
    }
  }

  /// «افتح خرائط جوجل ووجهني إلى…»: hands walking navigation to Google Maps,
  /// which reads every turn aloud on its own.
  Future<void> _openGoogleMaps(String? dest) async {
    NearbyPlace? t;
    if (dest != null && dest.trim().isNotEmpty) {
      t = await _findPlace(dest);
      if (t == null) return;
    } else {
      t = _lastTarget;
      if (t == null) {
        final a = await _listenFor('إلى أين تريد أن تذهب؟');
        if (a == null) return _openApp('خرائط');
        t = await _findPlace(a);
        if (t == null) return;
      }
    }
    _lastTarget = t;
    await _say('أفتح خرائط جوجل للمشي إلى ${t.name}، وستقرأ عليك الاتجاهات.', phase: Phase.answer);
    final ok = await _launch('google.navigation:q=${t.lat},${t.lon}&mode=w') ||
        await _launch('https://www.google.com/maps/dir/?api=1&destination=${t.lat},${t.lon}&travelmode=walking');
    if (!ok) await _say('تعذّر فتح خرائط جوجل. أستطيع أن أرشدك بنفسي: قل امشيني.', phase: Phase.answer);
  }

  /// Ride apps by package; Uber also takes the destination in its link.
  static const _rideApps = {
    'uber': ('أوبر', 'com.ubercab'),
    'careem': ('كريم', 'com.careem.acma'),
    'bolt': ('بولت', 'ee.mtakso.client'),
    'jeeny': ('جيني', 'me.com.easytaxi'),
    'wasalni': ('وصلني', ''),
  };

  /// «اطلب سيارة (إلى المستشفى)»: where to → confirm → opens the ride app ready to book.
  /// The user still reviews the price and confirms inside the app (payment is theirs).
  Future<void> _ride(String? app, {NearbyPlace? target, String? destName}) async {
    _pending = null;
    var t = target;
    if (t == null && destName != null && destName.isNotEmpty) t = await _findPlace(destName);
    if (t == null && destName == null) {
      t = _lastTarget;
      if (t == null) {
        final a = await _listenFor('إلى أين تريد الذهاب بالسيارة؟');
        if (a == null) return await _say('ألغيت الطلب.', phase: Phase.answer);
        t = await _findPlace(a);
      }
    }
    if (t == null) return;
    final (label, pkg) = _rideApps[app ?? 'uber']!;
    final ok = await _confirm('أطلب سيارة من $label إلى ${t.name}؟');
    if (ok != true) return await _say('حسنًا، لم أطلب.', phase: Phase.answer);
    _lastTarget = t;

    if (app == null || app == 'uber') {
      final uber = Uri.https('m.uber.com', '/ul/', {
        'action': 'setPickup',
        'pickup': 'my_location',
        'dropoff[latitude]': '${t.lat}',
        'dropoff[longitude]': '${t.lon}',
        'dropoff[nickname]': t.name,
      });
      await _say('أفتح أوبر والوجهة ${t.name} جاهزة. راجع السعر واضغط تأكيد الطلب أسفل الشاشة.', phase: Phase.answer);
      if (!await _launch(uber.toString())) await _say('تعذّر فتح أوبر. قل: اطلب كريم، أو اطلب بولت.', phase: Phase.answer);
      return;
    }
    // Other apps can't take the destination from outside: copy it so the user can paste it.
    await Clipboard.setData(ClipboardData(text: t.name));
    await _say('أفتح $label. الوجهة ${t.name} منسوخة: الصقها في خانة إلى أين.', phase: Phase.answer);
    final opened = pkg.isNotEmpty && await NativeBridge.openApp(pkg);
    if (!opened) await _openApp(label);
  }

  /// Vision requests: when the user asked for a picture outright («صوّر»، «ما أمامي»)
  /// the camera opens at once; when it's only implied («كم معي من النقود») ask first.
  Future<void> _visionAsked(String text) async {
    final explicit = RegExp(r'(الكاميرا|كاميرا|صور|التقط|امامي|قدامي|صف لي|صف المكان|ماذا تري|وش تشوف)').hasMatch(normalizeAr(text));
    if (!explicit) {
      final ok = await _confirm('أفتح الكاميرا وأصوّر ما أمامك؟');
      if (ok != true) return await _say('حسنًا.', phase: Phase.answer);
    }
    return _vision(text);
  }

  Future<bool> _launch(String url) async {
    try {
      return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  // ================= Open apps =================

  List<AppEntry>? _apps;

  /// «افتح يوتيوب» — finds the app by its Arabic/English name and opens it.
  Future<void> _openApp(String name) async {
    _apps ??= [for (final (l, p) in await NativeBridge.listApps()) AppEntry(l, p)];
    var found = AppMatcher.find(name, _apps!);
    if (found.isEmpty) {
      _apps = [for (final (l, p) in await NativeBridge.listApps()) AppEntry(l, p)]; // maybe newly installed
      found = AppMatcher.find(name, _apps!);
    }
    if (found.isEmpty) {
      return await _say('لم أجد تطبيقًا باسم $name على جوالك.', phase: Phase.answer);
    }
    final app = found.first;
    await _say('أفتح ${app.label}.', phase: Phase.answer);
    if (!await NativeBridge.openApp(app.package)) {
      await _say('تعذّر فتح ${app.label}.', phase: Phase.answer);
    }
  }

  // ================= Messages (WhatsApp / SMS) =================

  /// «ارسل لأحمد واتساب قل له إني في الطريق»: find the contact, get the text
  /// (asks for it if missing), read it back, and send only after «نعم».
  Future<void> _message(String rest, String channel, {bool textOnly = false}) async {
    ContactMatch? who;
    var text = textOnly ? rest.trim() : '';
    if (!textOnly && rest.trim().isNotEmpty) {
      // Who? Try the first 1–3 words as the name; keep the best phonebook match.
      _thinking();
      try {
        final direct = RegExp(r'^\+?[\d\s]{7,}').firstMatch(toLatinDigits(rest));
        if (direct != null) {
          final n = direct.group(0)!.replaceAll(' ', '');
          who = ContactMatch(n.split('').join(' '), n, 9);
          text = Messaging.cleanMessage(rest.substring(direct.end));
        } else {
          for (final (name, msg) in Messaging.candidates(rest)) {
            final saved = memory.data.people.where((p) => normalizeAr(p.name) == normalizeAr(name)).firstOrNull;
            final found = saved != null ? [ContactMatch(saved.name, saved.phone, 5)] : await phone.find(name);
            if (found.isEmpty) continue;
            if (who == null || found.first.score >= who.score) {
              who = found.first;
              text = msg;
            }
          }
        }
      } finally {
        fx.stopThinking();
      }
      // No exact match: let the user pick from the closest names.
      who ??= await _resolveContact(Messaging.candidates(rest).firstOrNull?.$1 ?? rest);
      if (who == null) return;
    }
    if (who == null) {
      final t = await _listenFor(text.isEmpty ? 'لمن تريد أن ترسل؟' : 'لمن أرسل: $text؟');
      if (t == null) return await _say('ألغيت الرسالة.', phase: Phase.answer);
      who = await _resolveContact(t);
      if (who == null) return;
    }
    if (text.isEmpty) {
      final t = await _listenFor('ماذا تريد أن تقول لـ ${who.name}؟');
      if (t == null || t.trim().isEmpty) return await _say('ألغيت الرسالة.', phase: Phase.answer);
      text = Messaging.cleanMessage(t);
    }
    final d = _Draft(who.name, who.number, text, channel);
    final ok = await _confirm('سأرسل إلى ${who.name}${channel == 'sms' ? ' رسالة نصية' : ' على واتساب'}: $text. أرسل؟');
    if (ok == true) return _sendDraft(d);
    await _say(ok == false ? 'حسنًا، لم أرسلها.' : 'لم أسمع تأكيدًا، فلم أرسلها.', phase: Phase.answer);
  }

  /// Speaks [question] and returns what the user says next (null if nothing).
  Future<String?> _listenFor(String question) async {
    await _say(question, phase: Phase.answer);
    phase = Phase.listening;
    heard = '';
    notifyListeners();
    await fx.cue(Cue.listen);
    await Future.delayed(const Duration(milliseconds: 250));
    final t = await _hear();
    heard = t;
    return t.trim().isEmpty ? null : t;
  }

  Future<void> _sendDraft(_Draft d) async {
    if (d.channel == 'sms') {
      final sent = _playBuild ? -1 : await NativeBridge.sendSms([d.number], d.text);
      if (sent > 0) {
        await fx.cue(Cue.saved);
        return await _say('أرسلت رسالة نصية إلى ${d.name}.', phase: Phase.answer);
      }
      // Google Play build (no SMS permission) or sending failed: open Messages with the text ready.
      await _say('أفتح الرسائل والنص جاهز. اضغط إرسال.', phase: Phase.answer);
      if (!await _launch('sms:${d.number}?body=${Uri.encodeComponent(d.text)}')) {
        await _say('تعذّر فتح الرسائل.', phase: Phase.answer);
      }
      return;
    }
    final auto = await NativeBridge.autoSendEnabled();
    await _say(auto ? 'أفتح واتساب وأرسل.' : 'أفتح محادثة ${d.name} في واتساب والرسالة مكتوبة.', phase: Phase.answer);
    _sentDraft = d;
    // 1) WhatsApp's own registered number for this contact (exact).
    // 2) A number saved in international form (+… / 00…).
    // 3) Otherwise let WhatsApp match the number as saved in the phonebook (needs auto-send to type the text).
    final jid = await NativeBridge.whatsappNumberFor(d.name, d.number);
    final raw = toLatinDigits(d.number).replaceAll(RegExp(r'[^\d+]'), '');
    final international = raw.startsWith('+') || raw.startsWith('00');
    final String mode;
    final String target;
    if (jid != null) {
      mode = 'link';
      target = jid;
    } else if (international || (!auto && raw.startsWith('05'))) {
      mode = 'link';
      target = Messaging.whatsappNumber(d.number);
    } else {
      mode = 'contact';
      target = raw;
    }
    debugPrint('[hadaq] whatsapp mode=$mode source=${jid != null ? 'whatsapp-contact' : (international ? 'international' : 'local')}');
    final res = await NativeBridge.sendWhatsApp(target, d.text, auto: auto, mode: mode);
    switch (res) {
      case 'armed':
        return; // the accessibility service reports back via onWhatsAppSent
      case 'opened':
        _sentDraft = null;
        if (mode == 'contact') {
          await Clipboard.setData(ClipboardData(text: d.text));
          await voice.speak('فتحت محادثة ${d.name}. الرسالة منسوخة: الصقها في مربع الكتابة ثم اضغط إرسال.');
        }
        await voice.speak(_playBuild
            ? 'زر الإرسال في أسفل الشاشة بجانب مربع الكتابة.'
            : 'زر الإرسال في أسفل الشاشة بجانب مربع الكتابة. '
                'ولكي أرسل عنك تلقائيًا في المرات القادمة، قل لي: فعّل الإرسال التلقائي.');
        return;
      case 'not_installed':
        _sentDraft = null;
        _pending = _Pending('smsInstead', d);
        return await _say('واتساب غير مثبت على جوالك. أرسلها رسالة نصية بدلًا منه؟', phase: Phase.answer);
      default:
        _sentDraft = null;
        await _say('تعذّر فتح واتساب.', phase: Phase.answer);
    }
  }

  /// Explains and opens Accessibility settings so the user can turn on auto-send.
  Future<void> _enableAutoSend() async {
    if (_playBuild) {
      return await _say('الإرسال التلقائي غير متاح في هذه النسخة. أفتح لك المحادثة والرسالة مكتوبة، وتضغط أنت إرسال.',
          phase: Phase.answer);
    }
    if (await NativeBridge.autoSendEnabled()) {
      return await _say('الإرسال التلقائي مفعّل. سأضغط زر الإرسال في واتساب بعد أن تؤكد كل رسالة.', phase: Phase.answer);
    }
    await _say(
      'سأفتح إعدادات إمكانية الوصول. اختر: التطبيقات المثبتة، ثم: حدق إرسال واتساب، ثم فعّله ووافق. '
      'حدق يضغط زر الإرسال فقط، وفقط بعد أن تقول نعم لتأكيد الرسالة، ولا يقرأ محادثاتك.',
      phase: Phase.answer,
    );
    await NativeBridge.openAccessibilitySettings();
  }

  // ================= Calls =================

  /// Asks a yes/no question and listens straight away (no tap needed).
  /// true / false, or null if there was no clear answer after one retry.
  Future<bool?> _confirm(String question) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final t = await _listenFor(attempt == 0 ? question : 'لم أسمع جيدًا. قل نعم أو لا.');
      if (t == null) continue;
      final type = IntentClassifier().classify(t).type;
      if (type == IntentType.yes) return true;
      if (type == IntentType.no || type == IntentType.stop) return false;
    }
    return null;
  }

  /// Finds the person the user means: saved people first, then the phonebook
  /// (Arabic or English spelling). Asks which one when several match, and offers
  /// the closest names when nothing matches exactly. null = gave up.
  Future<ContactMatch?> _resolveContact(String spoken) async {
    var who = spoken.trim().replaceFirst(RegExp(r'^(?:اتصل|كلم|ارسل|ابعث)\s*(?:ب|على|ل|الى|إلى)?\s*'), '');
    if (RegExp(r'^\+?[\d\s]{3,}$').hasMatch(toLatinDigits(who))) {
      final n = toLatinDigits(who).replaceAll(' ', '');
      return ContactMatch(n.split('').join(' '), n, 9);
    }
    final w = normalizeAr(who).replaceFirst(RegExp(r'^[بل](?=\S{2,})'), '');
    final saved = memory.data.people.where((p) {
      final n = normalizeAr(p.name);
      return n == w || n.startsWith(w) || w.endsWith(n);
    }).toList();
    if (saved.length == 1) return ContactMatch(saved.first.name, saved.first.phone, 5);

    _thinking();
    List<ContactMatch> found;
    try {
      found = await phone.find(who);
    } finally {
      fx.stopThinking();
    }
    var top = found.where((m) => m.score == (found.isEmpty ? 0 : found.first.score)).take(3).toList();
    if (top.isEmpty) {
      // Nothing exact: offer the closest-sounding names.
      top = await phone.suggest(who);
      if (top.isEmpty) {
        await _say('لم أجد $who في جهات اتصالك. قل الاسم كما هو محفوظ في جوالك، أو قل الرقم.', phase: Phase.answer);
        return null;
      }
      if (top.length == 1) {
        final ok = await _confirm('لم أجد $who. هل تقصد ${top.first.name}؟');
        return ok == true ? top.first : null;
      }
      return _pickContact(top, 'لم أجد $who. هل تقصد ${top.map((m) => m.name).join('، أو ')}؟');
    }
    if (top.length == 1) return top.first;
    return _pickContact(top, 'عندي ${top.map((m) => m.name).join('، و')}. أيّهم تقصد؟');
  }

  /// Lets the user pick one of a few contacts by voice: «الأول»، «الثاني»، or the name itself.
  Future<ContactMatch?> _pickContact(List<ContactMatch> options, String question) async {
    clarifyOptions = [for (final m in options) m.name];
    final t = await _listenFor(question);
    clarifyOptions = [];
    if (t == null) return null;
    final i = IntentClassifier().classify(t).type;
    if (i == IntentType.choiceFirst) return options[0];
    if (i == IntentType.choiceSecond && options.length > 1) return options[1];
    if (i == IntentType.choiceThird && options.length > 2) return options[2];
    if (i == IntentType.yes && options.length == 1) return options[0];
    final said = normalizeAr(t);
    for (final m in options) {
      final n = normalizeAr(m.name);
      if (said.contains(n) || n.contains(said) || PhoneService.sameSound(said, n)) return m;
    }
    await _say('لم أفهم أيّهم. قل الاسم مرة أخرى.', phase: Phase.answer);
    return null;
  }

  /// «اتصل بأحمد» → «أتصل بأحمد؟» → «نعم» → calls. «اتصل» alone asks who first.
  Future<void> _call(String who, {String? service}) async {
    if (who == '__emergency__') return _callEmergency(service);
    if (who.trim().isEmpty) {
      final t = await _listenFor('بمن تريد أن تتصل؟');
      if (t == null) return await _say('ألغيت الاتصال.', phase: Phase.answer);
      who = t;
    }
    final m = await _resolveContact(who);
    if (m != null) await _confirmCall(m.name, m.number);
  }

  Future<void> _confirmCall(String name, String number) async {
    final ok = await _confirm('أتصل بـ $name؟');
    if (ok == true) return _placeCall(name, number);
    await _say(ok == false ? 'حسنًا، لن أتصل.' : 'لم أسمع تأكيدًا، فلم أتصل.', phase: Phase.answer);
  }

  Future<void> _placeCall(String name, String number) async {
    await _say('أتصل الآن.', phase: Phase.answer);
    final ok = await phone.call(number);
    if (!ok) await _say('تعذّر الاتصال. تأكد من السماح لحدق بإجراء المكالمات.', phase: Phase.answer);
  }

  /// «اتصل بالطوارئ»: the saved emergency contact; «الإسعاف/الشرطة»: the official number.
  /// If no emergency contact is saved yet, asks for one, saves it, then calls.
  Future<void> _callEmergency(String? service) async {
    final official = backend.config.emergencyNumber;
    if (service != null) {
      final label = {'اسعاف': 'الإسعاف', 'شرطه': 'الشرطة', 'دفاع المدني': 'الدفاع المدني'}[service] ?? 'الطوارئ';
      return _confirmCall('$label على الرقم ${official.split('').join(' ')}', official);
    }
    final saved = memory.data.emergencyContacts;
    if (saved.isNotEmpty) return _confirmCall(saved.first.name, saved.first.phone);
    final t = await _listenFor('لا يوجد رقم طوارئ محفوظ. قل رقم الطوارئ، أو اسم الشخص من جهات اتصالك.');
    if (t == null) return await _say('لم أحفظ شيئًا. ولطوارئ الدولة اتصل بـ $official.', phase: Phase.answer);
    final m = await _resolveContact(t);
    if (m == null) return;
    final person = Person(m.score == 9 ? 'رقم الطوارئ' : m.name, m.number.replaceAll(' ', ''));
    await memory.update((d) {
      d.people.removeWhere((x) => x.phone == person.phone);
      d.people.add(person);
    });
    await fx.cue(Cue.saved);
    await _say('حفظته رقمًا للطوارئ.', phase: Phase.answer);
    return _confirmCall(person.name, person.phone);
  }

  // ================= SOS =================

  Future<void> triggerSos() async {
    if (phase == Phase.sos) return;
    _sosCancelled = false;
    await voice.cancelListening();
    await voice.stopSpeaking();
    fx.stopThinking();
    final contacts = memory.data.emergencyContacts;
    sosTargets = contacts.map((c) => c.name).join(' و');
    phase = Phase.sos;
    sosCount = 5;
    heard = 'النجدة!';
    notifyListeners();
    await fx.cue(Cue.alarm);
    if (contacts.isEmpty) {
      await voice.speak(local: true, 'طوارئ. لا توجد جهة طوارئ محفوظة. اتصل بالرقم ${backend.config.emergencyNumber}. ولإضافة جهة قل لاحقًا: أضف أمي جهة طوارئ رقمها، ثم الرقم.');
      phase = Phase.answer;
      answer = 'لا توجد جهة طوارئ محفوظة. اتصل بـ ${backend.config.emergencyNumber}.';
      notifyListeners();
      return;
    }
    await voice.speak('سأرسل موقعك إلى $sosTargets. قل لا أو المس الشاشة للإلغاء.', local: true);
    // Listen for «لا» during the countdown.
    unawaited(voice.listen(onPartial: (t) {
      final n = normalizeAr(t);
      if (RegExp(r'(^| )(لا|الغ|توقف|الغاء)( |$)').hasMatch(n)) cancelSos();
    }));
    for (var i = 5; i > 0; i--) {
      if (_sosCancelled) return;
      sosCount = i;
      notifyListeners();
      fx.cue(Cue.thinking);
      await Future.delayed(const Duration(seconds: 1));
    }
    if (_sosCancelled) return;
    await voice.cancelListening();
    await _sendSos(contacts);
  }

  Future<void> _sendSos(List<Person> contacts) async {
    sosCount = 0;
    notifyListeners();
    final pos = await location.current();
    final name = memory.data.name ?? 'مستخدم حدق';
    final where = pos != null ? 'موقعي: ${LocationService.mapsLink(pos.latitude, pos.longitude)}' : 'تعذّر تحديد الموقع.';
    final msg = 'نداء استغاثة من $name عبر تطبيق حدق: أحتاج مساعدة. $where';
    final numbers = contacts.map((c) => c.phone).toList();
    final sent = await NativeBridge.sendSms(numbers, msg);
    var opened = false;
    if (sent <= 0) {
      // Browser (or SMS blocked): open the messages app with the text ready to send.
      try {
        opened = await launchUrl(Uri.parse('sms:${numbers.join(',')}?body=${Uri.encodeComponent(msg)}'));
      } catch (_) {}
    }
    final sos = backend.config.emergencyNumber;
    await fx.cue(sent > 0 || opened ? Cue.saved : Cue.error);
    phase = Phase.answer;
    final (shown, spoken) = sent > 0
        ? ('أُرسل موقعك إلى $sosTargets.', 'أرسلت موقعك إلى $sosTargets. ابقَ في مكانك إن استطعت.')
        : opened
            ? ('فُتحت الرسائل وموقعك جاهز. اضغط إرسال.', 'فتحت تطبيق الرسائل وفيه موقعك جاهز. اضغط زر الإرسال.')
            : ('تعذّر إرسال الرسالة. اتصل بـ $sos.', 'تعذّر إرسال الرسالة. اتصل بالرقم $sos.');
    answer = shown;
    notifyListeners();
    await _say(spoken, phase: Phase.answer);
  }

  Future<void> cancelSos() async {
    if (phase != Phase.sos || _sosCancelled) return;
    _sosCancelled = true;
    await voice.cancelListening();
    await voice.stopSpeaking();
    await _say('ألغيت الطوارئ.', phase: Phase.idle, show: false);
  }

  // ================= Output =================

  void _thinking({Phase keepPhase = Phase.thinking}) {
    phase = keepPhase == Phase.camera ? Phase.camera : Phase.thinking;
    answer = '';
    notifyListeners();
    fx.startThinking();
  }

  /// Shows [text] in large type (for low vision and sighted companions) and speaks it.
  Future<void> _say(String text, {required Phase phase, bool show = true}) async {
    fx.stopThinking();
    this.phase = phase;
    if (show) answer = text;
    if (phase != Phase.answer && phase != Phase.camera) suggestions = [];
    if (phase != Phase.clarify) clarifyOptions = [];
    notifyListeners();
    _lastSpoken = text;
    sync.logReply(text);
    await voice.speak(text);
  }
}
