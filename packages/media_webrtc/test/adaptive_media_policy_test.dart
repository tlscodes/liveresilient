import 'package:media_webrtc/media_webrtc.dart';
import 'package:test/test.dart';

RtcStatsSample _sample({
  double packetLossFraction = 0.0,
  int rttMs = 50,
  int jitterMs = 0,
  int incomingBitrateBps = 0,
  int outgoingBitrateBps = 0,
  int availableOutgoingBitrateBps = 0,
  int timestampMs = 0,
}) => RtcStatsSample(
  packetLossFraction: packetLossFraction,
  rttMs: rttMs,
  jitterMs: jitterMs,
  incomingBitrateBps: incomingBitrateBps,
  outgoingBitrateBps: outgoingBitrateBps,
  availableOutgoingBitrateBps: availableOutgoingBitrateBps,
  timestampMs: timestampMs,
);

void main() {
  final config = AdaptiveMediaPolicyConfig();

  group('AdaptiveMediaPolicy severe loss', () {
    test('a single severe-loss sample drops two steps immediately', () {
      final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.high);

      final decision = policy.onSample(
        _sample(packetLossFraction: 0.25, rttMs: 30),
      );

      expect(decision, isNotNull);
      expect(decision!.previous, MediaProfile.high);
      expect(decision.next, MediaProfile.low); // high(0) + 2 = low(2)
      expect(policy.profile, MediaProfile.low);
    });

    test('severe loss clamps at the bottom of the ladder instead of '
        'throwing', () {
      final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.minimal);

      final decision = policy.onSample(
        _sample(packetLossFraction: 0.5, rttMs: 30),
      );

      expect(decision!.next, MediaProfile.audioOnly);
      expect(policy.profile, MediaProfile.audioOnly);
    });

    test('severe loss resets both hysteresis counters', () {
      final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.high);
      // Build up a partial clean streak first.
      policy.onSample(_sample(packetLossFraction: 0.0, rttMs: 30));
      policy.onSample(_sample(packetLossFraction: 0.25, rttMs: 30)); // severe

      // Now a single bad (non-severe) sample must NOT downgrade yet, proving
      // _consecutiveBad was reset to 0 by the severe branch, not left at
      // some stale non-zero value that would trigger early.
      final afterSevere = policy.onSample(
        _sample(packetLossFraction: 0.10, rttMs: 30),
      );
      expect(afterSevere, isNull);
    });
  });

  group('AdaptiveMediaPolicy badSamplesToDowngrade', () {
    test('downgrades one step only after badSamplesToDowngrade consecutive '
        'bad (non-severe) samples', () {
      final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.high);
      expect(config.badSamplesToDowngrade, 2);

      final first = policy.onSample(
        _sample(packetLossFraction: 0.10, rttMs: 30),
      );
      expect(first, isNull, reason: 'first bad sample alone must not act');
      expect(policy.profile, MediaProfile.high);

      final second = policy.onSample(
        _sample(packetLossFraction: 0.10, rttMs: 30),
      );
      expect(second, isNotNull);
      expect(second!.previous, MediaProfile.high);
      expect(second.next, MediaProfile.medium);
      expect(policy.profile, MediaProfile.medium);
    });

    test('a high RTT alone (loss under threshold) also counts as bad', () {
      final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.high);

      policy.onSample(_sample(packetLossFraction: 0.0, rttMs: 700));
      final decision = policy.onSample(
        _sample(packetLossFraction: 0.0, rttMs: 700),
      );

      expect(decision, isNotNull);
      expect(decision!.next, MediaProfile.medium);
    });

    test('a clean sample between two bad samples resets the bad streak', () {
      final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.high);

      policy.onSample(_sample(packetLossFraction: 0.10, rttMs: 30)); // bad #1
      policy.onSample(_sample(packetLossFraction: 0.0, rttMs: 30)); // clean
      final decision = policy.onSample(
        _sample(packetLossFraction: 0.10, rttMs: 30),
      ); // bad #1 again, not #2

      expect(decision, isNull);
      expect(policy.profile, MediaProfile.high);
    });
  });

  group('AdaptiveMediaPolicy cleanSamplesToUpgrade + bandwidth headroom', () {
    test('upgrades one step after cleanSamplesToUpgrade consecutive clean '
        'samples when bandwidth headroom is sufficient', () {
      expect(config.cleanSamplesToUpgrade, 8);
      final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.low);
      // medium.videoMaxBitrateBps = 800000; headroom 1.25 => need >= 1e6.
      const ample = 2000000;

      MediaPolicyDecision? last;
      for (var i = 0; i < config.cleanSamplesToUpgrade; i++) {
        last = policy.onSample(
          _sample(
            packetLossFraction: 0.0,
            rttMs: 30,
            availableOutgoingBitrateBps: ample,
          ),
        );
      }

      expect(last, isNotNull);
      expect(last!.previous, MediaProfile.low);
      expect(last.next, MediaProfile.medium);
      expect(policy.profile, MediaProfile.medium);
    });

    test('fewer than cleanSamplesToUpgrade clean samples never upgrades', () {
      final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.low);
      const ample = 2000000;

      for (var i = 0; i < config.cleanSamplesToUpgrade - 1; i++) {
        final decision = policy.onSample(
          _sample(
            packetLossFraction: 0.0,
            rttMs: 30,
            availableOutgoingBitrateBps: ample,
          ),
        );
        expect(decision, isNull);
      }
      expect(policy.profile, MediaProfile.low);
    });

    test(
      'insufficient bandwidth headroom blocks the upgrade even after enough '
      'clean samples, and the clean streak does not force it later either',
      () {
        final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.low);
        // medium needs >= 800000*1.25 = 1,000,000; this stays well under.
        const insufficient = 500000;

        for (var i = 0; i < config.cleanSamplesToUpgrade * 3; i++) {
          final decision = policy.onSample(
            _sample(
              packetLossFraction: 0.0,
              rttMs: 30,
              availableOutgoingBitrateBps: insufficient,
            ),
          );
          expect(decision, isNull, reason: 'sample $i must not upgrade');
        }
        expect(policy.profile, MediaProfile.low);
      },
    );

    test('no bandwidth estimate reported (0) relies on hysteresis alone and '
        'still upgrades', () {
      final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.low);

      MediaPolicyDecision? last;
      for (var i = 0; i < config.cleanSamplesToUpgrade; i++) {
        last = policy.onSample(
          _sample(
            packetLossFraction: 0.0,
            rttMs: 30,
            availableOutgoingBitrateBps: 0,
          ),
        );
      }

      expect(last, isNotNull);
      expect(last!.next, MediaProfile.medium);
    });

    test('already at MediaProfile.high never upgrades further', () {
      final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.high);

      MediaPolicyDecision? last;
      for (var i = 0; i < config.cleanSamplesToUpgrade + 5; i++) {
        last = policy.onSample(
          _sample(
            packetLossFraction: 0.0,
            rttMs: 30,
            availableOutgoingBitrateBps: 5000000,
          ),
        );
      }

      expect(last, isNull);
      expect(policy.profile, MediaProfile.high);
    });
  });

  group('AdaptiveMediaPolicy oscillation resistance', () {
    test('alternating good/bad samples never moves the ladder a single step '
        '(neither streak threshold is ever reached)', () {
      final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.medium);

      for (var i = 0; i < 50; i++) {
        final bad = i.isEven;
        final decision = policy.onSample(
          bad
              ? _sample(packetLossFraction: 0.10, rttMs: 30)
              : _sample(
                  packetLossFraction: 0.0,
                  rttMs: 30,
                  availableOutgoingBitrateBps: 5000000,
                ),
        );
        expect(decision, isNull, reason: 'alternation $i must not shift');
      }

      expect(policy.profile, MediaProfile.medium);
    });
  });

  group('AdaptiveMediaPolicy.reset()', () {
    test('reset() keeps the current profile when no profile is given', () {
      final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.low);

      policy.reset();

      expect(policy.profile, MediaProfile.low);
    });

    test('reset() clears the in-flight bad-sample streak', () {
      final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.high);

      // One bad sample: consecutiveBad=1, not enough to shift yet.
      final first = policy.onSample(
        _sample(packetLossFraction: 0.10, rttMs: 30),
      );
      expect(first, isNull);

      policy.reset();

      // If the streak had NOT been cleared, this would be the 2nd
      // consecutive bad sample and would shift immediately. Proving it
      // does not shift here demonstrates reset() cleared the counter.
      final afterReset = policy.onSample(
        _sample(packetLossFraction: 0.10, rttMs: 30),
      );
      expect(
        afterReset,
        isNull,
        reason: 'reset() must have cleared the bad streak',
      );
      expect(policy.profile, MediaProfile.high);

      // A second consecutive bad sample now (post-reset) should shift.
      final second = policy.onSample(
        _sample(packetLossFraction: 0.10, rttMs: 30),
      );
      expect(second, isNotNull);
      expect(second!.next, MediaProfile.medium);
    });

    test('reset() clears the in-flight clean-sample streak', () {
      final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.low);
      const ample = 2000000;

      for (var i = 0; i < config.cleanSamplesToUpgrade - 1; i++) {
        policy.onSample(
          _sample(
            packetLossFraction: 0.0,
            rttMs: 30,
            availableOutgoingBitrateBps: ample,
          ),
        );
      }

      policy.reset();

      // If the clean streak had survived reset(), one more clean sample
      // would complete cleanSamplesToUpgrade and upgrade immediately.
      final afterReset = policy.onSample(
        _sample(
          packetLossFraction: 0.0,
          rttMs: 30,
          availableOutgoingBitrateBps: ample,
        ),
      );
      expect(
        afterReset,
        isNull,
        reason: 'reset() must have cleared the clean streak',
      );
      expect(policy.profile, MediaProfile.low);
    });

    test('reset(profile: ...) explicitly overrides the current profile', () {
      final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.high);

      policy.reset(profile: MediaProfile.audioOnly);

      expect(policy.profile, MediaProfile.audioOnly);
    });
  });

  group('AdaptiveMediaPolicy "middling" sample (neither bad nor clean)', () {
    test(
      'a sample with loss between lossCleanThreshold and '
      'lossDowngradeThreshold resets the clean streak without downgrading',
      () {
        final policy = AdaptiveMediaPolicy(initialProfile: MediaProfile.low);
        const ample = 2000000;

        // Build a partial clean streak first.
        for (var i = 0; i < config.cleanSamplesToUpgrade - 1; i++) {
          policy.onSample(
            _sample(
              packetLossFraction: 0.0,
              rttMs: 30,
              availableOutgoingBitrateBps: ample,
            ),
          );
        }

        // loss 0.03 is >= lossCleanThreshold(0.02) so not clean, but
        // < lossDowngradeThreshold(0.05) and rtt is low, so not bad either.
        final middling = policy.onSample(
          _sample(
            packetLossFraction: 0.03,
            rttMs: 30,
            availableOutgoingBitrateBps: ample,
          ),
        );
        expect(middling, isNull);

        // If the clean streak had survived, one more clean sample would
        // complete cleanSamplesToUpgrade and upgrade immediately.
        final afterMiddling = policy.onSample(
          _sample(
            packetLossFraction: 0.0,
            rttMs: 30,
            availableOutgoingBitrateBps: ample,
          ),
        );
        expect(
          afterMiddling,
          isNull,
          reason: 'the middling sample must have reset the clean streak',
        );
        expect(policy.profile, MediaProfile.low);
      },
    );
  });

  group('MediaPolicyDecision', () {
    test(
      'parameters resolves to the target profile\'s MediaProfileParameters',
      () {
        const decision = MediaPolicyDecision(
          previous: MediaProfile.high,
          next: MediaProfile.medium,
          reason: 'test',
        );

        expect(
          decision.parameters,
          MediaProfileParameters.of(MediaProfile.medium),
        );
        expect(decision.parameters.videoMaxBitrateBps, 800000);
      },
    );

    test('toString() reports previous -> next: reason', () {
      const decision = MediaPolicyDecision(
        previous: MediaProfile.high,
        next: MediaProfile.medium,
        reason: 'test reason',
      );

      expect(
        decision.toString(),
        'MediaPolicyDecision(high -> medium: test reason)',
      );
    });
  });

  group('AdaptiveMediaPolicyConfig validation', () {
    test('rejects lossDowngradeThreshold outside [0, 1]', () {
      expect(
        () => AdaptiveMediaPolicyConfig(lossDowngradeThreshold: -0.1),
        throwsRangeError,
      );
      expect(
        () => AdaptiveMediaPolicyConfig(lossDowngradeThreshold: 1.1),
        throwsRangeError,
      );
    });

    test('rejects lossSevereThreshold outside [0, 1]', () {
      expect(
        () => AdaptiveMediaPolicyConfig(lossSevereThreshold: 1.5),
        throwsRangeError,
      );
    });

    test('rejects lossCleanThreshold outside [0, 1]', () {
      expect(
        () => AdaptiveMediaPolicyConfig(lossCleanThreshold: -0.1),
        throwsRangeError,
      );
    });

    test('rejects rttDowngradeThresholdMs below 1', () {
      expect(
        () => AdaptiveMediaPolicyConfig(rttDowngradeThresholdMs: 0),
        throwsRangeError,
      );
    });

    test('rejects badSamplesToDowngrade below 1', () {
      expect(
        () => AdaptiveMediaPolicyConfig(badSamplesToDowngrade: 0),
        throwsRangeError,
      );
    });

    test('rejects cleanSamplesToUpgrade below 1', () {
      expect(
        () => AdaptiveMediaPolicyConfig(cleanSamplesToUpgrade: 0),
        throwsRangeError,
      );
    });

    test('rejects upgradeBandwidthHeadroom <= 0', () {
      expect(
        () => AdaptiveMediaPolicyConfig(upgradeBandwidthHeadroom: 0.0),
        throwsArgumentError,
      );
      expect(
        () => AdaptiveMediaPolicyConfig(upgradeBandwidthHeadroom: -1.0),
        throwsArgumentError,
      );
    });

    test('rejects lossCleanThreshold >= lossDowngradeThreshold', () {
      expect(
        () => AdaptiveMediaPolicyConfig(
          lossCleanThreshold: 0.05,
          lossDowngradeThreshold: 0.05,
        ),
        throwsArgumentError,
      );
    });

    test('rejects lossDowngradeThreshold > lossSevereThreshold', () {
      expect(
        () => AdaptiveMediaPolicyConfig(
          lossDowngradeThreshold: 0.5,
          lossSevereThreshold: 0.3,
        ),
        throwsArgumentError,
      );
    });

    test('accepts a valid, internally-consistent configuration', () {
      expect(
        () => AdaptiveMediaPolicyConfig(
          lossCleanThreshold: 0.01,
          lossDowngradeThreshold: 0.05,
          lossSevereThreshold: 0.2,
        ),
        returnsNormally,
      );
    });
  });
}
