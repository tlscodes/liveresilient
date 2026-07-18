import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:signaling/signaling.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

/// `ReliableOutbox` schedules real `Timer`s (retry back-off) and reads
/// `clock.now()` for enqueue timestamps and message-lifetime expiry. Every
/// test below drives both through the same fake timeline so elapsed time
/// and "now" never drift apart.
void runFake(void Function(FakeAsync async) body) {
  final epoch = DateTime.utc(2026, 1, 1);
  fakeAsync((async) {
    withClock(Clock(() => epoch.add(async.elapsed)), () => body(async));
  });
}

void main() {
  group('enqueue -> acknowledge', () {
    test('acknowledged outcome completes the enqueue future and stops '
        'retransmission for good', () {
      runFake((async) {
        final transmitter = RecordingTransmitter();
        final outbox = ReliableOutbox(transmit: transmitter.call);
        final envelope = testEnvelope(messageId: 'm1');

        OutboxOutcome? outcome;
        outbox.enqueue(envelope).then((o) => outcome = o);
        async.elapse(Duration.zero); // fires the immediate first attempt

        expect(transmitter.ids, ['m1']);

        outbox.acknowledge('m1');
        async.flushMicrotasks();

        expect(outcome, OutboxOutcome.acknowledged);
        expect(outbox.pendingCount, 0);

        // Elapse well past several back-off periods: the id must never
        // be retransmitted again.
        async.elapse(const Duration(minutes: 5));
        expect(transmitter.ids, ['m1']);

        outbox.dispose();
      });
    });
  });

  group('no-ack retransmission back-off', () {
    test('delay before attempt n+1 is d(n) = min(initialRetryDelay * 2^n, '
        'maxRetryDelay), for n = 1..10, and never exceeds maxRetryDelay', () {
      runFake((async) {
        final transmitter = RecordingTransmitter();
        // messageLifetime is raised well past the ~210s this property
        // sweep needs, to isolate the back-off schedule from expiry
        // (expiry has its own dedicated test below).
        final outbox = ReliableOutbox(
          transmit: transmitter.call,
          config: OutboxConfig(messageLifetime: const Duration(hours: 1)),
        );
        outbox.enqueue(testEnvelope(messageId: 'm1'));

        async.elapse(Duration.zero);
        expect(transmitter.log.length, 1); // attempt 1, immediate

        for (var n = 1; n <= 10; n++) {
          final expectedMs = math.min(1000 * math.pow(2, n).toInt(), 30000);
          expect(expectedMs, lessThanOrEqualTo(30000));

          final before = transmitter.log.length;
          final halfMs = expectedMs ~/ 2;

          // Not retransmitted before ~half of the expected delay.
          async.elapse(Duration(milliseconds: halfMs));
          expect(
            transmitter.log.length,
            before,
            reason: 'attempt ${n + 1} fired too early (n=$n)',
          );

          // Retransmitted once the full expected delay has elapsed.
          async.elapse(Duration(milliseconds: expectedMs - halfMs + 5));
          expect(
            transmitter.log.length,
            before + 1,
            reason: 'attempt ${n + 1} missed its deadline (n=$n)',
          );
        }

        outbox.dispose();
      });
    });

    test('a transmission error is absorbed; retries continue on schedule', () {
      runFake((async) {
        final transmitter = RecordingTransmitter()
          ..throwOnce = StateError('boom');
        final outbox = ReliableOutbox(transmit: transmitter.call);
        outbox.enqueue(testEnvelope(messageId: 'm1'));

        async.elapse(Duration.zero);
        expect(transmitter.log.length, 1); // attempt made despite throwing

        async.elapse(const Duration(seconds: 2));
        expect(transmitter.log.length, 2); // retried normally afterward

        outbox.dispose();
      });
    });
  });

  group('expiry', () {
    test('expires as OutboxOutcome.expired after messageLifetime and removes '
        'from the store', () {
      runFake((async) {
        final transmitter = RecordingTransmitter();
        final store = InMemoryOutboxStore();
        final outbox = ReliableOutbox(
          transmit: transmitter.call,
          store: store,
          config: OutboxConfig(messageLifetime: const Duration(seconds: 10)),
        );
        final envelope = testEnvelope(messageId: 'm1');

        OutboxOutcome? outcome;
        outbox.enqueue(envelope).then((o) => outcome = o);
        async.elapse(Duration.zero);
        expect(store.saveCalls, contains('m1'));

        // Attempts at t=0, t=2, t=6 (age 6s < 10s); the attempt due at
        // t=14 observes age >= 10s and expires instead of transmitting.
        async.elapse(const Duration(seconds: 15));

        expect(outcome, OutboxOutcome.expired);
        expect(outbox.pendingCount, 0);
        expect(store.removeCalls, contains('m1'));
        expect(transmitter.ids.where((id) => id == 'm1').length, 3);
      });
    });
  });

  group('duplicate enqueue', () {
    test('duplicate enqueue of the same messageId keeps a single pending '
        'entry and resolves every caller identically', () {
      runFake((async) {
        final transmitter = RecordingTransmitter();
        final outbox = ReliableOutbox(transmit: transmitter.call);
        final envelope = testEnvelope(messageId: 'm1');

        OutboxOutcome? outcome1;
        OutboxOutcome? outcome2;
        outbox.enqueue(envelope).then((o) => outcome1 = o);
        outbox.enqueue(envelope).then((o) => outcome2 = o);

        expect(outbox.pendingCount, 1);

        async.elapse(Duration.zero);
        expect(transmitter.log.length, 1); // one entry, one transmission

        outbox.acknowledge('m1');
        async.flushMicrotasks();

        expect(outcome1, OutboxOutcome.acknowledged);
        expect(outcome2, OutboxOutcome.acknowledged);
      });
    });
  });

  group('overload', () {
    test(
      'enqueue beyond maxPending throws StateError, rejecting the future',
      () {
        runFake((async) {
          final transmitter = RecordingTransmitter();
          final outbox = ReliableOutbox(
            transmit: transmitter.call,
            config: OutboxConfig(maxPending: 2),
          );

          outbox.enqueue(testEnvelope(messageId: 'a'));
          outbox.enqueue(testEnvelope(messageId: 'b'));
          expect(outbox.pendingCount, 2);

          Object? caught;
          outbox.enqueue(testEnvelope(messageId: 'c')).catchError((Object e) {
            caught = e;
            return OutboxOutcome.disposed;
          });
          async.flushMicrotasks();

          expect(caught, isStateError);
          expect(outbox.pendingCount, 2);

          outbox.dispose();
        });
      },
    );
  });

  group('restore', () {
    test('reloads persisted envelopes from the store and starts retransmitting '
        'them', () {
      runFake((async) {
        final transmitter = RecordingTransmitter();
        final store = InMemoryOutboxStore();
        final persisted = testEnvelope(messageId: 'persisted-1');
        store.seed(persisted);

        final outbox = ReliableOutbox(transmit: transmitter.call, store: store);
        expect(outbox.pendingCount, 0);

        outbox.restore();
        async.flushMicrotasks(); // await store.loadAll()
        expect(outbox.pendingCount, 1);

        async.elapse(Duration.zero);
        expect(transmitter.ids, contains('persisted-1'));

        outbox.dispose();
      });
    });

    test('calling restore() a second time does not duplicate the already '
        'loaded entries (the containsKey guard)', () {
      runFake((async) {
        final transmitter = RecordingTransmitter();
        final store = InMemoryOutboxStore();
        store.seed(testEnvelope(messageId: 'persisted-1'));

        final outbox = ReliableOutbox(transmit: transmitter.call, store: store);

        outbox.restore();
        async.flushMicrotasks();
        expect(outbox.pendingCount, 1);

        outbox.restore();
        async.flushMicrotasks();
        expect(outbox.pendingCount, 1);

        async.elapse(Duration.zero);
        // Exactly one live retry timer per entry: a duplicated entry
        // would have scheduled a second concurrent retry chain and so
        // transmitted twice for the same id at t=0.
        expect(transmitter.ids.where((id) => id == 'persisted-1').length, 1);

        outbox.dispose();
      });
    });
  });

  group('flush', () {
    test('cancels pending back-off timers and retransmits every pending '
        'envelope immediately', () {
      runFake((async) {
        final transmitter = RecordingTransmitter();
        final outbox = ReliableOutbox(transmit: transmitter.call);
        outbox.enqueue(testEnvelope(messageId: 'm1'));
        async.elapse(Duration.zero);
        expect(transmitter.log.length, 1);

        // Still deep inside the back-off window (next attempt due at
        // roughly +2s).
        async.elapse(const Duration(milliseconds: 500));
        expect(transmitter.log.length, 1);

        outbox.flush();
        async.elapse(Duration.zero);
        expect(transmitter.log.length, 2);

        outbox.dispose();
      });
    });
  });

  group('dispose', () {
    test('completes every pending envelope as disposed and cancels its '
        'timers; further enqueue throws', () {
      runFake((async) {
        final transmitter = RecordingTransmitter();
        final outbox = ReliableOutbox(transmit: transmitter.call);

        final outcomes = <String, OutboxOutcome>{};
        outbox
            .enqueue(testEnvelope(messageId: 'a'))
            .then((o) => outcomes['a'] = o);
        outbox
            .enqueue(testEnvelope(messageId: 'b'))
            .then((o) => outcomes['b'] = o);
        async.elapse(Duration.zero);

        outbox.dispose();
        async.flushMicrotasks();

        expect(outcomes, {
          'a': OutboxOutcome.disposed,
          'b': OutboxOutcome.disposed,
        });
        expect(outbox.pendingCount, 0);
        expect(async.pendingTimers, isEmpty);

        Object? caught;
        outbox.enqueue(testEnvelope(messageId: 'c')).catchError((Object e) {
          caught = e;
          return OutboxOutcome.disposed;
        });
        async.flushMicrotasks();
        expect(caught, isStateError);

        // No further activity from cancelled timers.
        async.elapse(const Duration(minutes: 5));
        expect(transmitter.log.length, 2); // only the initial a/b attempts
      });
    });
  });

  group('OutboxConfig validation', () {
    test('the defaults are accepted', () {
      expect(() => OutboxConfig(), returnsNormally);
    });

    test('non-positive initialRetryDelay throws ArgumentError', () {
      expect(
        () => OutboxConfig(initialRetryDelay: Duration.zero),
        throwsArgumentError,
      );
    });

    test('non-positive maxRetryDelay throws ArgumentError', () {
      expect(
        () => OutboxConfig(maxRetryDelay: Duration.zero),
        throwsArgumentError,
      );
    });

    test('non-positive messageLifetime throws ArgumentError', () {
      expect(
        () => OutboxConfig(messageLifetime: Duration.zero),
        throwsArgumentError,
      );
    });

    test('maxRetryDelay < initialRetryDelay throws ArgumentError', () {
      expect(
        () => OutboxConfig(
          initialRetryDelay: const Duration(seconds: 5),
          maxRetryDelay: const Duration(seconds: 1),
        ),
        throwsArgumentError,
      );
    });

    test('maxRetryDelay == initialRetryDelay is accepted', () {
      expect(
        () => OutboxConfig(
          initialRetryDelay: const Duration(seconds: 5),
          maxRetryDelay: const Duration(seconds: 5),
        ),
        returnsNormally,
      );
    });

    test('backoffMultiplier < 1 throws ArgumentError', () {
      expect(() => OutboxConfig(backoffMultiplier: 0.5), throwsArgumentError);
    });

    test('backoffMultiplier == 1 is accepted', () {
      expect(() => OutboxConfig(backoffMultiplier: 1), returnsNormally);
    });

    test('maxPending < 1 throws ArgumentError', () {
      expect(() => OutboxConfig(maxPending: 0), throwsArgumentError);
      expect(() => OutboxConfig(maxPending: -1), throwsArgumentError);
    });

    test('maxPending == 1 is accepted', () {
      expect(() => OutboxConfig(maxPending: 1), returnsNormally);
    });
  });

  group('InboxDeduplicator', () {
    test('constructor rejects maximumEntries < 1', () {
      expect(() => InboxDeduplicator(maximumEntries: 0), throwsRangeError);
      expect(() => InboxDeduplicator(maximumEntries: -1), throwsRangeError);
    });

    test('maximumEntries == 1 is accepted', () {
      expect(() => InboxDeduplicator(maximumEntries: 1), returnsNormally);
    });

    test('markIfNew reports true once, then false for the same id', () {
      final dedup = InboxDeduplicator();
      expect(dedup.markIfNew('m1'), isTrue);
      expect(dedup.markIfNew('m1'), isFalse);
      expect(dedup.markIfNew('m1'), isFalse);
    });

    test('eviction at exact boundary: filling to maximumEntries then adding '
        'one more evicts the OLDEST id, which then reports as new again', () {
      final dedup = InboxDeduplicator(maximumEntries: 3);

      expect(dedup.markIfNew('a'), isTrue);
      expect(dedup.markIfNew('b'), isTrue);
      expect(dedup.markIfNew('c'), isTrue);

      // At capacity: every one of a/b/c is still a known duplicate.
      expect(dedup.markIfNew('a'), isFalse);
      expect(dedup.markIfNew('b'), isFalse);
      expect(dedup.markIfNew('c'), isFalse);

      // A 4th distinct id evicts the oldest ('a').
      expect(dedup.markIfNew('d'), isTrue);

      // b, c, d survived the eviction. Checked BEFORE probing 'a' below,
      // since markIfNew('a') is itself an insertion that would trigger a
      // second eviction (at this 3-entry capacity) and invalidate these.
      expect(dedup.markIfNew('b'), isFalse);
      expect(dedup.markIfNew('c'), isFalse);
      expect(dedup.markIfNew('d'), isFalse);

      expect(
        dedup.markIfNew('a'),
        isTrue,
        reason: 'the evicted oldest id must report as new again',
      );
    });

    test('re-seeing an id does not refresh its eviction position (pinned '
        'LinkedHashSet insertion-order semantics)', () {
      final dedup = InboxDeduplicator(maximumEntries: 3);

      expect(dedup.markIfNew('a'), isTrue);
      expect(dedup.markIfNew('b'), isTrue);
      expect(dedup.markIfNew('c'), isTrue);

      // Re-seeing 'a' (already the oldest) is a no-op on ordering: it
      // must NOT move 'a' to the back of the eviction queue.
      expect(dedup.markIfNew('a'), isFalse);

      // A 4th distinct id must still evict 'a' (the original oldest),
      // not 'b' — proving re-seeing did not refresh its position.
      expect(dedup.markIfNew('d'), isTrue);

      // Checked BEFORE probing 'a' below, since markIfNew('a') is itself an
      // insertion that would trigger a second eviction (at this 3-entry
      // capacity) and invalidate this assertion.
      expect(
        dedup.markIfNew('b'),
        isFalse,
        reason: '"b" must still be known — it was never evicted',
      );
      expect(
        dedup.markIfNew('a'),
        isTrue,
        reason: '"a" must have been evicted despite being re-seen',
      );
    });
  });
}
