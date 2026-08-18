/// Legacy theme entry point — now a thin shim over the token design system
/// in `ui/tokens.dart`, kept so existing imports and tests keep working.
///
/// New UI code imports `ui/tokens.dart` directly ([AppSpacing], [AppRadius],
/// [AppMotion], `context.tokens`); this file only preserves the original
/// two names.
library;

import 'package:flutter/material.dart';

import 'ui/tokens.dart';

export 'ui/tokens.dart';

/// Fixed spacing scale used across every screen. Superseded by [AppSpacing]
/// (same values); retained because existing screens/tests reference it.
abstract final class Spacing {
  static const double s4 = AppSpacing.s4;
  static const double s8 = AppSpacing.s8;
  static const double s12 = AppSpacing.s12;
  static const double s16 = AppSpacing.s16;
  static const double s24 = AppSpacing.s24;
}

/// Builds the app's [ThemeData] for [brightness]. Delegates to the token
/// design system so light and dark stay one design with one source of truth.
ThemeData buildAppTheme(Brightness brightness) => buildAppThemeData(brightness);
