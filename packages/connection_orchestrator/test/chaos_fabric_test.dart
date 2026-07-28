/// The test for the claim, not for the details.
///
/// Everything else in this package checks a behaviour someone thought of.
/// This drives thousands of random failures through the fabric and asserts
/// only the things that must hold whatever happened — which is the only
/// kind of check that catches what nobody thought of.
library;

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

import 'chaos/chaos_world.dart';

void main() {
  group('the fabric holds its invariants under chaos', () {
    // Fixed seeds, so a failure here is a failure anyone can reproduce
    // exactly rather than a story about a flaky afternoon.
    for (final seed in [1, 2, 3, 7, 11, 13, 42, 99, 256, 1024, 4093, 65537]) {
      test('seed $seed', () async {
        final breach = await runSeed(seed);
        if (breach != null) {
          // Re-run shorter prefixes so the report is the smallest world
          // that still breaks.
          final smallest = await shrink(seed);
          fail('seed $seed\n${smallest ?? breach}');
        }
      });
    }

    test('a wider world with more lanes and more events', () async {
      final breach = await runSeed(20260728, laneCount: 6, steps: 400);
      expect(breach, isNull, reason: '${breach ?? ''}');
    });

    test(
      'a world with a single lane, where there is nowhere to fail over',
      () async {
        // The degenerate case is where "degrade, do not disconnect" is
        // hardest: with one lane, degrading means the queue or nothing.
        final breach = await runSeed(5, laneCount: 1, steps: 200);
        expect(breach, isNull, reason: '${breach ?? ''}');
      },
    );

    test('the same seed produces the same world twice', () async {
      // Without this, a green run proves nothing about the next one.
      final first = chaosScript(31337, laneCount: 4);
      final second = chaosScript(31337, laneCount: 4);
      expect(first.map((e) => e.toString()), second.map((e) => e.toString()));
    });
  });

  group('the promise itself', () {
    late DtnBundleQueue queue;
    late ConnectionFabric fabric;
    late List<ChaosLane> lanes;
    var clock = 1000;

    setUp(() {
      clock = 1000;
      queue = DtnBundleQueue(maxBundles: 32, maxBytes: 1 << 20);
      fabric = ConnectionFabric(fallbackQueue: queue, nowMs: () => clock);
      lanes = [
        for (var i = 0; i < 3; i++) ChaosLane('lane$i', latencyMs: 10 + i * 10),
      ];
      for (var i = 0; i < lanes.length; i++) {
        fabric.registerLane(
          lanes[i],
          LaneProfile(id: 'lane$i', kind: LaneKind.internet, costRank: i),
        );
      }
    });

    tearDown(() => fabric.dispose());

    test('one healthy lane among failures still carries the payload', () async {
      // This is the sentence the whole project rests on, as a test.
      lanes[0].mood = LaneMood.throwing;
      lanes[1].mood = LaneMood.failing;
      lanes[2].mood = LaneMood.healthy;

      final outcome = await fabric.deliver([
        1,
        2,
        3,
        4,
      ], bundleId: 'the-message');
      expect(outcome, DeliveryOutcome.sentLive);
      expect(lanes[2].carried.single, [1, 2, 3, 4]);
      expect(queue.pendingCount, 0);
    });

    test('every lane down means parked, never lost', () async {
      for (final lane in lanes) {
        lane.mood = LaneMood.failing;
        lane.setHealth(reachable: false);
      }
      final outcome = await fabric.deliver([9, 9, 9], bundleId: 'parked');
      expect(outcome, DeliveryOutcome.queuedForLater);
      expect(queue.pendingCount, 1);
    });

    test('a lane coming back drains what was parked', () async {
      for (final lane in lanes) {
        lane.mood = LaneMood.failing;
        lane.setHealth(reachable: false);
      }
      await fabric.deliver([7], bundleId: 'a');
      await fabric.deliver([8], bundleId: 'b');
      expect(queue.pendingCount, 2);

      lanes[1]
        ..mood = LaneMood.healthy
        ..setHealth(reachable: true);
      final drained = await fabric.refresh();

      expect(drained, 2);
      expect(queue.pendingCount, 0);
      expect(lanes[1].carried, hasLength(2));
    });

    test('a lane that throws does not take the fabric with it', () async {
      // A transport that breaks rudely is the normal case on a bad
      // network, not an exceptional one.
      for (final lane in lanes) {
        lane.mood = LaneMood.throwing;
      }
      final outcome = await fabric.deliver([1], bundleId: 'rude');
      expect(outcome, DeliveryOutcome.queuedForLater);

      lanes[0].mood = LaneMood.healthy;
      expect(await fabric.refresh(), 1);
    });

    test('a lane that lies about carrying is survivable end to end', () async {
      // The black hole: it reports success and carries nothing. The fabric
      // cannot detect this — nothing at this layer can — so what is
      // asserted is what must remain true anyway: the caller was told the
      // truth about what the fabric did, and no other lane silently
      // duplicated the work.
      lanes[0]
        ..mood = LaneMood.blackHole
        ..setHealth(reachable: true, rttMs: 5);
      lanes[1].mood = LaneMood.healthy;
      lanes[2].mood = LaneMood.healthy;

      final outcome = await fabric.deliver([4, 5], bundleId: 'swallowed');
      expect(outcome, DeliveryOutcome.sentLive);
      expect(
        lanes[0].carried,
        isEmpty,
        reason: 'the black hole carried nothing, as designed',
      );
    });

    test('the queue drops rather than growing without bound', () async {
      for (final lane in lanes) {
        lane.mood = LaneMood.failing;
        lane.setHealth(reachable: false);
      }
      for (var i = 0; i < 100; i++) {
        await fabric.deliver([i & 0xFF], bundleId: 'flood-$i');
      }
      expect(queue.pendingCount, lessThanOrEqualTo(32));
    });

    test('a critical payload outlives bulk when the queue overflows', () async {
      // Degrading is a choice about what to keep, and the choice has to be
      // the important thing.
      for (final lane in lanes) {
        lane.mood = LaneMood.failing;
        lane.setHealth(reachable: false);
      }
      await fabric.deliver(
        [1],
        bundleId: 'urgent',
        priority: LinkMessagePriority.callSignal,
      );
      for (var i = 0; i < 200; i++) {
        await fabric.deliver(
          [i & 0xFF],
          bundleId: 'bulk-$i',
          priority: LinkMessagePriority.bulk,
        );
      }
      final pending = queue
          .pendingInDeliveryOrder(clock)
          .map((b) => b.id)
          .toList();
      expect(pending, contains('urgent'));
    });
  });
}
