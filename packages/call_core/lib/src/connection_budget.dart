import 'dart:math' as math;

import 'reconnect_policy.dart';

/// The network conditions a connect attempt has to survive.
///
/// [rtt] is the round-trip time observed on the nominated candidate pair, or —
/// before any pair exists — the round-trip time the path is known to impose.
/// [loss] is a fraction in `[0, 1]`, not a percentage.
class NetworkConditions {
  const NetworkConditions({
    required this.rtt,
    required this.loss,
    this.bandwidthBps,
  });

  /// Conditions of a link with no impairment, used when nothing is known yet.
  static const NetworkConditions pristine = NetworkConditions(
    rtt: Duration(milliseconds: 70),
    loss: 0,
  );

  final Duration rtt;
  final double loss;

  /// Usable throughput in BITS per second, or null when the link is not the
  /// constraint.
  ///
  /// Round-trip time and loss say nothing about a narrow pipe: on a 16 kbit/s
  /// link the negotiation is slow because the bytes take time to leave, not
  /// because they are late or lost. Without this term a bandwidth-constrained
  /// profile is modelled as if it were pristine.
  final int? bandwidthBps;

  @override
  String toString() =>
      'NetworkConditions(rtt: ${rtt.inMilliseconds}ms, '
      'loss: $loss, bandwidthBps: $bandwidthBps)';
}

/// Two-sided bound on a fixed emitter tick, or the reason no such tick
/// exists.
///
/// Returned by [AdaptiveConnectionBudget.maxSchedulerStepFor]. A sealed
/// three-state value on purpose: over the grid this class is exercised
/// against (rtt 4..2000 ms, loss 0..0.9) a large part of the links admit no
/// tick at all, and that is an ordinary link condition a caller reports —
/// not a defect to be papered over with a clamped number, a zero, or a
/// sentinel.
sealed class SchedulerStepBound {
  const SchedulerStepBound();
}

/// The admissible interval exists: any fixed tick in `[minStep, maxStep]`
/// keeps the emitter inside both the latency budget and the link's granted
/// share.
final class SchedulerStepAdmissible extends SchedulerStepBound {
  /// Throws [ArgumentError] on an empty interval.
  ///
  /// A check, not an assertion. `assert` is removed in a release build, so
  /// the state this guards — an "admissible" value whose floor sits above
  /// its ceiling — would be constructible in exactly the build that ships,
  /// and a caller would then pace an emitter to a step no bound allows. The
  /// whole point of this sealed type is that an impossible interval is a
  /// different value, not a number; a guard that holds only in debug leaves
  /// that promise unkept where it matters.
  SchedulerStepAdmissible({required this.minStep, required this.maxStep}) {
    if (minStep > maxStep) {
      throw ArgumentError(
        'empty interval ($minStep > $maxStep) is '
        'SchedulerStepImpossibleForResponsiveness, not an admissible value',
      );
    }
  }

  /// Shortest admissible tick: the time the link's spare rate
  /// (usable share minus offered rate) needs to carry one frame's bits. A
  /// shorter tick offers bits faster than the spare rate absorbs them.
  final Duration minStep;

  /// Longest admissible tick: what remains of the one-way interactive
  /// budget after the network and the jitter buffer take their share.
  final Duration maxStep;
}

/// No lower bound exists: the offered rate meets or exceeds the usable
/// share of the link, so the spare rate that would carry one frame per tick
/// is zero or negative and the lower-bound division has no denominator.
final class SchedulerStepImpossibleForCapacity extends SchedulerStepBound {
  const SchedulerStepImpossibleForCapacity({
    required this.offeredRateBps,
    required this.usableShareBps,
    required this.shortfallBps,
  });

  /// The wire rate the emitter was going to offer, bits per second.
  final int offeredRateBps;

  /// The share of the link this stream may use, bits per second.
  final int usableShareBps;

