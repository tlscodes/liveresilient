import 'dart:async';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

/// A mutable fake clock advanced in lockstep with [FakeAsync.elapse] so the
/// prober's RTT/cooldown measurements track fake time.
class FakeClock {
  DateTime _now = DateTime(2026, 1, 1);
  DateTime call() => _now;
  void advance(Duration by) => _now = _now.add(by);
}

/// Advances fake time in small steps, keeping [clock] in lockstep so timers
/// firing at intermediate moments observe a consistent wall clock.
void tick(FakeAsync async, FakeClock clock, Duration total) {
  const step = Duration(milliseconds: 10);
  var remaining = total;
  while (remaining > Duration.zero) {
    final d = remaining < step ? remaining : step;
    clock.advance(d);
    async.elapse(d);
    remaining -= d;
  }
}

void expectNoPendingTimers(FakeAsync async) {
  expect(async.periodicTimerCount, 0, reason: 'periodic timers leaked');
  expect(async.nonPeriodicTimerCount, 0, reason: 'timers leaked');
}

final uriA = Uri.parse('https://a.example.com/probe');
final uriB = Uri.parse('https://b.example.com/probe');
final uriC = Uri.parse('https://c.example.com/probe');

void main() {
  group('ReachabilityProber', () {
    test('constructor validation', () {
      Future<bool> probe(Uri _) async => true;
      expect(
        () => ReachabilityProber(candidates: [], probe: probe),
        throwsArgumentError,
      );
      expect(
        () => ReachabilityProber(
          candidates: [uriA],
          probe: probe,
          probeTimeout: Duration.zero,
        ),
        throwsArgumentError,
      );
      expect(
        () => ReachabilityProber(
          candidates: [uriA],
          probe: probe,
          probeTimeout: const Duration(seconds: -1),
        ),
        throwsArgumentError,
      );
      expect(
        () => ReachabilityProber(candidates: [uriA], probe: probe, alpha: 0),
        throwsArgumentError,
      );
      expect(
        () => ReachabilityProber(candidates: [uriA], probe: probe, alpha: 1.1),
        throwsArgumentError,
      );
    });

    test('probes start staggered: 0, 200ms, 400ms', () {
      fakeAsync((async) {
        final clock = FakeClock();
        final started = <Uri>[];
        final prober = ReachabilityProber(
          candidates: [uriA, uriB, uriC],
          probe: (uri) {
            started.add(uri);
            return Completer<bool>().future; // never completes → timeout
          },
          now: clock.call,
        );
        unawaited(prober.probeAll());

        tick(async, clock, const Duration(milliseconds: 10));
        expect(started, [uriA]);
        tick(async, clock, const Duration(milliseconds: 200));
        expect(started, [uriA, uriB]);
        tick(async, clock, const Duration(milliseconds: 200));
        expect(started, [uriA, uriB, uriC]);

        // Let all timeouts fire so nothing leaks.
        tick(async, clock, const Duration(seconds: 3));
        expectNoPendingTimers(async);
        prober.dispose();
      });
    });

    test('fast winner: later candidates never start, winner returned', () {
      fakeAsync((async) {
        final clock = FakeClock();
        final started = <Uri>[];
        final prober = ReachabilityProber(
          candidates: [uriA, uriB, uriC],
          probe: (uri) {
            started.add(uri);
            return Future<bool>.delayed(
              const Duration(milliseconds: 50),
              () => true,
            );
          },
          now: clock.call,
        );
        Uri? winner;
        unawaited(prober.probeAll().then((w) => winner = w));

        tick(async, clock, const Duration(milliseconds: 100));
        expect(winner, uriA);
        expect(started, [uriA]); // B and C never invoked.

        tick(async, clock, const Duration(seconds: 3));
        expectNoPendingTimers(async);
        prober.dispose();
      });
    });

    test('slow winner: second-started candidate wins and is returned', () {
      fakeAsync((async) {
        final clock = FakeClock();
        final prober = ReachabilityProber(
          candidates: [uriA, uriB],
          probe: (uri) {
            if (uri == uriA) {
              return Future<bool>.delayed(
                const Duration(milliseconds: 100),
                () => false,
              );
            }
            return Future<bool>.delayed(
              const Duration(milliseconds: 50),
              () => true,
            );
          },
          now: clock.call,
        );
        Uri? winner;
        unawaited(prober.probeAll().then((w) => winner = w));

        // B starts at 200ms, succeeds at 250ms.
        tick(async, clock, const Duration(milliseconds: 300));
        expect(winner, uriB);
        expectNoPendingTimers(async);
        prober.dispose();
      });
    });

    test('per-probe timeout counts as failure and trips the breaker', () {
      fakeAsync((async) {
        final clock = FakeClock();
        var calls = 0;
        final prober = ReachabilityProber(
          candidates: [uriA],
          probe: (_) {
            calls++;
            return Completer<bool>().future; // hangs → timeout
          },
          now: clock.call,
          breakerConfig: const CircuitBreakerConfig(failureThreshold: 2),
        );
        Uri? result;
        unawaited(prober.probeAll().then((w) => result = w));
        tick(async, clock, const Duration(seconds: 3));
        expect(result, isNull);
        expect(prober.ranked, [uriA]); // one failure: breaker still closed

        prober.onNetworkChanged();
        unawaited(prober.probeAll());
        tick(async, clock, const Duration(seconds: 3));
        expect(calls, 2);
        expect(prober.ranked, isEmpty); // second failure opened the breaker

        expectNoPendingTimers(async);
        prober.dispose();
      });
    });

    test('cooldown: second round probes nothing, ranked unchanged', () {
      fakeAsync((async) {
        final clock = FakeClock();
        var calls = 0;
        final prober = ReachabilityProber(
          candidates: [uriA, uriB],
          probe: (_) {
            calls++;
            return Future<bool>.delayed(
              const Duration(milliseconds: 10),
              () => true,
            );
          },
          stagger: Duration.zero,
          now: clock.call,
        );
        unawaited(prober.probeAll());
        tick(async, clock, const Duration(milliseconds: 100));
        expect(calls, 2);
        final rankedBefore = prober.ranked;

        Uri? cached;
        unawaited(prober.probeAll().then((w) => cached = w));
        tick(async, clock, const Duration(milliseconds: 100));
        expect(calls, 2); // zero new probe invocations
        expect(prober.ranked, rankedBefore);
        expect(cached, rankedBefore.first); // best cached success stands

        expectNoPendingTimers(async);
        prober.dispose();
      });
    });

    test('onNetworkChanged invalidates cooldown so next round re-probes', () {
      fakeAsync((async) {
        final clock = FakeClock();
        var calls = 0;
        final prober = ReachabilityProber(
          candidates: [uriA, uriB],
          probe: (_) {
            calls++;
            return Future<bool>.delayed(
              const Duration(milliseconds: 10),
              () => true,
            );
          },
          stagger: Duration.zero,
          now: clock.call,
        );
        unawaited(prober.probeAll());
        tick(async, clock, const Duration(milliseconds: 100));
        expect(calls, 2);

        prober.onNetworkChanged();
        unawaited(prober.probeAll());
        tick(async, clock, const Duration(milliseconds: 100));
        expect(calls, 4);

        expectNoPendingTimers(async);
        prober.dispose();
      });
    });

    test('EWMA: low-RTT candidate ranks above slow one; open breaker drops '
        'a candidate from ranked', () {
      fakeAsync((async) {
        final clock = FakeClock();
        final prober = ReachabilityProber(
          candidates: [uriB, uriA, uriC], // B first, so ranking must flip
          probe: (uri) {
            if (uri == uriA) {
              return Future<bool>.delayed(
                const Duration(milliseconds: 20),
                () => true,
              );
            }
            if (uri == uriB) {
              return Future<bool>.delayed(
                const Duration(milliseconds: 900),
                () => true,
              );
            }
            return Future<bool>.delayed(
              const Duration(milliseconds: 10),
              () => false, // C always fails
            );
          },
          stagger: Duration.zero, // all start together; all record results
          now: clock.call,
          breakerConfig: const CircuitBreakerConfig(failureThreshold: 3),
        );

        for (var i = 0; i < 4; i++) {
          unawaited(prober.probeAll());
          tick(async, clock, const Duration(seconds: 3));
          prober.onNetworkChanged();
        }

        // A (20ms RTT) outranks B (900ms RTT); C's breaker opened after 3
        // consecutive failures and it dropped out of the ranking.
        expect(prober.ranked, [uriA, uriB]);

        expectNoPendingTimers(async);
        prober.dispose();
      });
    });

    test('all-fail: returns null, records every failure, rankings emits', () {
      fakeAsync((async) {
        final clock = FakeClock();
        final emissions = <List<Uri>>[];
        final prober = ReachabilityProber(
          candidates: [uriA, uriB],
          probe: (_) => Future<bool>.delayed(
            const Duration(milliseconds: 10),
            () => false,
          ),
          stagger: Duration.zero,
          now: clock.call,
          breakerConfig: const CircuitBreakerConfig(failureThreshold: 1),
        );
        prober.rankings.listen(emissions.add);

        Uri? result;
        unawaited(prober.probeAll().then((w) => result = w));
        tick(async, clock, const Duration(seconds: 1));

        expect(result, isNull);
        // failureThreshold 1: each failure opens that breaker → membership
        // shrinks → ranking changed → stream emitted.
        expect(emissions, isNotEmpty);
        expect(prober.ranked, isEmpty);

        expectNoPendingTimers(async);
        prober.dispose();
      });
    });

    test('overlapping probeAll returns the same in-flight future', () {
      fakeAsync((async) {
        final clock = FakeClock();
        var calls = 0;
        final prober = ReachabilityProber(
          candidates: [uriA],
          probe: (_) {
            calls++;
            return Future<bool>.delayed(
              const Duration(milliseconds: 50),
              () => true,
            );
          },
          now: clock.call,
        );
        final f1 = prober.probeAll();
        final f2 = prober.probeAll();
        expect(identical(f1, f2), isTrue);
        tick(async, clock, const Duration(milliseconds: 100));
        expect(calls, 1);
        expectNoPendingTimers(async);
        prober.dispose();
      });
    });

    test(
      'dispose mid-round: no throw, no timer leak, probeAll then throws',
      () {
        fakeAsync((async) {
          final clock = FakeClock();
          final prober = ReachabilityProber(
            candidates: [uriA, uriB, uriC],
            probe: (_) => Future<bool>.delayed(
              const Duration(milliseconds: 500),
              () => true,
            ),
            now: clock.call,
          );
          Uri? result;
          var completed = false;
          unawaited(
            prober.probeAll().then((w) {
              result = w;
              completed = true;
            }),
          );

          tick(async, clock, const Duration(milliseconds: 250)); // A, B started
          prober.dispose();
          async.flushMicrotasks();
          expect(completed, isTrue); // in-flight round completed with null
          expect(result, isNull);

          // Late probe completions land harmlessly.
          tick(async, clock, const Duration(seconds: 3));
          expectNoPendingTimers(async);
          expect(prober.probeAll, throwsStateError);
        });
      },
    );
  });
}
