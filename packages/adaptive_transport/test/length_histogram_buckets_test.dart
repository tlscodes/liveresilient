import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

/// Ticket 1 gate 1c — the bucket ladder is derived from a sampled histogram,
/// not compiled in.
///
/// The defect: `distribution: "bucketed"` was selectable from configuration
/// while its ladder stayed the guess hardcoded in TrafficShapingPolicy. A
/// target distribution nothing measured cannot be checked against a
/// measurement, so a shaped stream could sit far from its intended shape and
/// nothing would say so.
void main() {
  group('TrafficShapingPolicy.fromLengthHistogram', () {
    test('1c  a uniform sample yields evenly spread rungs', () {
      final policy = TrafficShapingPolicy.fromLengthHistogram(
        {100: 10, 200: 10, 300: 10, 400: 10, 500: 10, 600: 10},
        buckets: 6,
      );
      expect(policy.lengthBuckets, [100, 200, 300, 400, 500, 600]);
      expect(policy.distribution, LengthDistribution.bucketed);
    });

    test('1c  rungs follow the observed mass, not the observed variety', () {
      // Almost everything lands at 1200; the ladder must reflect that rather
      // than give the two rare lengths equal footing.
      final policy = TrafficShapingPolicy.fromLengthHistogram(
        {60: 1, 1200: 998, 1350: 1},
        buckets: 4,
      );
      expect(policy.lengthBuckets.first, 1200);
      expect(
        policy.lengthBuckets.last,
        1350,
        reason: 'the largest observation must be representable or the longest '
            'frames have nowhere to pad to',
      );
    });

    test('1c  duplicate quantile edges collapse instead of repeating', () {
      final policy = TrafficShapingPolicy.fromLengthHistogram(
        {512: 1000},
        buckets: 8,
      );
      expect(policy.lengthBuckets, [512]);
    });

    test('1c  the ladder always ascends strictly', () {
      final policy = TrafficShapingPolicy.fromLengthHistogram(
        {64: 3, 128: 40, 256: 200, 512: 90, 1024: 5, 1350: 2},
        buckets: 5,
      );
      for (var i = 1; i < policy.lengthBuckets.length; i++) {
        expect(
          policy.lengthBuckets[i],
          greaterThan(policy.lengthBuckets[i - 1]),
        );
      }
    });

    test('1c  a sample that proves nothing is refused, not silently accepted', () {
      expect(
        () => TrafficShapingPolicy.fromLengthHistogram(const {}),
        throwsArgumentError,
      );
      expect(
        () => TrafficShapingPolicy.fromLengthHistogram(const {1200: 0}),
        throwsArgumentError,
        reason: 'zero observations is the same guess wearing a '
            "measurement's name",
      );
      expect(
        () => TrafficShapingPolicy.fromLengthHistogram(const {0: 5}),
        throwsArgumentError,
      );
      expect(
        () => TrafficShapingPolicy.fromLengthHistogram(const {100: -1}),
        throwsArgumentError,
      );
      expect(
        () => TrafficShapingPolicy.fromLengthHistogram(
          const {100: 5},
          buckets: 0,
        ),
        throwsArgumentError,
      );
    });

    test('1c  the derived ladder actually drives padding', () {
      final policy = TrafficShapingPolicy.fromLengthHistogram(
        {200: 10, 400: 10},
        buckets: 2,
        maxPadding: 512,
      );
      final shaper = TrafficShaper(policy: policy, allowInsecureRandom: false);
      // A 150-byte payload plus the 2-byte trailer must climb to the first
      // rung at or above it.
      final shaped = shaper.shape(List<int>.filled(150, 7));
      expect(shaped.length, 200);
    });
  });

  group('config parsing (gate 1c)', () {
    ProbeDefenseConfig parse(Map<String, Object?> shaping) =>
        ProbeDefenseConfig.fromJson({'shaping': shaping});

    test('1c  a histogram in configuration reaches the ladder', () {
      final config = parse({
        'distribution': 'bucketed',
        'lengthHistogram': {'300': 10, '600': 10},
      });
      expect(config.shaping.lengthBuckets, [300, 600]);
    });

    test('1c  an explicit ascending ladder is accepted as given', () {
      final config = parse({
        'distribution': 'bucketed',
        'lengthBuckets': [128, 256, 1024],
      });
      expect(config.shaping.lengthBuckets, [128, 256, 1024]);
    });

    test('1c  two ladders for one distribution is refused, not merged', () {
      expect(
        () => parse({
          'lengthHistogram': {'300': 1},
          'lengthBuckets': [128, 256],
        }),
        throwsA(isA<ProbeDefenseConfigError>()),
      );
    });

    test('1c  a non-ascending ladder is refused', () {
      expect(
        () => parse({
          'lengthBuckets': [256, 128],
        }),
        throwsA(isA<ProbeDefenseConfigError>()),
      );
      expect(
        () => parse({
          'lengthBuckets': [128, 128],
        }),
        throwsA(isA<ProbeDefenseConfigError>()),
      );
      expect(
        () => parse({
          'lengthBuckets': <Object?>[],
        }),
        throwsA(isA<ProbeDefenseConfigError>()),
      );
    });

    test('1c  a bad sample fails when the config is read, naming the field', () {
      expect(
        () => parse({
          'lengthHistogram': {'1200': 0},
        }),
        throwsA(
          isA<ProbeDefenseConfigError>().having(
            (e) => e.message,
            'message',
            contains('lengthHistogram'),
          ),
        ),
      );
    });

    test('1c  omitting both keeps the previous default, so nothing changes', () {
      final config = parse({'distribution': 'bucketed'});
      expect(
        config.shaping.lengthBuckets,
        TrafficShapingPolicy.voice.lengthBuckets,
      );
    });
  });
}
