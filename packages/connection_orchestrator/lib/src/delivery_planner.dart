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
///
/// Every plan carries a [PlanExplanation]: the per-lane score arithmetic
/// and a literal sentence naming the numbers that decided the strategy,
/// so a log line can show exactly why the planner did what it did.
library;

import 'package:device_link/device_link.dart' show LinkMessagePriority;

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
    this.energyRank = 0,
  });

  final String id;

  /// Live EWMA health score from the transport channel (0..~1).
  final double healthScore;

  /// UCB-adjusted learned success score for the current context.
  final double learnedScore;

  final int costRank;

  /// Relative battery drain (0 = negligible); penalized on low battery.
  final int energyRank;
}

/// Every term of one lane's blended score, already weighted, so the sum
/// [blendedScore] is reproducible from the parts.
class LaneScoreBreakdown {
  const LaneScoreBreakdown({
    required this.laneId,
    required this.healthScore,
    required this.learnedScore,
    required this.costPenalty,
    required this.energyPenalty,
    required this.blendedScore,
  });

  final String laneId;

  /// Raw live health input (before the health weight is applied).
  final double healthScore;

  /// Raw learned-context input (before the learned weight is applied).
  final double learnedScore;

  /// Applied cost deduction: planner costPenalty × the lane's costRank.
  final double costPenalty;

  /// Applied low-battery deduction; 0 when the battery is fine.
  final double energyPenalty;

  /// healthWeight·health + learnedWeight·learned − costPenalty −
  /// energyPenalty: the number the ranking sorted by.
  final double blendedScore;
}

/// Why the planner chose what it chose: the strategy name, the context
/// key the learned scores were read under, per-lane score arithmetic
/// (ranked best first), and a literal sentence with the deciding numbers.
class PlanExplanation {
  const PlanExplanation({
    required this.strategy,
    required this.contextKey,
    required this.lanes,
    required this.grounds,
  });

  final String strategy;
  final String contextKey;
  final List<LaneScoreBreakdown> lanes;

  /// e.g. 'raceFanout: top-two gap 0.09 <= raceMargin 0.15'.
  final String grounds;

  @override
  String toString() => 'PlanExplanation($grounds)';
}

/// The plan: strategy plus the lane ids to use, best first.
class DeliveryPlan {
  const DeliveryPlan({
    required this.strategy,
    required this.laneIds,
    this.explanation,
  });

  final DeliveryStrategy strategy;
  final List<String> laneIds;

  /// Always filled by [DeliveryPlanner.plan]; null only on hand-built
  /// plans (the parameter is optional so existing construction sites keep
  /// compiling).
  final PlanExplanation? explanation;

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
    this.energyPenaltyLowBattery = 0.1,
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

  /// Extra per-energy-rank penalty applied only while the battery is low,
  /// so a hungry radio loses near-ties exactly when it matters.
  final double energyPenaltyLowBattery;

  double blendedScore(PlannerLaneView lane, {bool lowBattery = false}) =>
      healthWeight * lane.healthScore +
      learnedWeight * lane.learnedScore -
      costPenalty * lane.costRank -
      (lowBattery ? energyPenaltyLowBattery * lane.energyRank : 0);

  /// Produces the plan for this delivery.
  ///
  /// [bestLaneSliding] is the foresight input: when the trend watch
  /// predicts the current best lane is heading down, non-bulk traffic is
  /// duplicated onto the runner-up BEFORE the slide completes, so a
  /// mid-flight lane failure costs nothing (danger-window dual-send).
  DeliveryPlan plan({
    required List<PlannerLaneView> lanes,
    required DeliveryContext context,
    required bool urgent,
    bool bestLaneSliding = false,
    bool lowBattery = false,
  }) {
    String two(double v) => v.toStringAsFixed(2);
    if (lanes.isEmpty) {
      return DeliveryPlan(
        strategy: DeliveryStrategy.queueOnly,
        laneIds: const [],
        explanation: PlanExplanation(
          strategy: DeliveryStrategy.queueOnly.name,
          contextKey: context.key,
          lanes: const [],
          grounds: 'queueOnly: 0 lanes registered',
        ),
      );
    }
    double score(PlannerLaneView l) => blendedScore(l, lowBattery: lowBattery);
    final ranked = [...lanes]..sort((a, b) => score(b).compareTo(score(a)));
    final ids = [for (final l in ranked) l.id];
    // Built from the same score() the ranking used, so the breakdown can
    // never disagree with the decision.
    final breakdowns = [
      for (final l in ranked)
        LaneScoreBreakdown(
          laneId: l.id,
          healthScore: l.healthScore,
          learnedScore: l.learnedScore,
          costPenalty: costPenalty * l.costRank,
          energyPenalty: lowBattery
              ? energyPenaltyLowBattery * l.energyRank
              : 0,
          blendedScore: score(l),
        ),
    ];
    PlanExplanation explain(DeliveryStrategy strategy, String grounds) =>
        PlanExplanation(
          strategy: strategy.name,
          contextKey: context.key,
          lanes: breakdowns,
          grounds: grounds,
        );

    if (urgent) {
      final credible = [
        for (final l in ranked)
          if (score(l) >= credibleFloor) l.id,
      ];
      final grounds =
          'replicate: urgent; ${credible.length} of ${ranked.length} lanes '
          'at or above credibleFloor ${two(credibleFloor)}'
          '${credible.isEmpty ? '; using best lane anyway' : ''}';
      return DeliveryPlan(
        strategy: DeliveryStrategy.replicate,
        laneIds: credible.isEmpty ? [ids.first] : credible,
        explanation: explain(DeliveryStrategy.replicate, grounds),
      );
    }
    // Racing spends redundant bytes; routine bulk traffic never does.
    // Two triggers: a statistical near-tie, or foresight — the best lane
    // is predicted to slide, so pay the redundancy before it breaks.
    if (context.priority != LinkMessagePriority.bulk && ranked.length >= 2) {
      final gap = score(ranked[0]) - score(ranked[1]);
      if (bestLaneSliding || gap <= raceMargin) {
        final grounds = gap <= raceMargin
            ? 'raceFanout: top-two gap ${two(gap)} <= '
                  'raceMargin ${two(raceMargin)}'
            : 'raceFanout: best lane predicted to slide; '
                  'top-two gap ${two(gap)}';
        return DeliveryPlan(
          strategy: DeliveryStrategy.raceFanout,
          laneIds: ids.take(2).toList(),
          explanation: explain(DeliveryStrategy.raceFanout, grounds),
        );
      }
    }
    final String grounds;
    if (ranked.length < 2) {
      grounds = 'singleBest: 1 lane available';
    } else {
      final gap = score(ranked[0]) - score(ranked[1]);
      grounds = context.priority == LinkMessagePriority.bulk
          ? 'singleBest: bulk priority never races; top-two gap ${two(gap)}'
          : 'singleBest: top-two gap ${two(gap)} > '
                'raceMargin ${two(raceMargin)}';
    }
    return DeliveryPlan(
      strategy: DeliveryStrategy.singleBest,
      laneIds: ids,
      explanation: explain(DeliveryStrategy.singleBest, grounds),
    );
  }
}
