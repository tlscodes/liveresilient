/// Online learning memory for lanes: a contextual success model.
///
/// This is the fabric's "small brain". For every (lane, context) pair it
/// keeps an exponentially-decayed success/failure count, so it learns
/// facts like "the local-peer lane is great at home in the evening but
/// useless downtown at noon" — and forgets them gracefully when the world
/// changes. Selection uses an upper-confidence bound, so rarely-tried
/// lanes get deliberately re-explored instead of being written off
/// forever. Fully deterministic: no randomness, time is injected.
library;

import 'dart:math' as math;

import 'package:device_link/device_link.dart' show LinkMessagePriority;

/// The situation a delivery happens in. Buckets are coarse on purpose:
/// enough to distinguish regimes, small enough to learn fast.
class DeliveryContext {
  const DeliveryContext({
    required this.timeBucket,
    this.place = 'unknown',
    this.priority = LinkMessagePriority.bulk,
    this.lossFraction,
    this.rttMs,
  });

  /// Derives the context from a wall-clock ms timestamp: four six-hour
  /// day-part buckets (night/morning/afternoon/evening).
  factory DeliveryContext.at(
    int nowMs, {
    String place = 'unknown',
    LinkMessagePriority priority = LinkMessagePriority.bulk,
    double? lossFraction,
    double? rttMs,
  }) {
    final hour = DateTime.fromMillisecondsSinceEpoch(nowMs).hour;
    return DeliveryContext(
      timeBucket: hour ~/ 6,
      place: place,
      priority: priority,
      lossFraction: lossFraction,
      rttMs: rttMs,
    );
  }

  /// 0..3: night, morning, afternoon, evening.
  final int timeBucket;

  /// Coarse location tag supplied by the app (e.g. a network name hash or
  /// "home"/"transit"). Never a precise position — a label, not a place.
  final String place;

  final LinkMessagePriority priority;

  /// Measured packet-loss fraction (0..1) when the caller has one; null
  /// keeps the legacy two-part [key], so stats persisted before condition
  /// bands existed stay live.
  final double? lossFraction;

  /// Measured round-trip time in milliseconds; null = unmeasured.
  final double? rttMs;

  /// Coarse loss-rate band label used in [key].
  ///
  /// Edges 0.05 / 0.15 / 0.30: 0.30 is the proven arq-to-fountain switch
  /// threshold from the network rig (RIG_GUIDE loss 0.2/0.3 sections), so
  /// the historic switch point sits exactly on the l2/l3 band edge; 0.05
  /// and 0.15 separate the rig's mild profile families (the loss10
  /// profile, 0.10, lands inside 'l1').
  static String lossBand(double lossFraction) {
    // 0.05: upper edge of the near-lossless band (rig clean profiles).
    if (lossFraction < 0.05) return 'l0';
    // 0.15: upper edge of the mild-loss band (rig loss10 = 0.10 is here).
    if (lossFraction < 0.15) return 'l1';
    // 0.30: the rig-proven arq-to-fountain switch threshold.
    if (lossFraction < 0.30) return 'l2';
    return 'l3';
  }

  /// Coarse round-trip-time band label used in [key].
  static String rttBand(double rttMs) {
    // 150 ms: the interactive-latency threshold.
    if (rttMs < 150) return 'r0';
    // 600 ms: the rig's extreme-profile p95 round-trip class.
    if (rttMs < 600) return 'r1';
    return 'r2';
  }

  /// Learning key. Both conditions null → the original two-part
  /// 'timeBucket|place' shape, so stats persisted under the old key stay
  /// live. Any condition present → four parts, with 'x' standing in for a
  /// missing one.
  String get key {
    final loss = lossFraction;
    final rtt = rttMs;
    if (loss == null && rtt == null) return '$timeBucket|$place';
    final lossPart = loss == null ? 'x' : lossBand(loss);
    final rttPart = rtt == null ? 'x' : rttBand(rtt);
    return '$timeBucket|$place|$lossPart|$rttPart';
  }
}

class _Stats {
  double successes = 0;
  double failures = 0;

  double get attempts => successes + failures;

  /// Laplace-smoothed success probability: unknown pairs start at 0.5.
  double get probability => (successes + 1) / (attempts + 2);

  void record({required bool success, required double decay}) {
    successes *= decay;
    failures *= decay;
    if (success) {
      successes += 1;
    } else {
      failures += 1;
    }
  }
}

/// Decayed per-(lane, context) success statistics with UCB exploration.
class LaneExperience {
  LaneExperience({this.decay = 0.98, this.explorationWeight = 0.25})
    : assert(decay > 0 && decay <= 1, 'decay must be in (0, 1]');

  /// Applied to old counts on every new observation, so stale history
  /// fades and the model tracks a changing environment.
  final double decay;

  /// Scales the UCB bonus: 0 = pure exploitation.
  final double explorationWeight;

  final Map<String, _Stats> _stats = {};
  double _totalAttempts = 0;

  String _key(String laneId, DeliveryContext ctx) => '$laneId|${ctx.key}';

  /// Feeds one delivery outcome back into the model.
  void record(String laneId, DeliveryContext ctx, {required bool success}) {
    _stats
        .putIfAbsent(_key(laneId, ctx), _Stats.new)
        .record(success: success, decay: decay);
    _totalAttempts += 1;
  }

  /// Learned success probability for this lane in this context (0.5 when
  /// nothing is known yet).
  double probability(String laneId, DeliveryContext ctx) =>
      _stats[_key(laneId, ctx)]?.probability ?? 0.5;

  /// Probability plus an upper-confidence exploration bonus: lanes with
  /// little evidence in this context score a deliberate second chance.
  double ucbScore(String laneId, DeliveryContext ctx) {
    final s = _stats[_key(laneId, ctx)];
    final attempts = s?.attempts ?? 0;
    final bonus = math.sqrt(math.log(_totalAttempts + 1.5) / (attempts + 1));
    return (s?.probability ?? 0.5) + explorationWeight * bonus;
  }

  /// Evidence volume for tests/telemetry.
  double attempts(String laneId, DeliveryContext ctx) =>
      _stats[_key(laneId, ctx)]?.attempts ?? 0;

  /// Serializes the learned model so the app can persist it across
  /// restarts — the brain keeps its memories.
  Map<String, Object?> toJson() => {
    'totalAttempts': _totalAttempts,
    'stats': {
      for (final e in _stats.entries)
        e.key: {'s': e.value.successes, 'f': e.value.failures},
    },
  };

  /// Restores a previously serialized model. Unknown/corrupt entries are
  /// skipped: a damaged memory file degrades to a fresh brain, never a
  /// crash.
  factory LaneExperience.fromJson(
    Map<String, Object?> json, {
    double decay = 0.98,
    double explorationWeight = 0.25,
  }) {
    final exp = LaneExperience(
      decay: decay,
      explorationWeight: explorationWeight,
    );
    final total = json['totalAttempts'];
    if (total is num && total.toDouble().isFinite) {
      exp._totalAttempts = total.toDouble();
    }
    final stats = json['stats'];
    if (stats is Map) {
      for (final entry in stats.entries) {
        final v = entry.value;
        if (entry.key is! String || v is! Map) continue;
        final s = v['s'];
        final f = v['f'];
        // isFinite also rejects NaN, which passes a bare `< 0` check.
        if (s is! num || f is! num) continue;
        if (!s.toDouble().isFinite || !f.toDouble().isFinite) continue;
        if (s < 0 || f < 0) continue;
        exp._stats[entry.key as String] = _Stats()
          ..successes = s.toDouble()
          ..failures = f.toDouble();
      }
    }
    return exp;
  }
}
