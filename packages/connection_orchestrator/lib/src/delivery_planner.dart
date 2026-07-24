/// The conductor: turns "what do I know about my lanes right now" into a
/// concrete delivery plan — which lanes, in what combination.
///
/// Blends three signals per lane: live measured health (EWMA score from
/// the channel), learned contextual success probability (the experience
/// model), and static cost — then picks a strategy:
///
///  - [DeliveryStrategy.singleBest]: routine traffic rides the winner,
///    with sequential failover down the ranking.
///  - [DeliveryStrategy.raceFanout]: when the top two lanes are too close
///    to call, send on both at once and take the first success — paying a
///    little redundancy to cut tail latency and learn about both.
///  - [DeliveryStrategy.replicate]: critical traffic (call signaling) goes
///    out on every credible lane simultaneously; receivers dedupe.
///  - [DeliveryStrategy.queueOnly]: nothing credible is up; park it.
library;

import 'package:device_link/device_link.dart' show MeshMessagePriority;

import 'lane_experience.dart';

/// How the payload should be carried.
enum DeliveryStrategy { singleBest, raceFanout, replicate, queueOnly }

/// One lane as the planner sees it: identity plus its three signals.
class PlannerLaneView {
  const PlannerLaneView({
    required this.id,
    required this.healthScore,
    required this.learnedScore,
    required this.costRank,
  });

  final String id;

  /// Live EWMA health score from the transport channel (0..~1).
  final double healthScore;

  /// UCB-adjusted learned success score for the current context.
  final double learnedScore;

  final int costRank;
}

/// The plan: strategy plus the lane ids to use, best first.
class DeliveryPlan {
  const DeliveryPlan({required this.strategy, required this.laneIds});

  final DeliveryStrategy strategy;
  final List<String> laneIds;

  @override
  String toString() => 'DeliveryPlan($strategy, $laneIds)';
}

/// Deterministic planning policy. Pure function of its inputs, so every
/// decision is unit-testable and explainable.
class DeliveryPlanner {
  const DeliveryPlanner({
    this.healthWeight = 0.5,
    this.learnedWeight = 0.5,
    this.costPenalty = 0.05,
    this.raceMargin = 0.15,
    this.credibleFloor = 0.2,
  });

  /// Relative weight of live health vs learned context experience.
  final double healthWeight;
  final double learnedWeight;

  /// Score penalty per cost rank (cheap lanes win near-ties).
  final double costPenalty;

  /// When the top two blended scores are within this margin, race them.
  final double raceMargin;

  /// Lanes below this blended score are not credible enough to replicate
  /// over (they still get tried as failover in singleBest).
  final double credibleFloor;

  double blendedScore(PlannerLaneView lane) =>
      healthWeight * lane.healthScore +
      learnedWeight * lane.learnedScore -
      costPenalty * lane.costRank;

  /// Produces the plan for this delivery.
  DeliveryPlan plan({
    required List<PlannerLaneView> lanes,
    required DeliveryContext context,
    required bool urgent,
  }) {
    if (lanes.isEmpty) {
      return const DeliveryPlan(
        strategy: DeliveryStrategy.queueOnly,
        laneIds: [],
      );
    }
    final ranked = [...lanes]
      ..sort((a, b) => blendedScore(b).compareTo(blendedScore(a)));
    final ids = [for (final l in ranked) l.id];

    if (urgent) {
      final credible = [
        for (final l in ranked)
          if (blendedScore(l) >= credibleFloor) l.id,
      ];
      return DeliveryPlan(
        strategy: DeliveryStrategy.replicate,
        laneIds: credible.isEmpty ? [ids.first] : credible,
      );
    }
    // Racing spends redundant bytes; routine bulk traffic never does.
    if (context.priority != MeshMessagePriority.bulk &&
        ranked.length >= 2 &&
        blendedScore(ranked[0]) - blendedScore(ranked[1]) <= raceMargin) {
      return DeliveryPlan(
        strategy: DeliveryStrategy.raceFanout,
        laneIds: ids.take(2).toList(),
      );
    }
    return DeliveryPlan(strategy: DeliveryStrategy.singleBest, laneIds: ids);
  }
}
