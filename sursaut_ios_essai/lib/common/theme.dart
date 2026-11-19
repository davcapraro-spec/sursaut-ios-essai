import 'package:flutter/material.dart';

/// Couleurs reprises de la maquette (fond sombre, accent ambre).
const Color kGround = Color(0xFF151517);
const Color kPanel = Color(0xFF1E1E21);
const Color kAccent = Color(0xFFF2A33A);

ThemeData sursautDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kAccent,
    brightness: Brightness.dark,
  ).copyWith(primary: kAccent, surface: kPanel);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kGround,
    sliderTheme: const SliderThemeData(
      trackHeight: 4,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 14),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 28),
    ),
  );
}
