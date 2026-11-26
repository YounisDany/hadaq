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

ThemeData hadaqTheme() => ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: HC.bgBottom,
      colorScheme: const ColorScheme.dark(primary: HC.blue, surface: HC.navy),
      useMaterial3: true,
    );
