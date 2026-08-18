/// Learned personal correction on top of the deterministic budget model —
/// distributional («هوشمندی v4» pillar 1).
///
/// The deterministic model predicts how long a connection step should
/// take; this calibrator learns how this device's real calls deviate from
/// that prediction. v3 kept one EWMA of the actual/predicted ratio per
/// condition cell and clamped the ratio to [0.25, 4] — which crushed the
/// measured loss60 cell whose real ratios span 0.66..70 and made the
/// replay-benchmark calibrator component drop to 0.959. This version
/// keeps the WHOLE ratio distribution per cell as a sparse fixed-bin
/// histogram over log2(ratio) and answers two separate questions:
///
/// - [correction]: the point multiplier that minimizes the mean relative
///   error E|c/r - 1| — the exact quantity the replay benchmark scores.
///   Measured on the 24-run corpus (2026-08-11): normalized
///   1.036/1.039/1.044/1.044 across epochs 1-4 (v3 EWMA: 0.954-0.959).
/// - [budgetQuantile]: the ratio quantile (default p80) for deadline
///   budgeting. Measured: using p80 as the point correction instead
///   crashes the benchmark component to 0.52 — the two roles must never
///   be merged.
///
/// The correction output range is now [1/128, 128] (the histogram's edge
/// centers), NOT the old [0.25, 4.0] envelope — a consumer that assumed
/// the old cap must not: a 70x personal reality is representable now.
/// Fully deterministic: no randomness, no wall-clock reads; sparse bin
/// keys are iterated in sorted order everywhere a statistic is computed.
library;

import 'dart:math' as math;

import 'lane_experience.dart';

/// Per-condition-cell log2-ratio histograms of how far actual connect
/// timings run from the deterministic budget model's predictions.
class BudgetCalibrator {
  BudgetCalibrator({
    // 3: the package's minimum-sample precedent (TrendMonitor.slopePerSec
    // returns no slope before 3 samples; NetworkAtlas mirrors it). Also
    // doubles as the global-shape pseudo-count in the shrinkage blend.
    this.minWeight = 3,
  });

  /// Below this many raw samples a cell has no voice of its own, and the
  /// global histogram speaks only at or above it. Thresholds compare RAW
  /// stored masses (exact sums of 1.0 and migrated integer weights),
  /// never scaled blends.
  final int minWeight;

  /// 4 bins per octave: quarter-octave resolution — worst within-bin
  /// error ~9% while cells stay small.
  static const int binsPerOctave = 4;

  /// Bin index bound: k = round(4*log2 ratio) clamped to [-28, 28], so
  /// centers are 2^(k/4) in [1/128, 128] and ratio 0.5, 1.0, 2.0, 128
  /// are EXACT centers (center-aligned; edge-aligned bins would make a
  /// perfectly calibrated cell read 2^0.125 ≈ 1.09 forever).
  static const int maxBinIndex = 28;

  /// Serialization format version written by [toJson].
  static const int formatVersion = 2;

  // 6: cap on migrated v1 cell mass — an EWMA with alpha 0.3 carries an
  // effective sample size of ~(2-0.3)/0.3 ≈ 5.7, so a legacy w=50 must
  // not outvote ~50 fresh observations forever in a decay-free histogram.
  static const int _migratedMassCap = 6;

  /// cellKey -> (bin index k -> mass). Signed k, NOT array offsets.
  final Map<String, Map<int, double>> _cells = {};

  /// The all-cells histogram (the shrinkage prior's shape).
  final Map<int, double> _all = {};

  // Band vocabulary and the 'x' missing-marker are the package's single
  // source: DeliveryContext.lossBand/rttBand in lane_experience.dart.
  String _cellKey(double? lossFraction, double? rttMs) {
    final loss = (lossFraction != null && lossFraction.isFinite)
        ? DeliveryContext.lossBand(lossFraction)
        : 'x';
    final rtt = (rttMs != null && rttMs.isFinite)
        ? DeliveryContext.rttBand(rttMs)
        : 'x';
    return '$loss|$rtt';
  }

  /// k = round(binsPerOctave * log2 ratio), range-clamped into the edge
  /// bins. Caller guarantees ratio is finite and positive.
  static int _binOf(double ratio) {
    final k = (binsPerOctave * math.log(ratio) / math.ln2).round();
    return k.clamp(-maxBinIndex, maxBinIndex);
  }

  /// Center of bin k: 2^(k/binsPerOctave).
  static double _centerOf(int k) =>
      math.pow(2.0, k / binsPerOctave).toDouble();

  /// Feeds one (prediction, outcome) pair into the model. Ignores
  /// non-positive or non-finite timings: garbage in, nothing learned.
  void observe({
    required double predictedMs,
    required double actualMs,
    double? lossFraction,
    double? rttMs,
  }) {
    if (!predictedMs.isFinite || predictedMs <= 0) return;
    if (!actualMs.isFinite || actualMs <= 0) return;
    final k = _binOf(actualMs / predictedMs);
    final cell = _cells.putIfAbsent(_cellKey(lossFraction, rttMs), () => {});
    cell[k] = (cell[k] ?? 0.0) + 1.0;
    _all[k] = (_all[k] ?? 0.0) + 1.0;
  }

  static double _mass(Map<int, double> hist) {
    var total = 0.0;
    for (final v in hist.values) {
      total += v;
    }
    return total;
  }