  /// `offeredRateBps - usableShareBps`: how far the offer overruns the
  /// link, bits per second. Zero means exactly saturated — still
  /// impossible, because a saturated link has no spare rate left to drain
  /// a queue with.
  final int shortfallBps;
}

/// The latency side admits no tick: the upper bound
/// `interactiveBudget - oneWayNetwork - jitterBuffer` is non-positive, or
/// both bounds exist but the capacity lower bound exceeds it.
final class SchedulerStepImpossibleForResponsiveness
    extends SchedulerStepBound {
  const SchedulerStepImpossibleForResponsiveness({
    required this.interactiveBudget,
    required this.oneWayNetwork,
    required this.jitterBuffer,
    required this.resultingStep,
  });

  /// The one-way mouth-to-ear budget the bound was computed against
  /// ([AdaptiveConnectionBudget.interactiveLatencyBudget]).
  final Duration interactiveBudget;

  /// The one-way network term charged against the budget — half the
  /// round-trip; see [AdaptiveConnectionBudget.maxSchedulerStepFor] for
  /// why, and for what the halving assumes.
  final Duration oneWayNetwork;

  /// The receive-side buffering charged against the budget
  /// ([AdaptiveConnectionBudget.jitterBufferDelay]).
  final Duration jitterBuffer;

  /// The figure that failed: the non-positive upper bound itself, or —
  /// when the interval inverted — the positive upper bound that the
  /// capacity lower bound exceeds.
  final Duration resultingStep;
}

/// Derives connect/reconnect deadlines from the conditions the path imposes.
///
/// The deadlines used to be compile-time constants calibrated against a ~0.7s
/// round-trip. They are not a safety margin on a shaped link: one full
/// ICE + DTLS + first-media attempt costs roughly eight round trips, and every
/// request/response round only completes with probability `(1 - loss)^2`, so on
/// a 1.8s / 60%-loss profile a single attempt costs ~94s. A 15s cap therefore
/// severs the handshake mid-flight and reports it as a connect failure, which
/// is arithmetic, not flakiness.
///
/// The budget is deliberately bounded on both sides: it tightens back to
/// [minElapsed] on a healthy link, so a regression that makes connecting slow
/// under good conditions still fails.
class AdaptiveConnectionBudget {
  const AdaptiveConnectionBudget._({
    required this.conditions,
    required this.attemptCost,
    required this.maxElapsed,
    required this.maxAttempts,
    required this.baseDelay,
    required this.maxDelay,
  });

  /// Round trips consumed by signalling (2), ICE connectivity checks (3),
  /// the DTLS handshake (2) and the first media confirmation (1).
  static const int handshakeRoundTrips = 8;

  /// Floor on the round-trip used in the model. Reported values below this are
  /// sampling noise, and dividing the budget by them produces nothing useful.
  static const Duration minRtt = Duration(milliseconds: 200);

  /// Fixed cost that does not scale with the round-trip.
  static const Duration fixedCost = Duration(seconds: 4);

  /// The initial DTLS/STUN retransmission timer.
  ///
  /// Under loss, this — not the propagation round-trip — is what sets the
  /// pace: a dropped flight is not noticed until the timer fires, and the
  /// timer then DOUBLES. On a 4ms link at 60% loss the round-trips are
  /// instant and the handshake still takes minutes, entirely inside these
  /// timers.
  static const Duration retransmitTimer = Duration(seconds: 1);

  /// Cap on the doubling exponent, i.e. the deepest backoff modelled.
  ///
  /// `2^6 - 1 = 63` retransmit-timer units. Past this the series diverges
  /// faster than any budget worth granting, and a link that needs a seventh
  /// doubling is not going to carry a call.
  static const int maxBackoffDoublings = 6;

  /// Attempts the budget must be able to absorb, so that one unlucky attempt
  /// (jitter on the exponential DTLS timers) is not fatal.
  static const int attemptsAllowed = 3;

  /// Serialized critical signaling deliveries in one connect (room join,
  /// offer, answer) — the count behind the TCP-stall term in [_terms].
  static const int tcpSerializedDeliveries = 3;

