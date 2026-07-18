/// Single Material 3 theme (light + dark) and the app's spacing scale.
///
/// Kept as one small file so every screen shares one source of truth for
/// color and spacing instead of hardcoding magic numbers.
library;

import 'package:flutter/material.dart';

/// Fixed spacing scale used across every screen. `abstract final class` so
/// it is never instantiated — a namespace for `const` values only.
abstract final class Spacing {
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s24 = 24;
}

/// Builds the app's [ThemeData] for [brightness]. Both light and dark share
/// the same seed color so the two themes read as one design, not two.
ThemeData buildAppTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: Colors.teal,
    brightness: brightness,
  );
  return ThemeData(colorScheme: scheme, useMaterial3: true);
}
