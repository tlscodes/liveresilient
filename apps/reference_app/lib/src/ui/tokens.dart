/// Token design system — the single source of truth for color, type,
/// spacing, radius, motion and haptics across every screen.
///
/// Design rules encoded here (do not re-derive per screen):
///  * Semantic colors live in [AppTokens], a [ThemeExtension] — screens never
///    hardcode a hex value or reach into [ColorScheme] for a *semantic* role
///    (bubble/verified/gauge/shimmer); they read `context.tokens`.
///  * Layout constants ([AppSpacing], [AppRadius]) and motion ([AppMotion])
///    are compile-time consts so widgets stay `const`-constructible — part of
///    the 60fps budget.
///  * Everything is direction-agnostic: widgets built on these tokens use
///    EdgeInsetsDirectional / AlignmentDirectional so Persian RTL is
///    first-class, not mirrored as an afterthought.
///  * Type follows the platform's Dynamic Type: styles derive from the
///    ambient [TextTheme] (which Flutter scales via `MediaQuery.textScaler`),
///    never fixed pixel sizes outside this file.
///  * Ambient (repeating) animations run only while [AppMotion.ambient
///    Enabled] — false under `flutter test`, so `pumpAndSettle` in the 185
///    existing tests always settles. Tests that exercise an ambient effect
///    opt back in and pump explicit durations.
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Spacing scale. Supersets the legacy `Spacing` class in `theme.dart`
/// (kept there for source compatibility); new UI code uses this one.
abstract final class AppSpacing {
  static const double s2 = 2;
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;
  static const double s48 = 48;
}

/// Corner radii. `bubble` is the large corner of a chat bubble; the corner
/// pointing at the sender uses `bubbleTail` — set per Directionality, never
/// per left/right.
abstract final class AppRadius {
  static const double r8 = 8;
  static const double r12 = 12;
  static const double r16 = 16;
  static const double r20 = 20;
  static const double r28 = 28;
  static const double bubble = 20;
  static const double bubbleTail = 6;
  static const BorderRadius sheet = BorderRadius.vertical(
    top: Radius.circular(r28),
  );
}

/// Motion tokens. One vocabulary for every animation so the app moves as a
/// single organism. Durations are short on purpose: the 60fps budget treats
/// animation as seasoning, not spectacle.
abstract final class AppMotion {
  /// Micro feedback: ticks, selection, icon swaps.
  static const Duration fast = Duration(milliseconds: 120);

  /// Default transitions: bubble entrance, badge changes.
  static const Duration base = Duration(milliseconds: 220);

  /// Soft reveals: thumbhash → preview cross-fade, sheet slides.
  static const Duration gentle = Duration(milliseconds: 340);

  /// Ambient loops: shimmer sweep, ringing pulse (per cycle).
  static const Duration ambient = Duration(milliseconds: 1400);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;
  static const Curve enter = Curves.easeOutBack;

  /// Gate for repeating animations (shimmer sweep, ringing pulse, gauge
  /// glow). Defaults to off under `flutter test` so `pumpAndSettle` never
  /// hangs on an ambient loop; the running app keeps them on. Widget tests
  /// that verify an ambient effect set this true and pump fixed durations.
  static bool ambientEnabled = !Platform.environment.containsKey(
    'FLUTTER_TEST',
  );
}