  static const Duration minElapsed = Duration(seconds: 30);

  /// Raised 300 -> 450 on 2026-08-07: with the measured TCP-stall term the
  /// 60%-loss profile's three-attempt budget is ~460 s, and a 300 s cap was
  /// cutting the third attempt off mid-flight — the cap exists to keep
  /// budgets meaningful, not to re-create the starvation this class fixes.
  static const Duration maxElapsedCap = Duration(seconds: 450);

  /// Upper bound on the retransmit inflation factor. The true cost grows faster
  /// than `1 / (1 - loss)^2` because the timers double, but an unbounded factor
  /// makes the budget diverge as loss approaches 1.
  static const double maxLossFactor = 8.0;

  /// Bytes one full negotiation puts on the wire, both directions summed.
  ///
  /// ESTIMATE, not a measurement — replace it with a packet capture when one
  /// exists. It is dominated by the two SDP offer/answer bodies carried over
  /// the signalling socket, which is the same shaped link (a few kB each once
  /// every ICE candidate is inlined), plus a DTLS handshake with a self-signed
  /// certificate (~4 kB of flights) and the STUN connectivity checks, which are
  /// small. 24 kB is the conservative end of that range: overstating it only
  /// grants a slow link more time, understating it re-creates the bug this
  /// whole class exists to fix.
  static const int handshakeBytes = 24 * 1024;

  /// Below this the link cannot carry a call at all, and modelling it produces
  /// a budget so large it stops meaning anything.
  static const int minBandwidthBps = 4000;

  /// One-way mouth-to-ear latency budget for interactive speech, the fixed
  /// side of the scheduler-step upper bound in [maxSchedulerStepFor]: what
  /// remains of these 150 ms after the network and the jitter buffer take
  /// their share is the longest tick a fixed emitter may run at.
  static const Duration interactiveLatencyBudget = Duration(milliseconds: 150);

  /// Receive-side jitter-buffer depth charged against
  /// [interactiveLatencyBudget] in [maxSchedulerStepFor].
  ///
  /// PINNED at 60 ms by the plan — the value is defined nowhere else in
  /// this repository, so this constant is the single place to change it
  /// when a configured or measured buffer depth exists.
  static const Duration jitterBufferDelay = Duration(milliseconds: 60);

  final NetworkConditions conditions;

  /// Modelled cost of one complete connect attempt under [conditions].
  final Duration attemptCost;

  final Duration maxElapsed;
  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;

