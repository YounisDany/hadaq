import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Camera that is OFF by default: opened for one question, one photo, then closed
/// (design: «الكاميرا مغلقة افتراضيًا… لا تُحفظ الصور»). The photo is kept only in memory.
class CameraService {
  CameraController? controller;

  Future<bool> open() async {
    if (!(await Permission.camera.request()).isGranted) return false;
    final cams = await availableCameras();
    if (cams.isEmpty) return false;
    final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
    controller = CameraController(back, ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
    await controller!.initialize();
    try {
      await controller!.setFocusMode(FocusMode.auto);
      await controller!.setExposureMode(ExposureMode.auto);
      // Flash only when it's dark: many photos came back «مظلمة».
      await controller!.setFlashMode(FlashMode.auto);
    } catch (_) {}
    return true;
  }

  Future<Uint8List?> capture() async {
    final c = controller;
    if (c == null || !c.value.isInitialized) return null;
    // Hold for a second so focus and exposure settle and the hand steadies
    // (350 ms gave blurry pictures); then focus on the center, where the user points.
    try {
      await c.setFocusPoint(const Offset(0.5, 0.5));
      await c.setExposurePoint(const Offset(0.5, 0.5));
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 1100));
    final file = await c.takePicture();
    final bytes = await file.readAsBytes();
    try {
      await File(file.path).delete(); // don't leave the photo on disk
    } catch (_) {}
    return bytes;
  }

  Future<void> close() async {
    final c = controller;
    controller = null;
    await c?.dispose();
  }
}

/// Native bridge (MainActivity.kt): SMS for SOS and the volume-up "talk" key.
class NativeBridge {
  static const _ch = MethodChannel('hadaq/native');

  static void Function()? _volumeUp;
  static void Function(bool ok)? _whatsappSent;

  static void _listen() => _ch.setMethodCallHandler((call) async {
        if (call.method == 'volumeUp') _volumeUp?.call();
        if (call.method == 'whatsappSent') _whatsappSent?.call(call.arguments == true);
        return null;
      });

  static void onVolumeUp(void Function() cb) {
    _volumeUp = cb;
    _listen();
  }

  static void onWhatsAppSent(void Function(bool ok) cb) {
    _whatsappSent = cb;
    _listen();
  }

  /// Launchable apps on the phone: (label, package).
  static Future<List<(String, String)>> listApps() async {
    try {
      final r = await _ch.invokeMethod<List>('listApps') ?? const [];
      return [for (final m in r.cast<Map>()) ('${m['label']}', '${m['package']}')];
    } catch (_) {
      return const [];
    }
  }

  static Future<bool> openApp(String package) async {
    try {
      return await _ch.invokeMethod<bool>('openApp', {'package': package}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Whether the «حَدَق — إرسال واتساب» accessibility service is turned on.
  static Future<bool> autoSendEnabled() async {
    try {
      return await _ch.invokeMethod<bool>('a11yEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openAccessibilitySettings() async {
    try {
      await _ch.invokeMethod('openA11ySettings');
    } catch (_) {}
  }

  /// The contact's exact WhatsApp number (international digits) as WhatsApp
  /// registered it in the phonebook, or null if they have no WhatsApp.
  static Future<String?> whatsappNumberFor(String name, String number) async {
    try {
      return await _ch.invokeMethod<String>('waNumber', {'name': name, 'number': number});
    } catch (_) {
      return null;
    }
  }

  /// 'armed' (auto-send on) | 'opened' (user presses send) | 'not_installed' | 'failed'
  static Future<String> sendWhatsApp(String phone, String text, {bool auto = true, String mode = 'link'}) async {
    try {
      return await _ch.invokeMethod<String>('sendWhatsApp', {'phone': phone, 'text': text, 'auto': auto, 'mode': mode}) ??
          'failed';
    } catch (_) {
      return 'failed';
    }
  }

  static Future<bool> ensureSmsPermission() async => (await Permission.sms.request()).isGranted;

  /// Returns the number of messages sent, or -1 on failure.
  static Future<int> sendSms(List<String> numbers, String text) async {
    try {
      if (!await ensureSmsPermission()) return -1;
      return await _ch.invokeMethod<int>('sendSms', {'numbers': numbers, 'text': text}) ?? 0;
    } catch (_) {
      return -1;
    }
  }
}

/// «هز الهاتف 3 مرات» -> SOS.
class ShakeDetector {
  StreamSubscription<UserAccelerometerEvent>? _sub;
  final List<DateTime> _peaks = [];
  DateTime _lastPeak = DateTime(2000);

  void start(void Function() onTripleShake) {
    _sub = userAccelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen((e) {
      final g = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
      final now = DateTime.now();
      if (g > 18 && now.difference(_lastPeak).inMilliseconds > 250) {
        _lastPeak = now;
        _peaks.add(now);
        _peaks.removeWhere((t) => now.difference(t).inMilliseconds > 1500);
        if (_peaks.length >= 3) {
          _peaks.clear();
          onTripleShake();
        }
      }
    });
  }

  void stop() => _sub?.cancel();
}