  /// The histogram [correction] and [budgetQuantile] read for the given
  /// conditions, honoring the fallback chain and the shrinkage blend:
  /// cell mass >= minWeight -> cell + global scaled to pseudo-count
  /// minWeight (global mass 0 -> cell alone); else global mass >=
  /// minWeight -> global; else null (no voice anywhere).
  Map<int, double>? _histFor(double? lossFraction, double? rttMs) {
    final cell = _cells[_cellKey(lossFraction, rttMs)];
    final cellMass = cell == null ? 0.0 : _mass(cell);
    if (cell != null && cellMass >= minWeight) {
      final globalMass = _mass(_all);
      if (globalMass == 0) return cell;
      final scale = minWeight / globalMass;
      final merged = <int, double>{...cell};
      for (final e in _all.entries) {
        merged[e.key] = (merged[e.key] ?? 0.0) + e.value * scale;
      }
      return merged;
    }
    if (_mass(_all) >= minWeight) return _all;
    return null;
  }

  /// Multiplicative correction for the given conditions: the minimizer
  /// of the mean relative error E|c/r - 1| over the held distribution —
  /// the weighted median of bin centers with weights mass/center,
  /// scanned in ascending bin order (first center whose cumulative
  /// weight reaches half; ties resolve to the lower center). 1.0 while
  /// nothing has minWeight samples.
  double correction({double? lossFraction, double? rttMs}) {
    final hist = _histFor(lossFraction, rttMs);
    if (hist == null) return 1.0;
    final ks = hist.keys.toList()..sort();
    var totalWeight = 0.0;
    for (final k in ks) {
      totalWeight += hist[k]! / _centerOf(k);
    }
    final half = totalWeight / 2;
    var acc = 0.0;
    for (final k in ks) {
      acc += hist[k]! / _centerOf(k);
      if (acc >= half) return _centerOf(k);
    }
    return _centerOf(ks.last);
  }

  /// Ratio quantile for deadline budgeting (default p80): the smallest
  /// bin center whose cumulative MASS reaches p of the total, over the
  /// same fallback chain and shrinkage blend as [correction]. Returns
  /// 1.0 while nothing has minWeight samples. This is the budget answer
  /// («بودجه = چندک انتخابی») — NEVER a substitute for [correction].
  double budgetQuantile({
    double? lossFraction,
    double? rttMs,
    double p = 0.8,
  }) {
    final hist = _histFor(lossFraction, rttMs);
    if (hist == null) return 1.0;
    final clampedP = p.isFinite ? p.clamp(0.0, 1.0) : 1.0;
    final ks = hist.keys.toList()..sort();
    final target = clampedP * _mass(hist);
    var acc = 0.0;
    for (final k in ks) {
      acc += hist[k]!;
      if (acc >= target) return _centerOf(k);
    }
    return _centerOf(ks.last);
  }

  /// Serializes the learned distributions (format v2). Bin keys are the
  /// SIGNED bin index as a decimal string ("-12", "0", "28") — JSON map
  /// keys must be strings and the signed form round-trips exactly.
  Map<String, Object?> toJson() => {
    'v': formatVersion,
    'all': {for (final e in _all.entries) '${e.key}': e.value},
    'cells': {
      for (final c in _cells.entries)
        c.key: {for (final e in c.value.entries) '${e.key}': e.value},
    },
  };

  /// Restores a serialized calibrator — v2 histograms, or a legacy v1
  /// EWMA file whose per-cell (value, weight) is migrated by planting
  /// mass min(weight, 6) at the bin containing log2(value), so an
  /// existing on-disk brain keeps its voice instead of silently
  /// resetting. Corrupt entries are skipped: a damaged file degrades
  /// toward a fresh (correction = 1.0) calibrator, never a crash.
  factory BudgetCalibrator.fromJson(
    Map<String, Object?> json, {
    int minWeight = 3,
  }) {
    final cal = BudgetCalibrator(minWeight: minWeight);
    if (json['v'] == formatVersion) {
      void restoreHist(Object? raw, Map<int, double> into) {
        if (raw is! Map) return;
        for (final e in raw.entries) {
          final key = e.key;
          final value = e.value;
          if (key is! String) continue;
          final k = int.tryParse(key);
          if (k == null || k < -maxBinIndex || k > maxBinIndex) continue;
          // num, not double: on web a whole double encodes as a JSON int.
          if (value is! num) continue;
          final mass = value.toDouble();
          if (!mass.isFinite || mass <= 0) continue;
          into[k] = (into[k] ?? 0.0) + mass;
        }
      }

      restoreHist(json['all'], cal._all);
      final cells = json['cells'];
      if (cells is Map) {
        for (final entry in cells.entries) {
          final key = entry.key;
          if (key is! String) continue;
          final hist = <int, double>{};
          restoreHist(entry.value, hist);
          if (hist.isNotEmpty) cal._cells[key] = hist;
        }
      }
      return cal;
    }
    // Legacy v1: {'all': {'v','w'}, 'cells': {key: {'v','w'}}}. Validate
    // BEFORE log2/round: a NaN reaching round() throws in Dart, and the
    // never-crash contract forbids that.
    (int, double)? migrate(Object? raw) {
      if (raw is! Map) return null;
      final v = raw['v'];
      final w = raw['w'];
      if (v is! num || !v.toDouble().isFinite || v <= 0) return null;
      if (w is! int || w <= 0) return null;
      return (_binOf(v.toDouble()), math.min(w, _migratedMassCap).toDouble());
    }

    final all = migrate(json['all']);
    if (all != null) cal._all[all.$1] = all.$2;
    final cells = json['cells'];
    if (cells is Map) {
      for (final entry in cells.entries) {
        final key = entry.key;
        if (key is! String) continue;
        final planted = migrate(entry.value);
        if (planted == null) continue;
        cal._cells[key] = {planted.$1: planted.$2};
      }
    }
    return cal;
  }
}