  /// The condition-derived terms shared by [fromConditions] and
  /// [operationBudget] — computed in ONE place so the whole-attempt budget
  /// and the per-operation budgets cannot drift apart.
  static ({
    int effRttMs,
    double lossFactor,
    int retransmitMs,
    int tcpStallMs,
    int serializationMs,
  })
  _terms(NetworkConditions conditions) {
    final effRttMs = math.max(
      conditions.rtt.inMilliseconds,
      minRtt.inMilliseconds,
    );
    final p = conditions.loss.isFinite ? conditions.loss.clamp(0.0, 0.9) : 0.9;
    final lossFactor = math.min(maxLossFactor, 1 / ((1 - p) * (1 - p)));

    // Serialization: how long the negotiation's own bytes take to leave a
    // narrow pipe. Retransmitted under loss for the same reason the round
    // trips are, so it carries the same factor.
    final bps = conditions.bandwidthBps;
    final serializationMs = (bps == null || bps <= 0)
        ? 0
        : (handshakeBytes *
                  8 *
                  1000 /
                  math.max(bps, minBandwidthBps) *
                  lossFactor)
              .round();

    // Retransmission under loss. `lossFactor` is the EXPECTED NUMBER of tries
    // a round trip needs; the timer DOUBLES between tries, so the time those
    // tries consume is the geometric sum `t * (2^n - 1)`, not `t * n`.
    //
    // Treating it as linear is what made an earlier version of this model
    // grant the 60%-loss profile 42s, while a packet capture of that profile
    // showed ICE and TURN still negotiating past 125s. The measurement was
    // right and the linear term was wrong.
    final doublings = math.min(lossFactor, maxBackoffDoublings.toDouble());
    final retransmitMs =
        (retransmitTimer.inMilliseconds * (math.pow(2, doublings) - 1)).round();

    // SERIALIZED TCP SIGNALING STALLS — an ATTEMPT-level term, deliberately
    // NOT folded into retransmitMs. One ladder models ONE stalled delivery;
    // a whole connect ATTEMPT is several signaling deliveries in SERIES
    // (join, offer, answer), each riding TCP where a retransmit chain
    // stalls the stream for a full ladder. Measured 2026-08-07 (T2 loss60,
    // phase-timeline instrumentation): room join alone took 43 s and one
    // offer send outlived 141 s while a single ladder promised 63 s — so
    // the attempt charges the ladder once fully plus once per additional
    // serialized delivery weighted by the probability (~p) that delivery
    // stalls at all. A SINGLE bounded operation keeps the single ladder:
    // folding the stall into every operation bound was measured the same
    // day to inflate one send-await to 292 s, so only ~1.5 recovery cycles
    // fit the budget and the call lost its fresh-socket retries — under an
    // at-least-once outbox, aborting one stalled await early is free (the
    // envelope keeps retransmitting) while a fresh dial samples fresh TCP
    // luck. Zero at p=0, negligible on the low-loss profiles.
    final tcpStallMs = (retransmitMs * (tcpSerializedDeliveries - 1) * p)
        .round();

    return (
      effRttMs: effRttMs,
      lossFactor: lossFactor,
      retransmitMs: retransmitMs,
      tcpStallMs: tcpStallMs,
      serializationMs: serializationMs,
    );
  }

  /// Builds a budget for [conditions].
  ///
  /// Every output is clamped, so out-of-range or absent measurements degrade
  /// into the bounds rather than into an [ArgumentError] downstream.
  factory AdaptiveConnectionBudget.fromConditions(
    NetworkConditions conditions,
  ) {
    final t = _terms(conditions);
    final attemptMs =
        (t.effRttMs * handshakeRoundTrips * t.lossFactor).round() +
        t.retransmitMs +
        t.tcpStallMs +
        t.serializationMs +
        fixedCost.inMilliseconds;
    final attemptCost = Duration(milliseconds: attemptMs);

    final maxElapsedMs = (attemptMs * attemptsAllowed).clamp(
      minElapsed.inMilliseconds,
      maxElapsedCap.inMilliseconds,
    );

    // How many whole attempts actually fit in the granted window. On a hostile
    // profile the 300s cap binds first, so this drops back towards the floor.
    final maxAttempts = (maxElapsedMs ~/ attemptMs).clamp(3, 12);

    final baseDelayMs = t.effRttMs.clamp(250, 2000);
    final maxDelayMs = (t.effRttMs * 4).clamp(2000, 16000);

    return AdaptiveConnectionBudget._(
      conditions: conditions,
      attemptCost: attemptCost,
      maxElapsed: Duration(milliseconds: maxElapsedMs),
      maxAttempts: maxAttempts,
      baseDelay: Duration(milliseconds: baseDelayMs),
      maxDelay: Duration(milliseconds: maxDelayMs),
    );
  }

  /// The deadline a *successful* connect is expected to meet.
  ///
  /// [maxElapsed] tolerates [attemptsAllowed] attempts so that retries are
  /// possible; this bound tolerates roughly one. A call that connects only by
  /// consuming the whole budget is a defect the budget would otherwise hide, so
  /// callers assert against this value separately from PASS/FAIL.
  Duration get expectedConnectBy =>
      Duration(milliseconds: (attemptCost.inMilliseconds * 1.5).round());

