import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:clock/clock.dart' as pkg_clock;
import 'package:test/test.dart';

TrafficShaper _shaper(TrafficShapingPolicy policy, {int seed = 13}) =>
    TrafficShaper(
      policy: policy,
      random: Random(seed),
      allowInsecureRandom: true,
    );

List<int> _payload(int length) =>
    List<int>.generate(length, (i) => (i * 31) & 0xFF);

void main() {
  group('TrafficShaper padding', () {
    test('round-trips the payload under every distribution', () {
      for (final distribution in LengthDistribution.values) {
        final shaper = _shaper(
          TrafficShapingPolicy(distribution: distribution),
        );
        for (final size in [0, 1, 40, 160, 1300]) {
          final payload = _payload(size);
          expect(TrafficShaper.unshape(shaper.shape(payload)), payload,
              reason: '$distribution at $size bytes');
        }
      }
    });

    test('never pads beyond the policy ceiling', () {
      for (final distribution in LengthDistribution.values) {
        final shaper = _shaper(
          TrafficShapingPolicy(distribution: distribution, maxPadding: 64),
        );
        for (var i = 0; i < 400; i++) {
          final padding = shaper.paddingFor(50);
          expect(padding, inInclusiveRange(0, 64), reason: '$distribution');
        }
      }
    });

    test('uniform padding spreads across the whole allowed range', () {
      final shaper = _shaper(
        const TrafficShapingPolicy(
          distribution: LengthDistribution.uniform,
          maxPadding: 96,
        ),
      );
      final draws = {for (var i = 0; i < 500; i++) shaper.paddingFor(100)};
      expect(draws.length, greaterThan(60),
          reason: 'a uniform draw must not collapse onto a few values');
      expect(draws.reduce(max), greaterThan(80));
      expect(draws.reduce(min), lessThan(16));
    });

    test('gaussian padding concentrates near its mean', () {
      final shaper = _shaper(
        const TrafficShapingPolicy(
          distribution: LengthDistribution.gaussian,
          gaussianMean: 40,
          gaussianStdDev: 8,
          maxPadding: 200,
        ),
      );
      final draws = [for (var i = 0; i < 1000; i++) shaper.paddingFor(100)];
      final mean = draws.reduce((a, b) => a + b) / draws.length;
      expect(mean, closeTo(40, 3));
      final withinTwoSigma =
          draws.where((d) => (d - 40).abs() <= 16).length / draws.length;
      expect(withinTwoSigma, greaterThan(0.9));
    });

    test('bucketed padding snaps lengths onto the ladder', () {
      final shaper = _shaper(
        const TrafficShapingPolicy(
          distribution: LengthDistribution.bucketed,
          maxPadding: 2048,
          lengthBuckets: [64, 128, 256, 512],
        ),
      );
      final lengths = <int>{};
      for (final size in [10, 40, 70, 130, 200, 300, 480]) {
        lengths.add(shaper.shape(_payload(size)).length);
      }
      expect(lengths, everyElement(isIn(const [64, 128, 256, 512])));
    });

    test('an oversized frame is not stretched past the ladder', () {
      final shaper = _shaper(
        const TrafficShapingPolicy(
          distribution: LengthDistribution.bucketed,
          lengthBuckets: [64, 128],
        ),
      );
      expect(shaper.paddingFor(400), 0);
    });

    test('the disabled policy costs exactly the two trailer bytes', () {
      final shaper = _shaper(TrafficShapingPolicy.disabled);
      expect(shaper.shape(_payload(100)).length, 102);
    });

    test('shaping decouples wire length from payload length', () {
      final shaper = _shaper(TrafficShapingPolicy.voice);
      // A codec emitting a near-constant frame size is the signature being
      // erased: same input length, many output lengths.
      final lengths = {
        for (var i = 0; i < 200; i++) shaper.shape(_payload(80)).length,
      };
      expect(lengths.length, greaterThan(20));
    });

    test('rejects a frame whose trailer overruns its own length', () {
      expect(
        () => TrafficShaper.unshape(Uint8List.fromList([1, 2, 0xFF, 0xFF])),
        throwsFormatException,
      );
      expect(
        () => TrafficShaper.unshape(Uint8List.fromList([1])),
        throwsFormatException,
      );
    });

    test('produces frames MicroDatagramLane can strip, and vice versa', () {
      final payload = Uint8List.fromList(_payload(120));
      final shaped = _shaper(TrafficShapingPolicy.voice).shape(payload);
      expect(MicroDatagramLane().decodeAndStripPadding(shaped), payload);

      final lane = MicroDatagramLane().encodeWithPadding(payload);
      expect(TrafficShaper.unshape(lane), payload);
    });

    test('refuses an injected RNG unless the test opts in', () {
      expect(
        () => TrafficShaper(random: Random(1)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('AdaptiveJitter', () {
    AdaptiveJitter jitter(TrafficShapingPolicy policy) => AdaptiveJitter(
          policy: policy,
          random: Random(7),
          allowInsecureRandom: true,
        );

    test('stays inside the policy ceiling when not bursting', () {
      const policy = TrafficShapingPolicy(
        maxJitter: Duration(microseconds: 1500),
        burstThreshold: 1000, // effectively never bursting
      );
      final j = jitter(policy);
      for (var i = 0; i < 200; i++) {
        expect(j.nextDelay().inMicroseconds, inInclusiveRange(0, 1500));
      }
    });

    test('raises the ceiling once a burst is detected', () {
      const policy = TrafficShapingPolicy(
        maxJitter: Duration(microseconds: 1000),
        burstThreshold: 3,
        burstJitterMultiplier: 3,
        burstWindow: Duration(milliseconds: 50),
      );
      pkg_clock.withClock(pkg_clock.Clock.fixed(DateTime.utc(2026, 7, 27)), () {
        final j = jitter(policy);
        expect(j.isBursting, isFalse);
        for (var i = 0; i < 3; i++) {
          expect(j.nextDelay().inMicroseconds, lessThanOrEqualTo(1000));
        }
        expect(j.isBursting, isTrue);
        final burstDelays = [
          for (var i = 0; i < 50; i++) j.nextDelay().inMicroseconds,
        ];
        expect(burstDelays.reduce(max), greaterThan(1000));
        expect(burstDelays.reduce(max), lessThanOrEqualTo(3000));
      });
    });

    test('forgets sends that fall out of the burst window', () {
      const policy = TrafficShapingPolicy(
        burstThreshold: 2,
        burstWindow: Duration(milliseconds: 20),
      );
      final start = DateTime.utc(2026, 7, 27);
      late AdaptiveJitter j;
      pkg_clock.withClock(pkg_clock.Clock.fixed(start), () {
        j = jitter(policy);
        j.nextDelay();
        j.nextDelay();
        expect(j.isBursting, isTrue);
      });
      pkg_clock.withClock(
        pkg_clock.Clock.fixed(start.add(const Duration(milliseconds: 100))),
        () {
          expect(j.recentSendCount, 0);
          expect(j.isBursting, isFalse);
        },
      );
    });

    test('the disabled policy adds no delay at all', () async {
      final j = jitter(TrafficShapingPolicy.disabled);
      expect(j.nextDelay(), Duration.zero);
      final stopwatch = Stopwatch()..start();
      await j.pace();
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(5));
    });

    test('refuses an injected RNG unless the test opts in', () {
      expect(
        () => AdaptiveJitter(random: Random(1)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('DomesticEdgeBridgeLane with shaping', () {
    test('sends shaped frames the peer can unshape', () async {
      final sent = <Uint8List>[];
      final lane = DomesticEdgeBridgeLane(
        endpoints: [Uri.parse('https://edge.example/call')],
        connector: (_) async => _CollectingConnection(sent),
        shaper: _shaper(TrafficShapingPolicy.voice),
      );
      addTearDown(lane.dispose);

      final payload = _payload(60);
      final result = await lane.send(payload);
      expect(result.status, SendStatus.ok);

      final framed = sent.single;
      final message = const GrpcMessageFramer().decode(framed);
      expect(message.length, greaterThan(payload.length));
      expect(TrafficShaper.unshape(message), payload);
    });

    test('leaves lengths untouched when no shaper is configured', () async {
      final sent = <Uint8List>[];
      final lane = DomesticEdgeBridgeLane(
        endpoints: [Uri.parse('https://edge.example/call')],
        connector: (_) async => _CollectingConnection(sent),
      );
      addTearDown(lane.dispose);

      final payload = _payload(60);
      await lane.send(payload);
      expect(const GrpcMessageFramer().decode(sent.single), payload);
    });
  });
}

class _CollectingConnection implements EdgeBridgeConnection {
  _CollectingConnection(this.sent);

  final List<Uint8List> sent;

  @override
  Stream<Uint8List> get inbound => const Stream<Uint8List>.empty();

  @override
  void add(Uint8List frame) => sent.add(frame);

  @override
  Future<void> close() async {}
}