/// Semantic colors that Material's [ColorScheme] has no role for.
///
/// Only colors live here (they lerp for theme animation); layout and motion
/// stay in the const namespaces above.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.bubbleMine,
    required this.onBubbleMine,
    required this.bubbleTheirs,
    required this.onBubbleTheirs,
    required this.verified,
    required this.onVerified,
    required this.pending,
    required this.danger,
    required this.gaugeGood,
    required this.gaugeFair,
    required this.gaugePoor,
    required this.shimmerBase,
    required this.shimmerHighlight,
    required this.outlineSoft,
    required this.surfaceGlass,
  });

  /// Outgoing bubble fill and its readable foreground.
  final Color bubbleMine;
  final Color onBubbleMine;

  /// Incoming bubble fill and its readable foreground.
  final Color bubbleTheirs;
  final Color onBubbleTheirs;

  /// Network-truth: content proven end-to-end (real ack / sha match).
  final Color verified;
  final Color onVerified;

  /// Network-truth: in flight, not yet proven.
  final Color pending;

  /// Failures and destructive actions.
  final Color danger;

  /// Live-quality gauge stops (also the diagnostics sparklines).
  final Color gaugeGood;
  final Color gaugeFair;
  final Color gaugePoor;

  /// Skeleton shimmer sweep.
  final Color shimmerBase;
  final Color shimmerHighlight;

  /// Hairline separators softer than [ColorScheme.outlineVariant].
  final Color outlineSoft;

  /// Translucent overlay surface (call-screen chrome over media).
  final Color surfaceGlass;

  static AppTokens light(ColorScheme scheme) => AppTokens(
    bubbleMine: scheme.primary,
    onBubbleMine: scheme.onPrimary,
    bubbleTheirs: scheme.surfaceContainerHigh,
    onBubbleTheirs: scheme.onSurface,
    verified: const Color(0xFF0E9F6E),
    onVerified: Colors.white,
    pending: scheme.onSurfaceVariant,
    danger: const Color(0xFFE02D3C),
    gaugeGood: const Color(0xFF0E9F6E),
    gaugeFair: const Color(0xFFD97706),
    gaugePoor: const Color(0xFFE02D3C),
    shimmerBase: scheme.surfaceContainerHigh,
    shimmerHighlight: scheme.surfaceContainerLowest,
    outlineSoft: scheme.outlineVariant.withValues(alpha: 0.5),
    surfaceGlass: scheme.surface.withValues(alpha: 0.72),
  );

  static AppTokens dark(ColorScheme scheme) => AppTokens(
    bubbleMine: scheme.primaryContainer,
    onBubbleMine: scheme.onPrimaryContainer,
    bubbleTheirs: scheme.surfaceContainerHigh,
    onBubbleTheirs: scheme.onSurface,
    verified: const Color(0xFF34D399),
    onVerified: const Color(0xFF052E22),
    pending: scheme.onSurfaceVariant,
    danger: const Color(0xFFF87171),
    gaugeGood: const Color(0xFF34D399),
    gaugeFair: const Color(0xFFFBBF24),
    gaugePoor: const Color(0xFFF87171),
    shimmerBase: scheme.surfaceContainerHigh,
    shimmerHighlight: scheme.surfaceContainerHighest,
    outlineSoft: scheme.outlineVariant.withValues(alpha: 0.4),
    surfaceGlass: scheme.surface.withValues(alpha: 0.66),
  );

  @override
  AppTokens copyWith({
    Color? bubbleMine,
    Color? onBubbleMine,
    Color? bubbleTheirs,
    Color? onBubbleTheirs,
    Color? verified,
    Color? onVerified,
    Color? pending,
    Color? danger,
    Color? gaugeGood,
    Color? gaugeFair,
    Color? gaugePoor,
    Color? shimmerBase,
    Color? shimmerHighlight,
    Color? outlineSoft,
    Color? surfaceGlass,
  }) {
    return AppTokens(
      bubbleMine: bubbleMine ?? this.bubbleMine,
      onBubbleMine: onBubbleMine ?? this.onBubbleMine,
      bubbleTheirs: bubbleTheirs ?? this.bubbleTheirs,
      onBubbleTheirs: onBubbleTheirs ?? this.onBubbleTheirs,
      verified: verified ?? this.verified,
      onVerified: onVerified ?? this.onVerified,
      pending: pending ?? this.pending,
      danger: danger ?? this.danger,
      gaugeGood: gaugeGood ?? this.gaugeGood,
      gaugeFair: gaugeFair ?? this.gaugeFair,
      gaugePoor: gaugePoor ?? this.gaugePoor,
      shimmerBase: shimmerBase ?? this.shimmerBase,
      shimmerHighlight: shimmerHighlight ?? this.shimmerHighlight,
      outlineSoft: outlineSoft ?? this.outlineSoft,
      surfaceGlass: surfaceGlass ?? this.surfaceGlass,
    );
  }

  @override
  AppTokens lerp(AppTokens? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppTokens(
      bubbleMine: l(bubbleMine, other.bubbleMine),
      onBubbleMine: l(onBubbleMine, other.onBubbleMine),
      bubbleTheirs: l(bubbleTheirs, other.bubbleTheirs),
      onBubbleTheirs: l(onBubbleTheirs, other.onBubbleTheirs),
      verified: l(verified, other.verified),
      onVerified: l(onVerified, other.onVerified),
      pending: l(pending, other.pending),
      danger: l(danger, other.danger),
      gaugeGood: l(gaugeGood, other.gaugeGood),
      gaugeFair: l(gaugeFair, other.gaugeFair),
      gaugePoor: l(gaugePoor, other.gaugePoor),
      shimmerBase: l(shimmerBase, other.shimmerBase),
      shimmerHighlight: l(shimmerHighlight, other.shimmerHighlight),
      outlineSoft: l(outlineSoft, other.outlineSoft),
      surfaceGlass: l(surfaceGlass, other.surfaceGlass),
    );
  }
}

