import 'package:flutter/material.dart';

class AppColors {
  static const well = Color(0xFF0B1922);
  static const submerged = Color(0xFF1A2D3D);
  static const stream = Color(0xFF2DD4BF);
  static const leaf = Color(0xFF34D399);
  static const sunlight = Color(0xFFFBBF24);
  static const mist = Color(0xFF94A3B8);
  static const foam = Color(0xFFF1F5F9);
  static const danger = Color(0xFFFF7A7A);

  static const surface = Color(0xFF152535);
  static const surfaceLight = Color(0xFF1E3347);
  static const border = Color(0x14FFFFFF);
  static const borderActive = Color(0x402DD4BF);
}

class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
}

class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}

class AppShadows {
  static const card = [
    BoxShadow(color: Color(0x30000000), blurRadius: 12, offset: Offset(0, 4)),
  ];
  static const glow = [
    BoxShadow(color: Color(0x262DD4BF), blurRadius: 20, spreadRadius: 0),
  ];
}
