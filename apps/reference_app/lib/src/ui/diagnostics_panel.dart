/// Live network diagnostics panel — the technical showcase of the adverse-
/// network stack, built on the network-truth contract (`network_truth.dart`).
///
/// Honesty rules encoded here:
///  * Every reading is labeled with its real source via the header chip
///    ([DiagnosticsPanel.sourceLabel]) — demo data never masquerades as radio
///    truth.
///  * A null metric is *unknown*, not zero: tiles show a long dash and the
///    sparklines skip the point entirely (drawing 0 would be an invented
///    measurement).
///
/// Performance shape:
///  * The panel owns its [StreamSubscription]; `setState` is scoped to this
///    leaf widget, so a reading repaints the panel only — never the screen
///    hosting it (a `StreamBuilder` per metric would rebuild just as often
///    but hand the subscription lifecycle to the framework; owning it keeps
///    cancel-on-dispose provable in a test).
///  * Sparklines are one [CustomPainter] class instantiated per metric, each
///    inside a [RepaintBoundary]. Ring values are copied into growable lists
///    before painting because the ring mutates between frames.
///  * Nothing repeats: the only animation is a one-shot [AnimatedSwitcher]
///    cross-fade on the numbers, so `pumpAndSettle` always settles.
library;

import 'dart:async';

import 'package:adaptive_transport/adaptive_transport.dart'
    show nativeShapeAvailabilityForThisBuild;
import 'package:flutter/material.dart';

import 'network_truth.dart';
import 'source_chip.dart';
import 'tokens.dart';

/// Card showing RTT / loss / bitrate tiles with sparklines over the last
/// [QualityHistory.capacity] readings.
class DiagnosticsPanel extends StatefulWidget {
  const DiagnosticsPanel({
    super.key,
    this.readings,
    this.seed,
    this.sourceLabel = 'loopback demo',
  });

  /// Live readings; optional so tests and goldens can render from [seed]
  /// alone with zero open streams.
  final Stream<CallQualityReading>? readings;

  /// Initial history copied into the panel's own ring at mount.
  final QualityHistory? seed;

  /// The honesty contract: names where the readings actually come from.
  final String sourceLabel;

  @override
  State<DiagnosticsPanel> createState() => _DiagnosticsPanelState();
}

class _DiagnosticsPanelState extends State<DiagnosticsPanel> {
  final QualityHistory _history = QualityHistory();
  StreamSubscription<CallQualityReading>? _sub;

  @override
  void initState() {
    super.initState();
    final seed = widget.seed;
    if (seed != null) {
      for (final reading in seed.readings) {
        _history.add(reading);
      }
    }
    _sub = widget.readings?.listen(_onReading);
  }

  @override
  void didUpdateWidget(DiagnosticsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.readings, widget.readings)) {
      _sub?.cancel();
      _sub = widget.readings?.listen(_onReading);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onReading(CallQualityReading reading) {
    // Leaf-scoped by construction: repaints the panel subtree only.
    setState(() => _history.add(reading));
  }

  static const String _dash = '—';

  static String _fmtRtt(CallQualityReading? r) {
    final v = r?.rttMs;
    return v == null ? _dash : '$v';
  }

  static String _fmtLoss(CallQualityReading? r) {
    final v = r?.lossFraction;
    return v == null ? _dash : (v * 100).toStringAsFixed(1);
  }

  static String _fmtRate(CallQualityReading? r) {
    final v = r?.bitrateBps;
    return v == null ? _dash : '${(v / 1000).round()}';
  }

  static Color _bandColor(AppTokens tokens, QualityBand band) => switch (band) {
    QualityBand.good => tokens.gaugeGood,
    QualityBand.fair => tokens.gaugeFair,
    QualityBand.poor => tokens.gaugePoor,
    QualityBand.unknown => tokens.pending,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final latest = _history.latest;
    final bandColor = _bandColor(tokens, bandOf(latest));

    // Copy the ring into growable lists NOW: the ring mutates between
    // frames while the painters may repaint later from these snapshots.
    final rtt = <double?>[];
    final loss = <double?>[];
    final rate = <double?>[];
    for (final r in _history.readings) {
      rtt.add(r.rttMs?.toDouble());
      loss.add(r.lossFraction);
      rate.add(r.bitrateBps == null ? null : r.bitrateBps! / 1000);
    }

    return Card(
      margin: EdgeInsetsDirectional.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.r16),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(AppSpacing.s16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Network diagnostics',
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpacing.s8),
                SourceChip(label: widget.sourceLabel),
              ],
            ),
            const SizedBox(height: AppSpacing.s16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _MetricTile(
                    caption: 'RTT (ms)',
                    value: _fmtRtt(latest),
                    valueColor: latest?.rttMs == null
                        ? tokens.pending
                        : bandColor,
                    sparkValues: rtt,
                    sparkColor: bandColor,
                  ),
                ),
                const SizedBox(width: AppSpacing.s12),
                Expanded(
                  child: _MetricTile(
                    caption: 'LOSS (%)',
                    value: _fmtLoss(latest),
                    valueColor: latest?.lossFraction == null
                        ? tokens.pending
                        : bandColor,
                    sparkValues: loss,
                    sparkColor: bandColor,
                  ),
                ),
                const SizedBox(width: AppSpacing.s12),
                Expanded(
                  child: _MetricTile(
                    caption: 'RATE (kbps)',
                    value: _fmtRate(latest),
                    valueColor: latest?.bitrateBps == null
                        ? tokens.pending
                        : bandColor,
                    sparkValues: rate,
                    sparkColor: bandColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s16),
            const _NativeShapeAvailabilityRow(),
          ],
        ),
      ),
    );
  }
}

