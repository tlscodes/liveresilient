import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

class _StubChannel implements TransportChannel {
  _StubChannel(this.name, this.attempts, {this.up = true});

  @override
  final String name;
  final bool up;

  /// Shared log of attempt order across the whole chain.
  final List<String> attempts;

  @override
  final ChannelHealth health =
      ChannelHealth(reliabilityPrior: 0.9, bandwidth: 0.9);

  @override
  Future<bool> probe() async => up;

  @override
  Future<SendResult> send(List<int> payload) async {
    attempts.add(name);
    return up
        ? const SendResult(SendStatus.ok)
        : const SendResult(SendStatus.unavailable);
  }

  @override
  Future<void> dispose() async {}
}

AdaptiveJitter _jitter(TrafficShapingPolicy policy, {int seed = 21}) =>
    AdaptiveJitter(
      policy: policy,
      random: Random(seed),
      allowInsecureRandom: true,
    );

void main() {
  group('Poisson jitter', () {
    const policy = TrafficShapingPolicy(
      jitterDistribution: JitterDistribution.poisson,
      maxJitter: Duration(microseconds: 2000),
      // A zero-length burst window keeps the burst multiplier out of the
      // math: thousands of draws in a tight loop would otherwise all land
      // inside a 20 ms window and raise the ceiling mid-sample.
      burstWindow: Duration.zero,
    );

    test('stays inside the ceiling despite an unbounded distribution', () {
      final j = _jitter(policy);
      for (var i = 0; i < 2000; i++) {
        expect(j.nextDelay().inMicroseconds, inInclusiveRange(0, 2000));
      }
    });

    test('is memoryless in shape: many short gaps, a thin long tail', () {
      final j = _jitter(policy);
      final draws = [for (var i = 0; i < 4000; i++) j.nextDelay().inMicroseconds];
      final belowMean = draws.where((d) => d < 1000).length / draws.length;
      // An exponential puts ~63% of its mass below its mean; a uniform
      // draw would put exactly 50% below the midpoint. That gap is the
      // observable difference between the two policies.
      expect(belowMean, greaterThan(0.55));
      expect(draws.where((d) => d > 1800).length, greaterThan(0),
          reason: 'the tail must still be reachable');
    });

    test('differs measurably from the uniform policy', () {
      const uniform = TrafficShapingPolicy(
        maxJitter: Duration(microseconds: 2000),
        burstThreshold: 1000,
      );
      final poissonDraws = [
        for (var i = 0, j = _jitter(policy); i < 3000; i++)
          j.nextDelay().inMicroseconds,
      ];
      final uniformDraws = [
        for (var i = 0, j = _jitter(uniform); i < 3000; i++)
          j.nextDelay().inMicroseconds,
      ];
      double median(List<int> xs) {
        final sorted = [...xs]..sort();
        return sorted[sorted.length ~/ 2].toDouble();
      }

      expect(median(poissonDraws), lessThan(median(uniformDraws) - 100));
    });

    test('the uniform default is unchanged', () {
      expect(TrafficShapingPolicy.voice.jitterDistribution,
          JitterDistribution.uniform);
    });
  });

  group('ResilientFallbackTransportChain with the edge bridge', () {
    test('tries the edge bridge before any relay when direct UDP is down',
        () async {
      final attempts = <String>[];
      final selector = ResilientFallbackTransportChain.build(
        primaryUdp: _StubChannel('udp', attempts, up: false),
        edgeBridge: _StubChannel('edge', attempts),
        webSocketRelay: _StubChannel('ws', attempts),
        httpLongPoll: _StubChannel('poll', attempts),
        localMesh: _StubChannel('mesh', attempts),
      );
      expect(await selector.sendChunk(Uint8List.fromList([1, 2, 3])), isTrue);
      expect(attempts, ['udp', 'edge'],
          reason: 'the edge carries it before the chain reaches a relay');
    });

    test('falls through to local mesh when every egress lane is down',
        () async {
      final attempts = <String>[];
      final selector = ResilientFallbackTransportChain.build(
        primaryUdp: _StubChannel('udp', attempts, up: false),
        edgeBridge: _StubChannel('edge', attempts, up: false),
        webSocketRelay: _StubChannel('ws', attempts, up: false),
        localMesh: _StubChannel('mesh', attempts),
        config: const RouterConfig(maxFailover: 4),
      );
      expect(await selector.sendChunk(Uint8List.fromList([1, 2, 3])), isTrue);
      expect(attempts.last, 'mesh',
          reason: 'with no egress at all, the radio lane is the only path');
    });

    test('an edge-only chain is legal — the edge is a complete path',
        () async {
      final attempts = <String>[];
      final selector = ResilientFallbackTransportChain.build(
        edgeBridge: _StubChannel('edge', attempts),
      );
      expect(await selector.sendChunk(Uint8List.fromList([1])), isTrue);
      expect(attempts, ['edge']);
    });
  });
}