extension AppTokensContext on BuildContext {
  /// `context.tokens` — the only sanctioned way to read semantic colors.
  AppTokens get tokens => Theme.of(this).extension<AppTokens>()!;
}

/// Standard haptic vocabulary. Routed through one seam so tests can silence
/// it and so the app speaks one physical language: selection for navigation,
/// light for send, success/warning for network-truth moments.
abstract final class AppHaptics {
  /// Test seam: widget tests set this false; goldens never vibrate.
  static bool enabled = !Platform.environment.containsKey('FLUTTER_TEST');

  static void selection() {
    if (enabled) HapticFeedback.selectionClick();
  }

  static void light() {
    if (enabled) HapticFeedback.lightImpact();
  }

  static void medium() {
    if (enabled) HapticFeedback.mediumImpact();
  }

  /// A network-truth confirmation (delivered / sha-verified).
  static void success() {
    if (enabled) HapticFeedback.lightImpact();
  }

  /// Quality drop, failure, slide-to-cancel commit.
  static void warning() {
    if (enabled) HapticFeedback.heavyImpact();
  }
}

/// Builds the full [ThemeData] for [brightness] — the one theme factory.
///
/// Both brightnesses share one seed so light and dark read as one design.
/// Type ramp: derived from Material defaults (Dynamic Type flows through
/// `MediaQuery.textScaler` untouched), with weight/height tuned for mixed
/// Persian/Latin chat text.
ThemeData buildAppThemeData(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF00696D),
    brightness: brightness,
  );
  final tokens = brightness == Brightness.light
      ? AppTokens.light(scheme)
      : AppTokens.dark(scheme);
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final text = base.textTheme.copyWith(
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w600,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.35),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.35),
    labelSmall: base.textTheme.labelSmall?.copyWith(letterSpacing: 0.2),
  );
  return base.copyWith(
    textTheme: text,
    extensions: <ThemeExtension<dynamic>>[tokens],
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 64,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.secondaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s16,
        vertical: AppSpacing.s12,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.r28),
        borderSide: BorderSide.none,
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.r16),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.r12),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.sheet),
      showDragHandle: true,
    ),
    dividerTheme: DividerThemeData(
      color: tokens.outlineSoft,
      thickness: 0.5,
      space: 0.5,
    ),
    splashFactory: InkSparkle.splashFactory,
  );
}