/// Unconditional row stating the native shape capability's availability,
/// fed from [nativeShapeAvailabilityForThisBuild] and worded solely by
/// [nativeShapeAvailabilityText].
///
/// Rendered whenever the panel is — no toggle, no debug flag, no
/// per-cause condition. A row that hid itself when the capability is
/// absent would claim availability by omission, which is exactly what
/// the network-truth contract forbids.
class _NativeShapeAvailabilityRow extends StatelessWidget {
  const _NativeShapeAvailabilityRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      nativeShapeAvailabilityText(nativeShapeAvailabilityForThisBuild),
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Small neutral chip naming the real origin of the readings.
/// One metric: big number, caption, sparkline.
class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.caption,
    required this.value,
    required this.valueColor,
    required this.sparkValues,
    required this.sparkColor,
  });

  final String caption;
  final String value;
  final Color valueColor;
  final List<double?> sparkValues;
  final Color sparkColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedSwitcher(
          duration: AppMotion.fast,
          switchInCurve: AppMotion.standard,
          switchOutCurve: AppMotion.standard,
          child: Text(
            value,
            key: ValueKey<String>(value),
            maxLines: 1,
            style: theme.textTheme.titleLarge?.copyWith(color: valueColor),
          ),
        ),
        const SizedBox(height: AppSpacing.s2),
        Text(
          caption,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.s8),
        RepaintBoundary(
          child: SizedBox(
            height: 36,
            width: double.infinity,
            child: CustomPaint(
              painter: _SparklinePainter(
                values: sparkValues,
                color: sparkColor,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Polyline over the ring snapshot, min/max autoscaled. Null points are
/// skipped — unknown is never drawn as zero — which may split the line into
/// segments; an isolated known point renders as a dot.
class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({required this.values, required this.color});

  final List<double?> values;
  final Color color;

  static const double _stroke = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    double? lo;
    double? hi;
    for (final v in values) {
      if (v == null) continue;
      if (lo == null || v < lo) lo = v;
      if (hi == null || v > hi) hi = v;
    }
    if (lo == null || hi == null) return; // Nothing measured: honest blank.
    final span = hi - lo;
    final drawable = size.height - _stroke * 2;

    double yFor(double v) => span == 0
        ? size.height / 2
        : _stroke + (1 - (v - lo!) / span) * drawable;
    double xFor(int i) => values.length == 1
        ? size.width / 2
        : i * size.width / (values.length - 1);

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final dot = Paint()..color = color;

    final path = Path();
    var segmentLength = 0;
    Offset? segmentStart;
    void closeSegment() {
      if (segmentLength == 1 && segmentStart != null) {
        canvas.drawCircle(segmentStart!, _stroke, dot);
      }
      segmentLength = 0;
      segmentStart = null;
    }

    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null) {
        closeSegment();
        continue;
      }
      final p = Offset(xFor(i), yFor(v));
      if (segmentLength == 0) {
        path.moveTo(p.dx, p.dy);
        segmentStart = p;
      } else {
        path.lineTo(p.dx, p.dy);
      }
      segmentLength++;
    }
    closeSegment();
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) =>
      color != oldDelegate.color || !_sameValues(values, oldDelegate.values);

  static bool _sameValues(List<double?> a, List<double?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
