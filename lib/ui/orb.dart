import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../app/controller.dart';
import 'theme.dart';

/// The «كرة الصوت» — the centre of the single screen. Its look follows the phase.
class VoiceOrb extends StatefulWidget {
  final Phase phase;
  final int sosCount;
  final CameraController? camera;
  final double size;
  const VoiceOrb({super.key, required this.phase, this.sosCount = 0, this.camera, this.size = 190});

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _a =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  (Color, Color) get _colors => switch (widget.phase) {
        Phase.saved => (const Color(0xFF4BE08A), HC.green),
        Phase.clarify => (const Color(0xFFFFD27A), HC.amber),
        Phase.sos => (const Color(0xFFFF8A8E), HC.red),
        _ => (HC.blueLight, HC.blue),
      };

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final (c1, c2) = _colors;
    final cam = widget.camera;
    final showCam = widget.phase == Phase.camera && cam != null && cam.value.isInitialized;

    return AnimatedBuilder(
      animation: _a,
      builder: (context, _) {
        final t = _a.value;
        final active = widget.phase == Phase.listening || widget.phase == Phase.sos;
        final pulse = widget.phase == Phase.thinking ? 1 + 0.05 * math.sin(t * 2 * math.pi) : 1.0;
        return SizedBox(
          width: s * 1.45,
          height: s * 1.45,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (active)
                for (var i = 0; i < 3; i++)
                  _ring(s, (t + i / 3) % 1, c2),
              Transform.scale(
                scale: pulse,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 350),
                  width: s,
                  height: s,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      center: const Alignment(-0.3, -0.4),
                      colors: [c1, c2, Color.lerp(c2, Colors.black, 0.35)!],
                      stops: const [0, 0.55, 1],
                    ),
                    boxShadow: [BoxShadow(color: c2.withValues(alpha: 0.55), blurRadius: 60, spreadRadius: 6)],
                  ),
                  child: ClipOval(
                    child: showCam
                        ? FittedBox(
                            fit: BoxFit.cover,
                            child: SizedBox(
                              width: s,
                              height: s * cam.value.aspectRatio,
                              child: CameraPreview(cam),
                            ),
                          )
                        : Center(child: _icon(s, t)),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _ring(double s, double p, Color c) => Opacity(
        opacity: (1 - p) * 0.5,
        child: Container(
          width: s * (1 + 0.45 * p),
          height: s * (1 + 0.45 * p),
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: c, width: 2)),
        ),
      );

  Widget _icon(double s, double t) {
    switch (widget.phase) {
      case Phase.idle:
        return Icon(Icons.mic_none_rounded, size: s * 0.38, color: Colors.white);
      case Phase.saved:
        return Icon(Icons.check_rounded, size: s * 0.45, color: Colors.white);
      case Phase.clarify:
        return Text('؟', style: TextStyle(fontSize: s * 0.42, fontWeight: FontWeight.w800, color: Colors.white));
      case Phase.sos:
        return Text(widget.sosCount > 0 ? '${widget.sosCount}' : 'SOS',
            style: TextStyle(fontSize: s * (widget.sosCount > 0 ? 0.42 : 0.24), fontWeight: FontWeight.w900, color: Colors.white));
      case Phase.setup:
        return _bars(s, t, live: true);
      case Phase.update:
        return Icon(Icons.system_update_rounded, size: s * 0.4, color: Colors.white);
      case Phase.memory:
        return Icon(Icons.psychology_alt_rounded, size: s * 0.4, color: Colors.white);
      case Phase.camera:
        return Icon(Icons.photo_camera_rounded, size: s * 0.36, color: Colors.white);
      case Phase.listening:
      case Phase.thinking:
      case Phase.answer:
        return _bars(s, t, live: widget.phase == Phase.listening);
    }
  }

  Widget _bars(double s, double t, {required bool live}) {
    const base = [0.35, 0.6, 0.85, 0.55, 1.0, 0.7, 0.45, 0.8, 0.4];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < base.length; i++)
          Container(
            margin: EdgeInsets.symmetric(horizontal: s * 0.012),
            width: s * 0.028,
            height: s * 0.32 * (live ? (0.35 + 0.65 * (0.5 + 0.5 * math.sin(t * 2 * math.pi * 2 + i))) * base[i] + 0.1 : base[i] * 0.8),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
          ),
      ],
    );
  }
}
