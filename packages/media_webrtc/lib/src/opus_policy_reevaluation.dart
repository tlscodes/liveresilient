/// Mid-call re-evaluation of an admitted Opus wire policy.
///
/// `OpusWireBudget.forBandwidth` answers the setup-time question: what
/// fits this link. This library answers the mid-call question: the link
/// moved — is acting on that worth the disruption? The two knobs are
/// treated asymmetrically because they are not symmetric on the wire:
///
///  * The Opus rate is an encoder parameter. It changes on the next frame
///    with no signalling, so it follows the link freely, every sample.
///  * The packetization time is negotiated with the far end. Changing it
///    forces a session renegotiation, so a policy that follows estimator
///    jitter renegotiates constantly and is worse than one that never
///    re-evaluates. Ptime only moves after a consecutive-sample dwell.
///
/// Nothing here reads a clock or arms a timer. The caller feeds samples,
/// decisions come out, and identical sample sequences always produce
/// identical decision sequences, so tests drive every path by feeding
/// integers — no waiting.
library;

import 'opus_wire_budget.dart';

/// What one bandwidth sample asks of the running call.
///
/// Sealed so the caller is forced to branch on every outcome; no outcome
/// is signalled by a null field or a sentinel number. Exactly one decision
/// is produced per sample fed to
/// [OpusPolicyReevaluator.onBandwidthSample].
sealed class OpusPolicyDecision {
  const OpusPolicyDecision();
}

/// Nothing to do: the link still endorses the policy in force.
///
/// Steadiness is judged on rate and ptime only. The carried [policy] is
/// still restated against the sampled bandwidth so `policy.occupancy`
/// keeps telling the truth about the link as it is now.
final class OpusPolicySteady extends OpusPolicyDecision {
  const OpusPolicySteady({required this.policy});

  /// The policy in force, refreshed with the sampled bandwidth.
  final OpusWireBudget policy;
}

/// The Opus rate should change now; no renegotiation is involved.
///
/// Emitted the moment admission picks a different rate at the ptime
/// already in force. Rate is deliberately unprotected by hysteresis:
/// applying it costs nothing on the wire, so reacting late is pure loss.
final class OpusPolicyRateChange extends OpusPolicyDecision {
  const OpusPolicyRateChange({
    required this.policy,
    required this.previousOpusRateBps,
  });

  /// The new policy to apply; its ptime equals the previous policy's,
  /// which is exactly why no renegotiation is needed.
  final OpusWireBudget policy;

  /// The rate being left behind — for logs and tests, never inferred.
  final int previousOpusRateBps;
}

/// The ptime must change, so a session renegotiation is required.
///
/// Only emitted after [OpusPolicyReevaluator.disruptionDwellSamples]
/// consecutive samples admitted the same new ptime. See the reevaluator's
/// class doc for why boundary flapping is provably unable to reach this.
final class OpusPolicyRenegotiationRequired extends OpusPolicyDecision {
  const OpusPolicyRenegotiationRequired({
    required this.policy,
    required this.previousPtimeMs,
  });

  /// The policy to renegotiate to. Its rate is the freshest admitted rate,
  /// because the pending target is refreshed on every agreeing sample.
  final OpusWireBudget policy;

  /// The ptime being abandoned — for logs and tests, never inferred.
  final int previousPtimeMs;
}

/// The link has fallen below what the cheapest candidate needs.
///
/// This class names the state and carries admission's own numbers; it
/// deliberately defines NO behaviour. The codebase already has a hard
/// mandate below the floor — shaping off, cbr false, dtx true, then
/// refuse or end the call — and re-evaluation routes to that standing
/// rule rather than inventing a third behaviour here.
///
/// Also dwell-protected: ending a call is the most disruptive outcome of
/// all, so one lying estimator sample must not be able to cause it. The
/// state does not latch — if a later sample fits again, recovery is the
/// caller's policy, not this class's.
final class OpusPolicyBelowFloor extends OpusPolicyDecision {
  const OpusPolicyBelowFloor({required this.refusal});

  /// The refusal with its cause (capacity vs responsiveness), bandwidth,
  /// per-stream budget and cheapest wire rate — the numbers that say why
  /// the call cannot continue as admitted.
  final OpusWireNoCandidateFits refusal;
}

/// A disruptive change is indicated but its dwell is not yet met.
///
/// This fifth state exists because a plain hold that silently conceals a
/// deferred disruption would make the hysteresis invisible — untestable
/// by the declared acceptance test and un-loggable in production. Its one
/// job is observability; the caller applies nothing.
///
/// While a ptime change is pending the rate also holds still. Picking a
/// "best rate at the sticky ptime" would require a second candidate
/// search with a pinned ptime, which this library refuses to duplicate;
/// if that is ever wanted it belongs in `OpusWireBudget.forBandwidth`
/// as a parameter, not here.
final class OpusPolicyChangePending extends OpusPolicyDecision {
  const OpusPolicyChangePending({
    required this.target,
    required this.samplesObserved,
    required this.samplesRequired,
  });

