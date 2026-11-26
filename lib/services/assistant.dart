import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'backend.dart';

/// Thrown when a request needs the internet and there is none.
class OfflineException implements Exception {}

class AssistantReply {
  final String answer;
  final String? label; // short object label for the chip, e.g. «علبة دواء»
  final List<String> suggestions; // quick spoken replies, e.g. «اقرأ النشرة»
  /// What the app should DO for a request its rules didn't catch:
  /// {"type": "call", "who": "…"}، {"type": "message", …}، {"type": "camera", …}…
  final Map<String, dynamic>? action;
  const AssistantReply(this.answer, {this.label, this.suggestions = const [], this.action});
}

/// The smart assistant (scene description, OCR, open questions) via the Gemini API.
/// Key and model come from --dart-define so nothing secret lives in the repo:
///   flutter run --dart-define=GEMINI_API_KEY=... [--dart-define=GEMINI_MODEL=...]
class AssistantService {
  static const apiKey = String.fromEnvironment('GEMINI_API_KEY');
  static const model = String.fromEnvironment('GEMINI_MODEL', defaultValue: 'gemini-2.5-flash');

  /// When set and enabled, calls go through the Hadaq server (key stays server-side).
  BackendService? backend;

  bool get configured => apiKey.isNotEmpty || (backend?.enabled ?? false);

  Future<AssistantReply> _viaBackend(String question, Uint8List? imageJpeg, String? userContext,
      List<(String, String)> history, bool actions) async {
    try {
      final text = await backend!.ask(
        question: question,
        imageB64: imageJpeg != null ? base64Encode(imageJpeg) : null,
        userContext: userContext,
        history: history,
        actions: actions,
      );
      return parseReply(text);
    } on BackendError catch (e) {
      return AssistantReply(e.message);
    } on SocketException {
      throw OfflineException();
    } on http.ClientException {
      throw OfflineException();
    } on TimeoutException {
      return const AssistantReply('تأخر الرد من المساعد. حاول مرة أخرى.');
    }
  }

  static const _system = '''
أنت «حَدَق»، مساعد صوتي لشخص كفيف أو ضعيف البصر. كل ما تكتبه سيُقرأ بصوت عالٍ.
القواعد:
- أجب بالعربية الفصحى المبسطة، بجملة إلى ثلاث جمل قصيرة. لا قوائم ولا رموز ولا تنسيق.
- ابدأ بالأهم للسلامة: العوائق، الدرج، الحفر، السيارات، الأبواب.
- استخدم الاتجاهات بالنسبة للمستخدم: أمامك، على يمينك، على يسارك، وقدّر المسافة بالأمتار أو الخطوات.
- عند قراءة نص اذكر نوعه ثم أهم ما فيه، واعرض قراءة الباقي.
- للدواء: الاسم والتركيز وتاريخ الانتهاء إن ظهر. للعملة: الفئة والعملة.
- إن لم تكن متأكدًا فقل ذلك بوضوح، ولا تخترع. لا تحدد هوية أشخاص من وجوههم.
- ليست بديلًا عن العصا البيضاء؛ لا تقل إن الطريق آمن تمامًا.
أعد JSON فقط بهذا الشكل:
{"answer": "النص المنطوق", "label": "وصف من كلمتين لما في الصورة أو فارغ", "suggestions": ["رد سريع 1", "رد سريع 2"]}
الردود السريعة (0 إلى 3) عبارات قصيرة يمكن للمستخدم قولها بعدك، مثل «اقرأ النشرة» أو «لا شكرًا».''';

  /// [history] is the last few turns as (user, assistant) pairs for context.
  Future<AssistantReply> ask(
    String question, {
    Uint8List? imageJpeg,
    String? userContext,
    List<(String, String)> history = const [],
    bool actions = false,
  }) async {
    if (backend?.enabled ?? false) return _viaBackend(question, imageJpeg, userContext, history, actions);
    if (!configured) {
      return const AssistantReply(
          'لم يُضبط مفتاح المساعد الذكي بعد. يحتاج المطوّر إلى إضافة مفتاح Gemini عند بناء التطبيق.');
    }
    final contents = <Map<String, dynamic>>[];
    for (final (u, a) in history.take(6)) {
      contents.add({'role': 'user', 'parts': [{'text': u}]});
      contents.add({'role': 'model', 'parts': [{'text': jsonEncode({'answer': a})}]});
    }
    contents.add({
      'role': 'user',
      'parts': [
        if (imageJpeg != null) {'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(imageJpeg)}},
        {'text': question},
      ],
    });

    final body = {
      'system_instruction': {
        'parts': [
          {'text': _system + (userContext != null ? '\n\nمعلومات عن المستخدم (من ذاكرته): $userContext' : '')}
        ]
      },
      'contents': contents,
      'generationConfig': {
        'responseMimeType': 'application/json',
        'temperature': 0.3,
        'maxOutputTokens': 400,
      },
    };

    final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey');
    final http.Response res;
    try {
      res = await http
          .post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 25));
    } on SocketException {
      throw OfflineException();
    } on TimeoutException {
      return const AssistantReply('تأخر الرد من المساعد. حاول مرة أخرى.');
    } on http.ClientException {
      throw OfflineException();
    }
    if (res.statusCode != 200) {
      return AssistantReply('تعذّر الوصول إلى المساعد الآن. الرمز ${res.statusCode}.');
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final text = (((j['candidates'] as List?)?.first as Map?)?['content']?['parts'] as List?)
            ?.map((p) => (p as Map)['text'] ?? '')
            .join() ??
        '';
    return parseReply(text);
  }

  static AssistantReply parseReply(String text) {
    var t = text.trim();
    if (t.startsWith('```')) {
      t = t.replaceAll(RegExp(r'^```(json)?'), '').replaceAll(RegExp(r'```$'), '').trim();
    }
    try {
      final m = jsonDecode(t) as Map<String, dynamic>;
      final label = (m['label'] as String?)?.trim();
      return AssistantReply(
        (m['answer'] as String? ?? '').trim(),
        label: (label == null || label.isEmpty) ? null : label,
        suggestions: ((m['suggestions'] as List?) ?? []).map((e) => '$e').take(3).toList(),
        action: m['action'] is Map && (m['action'] as Map)['type'] is String && (m['action'] as Map)['type'] != 'none'
            ? Map<String, dynamic>.from(m['action'] as Map)
            : null,
      );
    } catch (_) {
      return AssistantReply(t.isEmpty ? 'لم أفهم الرد. حاول مرة أخرى.' : t);
    }
  }
}