  /// Modelled cost of ONE bounded sub-operation of a connect attempt.
  ///
  /// [roundTrips] is how many network round trips the operation consumes
  /// (1..[handshakeRoundTrips]); [detectionFloor] is dead time an upper
  /// layer needs to NOTICE a failed channel before those round trips can
  /// begin (e.g. a signaling liveness window) — zero when the operation
  /// starts on a channel already known live. The retransmit-ladder and
  /// serialization terms are carried whole, not pro-rated: a single lost
  /// flight waits the same doubling timers regardless of how many round
  /// trips follow, and the negotiation's bytes cross the same narrow pipe.
  ///
  /// Guaranteed `<= attemptCost + detectionFloor` — a sub-operation may
  /// never be granted more than the whole attempt plus its detection
  /// window. With `roundTrips == handshakeRoundTrips` and no floor it IS
  /// [attemptCost].
  Duration operationBudget({
    required int roundTrips,
    Duration detectionFloor = Duration.zero,
  }) {
    if (roundTrips < 1 || roundTrips > handshakeRoundTrips) {
      throw ArgumentError.value(
        roundTrips,
        'roundTrips',
        'must be in 1..$handshakeRoundTrips',
      );
    }
    final t = _terms(conditions);
    final rawMs =
        detectionFloor.inMilliseconds +
        (t.effRttMs * roundTrips * t.lossFactor).round() +
        t.retransmitMs +
        t.serializationMs +
        fixedCost.inMilliseconds;
    final capMs = attemptCost.inMilliseconds + detectionFloor.inMilliseconds;
    return Duration(milliseconds: math.min(rawMs, capMs));
  }

  /// The policy the call stack should run under these conditions. The
  /// provenance string rides into the policy's give-up reason, so a call
  /// that dies with `reconnect_exhausted` names the budget it was judged
  /// against instead of sending the reader back to the logs.
  ExponentialBackoffReconnectPolicy toReconnectPolicy() =>
      ExponentialBackoffReconnectPolicy(
        maxAttempts: maxAttempts,
        baseDelay: baseDelay,
        maxDelay: maxDelay,
        maxElapsed: maxElapsed,
        provenance:
            'budget: attemptCost ${attemptCost.inSeconds}s from '
            'rtt ${conditions.rtt.inMilliseconds}ms '
            'loss ${conditions.loss} '
            'bw ${conditions.bandwidthBps ?? "-"}',
      );