  /// What will happen if the condition sustains.
  final OpusPolicyPendingTarget target;

  /// Consecutive samples that have agreed on [target] so far; always
  /// at least one, because a pending decision is itself evidence.
  final int samplesObserved;

  /// The dwell. The disruptive decision is emitted on the sample where
  /// [samplesObserved] reaches this value.
  final int samplesRequired;
}

/// The disruption a pending decision is counting toward.
///
/// Sealed, with one concrete payload per kind, so neither kind is ever
/// inferred from a null field on the other.
sealed class OpusPolicyPendingTarget {
  const OpusPolicyPendingTarget();
}

/// The dwell is counting toward a renegotiation to [budget].
final class OpusPolicyPendingPtime extends OpusPolicyPendingTarget {
  const OpusPolicyPendingPtime({required this.budget});

  /// The would-be policy; refreshed on every agreeing sample so commit
  /// ships the freshest admitted rate alongside the new ptime.
  final OpusWireBudget budget;
}

/// The dwell is counting toward the standing below-floor mandate.
final class OpusPolicyPendingFloor extends OpusPolicyPendingTarget {
  const OpusPolicyPendingFloor({required this.refusal});

  /// The refusal the mandate would be justified by.
  final OpusWireNoCandidateFits refusal;
}

/// Feeds successive bandwidth samples through admission and decides what,
/// if anything, the running call should change.
///
/// ## Hysteresis mechanism, and why it is flap-proof
///
/// A disruptive outcome (ptime change or below-floor) is emitted only
/// when [disruptionDwellSamples] consecutive samples admit the identical
/// target: the same new ptime, or the floor. Any sample that admits the
/// ptime in force resets the streak to zero; a sample admitting a
/// different disruptive target restarts it at one. Flapping around a
/// boundary alternates targets by definition, so for any dwell of two or
/// more the streak can never reach the dwell — renegotiation-by-flap is
/// impossible by construction, not merely unlikely. That is why the
/// constructor rejects a dwell below two instead of accepting it.
///
/// A sample count was chosen over a wall-clock dwell so the class stays
/// deterministic and clock-free; the caller's sampling cadence converts
/// the count into real time, and owning that cadence is the caller's
/// declared responsibility.
///
/// ## What this class refuses to do
///
///  * Read a clock or arm a timer — the caller owns time entirely.
///  * Move the rate while a ptime change is pending (see
///    [OpusPolicyChangePending] for why).
///  * Define below-floor behaviour — it routes to the standing mandate.
///  * Judge an absent estimate: an estimator that has lost its estimate
///    produces no sample, and no sample means no decision — the policy
///    in force simply stands. `forBandwidth(null)` is a setup question.
///
/// ## What this class cannot detect
///
///  * A lying estimator — decisions are exactly as good as the samples.
///  * Loss, RTT or jitter: bandwidth is the only input; responsiveness
///    enters only through the [TickIntervalProbe] supplied at
///    construction, exactly as it does at admission.
///  * Elapsed real time: a caller sampling every 10 ms has a tenfold
///    shorter real-time dwell than one sampling every 100 ms.
///  * A mid-call carrier or stream-count change; both are per-call
///    configuration, fixed at construction.
final class OpusPolicyReevaluator {
  /// [initialPolicy] is the budget the call was admitted with (the
  /// `OpusWireFitted.budget` from setup). Its carrier is reused for every
  /// re-admission, so setup and re-evaluation can never disagree about
  /// per-packet overhead — the disagreement is unrepresentable.
  ///
  /// Throws [ArgumentError] rather than clamping: a stream count below
  /// one is a caller bug, and a dwell below two would silently void the
  /// flap-immunity argument in the class doc.
  OpusPolicyReevaluator({
    required OpusWireBudget initialPolicy,
    int concurrentStreams = 1,
    this.disruptionDwellSamples = defaultDisruptionDwellSamples,
    TickIntervalProbe? tickProbe,
  }) : _policy = initialPolicy,
       _concurrentStreams = concurrentStreams,
       _tickProbe = tickProbe {
    if (concurrentStreams < 1) {
      throw ArgumentError.value(
        concurrentStreams,
        'concurrentStreams',
        'a call carries at least one stream',
      );
    }
    if (disruptionDwellSamples < 2) {
      throw ArgumentError.value(
        disruptionDwellSamples,
        'disruptionDwellSamples',
        'below two, a single jittery sample can force a renegotiation '
            'and the flap-immunity guarantee no longer holds',
      );
    }
  }

