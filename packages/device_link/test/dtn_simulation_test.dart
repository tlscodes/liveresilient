/// Randomized offline/online simulation for [DtnBundleQueue]: repeated
/// episodes of offering bundles while "offline" then flushing while
/// "online", on a simulated (plain int) clock, checking global delivery
/// invariants across the whole run. The queue itself holds no timers —
/// time only ever advances via the `nowMs` ints this test controls, so
/// there is no timer to leak.
library;

import 'dart:math';

import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

void main() {
  test('100+ offline/online episodes: exactly-once delivery, priority order, '
      'no expired delivery, capacity respected', () async {
    final random = Random(42);
    final priorities = LinkMessagePriority.values;

    final queue = DtnBundleQueue(maxBundles: 32, maxBytes: 4096);

    var nowMs = 0;
    var nextId = 0;

    final accepted = <String>{}; // ids admitted as BundleAdmission.stored
    final delivered = <String>[]; // ids actually forwarded==true, in order
    final deliveredSet = <String>{};

    for (var episode = 0; episode < 120; episode++) {
      // --- offline: offer a random batch ---
      final batchSize = random.nextInt(6); // 0..5
      for (var i = 0; i < batchSize; i++) {
        final id = 'b${nextId++}';
        final priority = priorities[random.nextInt(priorities.length)];
        // Some lifetimes are short enough to expire before reconnect.
        final lifetimeMs = 1 + random.nextInt(200);
        final sizeBytes = 1 + random.nextInt(64);
        final bundle = DtnBundle(
          id: id,
          payload: List<int>.filled(sizeBytes, 7),
          priority: priority,
          createdAtMs: nowMs,
          lifetimeMs: lifetimeMs,
        );
        final admission = queue.offer(bundle, nowMs: nowMs);
        if (admission == BundleAdmission.stored) {
          accepted.add(id);
        }

        // Capacity invariants after every offer.
        expect(queue.pendingCount, lessThanOrEqualTo(queue.maxBundles));
        expect(queue.pendingBytes, lessThanOrEqualTo(queue.maxBytes));

        nowMs += random.nextInt(20);
      }

      // Advance the clock further while "offline" (some bundles expire).
      nowMs += random.nextInt(150);

      // --- online: flush, occasionally failing once mid-flush ---
      var shouldFailOnce = random.nextBool();
      var lastPriorityIndex = priorities.length; // higher than any real index
      var lastCreatedAtMs = -1;

      Future<bool> forwarder(DtnBundle bundle) async {
        // No expired bundle should ever reach the forwarder.
        expect(bundle.isExpiredAt(nowMs), isFalse);

        // Priority-desc then arrival order within this flush call.
        if (bundle.priority.index == lastPriorityIndex) {
          expect(bundle.createdAtMs, greaterThanOrEqualTo(lastCreatedAtMs));
        } else {
          expect(bundle.priority.index, lessThan(lastPriorityIndex));
        }
        lastPriorityIndex = bundle.priority.index;
        lastCreatedAtMs = bundle.createdAtMs;

        if (shouldFailOnce) {
          shouldFailOnce = false;
          return false;
        }
        expect(deliveredSet.contains(bundle.id), isFalse); // no double deliver
        delivered.add(bundle.id);
        deliveredSet.add(bundle.id);
        return true;
      }

      await queue.flush(forwarder, nowMs: nowMs);

      // Retry flush in case the mid-episode failure stopped it early.
      if (queue.pendingCount > 0) {
        lastPriorityIndex = priorities.length;
        lastCreatedAtMs = -1;
        await queue.flush(forwarder, nowMs: nowMs);
      }

      expect(queue.pendingCount, lessThanOrEqualTo(queue.maxBundles));
      expect(queue.pendingBytes, lessThanOrEqualTo(queue.maxBytes));
    }

    // Final drain: whatever is left (not expired) should still flush cleanly.
    nowMs += 1;
    await queue.flush((bundle) async {
      expect(deliveredSet.contains(bundle.id), isFalse);
      delivered.add(bundle.id);
      deliveredSet.add(bundle.id);
      return true;
    }, nowMs: nowMs);

    // Every id delivered was accepted at some point, and no duplicates.
    expect(delivered.length, deliveredSet.length);
    for (final id in delivered) {
      expect(accepted, contains(id));
    }
    // Every delivered id was accepted (bundles rejected/expired-on-arrival by
    // offer() never entered `accepted`, so can never show up here).
    expect(deliveredSet.difference(accepted), isEmpty);
  });
}
