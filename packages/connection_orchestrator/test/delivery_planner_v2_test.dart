/// Pillar 3 pins: condition-aware context keys, explainable plans, and
/// the arq/fountain lane-choice policy.
library;

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart' show LinkMessagePriority;
import 'package:test/test.dart';

void main() {
  group('DeliveryContext · condition-aware key', () {
    test('legacy two-part key is preserved when no conditions are given', () {
      const ctx = DeliveryContext(timeBucket: 1, place: 'home');
      expect(ctx.key, '1|home');
    });

    test('conditions extend the key with loss and rtt bands', () {
      const ctx = DeliveryContext(
        timeBucket: 2,
        place: 'transit',
        lossFraction: 0.10,
        rttMs: 200,
      );
      expect(ctx.key, '2|transit|l1|r1');
    });

    test("a missing condition renders as 'x'", () {
      expect(
        const DeliveryContext(timeBucket: 0, lossFraction: 0.01).key,
        '0|unknown|l0|x',
      );
      expect(
        const DeliveryContext(timeBucket: 0, rttMs: 700).key,
        '0|unknown|x|r2',
      );
    });

    test('loss band edges sit exactly at 0.05 / 0.15 / 0.30', () {
      expect(DeliveryContext.lossBand(0.0), 'l0');
      expect(DeliveryContext.lossBand(0.049), 'l0');
      expect(DeliveryContext.lossBand(0.05), 'l1');
      // The rig's loss10 profile (0.10) lands inside l1.
      expect(DeliveryContext.lossBand(0.10), 'l1');
      expect(DeliveryContext.lossBand(0.149), 'l1');
      expect(DeliveryContext.lossBand(0.15), 'l2');
      expect(DeliveryContext.lossBand(0.299), 'l2');
      // The historic arq-to-fountain switch threshold is the l2/l3 edge.
      expect(DeliveryContext.lossBand(0.30), 'l3');
      expect(DeliveryContext.lossBand(0.9), 'l3');
    });

    test('rtt band edges sit exactly at 150 / 600 ms', () {
      expect(DeliveryContext.rttBand(0), 'r0');
      expect(DeliveryContext.rttBand(149.9), 'r0');
      expect(DeliveryContext.rttBand(150), 'r1');
      expect(DeliveryContext.rttBand(599.9), 'r1');
      expect(DeliveryContext.rttBand(600), 'r2');
      expect(DeliveryContext.rttBand(5000), 'r2');
    });
  });

  group('DeliveryPlanner · explainable plans', () {
    const planner = DeliveryPlanner();
    const ctx = DeliveryContext(timeBucket: 1, place: 'home');

    test('breakdown reproduces the blended formula on two lanes', () {
      final plan = planner.plan(
        lanes: const [
          PlannerLaneView(
            id: 'a',
            healthScore: 0.8,
            learnedScore: 0.6,
            costRank: 1,
          ),
          PlannerLaneView(
            id: 'b',
            healthScore: 0.9,
            learnedScore: 0.9,
            costRank: 0,
          ),
        ],
        context: ctx,
        urgent: false,
      );
      final explanation = plan.explanation!;
      expect(explanation.strategy, 'singleBest');
      expect(explanation.contextKey, '1|home');
      expect(explanation.lanes, hasLength(2));

      final best = explanation.lanes[0];
      expect(best.laneId, 'b', reason: 'breakdowns are ranked best first');
      expect(best.costPenalty, 0);
      expect(best.energyPenalty, 0);
      // healthWeight 0.5 · 0.9 + learnedWeight 0.5 · 0.9 − 0.05 · 0 = 0.90
      expect(best.blendedScore, closeTo(0.5 * 0.9 + 0.5 * 0.9, 1e-9));

      final other = explanation.lanes[1];
      expect(other.laneId, 'a');
      expect(other.costPenalty, closeTo(0.05 * 1, 1e-9));
      expect(other.energyPenalty, 0);
      // healthWeight 0.5 · 0.8 + learnedWeight 0.5 · 0.6 − 0.05 · 1 = 0.65
      expect(other.blendedScore, closeTo(0.5 * 0.8 + 0.5 * 0.6 - 0.05, 1e-9));
      expect(explanation.grounds, contains('singleBest'));
      expect(explanation.grounds, contains('top-two gap'));
    });

    test('race grounds carry the deciding gap and margin', () {
      const presenceCtx = DeliveryContext(
        timeBucket: 1,
        place: 'home',
        priority: LinkMessagePriority.presence,
      );
      final plan = planner.plan(
        lanes: const [
          // Blended 0.75 and 0.6875: gap 0.0625 — inside raceMargin 0.15.
          PlannerLaneView(
            id: 'a',
            healthScore: 1.0,
            learnedScore: 0.5,
            costRank: 0,
          ),
          PlannerLaneView(
            id: 'b',
            healthScore: 0.875,
            learnedScore: 0.5,
            costRank: 0,
          ),
        ],
        context: presenceCtx,
        urgent: false,
      );
      expect(plan.strategy, DeliveryStrategy.raceFanout);
      expect(
        plan.explanation!.grounds,
        'raceFanout: top-two gap 0.06 <= raceMargin 0.15',
      );
    });

    test('every strategy branch carries an explanation', () {
      final empty = planner.plan(lanes: const [], context: ctx, urgent: false);
      expect(empty.explanation, isNotNull);
      expect(empty.explanation!.strategy, 'queueOnly');
      expect(empty.explanation!.grounds, contains('0 lanes'));

      final urgentPlan = planner.plan(
        lanes: const [
          PlannerLaneView(
            id: 'net',
            healthScore: 0.9,
            learnedScore: 0.8,
            costRank: 0,
          ),
          PlannerLaneView(
            id: 'dead',
            healthScore: 0.0,
            learnedScore: 0.05,
            costRank: 0,
          ),
        ],
        context: ctx,
        urgent: true,
      );
      expect(urgentPlan.explanation!.strategy, 'replicate');
      expect(urgentPlan.explanation!.grounds, contains('1 of 2'));
      expect(urgentPlan.explanation!.grounds, contains('credibleFloor 0.20'));
    });
  });

  group('LaneChoicePolicy · fallback rule and learning', () {
    test('below min samples the deterministic loss rule decides', () {
      final policy = LaneChoicePolicy();

      final highLoss = policy.decide(lossFraction: 0.35, rttMs: 100);
      expect(highLoss.choice, 'fountain');
      expect(highLoss.source, 'fallback-rule');
      expect(highLoss.cellKey, 'l3|r0');
      expect(highLoss.samples, 0);
      expect(highLoss.grounds, contains('fallbackLossThreshold 0.30'));

      final lowLoss = policy.decide(lossFraction: 0.10, rttMs: 100);
      expect(lowLoss.choice, 'arq');
      expect(lowLoss.source, 'fallback-rule');

      final unknown = policy.decide();
      expect(unknown.choice, 'arq');
      expect(unknown.cellKey, 'x|x');
      expect(unknown.grounds, contains('lossFraction unknown'));
    });

    test('threshold is inclusive: loss exactly 0.30 picks fountain', () {
      final decision = LaneChoicePolicy().decide(
        lossFraction: 0.30,
        rttMs: 100,
      );
      expect(decision.choice, 'fountain');
      expect(decision.source, 'fallback-rule');
    });

    test('10 contradicting outcomes flip the cell from rule to learned', () {
      final policy = LaneChoicePolicy();
      // The rule says fountain here (loss 0.35 >= 0.30) — but observed
      // reality in this cell says arq succeeds and fountain fails.
      for (var i = 0; i < 5; i++) {
        policy.record(
          choice: 'arq',
          lossFraction: 0.35,
          rttMs: 100,
          success: true,
        );
        policy.record(
          choice: 'fountain',
          lossFraction: 0.35,
          rttMs: 100,
          success: false,
        );
      }
      final decision = policy.decide(lossFraction: 0.35, rttMs: 100);
      expect(decision.source, 'learned');
      expect(
        decision.choice,
        'arq',
        reason: 'recorded evidence overrules the static rule',
      );
      expect(decision.samples, 10);
      expect(decision.cellKey, 'l3|r0');
      expect(decision.grounds, contains('learned: arq p'));
    });

    test('learning is per cell: other cells still use the rule', () {
      final policy = LaneChoicePolicy();
      for (var i = 0; i < 10; i++) {
        policy.record(
          choice: 'arq',
          lossFraction: 0.35,
          rttMs: 100,
          success: true,
        );
      }
      expect(policy.decide(lossFraction: 0.35, rttMs: 100).source, 'learned');
      expect(
        policy.decide(lossFraction: 0.35, rttMs: 700).source,
        'fallback-rule',
        reason: 'a different rtt band is a different cell',
      );
    });

    test('JSON round-trip preserves the learned decision', () {
      final policy = LaneChoicePolicy();
      for (var i = 0; i < 5; i++) {
        policy.record(
          choice: 'arq',
          lossFraction: 0.35,
          rttMs: 100,
          success: true,
        );
        policy.record(
          choice: 'fountain',
          lossFraction: 0.35,
          rttMs: 100,
          success: false,
        );
      }
      final restored = LaneChoicePolicy.fromJson(policy.toJson());
      final decision = restored.decide(lossFraction: 0.35, rttMs: 100);
      expect(decision.source, 'learned');
      expect(decision.choice, 'arq');
      expect(decision.samples, 10);
    });

    test('corrupt JSON degrades to a fresh policy, never a crash', () {
      final fromGarbage = LaneChoicePolicy.fromJson({'cells': 'not-a-map'});
      expect(
        fromGarbage.decide(lossFraction: 0.35, rttMs: 100).source,
        'fallback-rule',
      );

      final fromPartial = LaneChoicePolicy.fromJson({
        'cells': {
          'l3|r0': {
            'n': 'corrupt',
            'arq': {'s': 1, 'f': 0},
            'fountain': {'s': 0, 'f': 1},
          },
          'l2|r1': {
            'n': 9,
            'arq': {'s': -3, 'f': 0},
            'fountain': {'s': 0, 'f': 1},
          },
          42: {'n': 9},
        },
      });
      expect(
        fromPartial.decide(lossFraction: 0.35, rttMs: 100).source,
        'fallback-rule',
        reason: 'the corrupt cell was skipped, not restored',
      );
      expect(
        fromPartial.decide(lossFraction: 0.20, rttMs: 300).source,
        'fallback-rule',
        reason: 'negative counts invalidate the cell',
      );

      expect(LaneChoicePolicy.fromJson({}).decide().choice, 'arq');
    });
  });
}