  /// Default dwell: three consecutive agreeing samples.
  ///
  /// Why three: two already defeats strict alternation, but delay-based
  /// bandwidth estimators routinely undershoot for a couple of
  /// consecutive reports after a cross-traffic burst; three requires the
  /// condition to outlive one such reaction cycle. At a typical
  /// one-report-per-second cadence that is roughly three seconds of
  /// sustained evidence — slow enough to ignore jitter, fast enough that
  /// a genuine collapse is answered before quality damage compounds.
  static const int defaultDisruptionDwellSamples = 3;

  /// Consecutive identical-target samples required before a disruptive
  /// outcome (ptime change or below-floor) is emitted. Never below two.
  final int disruptionDwellSamples;

  final int _concurrentStreams;
  final TickIntervalProbe? _tickProbe;

  OpusWireBudget _policy;
  OpusPolicyPendingTarget? _pending;
  int _streak = 0;

  /// The policy currently in force: rate, ptime, carrier, and the last
  /// bandwidth it was judged against. Only [OpusPolicyRateChange] and
  /// [OpusPolicyRenegotiationRequired] move rate or ptime;
  /// [OpusPolicySteady] merely refreshes the recorded bandwidth.
  OpusWireBudget get policy => _policy;

  /// Judges one bandwidth measurement and returns exactly one decision.
  ///
  /// The sample must be a real, positive measurement. An absent estimate
  /// is not a sample — feed nothing and the policy in force stands — so
  /// a non-positive value throws instead of being guessed around.
  OpusPolicyDecision onBandwidthSample(int bandwidthBps) {
    if (bandwidthBps <= 0) {
      throw ArgumentError.value(
        bandwidthBps,
        'bandwidthBps',
        'a sample is a positive measurement; when the estimator has '
            'no estimate, feed nothing',
      );
    }
    final admission = OpusWireBudget.forBandwidth(
      bandwidthBps,
      concurrentStreams: _concurrentStreams,
      carrier: _policy.carrier,
      tickProbe: _tickProbe,
    );
    return switch (admission) {
      // Unconstrained is the answer to an UNKNOWN link (null bandwidth),
      // which this method makes unrepresentable; thrown, not asserted,
      // because asserts are stripped in release builds here.
      OpusWireUnconstrained() => throw StateError(
        'forBandwidth returned OpusWireUnconstrained for a measured '
        'bandwidth; that state is reserved for an unknown link',
      ),
      OpusWireFitted(budget: final admitted) => _onFitted(admitted),
      OpusWireNoCandidateFits refusal => _onRefused(refusal),
    };
  }

  OpusPolicyDecision _onFitted(OpusWireBudget admitted) {
    if (admitted.ptimeMs == _policy.ptimeMs) {
      // The link endorses the ptime in force: any disruption streak is
      // now broken evidence, so it resets to zero. This reset IS the
      // hysteresis — it is what makes flapping unable to accumulate.
      _pending = null;
      _streak = 0;
      final previousRate = _policy.opusRateBps;
      _policy = admitted;
      if (admitted.opusRateBps == previousRate) {
        return OpusPolicySteady(policy: admitted);
      }
      return OpusPolicyRateChange(
        policy: admitted,
        previousOpusRateBps: previousRate,
      );
    }
    final pending = _pending;
    final sameTarget =
        pending is OpusPolicyPendingPtime &&
        pending.budget.ptimeMs == admitted.ptimeMs;
    _streak = sameTarget ? _streak + 1 : 1;
    final target = OpusPolicyPendingPtime(budget: admitted);
    _pending = target;
    if (_streak < disruptionDwellSamples) {
      return OpusPolicyChangePending(
        target: target,
        samplesObserved: _streak,
        samplesRequired: disruptionDwellSamples,
      );
    }
    final previousPtime = _policy.ptimeMs;
    _policy = admitted;
    _pending = null;
    _streak = 0;
    return OpusPolicyRenegotiationRequired(
      policy: admitted,
      previousPtimeMs: previousPtime,
    );
  }

  OpusPolicyDecision _onRefused(OpusWireNoCandidateFits refusal) {
    final sameTarget = _pending is OpusPolicyPendingFloor;
    // Saturate at the dwell instead of clearing: a link that stays below
    // the floor keeps reporting OpusPolicyBelowFloor on every further
    // sample, and the counter cannot creep toward overflow.
    _streak = sameTarget
        ? (_streak < disruptionDwellSamples ? _streak + 1 : _streak)
        : 1;
    final target = OpusPolicyPendingFloor(refusal: refusal);
    _pending = target;
    if (_streak < disruptionDwellSamples) {
      return OpusPolicyChangePending(
        target: target,
        samplesObserved: _streak,
        samplesRequired: disruptionDwellSamples,
      );
    }
    return OpusPolicyBelowFloor(refusal: refusal);
  }
}
