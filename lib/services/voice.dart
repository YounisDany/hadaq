import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Speech in (STT) and speech out (TTS), Arabic.
class VoiceService {
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final AudioRecorder _rec = AudioRecorder();
  bool _recording = false;
  bool _stopRequested = false;
  bool sttReady = false;
  String? _localeId;
  bool speaking = false;

  /// Base TTS rate for normal speech (flutter_tts: 0..1 on Android, 0.5 ≈ natural).
  static const _baseRate = 0.5;

  Future<void> init({double rateMultiplier = 1.0, double volume = 1.0}) async {
    sttReady = await _stt.initialize(onError: (_) {}, onStatus: (_) {});
    if (sttReady) {
      final locales = await _stt.locales();
      String? pick(String prefix) {
        for (final l in locales) {
          if (l.localeId.toLowerCase().replaceAll('-', '_').startsWith(prefix)) return l.localeId;
        }
        return null;
      }

      // Always ask for Arabic. Some recognizers (e.g. Google's on Samsung) don't list
      // Arabic in locales() yet still recognise it when asked; falling back to the
      // system locale (often English) turned Arabic speech into English words.
      _localeId = pick('ar_sa') ?? pick('ar') ?? 'ar-SA';
      debugPrint('[hadaq] stt locale=$_localeId (of ${locales.length} listed)');
    }

    await _tts.awaitSpeakCompletion(true);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) await _pickArabicEngine();
    final langs = (await _tts.getLanguages as List?)?.map((e) => '$e').toList() ?? [];
    final lang = langs.firstWhere((l) => l.toLowerCase().replaceAll('_', '-').startsWith('ar-sa'),
        orElse: () => langs.firstWhere((l) => l.toLowerCase().startsWith('ar'), orElse: () => 'ar-SA'));
    final res = await _tts.setLanguage(lang);
    if (!kIsWeb) await _pickLocalArabicVoice();
    debugPrint('[hadaq] tts engine=$engine lang=$lang setLanguage=$res arabicVoice=$hasArabicVoice');
    await applySettings(rateMultiplier: rateMultiplier, volume: volume);
    _tts.setStartHandler(() => speaking = true);
    _tts.setCompletionHandler(() => speaking = false);
    _tts.setCancelHandler(() => speaking = false);
    _tts.setErrorHandler((_) => speaking = false);
  }

  String? engine;
  bool hasArabicVoice = true;

  Future<void> _pickLocalArabicVoice() async {
    try {
      final voices = ((await _tts.getVoices) as List?)?.cast<Map>() ?? const [];
      Map? pick;
      for (final v in voices) {
        final name = '${v['name']}'.toLowerCase();
        final loc = '${v['locale']}'.toLowerCase();
        if (!loc.startsWith('ar')) continue;
        final local = name.contains('local') || (v['network_required'] == false || '${v['network_required']}' == '0');
        if (local && (pick == null || name.contains('arz') || name.contains('-ar-'))) pick = v;
      }
      if (pick != null) {
        await _tts.setVoice({'name': '${pick['name']}', 'locale': '${pick['locale']}'});
        debugPrint('[hadaq] tts local voice ${pick['name']}');
      }
    } catch (_) {}
  }

  /// The phone's default speech engine may have no Arabic voice (Samsung's often
  /// doesn't): it then reads Arabic in an English voice and produces silence.
  /// Prefer Google's engine, and any engine that reports Arabic as available.
  Future<void> _pickArabicEngine() async {
    try {
      final engines = ((await _tts.getEngines) as List?)?.map((e) => '$e').toList() ?? [];
      engines.sort((a, b) => (b.contains('google') ? 1 : 0) - (a.contains('google') ? 1 : 0));
      for (final e in engines) {
        await _tts.setEngine(e);
        await Future.delayed(const Duration(milliseconds: 400)); // engine re-binds
        final ok = await _tts.isLanguageAvailable('ar-SA') == true || await _tts.isLanguageAvailable('ar') == true;
        debugPrint('[hadaq] tts engine $e arabic=$ok');
        if (ok) {
          engine = e;
          hasArabicVoice = true;
          return;
        }
      }
      hasArabicVoice = false;
      if (engines.isNotEmpty) {
        engine = engines.first;
        await _tts.setEngine(engine!);
      }
    } catch (e) {
      debugPrint('[hadaq] tts engine pick failed: $e');
    }
  }

  Future<void> applySettings({required double rateMultiplier, required double volume}) async {
    _rate = rateMultiplier;
    await _tts.setSpeechRate((_baseRate * rateMultiplier).clamp(0.2, 1.0));
    await _tts.setVolume(volume.clamp(0.2, 1.0));
  }

  // ---------------------------------------------------------------- GPT voice
  /// When set, replies are spoken with the GPT voice streamed from the server
  /// (returns the stream URL for a text). Null = the phone's own voice.
  String Function(String text)? cloudUrl;
  final AudioPlayer _cloud = AudioPlayer();
  double _rate = 1.0;
  int _cloudFailures = 0;
  Completer<void>? _cloudDone;

  /// Speaks [text]. Uses the GPT voice when available; [local] forces the phone's
  /// voice (emergencies: no network delay). Falls back to the phone's voice on any error.
  Future<void> speak(String text, {bool local = false}) async {
    if (text.trim().isEmpty) return;
    await stopSpeaking();
    speaking = true;
    try {
      if (!local && cloudUrl != null && _cloudFailures < 3 && await _speakCloud(text)) return;
      await _tts.speak(text);
    } finally {
      speaking = false;
    }
  }

  /// Streams and plays the GPT voice; returns false if it could not start.
  Future<bool> _speakCloud(String text) async {
    final done = Completer<void>();
    _cloudDone = done;
    final started = Completer<bool>();
    final subs = <StreamSubscription>[
      _cloud.onPlayerStateChanged.listen((st) {
        if (st == PlayerState.playing && !started.isCompleted) started.complete(true);
        if ((st == PlayerState.stopped || st == PlayerState.completed) && !done.isCompleted) done.complete();
      }),
      _cloud.onPlayerComplete.listen((_) {
        if (!done.isCompleted) done.complete();
      }),
    ];
    try {
      await _cloud.setReleaseMode(ReleaseMode.stop);
      await _cloud.setPlaybackRate(_rate.clamp(0.5, 2.0));
      await _cloud.play(UrlSource(cloudUrl!(text), mimeType: 'audio/mpeg'));
      final ok = await started.future.timeout(const Duration(seconds: 7), onTimeout: () => false);
      if (!ok) {
        _cloudFailures++;
        await _cloud.stop();
        return false;
      }
      _cloudFailures = 0;
      // Wait until it finishes (or is stopped), with a generous safety cap.
      await done.future.timeout(const Duration(seconds: 90), onTimeout: () {});
      return true;
    } catch (e) {
      debugPrint('[hadaq] cloud tts failed: $e');
      _cloudFailures++;
      return false;
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
      if (identical(_cloudDone, done)) _cloudDone = null;
    }
  }

  Future<void> stopSpeaking() async {
    speaking = false;
    final d = _cloudDone;
    if (d != null && !d.isCompleted) d.complete();
    try {
      await _cloud.stop();
    } catch (_) {}
    await _tts.stop();
  }

  /// Listens until the user goes silent (design: «أتوقف تلقائيًا عندما تصمت»).
  /// [onPartial] is called with live text; the future completes with the final text
  /// ('' if nothing was heard).
  Future<String> listen({required void Function(String) onPartial}) async {
    if (!sttReady) return '';
    final done = Completer<String>();
    var last = '';
    await _stt.listen(
      listenOptions: SpeechListenOptions(
        localeId: _localeId,
        listenFor: const Duration(seconds: 20),
        pauseFor: const Duration(seconds: 2),
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
      ),
      onResult: (SpeechRecognitionResult r) {
        last = r.recognizedWords;
        onPartial(last);
        if (r.finalResult && !done.isCompleted) done.complete(last);
      },
    );
    // Safety net: if the engine stops without a final result.
    unawaited(() async {
      while (!done.isCompleted) {
        await Future.delayed(const Duration(milliseconds: 300));
        if (!_stt.isListening && !done.isCompleted) {
          await Future.delayed(const Duration(milliseconds: 400));
          if (!done.isCompleted) done.complete(last);
        }
      }
    }());
    return done.future;
  }

  Future<void> cancelListening() async {
    if (_recording) {
      _stopRequested = true; // ends the recording now; what was said is still transcribed
      return;
    }
    await _stt.cancel();
  }

  bool get isListening => _stt.isListening || _recording;

  /// Records one utterance for server transcription. Stops by itself after
  /// [silence] of quiet once speech was heard (faster than the phone recogniser's
  /// fixed pause), after [maxLen], or if nobody speaks within [noSpeech].
  /// Returns the audio (AAC/m4a), or null if no speech was detected.
  Future<Uint8List?> recordUtterance({
    void Function(double level)? onLevel,
    Duration silence = const Duration(milliseconds: 900),
    Duration maxLen = const Duration(seconds: 12),
    Duration noSpeech = const Duration(seconds: 5),
  }) async {
    if (!await _rec.hasPermission()) return null;
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/hadaq_utterance.m4a';
    await _rec.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 16000, numChannels: 1, bitRate: 32000, noiseSuppress: true),
      path: path,
    );
    _recording = true;
    _stopRequested = false;
    final started = DateTime.now();
    final floorSamples = <double>[];
    var speech = false;
    var lastLoud = started;
    final done = Completer<void>();
    final sub = _rec.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((a) {
      final db = a.current.isFinite ? a.current : -160.0;
      final now = DateTime.now();
      final t = now.difference(started);
      onLevel?.call(((db + 60) / 60).clamp(0.0, 1.0));
      if (t < const Duration(milliseconds: 300)) {
        floorSamples.add(db);
      } else {
        final floor = floorSamples.isEmpty ? -55.0 : floorSamples.reduce((x, y) => x + y) / floorSamples.length;
        final threshold = math.max(floor + 12, -42.0);
        if (db > threshold) {
          speech = true;
          lastLoud = now;
        }
      }
      final stop = _stopRequested ||
          t > maxLen ||
          (speech && now.difference(lastLoud) > silence) ||
          (!speech && t > noSpeech);
      if (stop && !done.isCompleted) done.complete();
    });
    await done.future;
    await sub.cancel();
    final out = await _rec.stop();
    _recording = false;
    if (!speech || out == null) return null;
    final f = File(out);
    final bytes = await f.readAsBytes();
    try {
      await f.delete(); // recordings are never kept
    } catch (_) {}
    return bytes;
  }
}
