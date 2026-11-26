import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';

/// Earcons + haptics from the design's «إشارات الصوت والاهتزاز» table.
enum Cue { listen, thinking, understood, saved, error, alarm }

class FeedbackService {
  final AudioPlayer _player = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
  bool strongVibration = false;
  bool? _hasVibrator;
  Timer? _pulse;

  Future<void> _vibrate(List<int> pattern) async {
    _hasVibrator ??= await Vibration.hasVibrator();
    if (_hasVibrator != true) return;
    final amp = strongVibration ? 255 : 140;
    await Vibration.vibrate(pattern: pattern, intensities: pattern.map((_) => amp).toList());
  }

  Future<void> cue(Cue c) async {
    switch (c) {
      case Cue.listen: // نغمة صاعدة + نقرة
        _play('listen');
        _vibrate([0, 30]);
      case Cue.thinking: // نبضة خفيفة كل ثانية
        _play('tick');
        _vibrate([0, 15]);
      case Cue.understood: // نغمتان قصيرتان
        _play('understood');
      case Cue.saved: // نغمة نجاح + اهتزاز مزدوج
        _play('saved');
        _vibrate([0, 60, 90, 60]);
      case Cue.error: // نغمة هابطة + اهتزاز طويل
        _play('error');
        _vibrate([0, 450]);
      case Cue.alarm:
        _play('alarm');
        _vibrate([0, 300, 150, 300]);
    }
  }

  void _play(String name) {
    _player.stop().then((_) => _player.play(AssetSource('sounds/$name.wav'), volume: 0.7)).catchError((_) {});
  }

  /// Soft waiting tick: starts right away (the user knows they were heard), then
  /// repeats until the reply begins.
  void startThinking() {
    stopThinking();
    cue(Cue.thinking);
    _pulse = Timer.periodic(const Duration(milliseconds: 900), (_) => cue(Cue.thinking));
  }

  void stopThinking() {
    _pulse?.cancel();
    _pulse = null;
  }
}
