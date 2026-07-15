import 'dart:math';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

/// Returns a deep-ish copy of [h] (mutable fields copied by value) so two
/// branches can be driven from an identical starting point without one
/// mutation leaking into the other.
ChannelHealth _clone(ChannelHealth h) => ChannelHealth(
  availability: h.availability,
  reliabilityPrior: h.reliabilityPrior,
  bandwidth: h.bandwidth,
  pathDegraded: h.pathDegraded,
  rttMs: h.rttMs,
  jitterMs: h.jitterMs,
);

/// Builds a random-but-valid starting [ChannelHealth] from a seeded [rng].
ChannelHealth _randomHealth(Random rng) => ChannelHealth(
  availability: rng.nextDouble(),
  reliabilityPrior: rng.nextDouble(),
  bandwidth: rng.nextDouble(),
  pathDegraded: false,
  // Keep rttMs non-negative and bounded; a negative RTT is not a real-world
  // input and would break the rttFactor monotonicity being tested.
  rttMs: rng.nextInt(3000),
  jitterMs: rng.nextInt(200),
);

void main() {
  group('SendResult', () {
    test('ok is an alias for delivered', () {
      const delivered = SendResult(SendStatus.duplicate);
      const notDelivered = SendResult(SendStatus.unavailable);
      expect(delivered.ok, delivered.delivered);
      expect(delivered.ok, isTrue);
      expect(notDelivered.ok, isFalse);
    });

    test('toString() includes status and rtt when present', () {
      const withRtt = SendResult(SendStatus.ok, rttMs: 42);
      const withoutRtt = SendResult(SendStatus.transient);
      expect(withRtt.toString(), 'SendResult(ok, rtt: 42ms)');
      expect(withoutRtt.toString(), 'SendResult(transient)');
    });
  });

  group('ChannelHealth constructor validation', () {
    test(
      'accepts boundary values 0.0 and 1.0 for reliabilityPrior/bandwidth',
      () {
        expect(
          () => ChannelHealth(reliabilityPrior: 0.0, bandwidth: 0.0),
          returnsNormally,
        );
        expect(
          () => ChannelHealth(reliabilityPrior: 1.0, bandwidth: 1.0),
          returnsNormally,
        );
      },
    );

    test('rejects reliabilityPrior below 0 or above 1', () {
      expect(
        () => ChannelHealth(reliabilityPrior: -0.01, bandwidth: 0.5),
        throwsRangeError,
      );
      expect(
        () => ChannelHealth(reliabilityPrior: 1.01, bandwidth: 0.5),
        throwsRangeError,
      );
    });

    test('rejects bandwidth below 0 or above 1', () {
      expect(
        () => ChannelHealth(reliabilityPrior: 0.5, bandwidth: -0.01),
        throwsRangeError,
      );
      expect(
        () => ChannelHealth(reliabilityPrior: 0.5, bandwidth: 1.01),
        throwsRangeError,
      );
    });

    test('defaults availability=1.0, pathDegraded=false', () {
      final h = ChannelHealth(reliabilityPrior: 0.8, bandwidth: 0.8);
      expect(h.availability, 1.0);
      expect(h.pathDegraded, isFalse);
    });
  });

  group('ChannelHealth.score() property tests (seeded Random(7))', () {
    test('score() always stays within the documented [0, 1] range', () {
      final rng = Random(7);
      for (var i = 0; i < 500; i++) {
        final h = _randomHealth(rng);
        final s = h.score();
        expect(
          s,
          inInclusiveRange(0.0, 1.0),
          reason: 'iteration $i: health=$h score=$s',
        );
      }
    });

    test('pathDegraded or non-positive availability forces score() to 0', () {
      final rng = Random(7);
      for (var i = 0; i < 500; i++) {
        final h = _randomHealth(rng)..pathDegraded = true;
        expect(h.score(), 0.0, reason: 'iteration $i');
      }
    });

    test('a worse RTT sample never yields a higher score than a better RTT '
        'sample, all else equal', () {
      final rng = Random(7);
      for (var i = 0; i < 500; i++) {
        final base = _randomHealth(rng);
        final betterRtt = rng.nextInt(500); // low RTT sample
        final worseRtt = betterRtt + 1 + rng.nextInt(3000); // strictly worse

        final good = _clone(base);
        final bad = _clone(base);

        // Same delivery outcome (both delivered) isolates the RTT effect.
        good.observe(SendResult(SendStatus.ok, rttMs: betterRtt));
        bad.observe(SendResult(SendStatus.ok, rttMs: worseRtt));

        expect(
          bad.score(),
          lessThanOrEqualTo(good.score()),
          reason:
              'iteration $i: base=$base betterRtt=$betterRtt '
              'worseRtt=$worseRtt good=${good.score()} bad=${bad.score()}',
        );
      }
    });

    test('a failed delivery (packet loss) never yields a higher score than a '
        'successful delivery, all else equal', () {
      final rng = Random(7);
      for (var i = 0; i < 500; i++) {
        final base = _randomHealth(rng);
        final sampleRtt = rng.nextInt(2000);

        final good = _clone(base);
        final bad = _clone(base);

        // Same RTT sample isolates the delivery/availability effect.
        // `transient` (not `unavailable`) so pathDegraded is untouched and
        // the comparison stays about availability, not the degraded gate.
        good.observe(SendResult(SendStatus.ok, rttMs: sampleRtt));
        bad.observe(SendResult(SendStatus.transient, rttMs: sampleRtt));

        expect(
          bad.score(),
          lessThanOrEqualTo(good.score()),
          reason: 'iteration $i: base=$base sampleRtt=$sampleRtt',
        );
      }
    });

    test('an unavailable delivery always drives score() to 0 (pathDegraded '
        'gate), regardless of prior health', () {
      final rng = Random(7);
      for (var i = 0; i < 500; i++) {
        final h = _randomHealth(rng);
        h.observe(SendResult(SendStatus.unavailable, rttMs: 50));
        expect(h.score(), 0.0, reason: 'iteration $i: health after=$h');
      }
    });
  });

  group('ChannelHealth.observe() EWMA convergence', () {
    test('repeated observation of a constant input converges rttMs and '
        'availability toward that constant', () {
      final rng = Random(7);
      for (var i = 0; i < 50; i++) {
        final h = _randomHealth(rng);
        const targetRtt = 200;
        for (var n = 0; n < 200; n++) {
          h.observe(const SendResult(SendStatus.ok, rttMs: targetRtt));
        }
        expect(
          h.rttMs,
          inInclusiveRange(targetRtt - 1, targetRtt + 1),
          reason: 'iteration $i did not converge: rttMs=${h.rttMs}',
        );
        expect(
          h.availability,
          closeTo(1.0, 1e-6),
          reason:
              'iteration $i did not converge: availability=${h.availability}',
        );
        expect(h.pathDegraded, isFalse);
      }
    });

    test('repeated failure observation converges availability toward 0 and '
        'sets pathDegraded', () {
      final rng = Random(7);
      for (var i = 0; i < 50; i++) {
        final h = _randomHealth(rng);
        for (var n = 0; n < 200; n++) {
          h.observe(const SendResult(SendStatus.unavailable, rttMs: 50));
        }
        expect(
          h.availability,
          closeTo(0.0, 1e-6),
          reason:
              'iteration $i did not converge: availability=${h.availability}',
        );
        expect(h.pathDegraded, isTrue);
      }
    });

    test('alpha outside (0, 1] throws RangeError', () {
      final h = ChannelHealth(reliabilityPrior: 0.5, bandwidth: 0.5);
      expect(
        () => h.observe(const SendResult(SendStatus.ok), alpha: 0.0),
        throwsRangeError,
      );
      expect(
        () => h.observe(const SendResult(SendStatus.ok), alpha: 1.01),
        throwsRangeError,
      );
    });
  });
}
