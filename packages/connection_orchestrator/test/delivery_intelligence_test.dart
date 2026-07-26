/// The conductor's brain: contextual learning, strategy planning, and
/// the fabric executing combined-lane plans.
library;

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

class _FakeChannel implements TransportChannel {
  _FakeChannel(this.name, {this.up = true});

  @override
  final String name;

  bool up;
  int sends = 0;

  @override
  final ChannelHealth health = ChannelHealth(
    reliabilityPrior: 0.9,
    bandwidth: 0.8,
    rttMs: 40,
  );

  @override
  Future<bool> probe() async => up;

  @override
  Future<SendResult> send(List<int> payload) async {
    sends++;
    return up
        ? const SendResult(SendStatus.ok, rttMs: 20)
        : const SendResult(SendStatus.transient);
  }

  @override
  Future<void> dispose() async {}
}

// 10:00 local time on a fixed date — bucket 1 (morning).
final _morningMs = DateTime(2026, 7, 24, 10).millisecondsSinceEpoch;
// 20:00 local time — bucket 3 (evening).
final _eveningMs = DateTime(2026, 7, 24, 20).millisecondsSinceEpoch;

void main() {
  group('LaneExperience · contextual learning', () {
    test('learns per (lane, time-bucket, place) independently', () {
      final exp = LaneExperience();
      final morningHome = DeliveryContext.at(_morningMs, place: 'home');
      final eveningHome = DeliveryContext.at(_eveningMs, place: 'home');
      final morningAway = DeliveryContext.at(_morningMs, place: 'transit');

      for (var i = 0; i < 10; i++) {
        exp.record('peer', morningHome, success: false);
        exp.record('peer', eveningHome, success: true);
      }

      expect(exp.probability('peer', morningHome), lessThan(0.2));
      expect(exp.probability('peer', eveningHome), greaterThan(0.8));
      expect(
        exp.probability('peer', morningAway),
        0.5,
        reason: 'unseen context stays at the neutral prior',
      );
    });

    test('decay forgets stale history so the model tracks change', () {
      final exp = LaneExperience(decay: 0.5);
      final ctx = DeliveryContext.at(_morningMs);
      for (var i = 0; i < 20; i++) {
        exp.record('net', ctx, success: false);
      }
      // With decay 0.5 the failure mass converges to ~2, so the floor is
      // (0+1)/(2+2) = 0.25 — strong distrust, never absolute.
      expect(exp.probability('net', ctx), lessThanOrEqualTo(0.26));

      for (var i = 0; i < 6; i++) {
        exp.record('net', ctx, success: true);
      }
      expect(
        exp.probability('net', ctx),
        greaterThan(0.7),
        reason: 'recent recoveries outweigh decayed failures',
      );
    });

    test('UCB gives an untried lane a real exploration bonus', () {
      final exp = LaneExperience();
      final ctx = DeliveryContext.at(_morningMs);
      for (var i = 0; i < 30; i++) {
        exp.record('net', ctx, success: true);
      }
      expect(
        exp.ucbScore('fresh-lane', ctx),
        greaterThan(exp.probability('fresh-lane', ctx)),
      );
    });
  });

  group('DeliveryPlanner · strategy choice', () {
    const planner = DeliveryPlanner();
    final ctx = DeliveryContext.at(_morningMs);

    PlannerLaneView lane(
      String id,
      double health,
      double learned, {
      int cost = 0,
    }) => PlannerLaneView(
      id: id,
      healthScore: health,
      learnedScore: learned,
      costRank: cost,
    );

    test('no lanes → queueOnly', () {
      final plan = planner.plan(lanes: [], context: ctx, urgent: false);
      expect(plan.strategy, DeliveryStrategy.queueOnly);
    });

    test('clear winner + bulk → singleBest with failover order', () {
      final plan = planner.plan(
        lanes: [lane('weak', 0.2, 0.4), lane('strong', 0.9, 0.9)],
        context: ctx,
        urgent: false,
      );
      expect(plan.strategy, DeliveryStrategy.singleBest);
      expect(plan.laneIds, ['strong', 'weak']);
    });

    test('near-tie on non-bulk traffic → race the top two', () {
      final presenceCtx = DeliveryContext.at(
        _morningMs,
        priority: LinkMessagePriority.presence,
      );
      final plan = planner.plan(
        lanes: [
          lane('a', 0.8, 0.7),
          lane('b', 0.75, 0.72),
          lane('c', 0.1, 0.2),
        ],
        context: presenceCtx,
        urgent: false,
      );
      expect(plan.strategy, DeliveryStrategy.raceFanout);
      expect(plan.laneIds, hasLength(2));
      expect(plan.laneIds, containsAll(['a', 'b']));
    });

    test('near-tie on bulk traffic still rides one lane (no waste)', () {
      final plan = planner.plan(
        lanes: [lane('a', 0.8, 0.7), lane('b', 0.75, 0.72)],
        context: ctx,
        urgent: false,
      );
      expect(plan.strategy, DeliveryStrategy.singleBest);
    });

    test('predicted slide on best lane → dual-send despite a wide margin', () {
      final presenceCtx = DeliveryContext.at(
        _morningMs,
        priority: LinkMessagePriority.presence,
      );
      final plan = planner.plan(
        lanes: [lane('sliding-best', 0.9, 0.9), lane('backup', 0.5, 0.5)],
        context: presenceCtx,
        urgent: false,
        bestLaneSliding: true,
      );
      expect(plan.strategy, DeliveryStrategy.raceFanout);
      expect(plan.laneIds, ['sliding-best', 'backup']);
    });

    test('predicted slide never duplicates bulk traffic', () {
      final plan = planner.plan(
        lanes: [lane('a', 0.9, 0.9), lane('b', 0.5, 0.5)],
        context: ctx,
        urgent: false,
        bestLaneSliding: true,
      );
      expect(plan.strategy, DeliveryStrategy.singleBest);
    });

    test('urgent → replicate over every credible lane, skip hopeless ones', () {
      final plan = planner.plan(
        lanes: [
          lane('net', 0.9, 0.8),
          lane('peer', 0.5, 0.6),
          lane('dead', 0.0, 0.05),
        ],
        context: ctx,
        urgent: true,
      );
      expect(plan.strategy, DeliveryStrategy.replicate);
      expect(plan.laneIds, containsAll(['net', 'peer']));
      expect(plan.laneIds, isNot(contains('dead')));
    });
  });

  group('ConnectionFabric · learned routing end to end', () {
    test(
      'repeated failures in one context reroute future traffic there',
      () async {
        var clockMs = _morningMs;
        final fabric = ConnectionFabric(
          fallbackQueue: DtnBundleQueue(),
          nowMs: () => clockMs,
          place: () => 'home',
        );
        final flaky = _FakeChannel('flaky');
        final steady = _FakeChannel('steady');
        // Identical health and cost: only learned experience can separate them.
        fabric.registerLane(
          flaky,
          const LaneProfile(id: 'flaky', kind: LaneKind.internet),
        );
        fabric.registerLane(
          steady,
          const LaneProfile(id: 'steady', kind: LaneKind.internet),
        );

        // Teach the model: flaky fails whenever it is tried at home in the
        // morning; steady always carries the failover.
        flaky.up = false;
        for (var i = 0; i < 8; i++) {
          await fabric.deliver([i], bundleId: 'warm$i');
        }
        // Flaky recovers its EWMA health via probes, but the learned memory
        // for this context still says "don't trust it here".
        flaky.up = true;
        flaky.health.availability = 1.0;

        final steadyBefore = steady.sends;
        await fabric.deliver([99], bundleId: 'routed');

        expect(fabric.lastPlan!.strategy, DeliveryStrategy.singleBest);
        expect(
          fabric.lastPlan!.laneIds.first,
          'steady',
          reason: 'context memory outranks equal instantaneous health',
        );
        expect(steady.sends, steadyBefore + 1);
        await fabric.dispose();
      },
    );

    test(
      'urgent call signaling replicates across lanes; one success wins',
      () async {
        final fabric = ConnectionFabric(
          fallbackQueue: DtnBundleQueue(),
          nowMs: () => _morningMs,
        );
        final net = _FakeChannel('net');
        final peer = _FakeChannel('peer', up: false);
        fabric.registerLane(
          net,
          const LaneProfile(id: 'net', kind: LaneKind.internet),
        );
        fabric.registerLane(
          peer,
          const LaneProfile(id: 'peer', kind: LaneKind.localPeer),
        );

        final outcome = await fabric.deliver(
          [1],
          bundleId: 'urgent',
          priority: LinkMessagePriority.callSignal,
        );

        expect(outcome, DeliveryOutcome.sentLive);
        expect(fabric.lastPlan!.strategy, DeliveryStrategy.replicate);
        expect(net.sends, 1);
        expect(
          peer.sends,
          1,
          reason: 'urgent traffic rides every credible lane',
        );
        await fabric.dispose();
      },
    );

    test(
      'urgent delivery still queues when every replicated lane fails',
      () async {
        final queue = DtnBundleQueue();
        final fabric = ConnectionFabric(fallbackQueue: queue, nowMs: () => 0);
        final a = _FakeChannel('a', up: false);
        final b = _FakeChannel('b', up: false);
        fabric.registerLane(
          a,
          const LaneProfile(id: 'a', kind: LaneKind.internet),
        );
        fabric.registerLane(
          b,
          const LaneProfile(id: 'b', kind: LaneKind.localPeer),
        );

        final outcome = await fabric.deliver(
          [1],
          bundleId: 'x',
          priority: LinkMessagePriority.callSignal,
        );

        expect(outcome, DeliveryOutcome.queuedForLater);
        expect(queue.pendingCount, 1);
        await fabric.dispose();
      },
    );
  });
}
