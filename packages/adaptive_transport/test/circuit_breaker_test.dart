import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

/// A mutable fake clock so tests never wait on real time.
class FakeClock {
  DateTime _now;
  FakeClock(this._now);

  DateTime call() => _now;

  void advance(Duration by) => _now = _now.add(by);
}

void main() {
  group('CircuitBreaker', () {
    late FakeClock clock;
    late CircuitBreaker breaker;
    const config = CircuitBreakerConfig(
      failureThreshold: 5,
      openDuration: Duration(seconds: 10),
      maxOpenDuration: Duration(minutes: 5),
      halfOpenMaxProbes: 2,
      halfOpenSuccessesToClose: 2,
    );

    setUp(() {
      clock = FakeClock(DateTime(2026, 1, 1));
      breaker = CircuitBreaker(config: config, clock: clock.call);
    });

    void trip() {
      for (var i = 0; i < config.failureThreshold; i++) {
        breaker.recordFailure();
      }
    }

    test('trips open after failureThreshold consecutive failures', () {
      trip();
      expect(breaker.state, CircuitState.open);
      expect(breaker.allowsRequest(), isFalse);
    });

    test('recordSuccess while open does not bypass the cooldown', () {
      trip();
      expect(breaker.state, CircuitState.open);

      breaker.recordSuccess();

      expect(breaker.state, CircuitState.open);
      expect(breaker.allowsRequest(), isFalse);
    });

    test('reading state repeatedly before cooldown never mutates or '
        'consumes anything', () {
      trip();

      for (var i = 0; i < 10; i++) {
        expect(breaker.state, CircuitState.open);
      }
      // Still fully closed off: no probe budget was silently consumed.
      expect(breaker.allowsRequest(), isFalse);
      expect(breaker.state, CircuitState.open);
    });

    test('state reads halfOpen purely from elapsed time, with no mutating '
        'call', () {
      trip();
      clock.advance(config.openDuration);

      // `state` alone (no allowsRequest/recordX) must reflect half-open.
      expect(breaker.state, CircuitState.halfOpen);
      expect(breaker.state, CircuitState.halfOpen);
    });

    test('allowsRequest admits at most halfOpenMaxProbes probes once '
        'half-open', () {
      trip();
      clock.advance(config.openDuration);

      expect(breaker.allowsRequest(), isTrue);
      expect(breaker.allowsRequest(), isTrue);
      // Probe budget (2) exhausted; further requests are rejected until a
      // probe resolves the state.
      expect(breaker.allowsRequest(), isFalse);
    });

    test(
      'halfOpenSuccessesToClose consecutive successes close the breaker',
      () {
        trip();
        clock.advance(config.openDuration);

        expect(breaker.allowsRequest(), isTrue);
        breaker.recordSuccess();
        expect(breaker.state, CircuitState.halfOpen);

        expect(breaker.allowsRequest(), isTrue);
        breaker.recordSuccess();

        expect(breaker.state, CircuitState.closed);
        expect(breaker.allowsRequest(), isTrue);
      },
    );

    test(
      'a failure while half-open re-trips with a doubled currentOpenDuration',
      () {
        trip();
        expect(breaker.currentOpenDuration, config.openDuration);

        clock.advance(config.openDuration);
        expect(breaker.allowsRequest(), isTrue); // consume a probe
        breaker.recordFailure();

        expect(breaker.state, CircuitState.open);
        expect(breaker.currentOpenDuration, config.openDuration * 2);

        // The new cooldown is the doubled duration, not the original one:
        // advancing by just the original openDuration must not be enough.
        clock.advance(config.openDuration);
        expect(breaker.state, CircuitState.open);

        clock.advance(config.openDuration);
        expect(breaker.state, CircuitState.halfOpen);
      },
    );
  });
}
