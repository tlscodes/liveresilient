/// Live call-quality instruments: an arc gauge, the adaptive-ladder display,
/// and the voice-note survival banner.
///
/// Everything here is fed by real [CallQualityReading]s and the real
/// [OperatingRung] — the widgets never invent data. No reading means dashes
/// and a "no signal" state, never a synthesized number.
library;

import 'dart:math' as math;

import 'package:call_core/call_core.dart' show OperatingRung;
import 'package:flutter/material.dart';

import 'network_truth.dart';
import 'tokens.dart';

/// Needle position 0..1 for [reading]; the single scoring formula shared by
/// the painter and the tests.
///
/// Returns null when [reading] is null or carries neither rtt nor loss (an
/// "empty" reading) — the gauge shows no needle rather than a made-up one.
/// Otherwise: `1 - (rttMs/1000)*0.5 - (lossFraction/0.3)*0.5`, clamped to
/// 0..1, with a null rtt or loss contributing zero penalty.
double? qualityScore(CallQualityReading? reading) {
  if (reading == null) return null;
  final rtt = reading.rttMs;
  final loss = reading.lossFraction;
  if (rtt == null && loss == null) return null;
  final score = 1 - ((rtt ?? 0) / 1000) * 0.5 - ((loss ?? 0) / 0.3) * 0.5;
  return score.clamp(0.0, 1.0);
}

/// Coarse, user-facing step of the adaptive ladder. The fine-grained truth
/// is the [OperatingRung] itself, which [LadderRungIndicator] also prints.
enum LadderStep {
  /// Full audio+video ([OperatingRung.fullVideo]).
  hd,

  /// Reduced-resolution video ([OperatingRung.reducedVideo]).
  sd,

  /// Voice only at full quality ([OperatingRung.audioOnly]).
  audio,

  /// Every below-audio survival rung, down to text-only.
  survival,
}

/// Maps the fine-grained [rung] to its coarse display step.
LadderStep ladderStepOf(OperatingRung rung) {
  switch (rung) {
    case OperatingRung.fullVideo:
      return LadderStep.hd;
    case OperatingRung.reducedVideo:
      return LadderStep.sd;
    case OperatingRung.audioOnly:
      return LadderStep.audio;
    case OperatingRung.lowRateVoice:
    case OperatingRung.tokenVoiceFull:
    case OperatingRung.tokenVoiceRow0:
    case OperatingRung.voiceNotes:
    case OperatingRung.textOnly:
      return LadderStep.survival;
  }
}

/// Resolves [AppTokens] even when the surrounding theme was not built with
/// [buildAppThemeData] (several pinned tests pump a plain [MaterialApp]);
/// falls back to the token set derived from the ambient [ColorScheme].
AppTokens tokensOrDefault(BuildContext context) {
  final theme = Theme.of(context);
  return theme.extension<AppTokens>() ??
      (theme.brightness == Brightness.dark
          ? AppTokens.dark(theme.colorScheme)
          : AppTokens.light(theme.colorScheme));
}

/// A 240-degree arc gauge for one live [CallQualityReading].
///
/// The numbers are the hero (big rtt, loss beneath); the arc is context.
/// The needle animates one-shot to each new value ([AppMotion.base]) and is
/// hidden entirely while there is no scoreable reading.
class QualityGauge extends StatelessWidget {
  /// Creates the gauge for [reading]; null renders the no-signal state.
  const QualityGauge({super.key, this.reading, this.size = 148});

  /// Latest live reading, or null when no stats have arrived yet.
  final CallQualityReading? reading;

  /// Diameter of the dial in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = tokensOrDefault(context);
    final score = qualityScore(reading);
    final band = bandOf(reading);
    final rtt = reading?.rttMs;
    final loss = reading?.lossFraction;

    final bandColor = switch (band) {
      QualityBand.good => tokens.gaugeGood,
      QualityBand.fair => tokens.gaugeFair,
      QualityBand.poor => tokens.gaugePoor,
      QualityBand.unknown => tokens.pending,
    };
    final bandWord = switch (band) {
      QualityBand.good => 'good',
      QualityBand.fair => 'fair',
      QualityBand.poor => 'poor',
      QualityBand.unknown => 'no signal',
    };

