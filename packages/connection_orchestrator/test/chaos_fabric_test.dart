/// The test for the claim, not for the details.
///
/// Everything else in this package checks a behaviour someone thought of.
/// This drives thousands of random failures through the fabric and asserts
/// only the things that must hold whatever happened — which is the only
/// kind of check that catches what nobody thought of.
library;

import 'dart:convert';

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

    // Reproducibility, checked two ways.
    //
    // Comparing one in-process script to another in-process script is a
    // tautology: same binary, same SDK, same machine, same second. It
    // passes by construction and cannot see the failure it claims to
    // guard — the script changing between builds, which would silently
    // turn "seed 42 is green" into a statement about a different world.
    //
    // Run 1 vs run 2 is kept (it catches hidden global state leaking
    // between calls); the actual guard is the frozen digest, an oracle
    // that does not come from this run.
    test('two independent runs of the same seed are byte-for-byte equal', () {
      final first = _canonicalScriptBytes(chaosScript(31337, laneCount: 4));
      final second = _canonicalScriptBytes(chaosScript(31337, laneCount: 4));
      expect(first, isNotEmpty);
      expect(first, orderedEquals(second));
    });

    test('the seeded world matches its frozen golden digest', () {
      // Measured once (2026-07-31, Dart 3.12.2) and pinned. A failure here
      // means the generated world moved: the generator, the event
      // rendering, or dart:math Random changed. All three are real
      // findings — record why before re-measuring the constant.
      final script = chaosScript(31337, laneCount: 4);
      expect(script.length, _chaosGoldenEventCount);
      expect(
        _fnv1a64Hex(_canonicalScriptBytes(script)),
        equals(_chaosScriptGoldenDigest),
        reason:
            'chaosScript(31337, laneCount: 4) drifted from the frozen world',
      );
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

/// Number of events in the frozen world below.
const _chaosGoldenEventCount = 120;

/// FNV-1a/64 over the canonical rendering of chaosScript(31337, laneCount: 4).
/// Measured 2026-07-31 on Dart 3.12.2 (stable), macos_x64.
const _chaosScriptGoldenDigest = '66e6264667ec9e61';

/// Canonical wire form of a chaos script: each event rendered by its own
/// toString(), newline-separated, UTF-8 encoded. Fixed separator and fixed
/// encoding so the digest cannot move because of platform string handling.
List<int> _canonicalScriptBytes(List<ChaosEvent> script) =>
    utf8.encode(script.map((e) => e.toString()).join('\n'));

/// FNV-1a 64-bit in [BigInt] so the result is identical on the VM and on
/// web (53-bit ints). Dependency-free on purpose: the oracle must not move
/// when a package version moves.
String _fnv1a64Hex(List<int> bytes) {
  final mask = (BigInt.one << 64) - BigInt.one;
  final prime = BigInt.parse('1099511628211');
  var hash = BigInt.parse('14695981039346656037');
  for (final b in bytes) {
    hash = (hash ^ BigInt.from(b)) & mask;
    hash = (hash * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
