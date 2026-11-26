import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Colours from the Hadaq design (dark navy, blue orb, AAA-contrast text).
abstract class HC {
  static const bgTop = Color(0xFF0B1A4A);
  static const bgBottom = Color(0xFF060E2E);
  static const navy = Color(0xFF0F2366);
  static const card = Color(0xFF16296E);
  static const cardBorder = Color(0xFF2B3F8A);
  static const blue = Color(0xFF3D8BFF);
  static const blueLight = Color(0xFF7FC0FF);
  static const purple = Color(0xFF6C4DF5);
  static const green = Color(0xFF22B35E);
  static const amber = Color(0xFFF5A524);
  static const red = Color(0xFFE5484D);
  static const sosBg = Color(0xFF3A1430);
  static const text = Colors.white;
  static const textDim = Color(0xFFB9C6EE); // 9.6:1 on bgTop
}

/// Frosted-glass surface for every card: blur what's behind, a translucent white
/// sheen and a light edge. [tint] colours it (red for the emergency bar).
class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? tint;
  final double? width;
  const Glass({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.radius = 22, this.tint, this.width});

  @override
  Widget build(BuildContext context) {
    final t = tint;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          width: width,
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: t == null
                  ? [Colors.white.withValues(alpha: 0.16), Colors.white.withValues(alpha: 0.05)]
                  : [t.withValues(alpha: 0.34), t.withValues(alpha: 0.14)],
            ),
            border: Border.all(color: (t ?? Colors.white).withValues(alpha: t == null ? 0.24 : 0.55), width: 1.2),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Font size that keeps long text inside the screen: the longer the text, the smaller.
double fitFont(String s, double base) {
  final n = s.length;
  if (n <= 70) return base;
  if (n <= 140) return base * 0.85;
  if (n <= 260) return base * 0.72;
  return base * 0.62;
}

ThemeData hadaqTheme() => ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: HC.bgBottom,
      colorScheme: const ColorScheme.dark(primary: HC.blue, surface: HC.navy),
      useMaterial3: true,
    );