    return Semantics(
      label: 'Call quality gauge',
      value: rtt == null && loss == null
          ? 'no reading yet'
          : '${rtt ?? 0} milliseconds round trip, '
                '${((loss ?? 0) * 100).toStringAsFixed(1)} percent loss, '
                '$bandWord',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: AlignmentDirectional.center,
              children: [
                RepaintBoundary(
                  child: TweenAnimationBuilder<double>(
                    // begin left null on purpose: the first build shows the
                    // value immediately; only CHANGES animate (one-shot,
                    // settle-safe — nothing repeats).
                    tween: Tween<double>(end: score ?? 0),
                    duration: AppMotion.base,
                    curve: AppMotion.standard,
                    builder: (context, needle, _) => CustomPaint(
                      size: Size.square(size),
                      painter: _GaugePainter(
                        needle: score == null ? null : needle,
                        track: tokens.outlineSoft,
                        good: tokens.gaugeGood,
                        fair: tokens.gaugeFair,
                        poor: tokens.gaugePoor,
                        needleColor: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      rtt == null ? '—' : '$rtt ms',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: AppSpacing.s2),
                    Text(
                      loss == null
                          ? '—'
                          : '${(loss * 100).toStringAsFixed(1)}% loss',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          Container(
            padding: const EdgeInsetsDirectional.symmetric(
              horizontal: AppSpacing.s12,
              vertical: AppSpacing.s4,
            ),
            decoration: BoxDecoration(
              color: bandColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadius.r12),
              border: Border.all(color: bandColor.withValues(alpha: 0.5)),
            ),
            child: Text(
              bandWord,
              style: theme.textTheme.labelSmall?.copyWith(
                color: bandColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints the 240° dial: full-sweep track, three fixed band segments
/// (poor → fair → good, low to high), and the needle at [needle] (0..1),
/// hidden when null.
class _GaugePainter extends CustomPainter {
  const _GaugePainter({
    required this.needle,
    required this.track,
    required this.good,
    required this.fair,
    required this.poor,
    required this.needleColor,
  });

  final double? needle;
  final Color track;
  final Color good;
  final Color fair;
  final Color poor;
  final Color needleColor;

  static const double _start = 150 * math.pi / 180;
  static const double _sweep = 240 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final stroke = size.shortestSide * 0.075;
    final radius = size.shortestSide / 2 - stroke;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawArc(
      rect,
      _start,
      _sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = track,
    );

    // Three fixed thirds; small gaps let the track show through.
    const gap = 0.02;
    void segment(double from, double to, Color color) {
      canvas.drawArc(
        rect,
        _start + _sweep * from,
        _sweep * (to - from),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.butt
          ..color = color,
      );
    }

    segment(0, 1 / 3 - gap, poor);
    segment(1 / 3 + gap, 2 / 3 - gap, fair);
    segment(2 / 3 + gap, 1, good);

    final value = needle;
    if (value != null) {
      final angle = _start + _sweep * value.clamp(0.0, 1.0);
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + direction * (radius * 0.58),
        center + direction * (radius + stroke * 0.5),
        Paint()
          ..strokeWidth = stroke * 0.55
          ..strokeCap = StrokeCap.round
          ..color = needleColor,
      );
    }
  }

  @override
  bool shouldRepaint(_GaugePainter oldDelegate) =>
      oldDelegate.needle != needle ||
      oldDelegate.track != track ||
      oldDelegate.good != good ||
      oldDelegate.fair != fair ||
      oldDelegate.poor != poor ||
      oldDelegate.needleColor != needleColor;
}

/// The adaptive ladder as four segmented capsules (HD / SD / Audio /
/// Survival) with the exact fine-grained rung name printed beneath — the
/// honest truth under the coarse display.
class LadderRungIndicator extends StatelessWidget {
  /// Creates the indicator for [rung]; null renders the no-signal state.
  const LadderRungIndicator({super.key, required this.rung});

  /// Current operating rung, or null when the ladder has not reported yet.
  final OperatingRung? rung;

  static const Map<LadderStep, String> _stepLabels = {
    LadderStep.hd: 'HD',
    LadderStep.sd: 'SD',
    LadderStep.audio: 'Audio',
    LadderStep.survival: 'Survival',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final currentRung = rung;
    final current = currentRung == null ? null : ladderStepOf(currentRung);

    return Semantics(
      label: 'Adaptive quality ladder',
      value: currentRung?.name ?? 'no ladder signal',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final step in LadderStep.values) ...[
                if (step != LadderStep.values.first)
                  const SizedBox(width: AppSpacing.s4),
                Container(
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: AppSpacing.s8,
                    vertical: AppSpacing.s4,
                  ),
                  decoration: BoxDecoration(
                    color: step == current
                        ? scheme.primary
                        : scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.r12),
                  ),
                  child: Text(
                    _stepLabels[step]!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: step == current
                          ? scheme.onPrimary
                          : scheme.onSecondaryContainer,
                      fontWeight:
                          step == current ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.s8),
          Text(
            currentRung?.name ?? 'no ladder signal',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Banner shown while the call survives in voice-note mode. Collapses to
/// zero height when [active] is false; size/opacity changes are one-shot
/// ([AppMotion.base]) and settle-safe.
class VoiceNoteModeBanner extends StatelessWidget {
  /// Creates the banner; [active] mirrors the call's real degraded mode.
  const VoiceNoteModeBanner({super.key, required this.active});

  /// Whether the call is currently in voice-note survival mode.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = tokensOrDefault(context);
    return AnimatedSize(
      duration: AppMotion.base,
      curve: AppMotion.standard,
      alignment: AlignmentDirectional.topCenter,
      child: AnimatedSwitcher(
        duration: AppMotion.fast,
        child: !active
            ? const SizedBox.shrink()
            : Padding(
                key: const ValueKey('voice-note-mode-banner'),
                padding: const EdgeInsetsDirectional.only(top: AppSpacing.s12),
                child: Container(
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: AppSpacing.s16,
                    vertical: AppSpacing.s12,
                  ),
                  decoration: BoxDecoration(
                    color: tokens.gaugeFair.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.r16),
                    border: Border.all(
                      color: tokens.gaugeFair.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.voicemail, size: 18, color: tokens.gaugeFair),
                      const SizedBox(width: AppSpacing.s8),
                      Flexible(
                        child: Text(
                          'Live voice degraded — voice-note mode keeps '
                          'audio flowing',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
