import 'dart:math';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

/// Minimal, fully-controllable [TransportChannel] fake. No real I/O, no
/// timers — [send]/[probe] resolve on the microtask queue via `async`.
class FakeChannel implements TransportChannel {
  @override
  final String name;

  @override
  final ChannelHealth health;

  /// Called once per [send] invocation with the 0-based call index for that
  /// channel; lets a test script different outcomes per attempt.
  final SendResult Function(int callIndex) _sendFn;
  final bool Function() _probeFn;

  int sendCalls = 0;
  int probeCalls = 0;
  bool disposed = false;

  FakeChannel(
    this.name,
    this.health, {
    SendResult Function(int callIndex)? send,
    bool Function()? probe,
  }) : _sendFn = send ?? ((_) => const SendResult(SendStatus.ok, rttMs: 10)),
       _probeFn = probe ?? (() => true);

  @override
  Future<bool> probe() async {
    probeCalls++;
    return _probeFn();
  }

  @override
  Future<SendResult> send(List<int> payload) async {
    final result = _sendFn(sendCalls);
    sendCalls++;
    return result;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

ChannelHealth _health({
  double availability = 1.0,
  required double reliabilityPrior,
  required double bandwidth,
  bool pathDegraded = false,
  int rttMs = 50,
}) => ChannelHealth(
  availability: availability,
  reliabilityPrior: reliabilityPrior,
  bandwidth: bandwidth,
  pathDegraded: pathDegraded,
  rttMs: rttMs,
);

void main() {
  group('PathSelector ranking', () {
    test('sendChunk attempts the highest-scored channel first', () async {
      final weak = FakeChannel(
        'weak',
        _health(reliabilityPrior: 0.2, bandwidth: 0.2, rttMs: 900),
      );
      final strong = FakeChannel(
        'strong',
        _health(reliabilityPrior: 0.95, bandwidth: 0.95, rttMs: 20),
      );
      // List order deliberately puts the weaker channel first so a pass
      // only happens if the selector actually ranks by score, not by
      // input order.
      final selector = PathSelector([
        weak,
        strong,
      ], config: const RouterConfig(maxFailover: 1, fanout: 1));
      addTearDown(selector.dispose);

      final ok = await selector.sendChunk([1, 2, 3]);

      expect(ok, isTrue);
      expect(strong.sendCalls, 1);
      expect(weak.sendCalls, 0);
    });

    test('failover proceeds to the next-ranked channel on failure', () async {
      final best = FakeChannel(
        'best',
        _health(reliabilityPrior: 0.9, bandwidth: 0.9, rttMs: 30),
        send: (_) => const SendResult(SendStatus.transient),
      );
      final second = FakeChannel(
        'second',
        _health(reliabilityPrior: 0.5, bandwidth: 0.5, rttMs: 200),
        send: (_) => const SendResult(SendStatus.ok, rttMs: 40),
      );
      final selector = PathSelector([
        second,
        best,
      ], config: const RouterConfig(maxFailover: 2, fanout: 1));
      addTearDown(selector.dispose);

      final ok = await selector.sendChunk([1]);

      expect(ok, isTrue);
      expect(best.sendCalls, 1);
      expect(second.sendCalls, 1);
    });
  });

  group('PathSelector circuit-breaker exclusion', () {
    test('a channel whose breaker has tripped is excluded from ranking, even '
        'though its health score is still positive', () async {
      final flaky = FakeChannel(
        'flaky',
        _health(reliabilityPrior: 0.9, bandwidth: 0.9, rttMs: 50),
        // `transient`, not `unavailable`: pathDegraded stays false, so
        // exclusion on the 4th call is provably the breaker, not the
        // score>0 filter in sendChunk.
        send: (_) => const SendResult(SendStatus.transient),
      );
      final selector = PathSelector(
        [flaky],
        config: const RouterConfig(maxFailover: 1, fanout: 1),
        breakerConfig: const CircuitBreakerConfig(failureThreshold: 3),
      );
      addTearDown(selector.dispose);

      for (var i = 0; i < 3; i++) {
        final ok = await selector.sendChunk([1]);
        expect(ok, isFalse, reason: 'attempt $i should fail');
      }
      expect(flaky.sendCalls, 3);
      expect(flaky.health.score(), greaterThan(0.0));

      // Breaker should now be open (3 consecutive failures); the 4th call
      // must not reach the channel at all.
      final ok = await selector.sendChunk([1]);
      expect(ok, isFalse);
      expect(
        flaky.sendCalls,
        3,
        reason: 'breaker-open channel must not be attempted again',
      );
    });
  });

  group('PathSelector failover budget (fixed: fanout can no longer '
      'overshoot maxFailover)', () {
    test('regression: maxFailover=3 with fanout=2 across 4 channels attempts '
        'exactly 3 times, not 4', () async {
      final channels = List.generate(
        4,
        (i) => FakeChannel(
          'c$i',
          _health(reliabilityPrior: 0.8, bandwidth: 0.8, rttMs: 50 + i),
          send: (_) => const SendResult(SendStatus.transient),
        ),
      );
      final selector = PathSelector(
        channels,
        config: const RouterConfig(maxFailover: 3, fanout: 2),
        breakerConfig: const CircuitBreakerConfig(failureThreshold: 1000),
      );
      addTearDown(selector.dispose);

      final ok = await selector.sendChunk([1]);

      expect(ok, isFalse);
      final totalAttempts = channels.fold<int>(
        0,
        (sum, c) => sum + c.sendCalls,
      );
      expect(totalAttempts, 3);
    });

    test('property: total attempts per sendChunk call never exceeds '
        'maxFailover (seeded Random(7), 500 iterations)', () async {
      final rng = Random(7);
      for (var iter = 0; iter < 500; iter++) {
        final channelCount = 1 + rng.nextInt(8); // 1..8
        final maxFailover = 1 + rng.nextInt(6); // 1..6
        final fanout = 1 + rng.nextInt(4); // 1..4

        final channels = List.generate(
          channelCount,
          (i) => FakeChannel(
            'c$i',
            _health(
              reliabilityPrior: 0.3 + rng.nextDouble() * 0.6,
              bandwidth: 0.3 + rng.nextDouble() * 0.6,
              rttMs: rng.nextInt(500),
            ),
            // Always fails so the loop always runs to its budget/length
            // limit rather than short-circuiting on first success.
            send: (_) => const SendResult(SendStatus.transient),
          ),
        );
        final selector = PathSelector(
          channels,
          config: RouterConfig(maxFailover: maxFailover, fanout: fanout),
          // High threshold: a single sendChunk call ranks channels once up
          // front, so breaker state changes mid-call must not affect this
          // call's attempt count; keep it out of the way regardless.
          breakerConfig: const CircuitBreakerConfig(failureThreshold: 1000),
        );

        final ok = await selector.sendChunk([1]);
        expect(ok, isFalse);

        final totalAttempts = channels.fold<int>(
          0,
          (sum, c) => sum + c.sendCalls,
        );
        expect(
          totalAttempts,
          lessThanOrEqualTo(maxFailover),
          reason:
              'iter $iter: channelCount=$channelCount '
              'maxFailover=$maxFailover fanout=$fanout '
              'totalAttempts=$totalAttempts',
        );
        expect(
          totalAttempts,
          min(channelCount, maxFailover),
          reason:
              'iter $iter: expected the full budget (bounded by channel '
              'count) to be spent since every channel always fails',
        );

        await selector.dispose();
      }
    });
  });

  group('PathSelector.refresh()', () {
    test('a successful probe clears pathDegraded and lifts availability '
        'halfway toward 1.0', () async {
      final ch = FakeChannel(
        'a',
        _health(
          availability: 0.4,
          reliabilityPrior: 0.8,
          bandwidth: 0.8,
          pathDegraded: true,
        ),
        probe: () => true,
      );
      final selector = PathSelector([ch]);
      addTearDown(selector.dispose);

      await selector.refresh();

      expect(ch.health.pathDegraded, isFalse);
      expect(ch.health.availability, closeTo(0.7, 1e-9)); // 0.4+0.5*(1-0.4)
    });

    test('a failed probe halves availability', () async {
      final ch = FakeChannel(
        'a',
        _health(availability: 0.8, reliabilityPrior: 0.8, bandwidth: 0.8),
        probe: () => false,
      );
      final selector = PathSelector([ch]);
      addTearDown(selector.dispose);

      await selector.refresh();

      expect(ch.health.availability, closeTo(0.4, 1e-9));
    });

    test(
      'a throwing probe also halves availability without propagating',
      () async {
        final ch = FakeChannel(
          'a',
          _health(availability: 0.6, reliabilityPrior: 0.8, bandwidth: 0.8),
          probe: () => throw StateError('probe failed'),
        );
        final selector = PathSelector([ch]);
        addTearDown(selector.dispose);

        await expectLater(selector.refresh(), completes);
        expect(ch.health.availability, closeTo(0.3, 1e-9));
      },
    );
  });

  group('NetworkConditionPolicy.redundancy()', () {
    test('stable recommends maxFailover=2, fanout=1', () {
      const r = NetworkConditionPolicy(NetworkConditionProfile.stable);
      expect(r.redundancy(), (maxFailover: 2, fanout: 1));
    });

    test('congested recommends maxFailover=3, fanout=1', () {
      const r = NetworkConditionPolicy(NetworkConditionProfile.congested);
      expect(r.redundancy(), (maxFailover: 3, fanout: 1));
    });

    test('degraded recommends maxFailover=4, fanout=2', () {
      const r = NetworkConditionPolicy(NetworkConditionProfile.degraded);
      expect(r.redundancy(), (maxFailover: 4, fanout: 2));
    });

    test('isolated recommends maxFailover=6, fanout=3', () {
      const r = NetworkConditionPolicy(NetworkConditionProfile.isolated);
      expect(r.redundancy(), (maxFailover: 6, fanout: 3));
    });

    test('toRouterConfig() carries the same maxFailover/fanout', () {
      const policy = NetworkConditionPolicy(NetworkConditionProfile.degraded);
      final config = policy.toRouterConfig();
      expect(config.maxFailover, 4);
      expect(config.fanout, 2);
    });
  });

  group('PathSelector.applyPolicy()', () {
    test('replaces config with the policy-derived RouterConfig', () async {
      final ch = FakeChannel(
        'a',
        _health(reliabilityPrior: 0.8, bandwidth: 0.8),
      );
      final selector = PathSelector([
        ch,
      ], config: const RouterConfig(maxFailover: 1, fanout: 1));
      addTearDown(selector.dispose);

      selector.applyPolicy(
        const NetworkConditionPolicy(NetworkConditionProfile.isolated),
      );

      expect(selector.config.maxFailover, 6);
      expect(selector.config.fanout, 3);
    });
  });

  group('PathSelector.online', () {
    test('true when at least one channel is usable', () {
      final ch = FakeChannel(
        'a',
        _health(reliabilityPrior: 0.8, bandwidth: 0.8),
      );
      final selector = PathSelector([ch]);
      addTearDown(selector.dispose);

      expect(selector.online, isTrue);
    });

    test('false when the only channel is pathDegraded (score is 0)', () {
      final ch = FakeChannel(
        'a',
        _health(reliabilityPrior: 0.8, bandwidth: 0.8, pathDegraded: true),
      );
      final selector = PathSelector([ch]);
      addTearDown(selector.dispose);

      expect(selector.online, isFalse);
    });

    test('false once the only channel breaker has tripped', () async {
      final ch = FakeChannel(
        'a',
        _health(reliabilityPrior: 0.8, bandwidth: 0.8),
        send: (_) => const SendResult(SendStatus.transient),
      );
      final selector = PathSelector(
        [ch],
        config: const RouterConfig(maxFailover: 1, fanout: 1),
        breakerConfig: const CircuitBreakerConfig(failureThreshold: 1),
      );
      addTearDown(selector.dispose);

      expect(selector.online, isTrue);
      await selector.sendChunk([1]); // one failure trips the breaker
      expect(selector.online, isFalse);
    });
  });

  group('PathSelector.telemetryStream', () {
    test('emits a send event per attempt and an exhausted event on total '
        'failure', () async {
      final ch = FakeChannel(
        'a',
        _health(reliabilityPrior: 0.8, bandwidth: 0.8),
        send: (_) => const SendResult(SendStatus.transient),
      );
      final selector = PathSelector([
        ch,
      ], config: const RouterConfig(maxFailover: 1, fanout: 1));
      addTearDown(selector.dispose);

      final events = <RouterTelemetryEvent>[];
      final sub = selector.telemetryStream.listen(events.add);

      await selector.sendChunk([1]);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(
        events.map((e) => e['kind']),
        containsAllInOrder(['send', 'exhausted']),
      );
    });

    test(
      'emits an exhausted event immediately when no channels are ranked',
      () async {
        final ch = FakeChannel(
          'a',
          _health(reliabilityPrior: 0.8, bandwidth: 0.8, pathDegraded: true),
        );
        final selector = PathSelector([ch]);
        addTearDown(selector.dispose);

        final events = <RouterTelemetryEvent>[];
        final sub = selector.telemetryStream.listen(events.add);

        final ok = await selector.sendChunk([1]);
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(ok, isFalse);
        expect(events, hasLength(1));
        expect(events.single['kind'], 'exhausted');
      },
    );
  });

  group('PathSelector.sendChunk() exception handling', () {
    test('a channel whose send() throws is treated as a transient failure, '
        'not propagated', () async {
      final throwing = FakeChannel(
        'throwing',
        _health(reliabilityPrior: 0.9, bandwidth: 0.9, rttMs: 20),
      );
      // Override send to throw synchronously via a wrapper channel, since
      // FakeChannel's _sendFn contract returns a SendResult; a bespoke fake
      // is used here to exercise the try/catch in sendChunk.
      final selector = PathSelector([
        _ThrowingChannel(throwing.name, throwing.health),
      ], config: const RouterConfig(maxFailover: 1, fanout: 1));
      addTearDown(selector.dispose);

      final ok = await selector.sendChunk([1]);

      expect(ok, isFalse);
      expect(throwing.health.pathDegraded, isFalse); // transient, not fatal
    });
  });
}

/// A [TransportChannel] whose [send] always throws synchronously (inside the
/// async function, so as an asynchronous error) — exercises the
/// `try { await ch.send(...) } catch (e) { ... }` branch in
/// `PathSelector.sendChunk`.
class _ThrowingChannel implements TransportChannel {
  @override
  final String name;
  @override
  final ChannelHealth health;

  _ThrowingChannel(this.name, this.health);

  @override
  Future<bool> probe() async => true;

  @override
  Future<SendResult> send(List<int> payload) async {
    throw StateError('send failed');
  }

  @override
  Future<void> dispose() async {}
}
