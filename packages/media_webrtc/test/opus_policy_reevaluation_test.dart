import 'package:media_webrtc/media_webrtc.dart';
import 'package:test/test.dart';

/// Ticket 1 acceptance gate 1f — mid-call re-evaluation, with hysteresis.
///
/// The declared gate: "unit test: mid-call conditions move from 64000 to 16000
/// -> the policy changes; and flapping at a boundary must engage hysteresis."
/// This was the one gate in the plan whose CODE had never been written; the
/// unit under test is `OpusPolicyReevaluator`.
///
/// EVERY NUMBER BELOW WAS MEASURED, NOT ASSUMED. Which policy a bandwidth
/// admits is not obvious from the gate's text — 16 kbit/s admits a policy on a
/// simplex link and admits nothing at all in duplex — so the expected values
/// come from `example/probe_admission.dart`, run on this code, this date:
///
///   streams=1  bw=64000  ->  rate=32000  ptime=60
///   streams=1  bw=32000  ->  rate=16000  ptime=120
///   streams=1  bw=24000  ->  rate=12000  ptime=120
///   streams=1  bw=16000  ->  rate=6000   ptime=120
///   streams=1  bw=12000  ->  refused, capacity, minBandwidth=14858
///   streams=2  bw=64000  ->  rate=16000  ptime=120
///   streams=2  bw=16000  ->  refused, capacity, minBandwidth=29715
///
/// That table is why the gate has two mid-call collapse tests rather than one:
/// on a simplex link 64000 -> 16000 is a ptime change, and in duplex — which is
/// what a call actually is — the same collapse falls below the floor entirely.
/// A test that only covered the first would report the gate green while the
/// realistic path went unexercised.
void main() {
  /// The policy a call is admitted with at [bandwidthBps]; the test starts
  /// where a real session starts rather than with a hand-built budget.
  OpusWireBudget admitted(int bandwidthBps, {int streams = 1}) {
    final admission = OpusWireBudget.forBandwidth(
      bandwidthBps,
      concurrentStreams: streams,
    );
    return (admission as OpusWireFitted).budget;
  }

  group('gate 1f — mid-call re-evaluation', () {
    test('1f  a sustained collapse from 64000 to 16000 changes the policy, '
        'through a renegotiation because the ptime must move', () {
      final unit = OpusPolicyReevaluator(initialPolicy: admitted(64000));
      expect(unit.policy.ptimeMs, 60, reason: 'measured admission at 64000');
      expect(unit.policy.opusRateBps, 32000);

      // The dwell is three, so the first two samples must not disrupt the
      // call — and must SAY they are counting, rather than looking steady.
      final first = unit.onBandwidthSample(16000);
      expect(first, isA<OpusPolicyChangePending>());
      expect((first as OpusPolicyChangePending).samplesObserved, 1);
      expect(first.samplesRequired, 3);
      expect(
        first.target,
        isA<OpusPolicyPendingPtime>(),
        reason:
            'the disruption being counted toward is a ptime change, which '
            'is the thing that costs a renegotiation',
      );
      expect(
        unit.policy.ptimeMs,
        60,
        reason: 'nothing may change while a disruption is merely pending',
      );

      final second = unit.onBandwidthSample(16000);
      expect((second as OpusPolicyChangePending).samplesObserved, 2);
      expect(unit.policy.ptimeMs, 60);

      final third = unit.onBandwidthSample(16000);
      expect(third, isA<OpusPolicyRenegotiationRequired>());
      final commit = third as OpusPolicyRenegotiationRequired;
      expect(commit.previousPtimeMs, 60);
      expect(commit.policy.ptimeMs, 120);
      expect(commit.policy.opusRateBps, 6000);
      expect(
        unit.policy.ptimeMs,
        120,
        reason: 'the committed decision is also the policy now in force',
      );
    });

    test('1f  the same collapse in duplex falls below the floor, and that is '
        'reported with its numbers rather than as a quiet downgrade', () {
      // Two crossings of the same pipe is what a call is. Here 16 kbit/s
      // admits nothing at all, so the honest outcome is a refusal carrying
      // the bandwidth it would need — not the cheapest candidate applied
      // anyway, which is the failure this ticket exists to remove.
      final unit = OpusPolicyReevaluator(
        initialPolicy: admitted(64000, streams: 2),
        concurrentStreams: 2,
      );
      expect(unit.policy.ptimeMs, 120);

      expect(unit.onBandwidthSample(16000), isA<OpusPolicyChangePending>());
      expect(unit.onBandwidthSample(16000), isA<OpusPolicyChangePending>());
      final third = unit.onBandwidthSample(16000);

      expect(third, isA<OpusPolicyBelowFloor>());
      final refusal = (third as OpusPolicyBelowFloor).refusal;
      expect(refusal.cause, OpusWireRefusalCause.capacity);
      expect(
        refusal.minimumBandwidthBps,
        29715,
        reason:
            'a capacity refusal must name the bandwidth that would fix it, '
            'measured from the same formula admission uses',
      );
    });

    test('1f  flapping at a boundary never renegotiates, however long it goes '
        'on', () {
      // The point of the gate. 64000 admits ptime 60; 32000 admits ptime 120.
      // Alternating between them asks for a renegotiation every other sample,
      // and a design without hysteresis would grant one every other sample.
      final unit = OpusPolicyReevaluator(initialPolicy: admitted(64000));
      var renegotiations = 0;
      var pendings = 0;

      for (var i = 0; i < 20; i++) {
        final decision = unit.onBandwidthSample(i.isEven ? 32000 : 64000);
        if (decision is OpusPolicyRenegotiationRequired) renegotiations++;
        if (decision is OpusPolicyChangePending) pendings++;
      }

      expect(
        renegotiations,
        0,
        reason: 'ten opportunities to renegotiate on jitter, none taken',
      );
      expect(
        pendings,
        10,
        reason:
            'and the deferral is visible on every one of them, so a '
            'suppressed disruption can be seen in a log instead of looking '
            'like a steady link',
      );
      expect(
        unit.policy.ptimeMs,
        60,
        reason: 'the policy in force never moved',
      );
    });

    test('1f  hysteresis is symmetric: flapping back up after a commit does '
        'not renegotiate either', () {
      // A design that guarded only the downward move would renegotiate on
      // every recovery blip, which is the same defect facing the other way.
      final unit = OpusPolicyReevaluator(initialPolicy: admitted(64000));
      for (var i = 0; i < 3; i++) {
        unit.onBandwidthSample(16000);
      }
      expect(unit.policy.ptimeMs, 120, reason: 'committed downward');

      var renegotiations = 0;
      for (var i = 0; i < 10; i++) {
        final decision = unit.onBandwidthSample(i.isEven ? 64000 : 16000);
        if (decision is OpusPolicyRenegotiationRequired) renegotiations++;
      }
      expect(renegotiations, 0);
      expect(unit.policy.ptimeMs, 120);
    });

    test('1f  a rate change at the same ptime is applied immediately, with no '
        'dwell', () {
      // The asymmetry that makes the design worth having: the rate costs
      // nothing to change, so waiting three samples for it would be pure
      // quality loss. 32000 and 24000 both admit ptime 120.
      final unit = OpusPolicyReevaluator(initialPolicy: admitted(32000));
      expect(unit.policy.ptimeMs, 120);
      expect(unit.policy.opusRateBps, 16000);

      final decision = unit.onBandwidthSample(24000);

      expect(decision, isA<OpusPolicyRateChange>());
      final change = decision as OpusPolicyRateChange;
      expect(change.previousOpusRateBps, 16000);
      expect(change.policy.opusRateBps, 12000);
      expect(
        change.policy.ptimeMs,
        120,
        reason:
            'the ptime is unchanged, which is exactly why no '
            'renegotiation is required',
      );
      expect(unit.policy.opusRateBps, 12000);
    });

    test('1f  an unchanged link reports steady, and refreshes the occupancy it '
        'was judged against', () {
      final unit = OpusPolicyReevaluator(initialPolicy: admitted(64000));
      final decision = unit.onBandwidthSample(60000);

      expect(decision, isA<OpusPolicySteady>());
      final steady = decision as OpusPolicySteady;
      expect(steady.policy.opusRateBps, 32000);
      expect(steady.policy.ptimeMs, 60);
      expect(
        steady.policy.bandwidthBps,
        60000,
        reason:
            'steady means the policy stands, not that the link report is '
            'discarded — occupancy must describe the link as it is now',
      );
    });

    test('1f  one recovering sample cancels a pending disruption outright', () {
      // The dwell counts CONSECUTIVE evidence. If a single good sample only
      // decremented the counter, a link that is bad two samples out of three
      // would still renegotiate, and the guarantee would be statistical
      // rather than structural.
      final unit = OpusPolicyReevaluator(initialPolicy: admitted(64000));
      expect(
        (unit.onBandwidthSample(16000) as OpusPolicyChangePending)
            .samplesObserved,
        1,
      );
      expect(
        (unit.onBandwidthSample(16000) as OpusPolicyChangePending)
            .samplesObserved,
        2,
      );
      expect(unit.onBandwidthSample(64000), isA<OpusPolicySteady>());
      expect(
        (unit.onBandwidthSample(16000) as OpusPolicyChangePending)
            .samplesObserved,
        1,
        reason: 'the streak restarted from scratch, not from two',
      );
    });

    test('1f  a below-floor link keeps reporting below-floor, and the counter '
        'saturates', () {
      final unit = OpusPolicyReevaluator(
        initialPolicy: admitted(64000, streams: 2),
        concurrentStreams: 2,
      );
      for (var i = 0; i < 2; i++) {
        expect(unit.onBandwidthSample(16000), isA<OpusPolicyChangePending>());
      }
      for (var i = 0; i < 5; i++) {
        expect(
          unit.onBandwidthSample(16000),
          isA<OpusPolicyBelowFloor>(),
          reason:
              'a link that stays below the floor must keep saying so; '
              'reporting it once would leave a caller that missed the one '
              'decision running a call the measurement says cannot work',
        );
      }
    });

    test('1f  the dwell and the stream count are validated, not clamped', () {
      // A clamp would silently void the flap-immunity argument the class
      // documents. This codebase's rule: make the impossible state loud.
      expect(
        () => OpusPolicyReevaluator(
          initialPolicy: admitted(64000),
          disruptionDwellSamples: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => OpusPolicyReevaluator(
          initialPolicy: admitted(64000),
          concurrentStreams: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => OpusPolicyReevaluator(
          initialPolicy: admitted(64000),
        ).onBandwidthSample(0),
        throwsArgumentError,
        reason:
            'an absent estimate is not a sample of zero; feeding nothing '
            'is how a caller says it does not know',
      );
    });

    test('1f  the responsiveness bound participates mid-call, exactly as it '
        'does at admission', () {
      // A long path cannot be fixed by lowering the rate, so re-evaluation
      // must not answer it with a rate change. The probe is the same seam
      // admission uses; here it rejects everything, as a 2-second round trip
      // does.
      final unit = OpusPolicyReevaluator(
        initialPolicy: admitted(64000),
        disruptionDwellSamples: 2,
        tickProbe:
            ({
              required int wireRateBps,
              required double perStreamBudgetBps,
              required int frameBitsOnWire,
            }) => false,
      );

      expect(unit.onBandwidthSample(1000000), isA<OpusPolicyChangePending>());
      final second = unit.onBandwidthSample(1000000);
      expect(second, isA<OpusPolicyBelowFloor>());
      final refusal = (second as OpusPolicyBelowFloor).refusal;
      expect(refusal.cause, OpusWireRefusalCause.responsiveness);
      expect(
        refusal.minimumBandwidthBps,
        isNull,
        reason:
            'no bandwidth fixes a delay refusal, so the field that would '
            'name one stays absent instead of misleading the caller',
      );
    });
  });
}
