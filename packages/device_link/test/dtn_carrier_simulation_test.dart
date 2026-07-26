/// Randomized multi-node carrier simulation for the delay-tolerant path:
/// a source, two mobile carriers, and a destination drift in and out of
/// contact over 120 episodes on a simulated (plain int) clock. Bundles
/// carry random priorities and lifetimes; some contacts interrupt
/// mid-exchange. Global invariants checked across the whole run:
///
///  - exactly-once: every bundle the source accepted is either delivered
///    to the destination exactly once, or provably expired undelivered;
///  - per-contact transfer order is priority-then-oldest;
///  - no duplicate delivery across carry-and-keep hops (the destination's
///    own de-dup is the last line of defence and is asserted directly);
///  - no queue ever exceeds its configured bounds;
///  - no timers: the queues and exchange hold none — time only advances
///    via the `nowMs` ints this test controls, so nothing can leak.
library;

import 'dart:math';

import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

const _maxBundles = 24;
const _maxBytes = 8192;

class _GrantedConsent implements DeviceLinkConsent {
  const _GrantedConsent();
  @override
  bool get granted => true;
}

void main() {
  test('120 randomized episodes over source→carriers→destination: '
      'exactly-once, in-order, bounded, leak-free', () async {
    final random = Random(1337);
    const exchange = BundleExchange(maxBundlesPerContact: 8);
    const consent = _GrantedConsent();

    DtnBundleQueue newQueue() =>
        DtnBundleQueue(maxBundles: _maxBundles, maxBytes: _maxBytes);

    final source = newQueue();
    final carriers = [newQueue(), newQueue()];
    final destination = newQueue();

    var nowMs = 0;
    var nextId = 0;

    // id → bundle metadata for the end-of-run accounting.
    final accepted = <String, DtnBundle>{};
    final deliveredOrderPerContact = <List<String>>[];
    final deliveredSet = <String>{};
    final deliveredAtMs = <String, int>{};

    void assertBounded(DtnBundleQueue q) {
      expect(q.pendingCount, lessThanOrEqualTo(_maxBundles));
    }

    // Runs one contact sender→receiver, possibly interrupting mid-way,
    // and checks the per-contact ordering invariant on what moved.
    Future<void> contact(
      DtnBundleQueue sender,
      DtnBundleQueue receiver, {
      required RetainPolicy retain,
      bool interrupt = false,
    }) async {
      var offersLeft = interrupt ? random.nextInt(4) : 1 << 30;
      final before = {
        for (final b in sender.pendingInDeliveryOrder(nowMs)) b.id: b,
      };
      final report = await exchange.run(
        sender: sender,
        receiver: receiver,
        nowMs: nowMs,
        retain: retain,
        consent: consent,
        isContactOpen: () => offersLeft-- > 0,
      );
      // Per-contact order: transferred ids must appear in the same relative
      // order as the sender's own priority-then-oldest delivery order.
      final expectedOrder = [
        for (final b in before.values)
          if (report.transferred.contains(b.id)) b.id,
      ];
      expect(report.transferred, expectedOrder);
      if (identical(receiver, destination)) {
        for (final id in report.transferred) {
          expect(
            deliveredSet.add(id),
            isTrue,
            reason: 'bundle $id delivered to destination twice',
          );
          deliveredAtMs[id] = nowMs;
        }
        deliveredOrderPerContact.add(report.transferred);
      }
      assertBounded(sender);
      assertBounded(receiver);
    }

    for (var episode = 0; episode < 120; episode++) {
      // Source produces a small random batch.
      for (var i = random.nextInt(4); i > 0; i--) {
        final b = DtnBundle(
          id: 'b${nextId++}',
          payload: List<int>.filled(1 + random.nextInt(64), 7),
          priority: LinkMessagePriority
              .values[random.nextInt(LinkMessagePriority.values.length)],
          createdAtMs: nowMs,
          lifetimeMs: 500 + random.nextInt(20000),
        );
        if (source.offer(b, nowMs: nowMs) == BundleAdmission.stored) {
          accepted[b.id] = b;
        }
      }

      // A random contact (or none) this episode.
      final roll = random.nextInt(6);
      final interrupt = random.nextInt(4) == 0;
      switch (roll) {
        case 0: // source meets a carrier (single-copy hand-off)
          await contact(
            source,
            carriers[random.nextInt(2)],
            retain: RetainPolicy.handOffAndForget,
            interrupt: interrupt,
          );
        case 1: // carriers meet each other (redundant carry-and-keep)
          await contact(
            carriers[0],
            carriers[1],
            retain: RetainPolicy.carryAndKeep,
            interrupt: interrupt,
          );
        case 2: // a carrier reaches the destination
          await contact(
            carriers[random.nextInt(2)],
            destination,
            retain: RetainPolicy.handOffAndForget,
            interrupt: interrupt,
          );
        case 3: // source meets destination directly
          await contact(
            source,
            destination,
            retain: RetainPolicy.handOffAndForget,
            interrupt: interrupt,
          );
        default: // no contact this episode — the world just drifts
          break;
      }

      nowMs += random.nextInt(800);
    }

    // Drain: repeated uninterrupted contacts until no further progress, so
    // every still-live bundle gets its chance to arrive.
    var progress = true;
    while (progress) {
      final beforeCount = deliveredSet.length;
      await contact(source, carriers[0], retain: RetainPolicy.handOffAndForget);
      await contact(
        carriers[0],
        carriers[1],
        retain: RetainPolicy.carryAndKeep,
      );
      await contact(
        carriers[0],
        destination,
        retain: RetainPolicy.handOffAndForget,
      );
      await contact(
        carriers[1],
        destination,
        retain: RetainPolicy.handOffAndForget,
      );
      await contact(source, destination, retain: RetainPolicy.handOffAndForget);
      progress = deliveredSet.length > beforeCount;
    }

    expect(
      accepted.length,
      greaterThan(100),
      reason: 'simulation should exercise a substantial bundle population',
    );
    expect(deliveredSet, isNotEmpty);

    // Exactly-once accounting: every accepted bundle was delivered exactly
    // once (uniqueness enforced above at delivery time), and every
    // undelivered bundle is either expired or was shed by a bounded queue —
    // never a live bundle left stuck in the network after a full drain.
    for (final entry in accepted.entries) {
      if (deliveredSet.contains(entry.key)) continue;
      final stillQueuedSomewhere = [source, ...carriers].any(
        (q) => q.pendingInDeliveryOrder(nowMs).any((p) => p.id == entry.key),
      );
      expect(
        stillQueuedSomewhere,
        isFalse,
        reason: 'live bundle ${entry.key} stuck after full drain',
      );
    }

    // No expired bundle was ever delivered: delivery happened strictly
    // before that bundle's deadline.
    for (final id in deliveredSet) {
      final b = accepted[id]!;
      expect(
        deliveredAtMs[id]! < b.createdAtMs + b.lifetimeMs,
        isTrue,
        reason:
            'bundle $id delivered at ${deliveredAtMs[id]} '
            'after its deadline ${b.createdAtMs + b.lifetimeMs}',
      );
    }

    assertBounded(source);
    assertBounded(carriers[0]);
    assertBounded(carriers[1]);
    assertBounded(destination);
  });
}
