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
          config: const OutboxConfig(messageLifetime: Duration(hours: 1)),
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
          config: const OutboxConfig(messageLifetime: Duration(seconds: 10)),
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
            config: const OutboxConfig(maxPending: 2),
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
}