  /// Two-sided bound on a fixed emitter tick under [conditions], returned
  /// as a [SchedulerStepBound] — an admissible interval, or the reason none
  /// exists.
  ///
  /// The upper bound is a latency budget:
  /// `interactiveLatencyBudget - T_net - jitterBufferDelay`, where `T_net`
  /// is HALF of `conditions.rtt`. The 150 ms budget is one-way mouth-to-ear
  /// and a media frame crosses the network once; charging the full
  /// round-trip would only be right if playout waited on an
  /// acknowledgement cycle before rendering, which it does not.
  ///
  /// The lower bound is link capacity:
  /// `frameBits / (usableShareBps - offeredRateBps)` as a duration — the
  /// time the link's spare rate needs to carry one frame, i.e. the shortest
  /// tick at which the emitter does not outrun the share it was granted.
  ///
  /// UNLIKE every other budget in this class, nothing here is clamped to a
  /// floor or a ceiling — deliberately, not as an oversight to fix. The
  /// other budgets clamp because any value inside their range is still
  /// physically meaningful; here the admissible interval may simply not
  /// exist — a large part of the rtt 4..2000 ms x loss 0..0.9 grid lands in
  /// the two impossible cases — and clamping would manufacture a
  /// plausible-looking tick with no physical backing. So emptiness is
  /// established FIRST, and only a caller holding a
  /// [SchedulerStepAdmissible] may then clamp within `[minStep, maxStep]`
  /// to its hardware or configuration limits. The two bounds also measure
  /// different things — one a latency budget, one link capacity — so no
  /// single clamp policy could be correct for both.
  ///
  /// [offeredRateBps] is the wire rate the emitter will offer and
  /// [usableShareBps] the share of the link it may use, both in bits per
  /// second; [frameBits] is the bits one frame puts on the wire.
  SchedulerStepBound maxSchedulerStepFor(
    NetworkConditions conditions, {
    required int offeredRateBps,
    required int usableShareBps,
    required int frameBits,
  }) {
    // Capacity is decided first: with no spare rate the lower-bound
    // division has no denominator, so no interval can even be formed —
    // the link is oversubscribed before latency enters the question.
    if (offeredRateBps >= usableShareBps) {
      return SchedulerStepImpossibleForCapacity(
        offeredRateBps: offeredRateBps,
        usableShareBps: usableShareBps,
        shortfallBps: offeredRateBps - usableShareBps,
      );
    }

    // ESTIMATE: the one-way delay is taken as half the round-trip, which
    // assumes a symmetric path. A one-way delay measurement from the
    // transport replaces this term when one exists.
    final Duration oneWayNetwork = conditions.rtt ~/ 2;

    final Duration maxStep =
        interactiveLatencyBudget - oneWayNetwork - jitterBufferDelay;
    if (maxStep <= Duration.zero) {
      return SchedulerStepImpossibleForResponsiveness(
        interactiveBudget: interactiveLatencyBudget,
        oneWayNetwork: oneWayNetwork,
        jitterBuffer: jitterBufferDelay,
        resultingStep: maxStep,
      );
    }

    final int spareBps = usableShareBps - offeredRateBps;
    final Duration minStep = Duration(
      microseconds: (frameBits * Duration.microsecondsPerSecond / spareBps)
          .round(),
    );

    if (minStep > maxStep) {
      return SchedulerStepImpossibleForResponsiveness(
        interactiveBudget: interactiveLatencyBudget,
        oneWayNetwork: oneWayNetwork,
        jitterBuffer: jitterBufferDelay,
        resultingStep: maxStep,
      );
    }

    return SchedulerStepAdmissible(minStep: minStep, maxStep: maxStep);
  }

  /// Wire cost of one heartbeat round (frame out, ack back) over the WSS
  /// signaling socket, headers included. ESTIMATE (~500 B both directions);
  /// replace with a capture when one exists. Used only to keep the keepalive
  /// stream inside its share of a narrow link, where overstating it merely
  /// slows heartbeats a little.
  static const int heartbeatWireBits = 4000;

  /// Fraction of a known link the keepalive stream may claim. The signaling
  /// control plane as a whole gets 30% (see `OpusWireBudget`); heartbeats
  /// are only one of its tenants, alongside acks, RTCP and ICE consent.
  static const double heartbeatLinkShare = 0.05;

