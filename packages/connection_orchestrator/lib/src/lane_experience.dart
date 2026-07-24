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

import 'package:device_link/device_link.dart' show MeshMessagePriority;

/// The situation a delivery happens in. Buckets are coarse on purpose:
/// enough to distinguish regimes, small enough to learn fast.
class DeliveryContext {
  const DeliveryContext({
    required this.timeBucket,
    this.place = 'unknown',
    this.priority = MeshMessagePriority.bulk,
  });

  /// Derives the context from a wall-clock ms timestamp: four six-hour
  /// day-part buckets (night/morning/afternoon/evening).
  factory DeliveryContext.at(
    int nowMs, {
    String place = 'unknown',
    MeshMessagePriority priority = MeshMessagePriority.bulk,
  }) {
    final hour = DateTime.fromMillisecondsSinceEpoch(nowMs).hour;
    return DeliveryContext(
      timeBucket: hour ~/ 6,
      place: place,
      priority: priority,
    );
  }

  /// 0..3: night, morning, afternoon, evening.
  final int timeBucket;

  /// Coarse location tag supplied by the app (e.g. a network name hash or
  /// "home"/"transit"). Never a precise position — a label, not a place.
  final String place;

  final MeshMessagePriority priority;

  String get key => '$timeBucket|$place';
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
}