  /// Signaling keepalive / liveness / dial timing under [conditions].
  ///
  /// The floors are the caller's healthy-link constants, so an unshaped run
  /// keeps its historic behaviour bit for bit; a shaped link only ever gets
  /// MORE patience — the same contract as the connect budget itself. The
  /// result is a record: call_core owns the arithmetic, the signaling layer
  /// owns its config type, and neither imports the other for this.
  ///
  /// Derivation (measured 2026-08-06, T2 loss60/extreme livelock): the e2e
  /// config declared a socket dead after a FIXED 8 s without inbound
  /// traffic. Signaling is TCP: under loss the frames are not lost, they are
  /// DELAYED by the retransmit doubling ladder — three consecutive drops at
  /// 60% per-direction loss (probability 0.216 per segment) already stall a
  /// segment ~7 s, and deeper runs blow past any fixed window routinely. So
  /// a LIVE socket was declared dead nearly every window, each declaration
  /// forced a reconnect plus ICE restart, and no connect attempt ever ran
  /// to completion: the call died with the budget exhausted in
  /// `phase=reconnecting`. The window must therefore cover the DELAY a live
  /// link can legitimately produce:
  ///
  ///   heartbeat = max(floor, effRtt, heartbeatWireBits / (share x bw))
  ///   liveness  = max(floor, 2 x heartbeat + retransmitLadder
  ///                          + effRtt x lossFactor)
  ///   dial      = max(floor, operationBudget(roundTrips: 4))
  ///               (a dial is TCP 1 + TLS 2 + WS upgrade 1 on the same link)
  ///   attempts  = max(floor, ceil(maxElapsed / dial))
  ///               (the socket layer must not give up before the call-level
  ///               budget does)
  ///
  /// Known bound, recorded not hidden: a genuinely blackholed socket on the
  /// hostile profiles now costs liveness + dial (~140 s on 60% loss) before
  /// an ICE restart can even start. A dead TCP socket normally surfaces as
  /// an error instead of silence, which bypasses the liveness timer — but a
  /// silent blackhole under heavy loss is detected slowly BY DESIGN, because
  /// the only thing distinguishing it from a live lossy link is time.
  ({
    Duration heartbeatInterval,
    Duration livenessTimeout,
    Duration connectTimeout,
    int maxReconnectAttempts,
    Duration messageLifetime,
  })
  signalingTiming({
    required Duration heartbeatFloor,
    required Duration livenessFloor,
    required Duration connectTimeoutFloor,
    required int reconnectAttemptsFloor,
    Duration messageLifetimeFloor = const Duration(minutes: 2),
  }) {
    final t = _terms(conditions);
    final bw = conditions.bandwidthBps;
    final hbBandwidthMs = (bw == null || bw <= 0)
        ? 0
        : (heartbeatWireBits * 1000 / (heartbeatLinkShare * bw)).round();
    final hbMs = [
      heartbeatFloor.inMilliseconds,
      t.effRttMs,
      hbBandwidthMs,
    ].reduce(math.max);
    final liveMs = math.max(
      livenessFloor.inMilliseconds,
      2 * hbMs + t.retransmitMs + (t.effRttMs * t.lossFactor).round(),
    );
    // The dial bound is the FLOOR, deliberately NOT derived upward. A dial
    // is the one operation where retrying beats waiting: each fresh TCP
    // connection is an independent sample, a handshake that lost an early
    // flight sits behind doubling RTOs and rarely un-stalls, and
    // abandoning it costs nothing that patience would save. Wire-measured
    // 2026-08-07 (loss60 signaling capture): with a derived 72 s dial
    // bound the client dialed in exact 72 s clockwork and ZERO of eight
    // handshakes completed; survival on a lossy link is dial CADENCE. The
    // patience budget lives at the attempt level (attemptCost/maxElapsed),
    // never per dial.
    final dialMs = connectTimeoutFloor.inMilliseconds;
    final attempts = math.max(
      reconnectAttemptsFloor,
      (maxElapsed.inMilliseconds / dialMs).ceil(),
    );
    // The outbox never gives up before the reconnect budget does. Measured
    // 2026-08-07 (loss60): a fixed 2 min lifetime expired a legitimate
    // in-flight send, the expiry was treated as a recovery trigger, and
    // the recovery restarted the negotiation the message belonged to.
    // maxElapsed is capped (maxElapsedCap), so this cannot grow unbounded.
    final lifetimeMs = math.max(
      messageLifetimeFloor.inMilliseconds,
      maxElapsed.inMilliseconds,
    );
    return (
      heartbeatInterval: Duration(milliseconds: hbMs),
      livenessTimeout: Duration(milliseconds: liveMs),
      connectTimeout: Duration(milliseconds: dialMs),
      maxReconnectAttempts: attempts,
      messageLifetime: Duration(milliseconds: lifetimeMs),
    );
  }

  @override
  String toString() =>
      'AdaptiveConnectionBudget('
      'attemptCost: ${attemptCost.inMilliseconds}ms, '
      'maxElapsed: ${maxElapsed.inSeconds}s, '
      'maxAttempts: $maxAttempts, '
      'baseDelay: ${baseDelay.inMilliseconds}ms, '
      'maxDelay: ${maxDelay.inMilliseconds}ms)';
}
