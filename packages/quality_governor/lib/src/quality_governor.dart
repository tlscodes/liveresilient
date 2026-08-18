/// Decides, on every voice tick, which rung of the quality ladder to run at.
///
/// THE INVARIANT, and the reason this class exists in this shape:
///
///   **Voice is never cut.** The governor may lower quality, drop shaping,
///   drop redundancy, and lower the frame rate. It may NEVER return "do not
///   send". There is no code path here that produces a stop, and a test
///   asserts that across every input the class accepts — including inputs that
///   are nonsense, and including a completely dead link.
///
/// That invariant is what makes the design tractable. The hard question in an
/// adaptive scheme is what to do when nothing fits the budget; here the answer
/// is fixed in advance: fall to the survival rung and keep talking. Shaping,
/// redundancy and frame rate are negotiable. Continuity is not.
///
/// WHY THE DECISION IS ARITHMETIC AND NOT A MODEL. The decision runs on the
/// send path, inside a 20 ms tick, so its budget is well under a millisecond.
/// The repo's on-device assistant package is a PORT with no engine behind it
/// (on_device_assistant/llm_backed_assistant.dart:17 declares an interface;
/// nothing implements it, no weights ship, and no latency figure exists
/// anywhere in that package). Putting the control decision there would make
/// the call depend on something that does not exist. The assistant's role is
/// to EXPLAIN the state to the user, which is what its `explainConnectivity`
/// is for — not to make it.
///
/// WHAT IT OBSERVES, and the trap in it. The input is the same statistic the
/// path selector already ranks on: `ChannelHealth.score()`. That score is a
/// statistic of THIS CHANNEL'S OWN DELIVERY ATTEMPTS
/// (adaptive_transport transport_channel.dart:119-130 folds `SendResult`
/// outcomes into an EWMA) — it is not an independent probe of the network. So
/// in the absence of traffic it goes stale, and a decision taken on a stale
/// score is a decision taken on the past. The governor therefore takes sample
/// AGE as an explicit input and refuses to climb on stale evidence.
library;

import 'quality_rung.dart';

/// What the governor was told about the link at one tick.
class LinkObservation {
  const LinkObservation({
    required this.nowMs,
    required this.score,
    required this.observedWireBps,
    required this.budgetBps,
    required this.sampleAgeMs,
    this.pathDegraded = false,
  });

  /// Monotonic clock in milliseconds, supplied by the caller. The governor
  /// holds no clock of its own so its behavior is reproducible in tests.
  final int nowMs;

  /// `ChannelHealth.score()` of the currently selected path, 0.0 to 1.0.
  /// A statistic of recent delivery outcomes, not a network probe.
  final double score;

  /// Bytes per second actually observed on the wire, from the trace recorder.
  final double observedWireBps;

  /// Bytes per second the caller is willing to spend on voice.
  ///
  /// NOTE ON WHERE THIS COMES FROM. It is NOT the 200-500 B/s figure in the
  /// audit: that is the spare MEDIA budget for background transfers during
  /// silence (connection_orchestrator media_queue.dart:1-8, :53-57), and that
  /// class never touches the voice path. The voice path has no configured
  /// budget anywhere in this repo, so the caller must state one. Conflating
  /// the two was a real error made during this work and is recorded here so it
  /// is not repeated.
  final double budgetBps;

  /// How old the newest delivery sample is. A score computed from samples that
  /// are seconds old describes a link that may no longer exist.
  final int sampleAgeMs;

  /// Set when the transport reported the path unusable.
  final bool pathDegraded;
}

/// The governor's output for one tick.
class QualityDecision {
  const QualityDecision({
    required this.rung,
    required this.rungIndex,
    required this.reason,
    required this.changed,
  });

  final QualityRung rung;
  final int rungIndex;

  /// Plain sentence naming why this rung was chosen. Written for the audit
  /// trail and for the user-facing explanation; never a code.
  final String reason;

  /// Whether this tick moved the rung.
  final bool changed;

  /// Always true. Present so callers can express the invariant in their own
  /// assertions rather than trusting a comment.
  bool get keepsVoiceFlowing => true;
}

/// Tuning constants. Every one of them is a policy choice, so each carries the
/// reason it has the value it has.
class GovernorConfig {
  const GovernorConfig({
    this.downgradeAfterBadTicks = 3,
    this.upgradeAfterGoodTicks = 25,
    this.minDwellMs = 2000,
    this.staleSampleMs = 3000,
    this.badScore = 0.25,
    this.goodScore = 0.6,
    this.budgetHeadroom = 0.9,
    this.penaltyBoxMs = 60000,
  });

  /// Downgrade quickly: three consecutive bad ticks. Being slow to shed load
  /// on a failing link is how a call dies.
  final int downgradeAfterBadTicks;

  /// Upgrade slowly: twenty-five consecutive good ticks. Deliberately
  /// asymmetric with the downgrade — a symmetric loop oscillates, and the cost
  /// of climbing too early is a fresh outage, while the cost of climbing late
  /// is only a few seconds of lower quality.
  final int upgradeAfterGoodTicks;

  /// Minimum time at a rung before any further move. Stops a burst of
  /// alternating evidence from walking the ladder every tick.
  final int minDwellMs;

  /// Beyond this age a delivery sample no longer describes the present link,
  /// so it may justify a downgrade but never an upgrade.
  final int staleSampleMs;

  /// Score at or below which a tick counts as bad.
  final double badScore;

  /// Score at or above which a tick counts as good. The gap between badScore
  /// and goodScore is the dead band: without it the two counters would both
  /// advance on the same middling evidence.
  final double goodScore;

  /// Fraction of the budget a rung must fit inside to be considered
  /// affordable. Below 1.0 because a rung that exactly fills the budget leaves
  /// nothing for the retransmissions that arrive precisely when the link is
  /// worst.
  final double budgetHeadroom;

  /// How long a rung stays marked unhelpful after a downgrade from it failed
  /// to improve matters. Prevents climbing back into a rung that just failed.
  final int penaltyBoxMs;
}

class QualityGovernor {
  QualityGovernor({
    this.config = const GovernorConfig(),
    List<QualityRung>? ladder,
    int? startIndex,
  }) : _ladder = ladder ?? qualityLadder,
       _index = startIndex ?? survivalRungIndex {
    if (_ladder.isEmpty) {
      throw ArgumentError(
        'the ladder must have at least one rung; without one '
        'there is nowhere to fall back to and voice could be cut',
      );
    }
    if (_index < 0 || _index >= _ladder.length) {
      throw ArgumentError.value(_index, 'startIndex', 'outside the ladder');
    }
  }

  final GovernorConfig config;
  final List<QualityRung> _ladder;

  int _index;
  int _badTicks = 0;
  int _goodTicks = 0;
  int _lastChangeMs = -1 << 40;

  /// Rung name → the time until which it is considered unhelpful.
  final Map<String, int> _penaltyUntilMs = {};

  /// The rung currently in force.
  QualityRung get current => _ladder[_index];

  /// Index of the rung currently in force.
  int get currentIndex => _index;

  /// The ladder this governor walks, in cost order.
  List<QualityRung> get ladder => List.unmodifiable(_ladder);

  bool _affordable(QualityRung rung, double budgetBps) {
    final cost = rung.measuredWireBps;
    // An unmeasured rung is never assumed affordable. Guessing here would put
    // the call on a configuration whose cost nobody knows.
    if (cost == null) return false;
    return cost <= budgetBps * config.budgetHeadroom;
  }

  bool _inPenaltyBox(QualityRung rung, int nowMs) =>
      (_penaltyUntilMs[rung.name] ?? -1) > nowMs;

  /// Highest-quality rung that fits the budget and is not in the penalty box.
  /// Returns [survivalRungIndex] when nothing fits — never -1, because "no
  /// rung" would mean "do not send", and that is the one answer this class
  /// does not have.
  int _bestAffordableIndex(double budgetBps, int nowMs) {
    var best = survivalRungIndex;
    for (var i = 0; i < _ladder.length; i++) {
      final rung = _ladder[i];
      if (_inPenaltyBox(rung, nowMs)) continue;
      if (!_affordable(rung, budgetBps)) continue;
      // Ladder is ordered by cost, so a later affordable rung is better.
      if (i > best) best = i;
    }
    return best;
  }

  QualityDecision _stay(String reason) => QualityDecision(
    rung: current,
    rungIndex: _index,
    reason: reason,
    changed: false,
  );

  QualityDecision _moveTo(int index, int nowMs, String reason) {
    final changed = index != _index;
    if (changed) {
      _index = index;
      _lastChangeMs = nowMs;
      _badTicks = 0;
      _goodTicks = 0;
    }
    return QualityDecision(
      rung: current,
      rungIndex: _index,
      reason: reason,
      changed: changed,
    );
  }

  /// One tick of the control loop.
  ///
  /// Never returns a decision that stops sending. The worst outcome available
  /// to it is the survival rung.
  QualityDecision observe(LinkObservation o) {
    // A degraded path is not evidence to weigh — it is a fact to act on, and
    // it bypasses the dwell timer because waiting two seconds on a dead path
    // is exactly the case this whole design exists to avoid.
    if (o.pathDegraded) {
      return _moveTo(
        survivalRungIndex,
        o.nowMs,
        'the transport reported the path degraded, so quality drops to the '
        'survival rung immediately; voice keeps flowing',
      );
    }

    // A rung the link can no longer pay for is abandoned at once, for the same
    // reason: the budget is not a preference, it is what the link will carry.
    if (!_affordable(current, o.budgetBps)) {
      final target = _bestAffordableIndex(o.budgetBps, o.nowMs);
      if (target != _index) {
        return _moveTo(
          target,
          o.nowMs,
          'the current rung costs more than the stated budget allows, so the '
          'highest affordable rung takes over',
        );
      }
      // Nothing affordable and already there: stay and keep talking.
      return _stay(
        'no rung fits the budget, so the survival rung continues; lowering '
        'quality further is not possible and stopping is not an option',
      );
    }

    final stale = o.sampleAgeMs > config.staleSampleMs;
    final bad = o.score <= config.badScore;
    final good = o.score >= config.goodScore && !stale;

    if (bad) {
      _badTicks++;
      _goodTicks = 0;
    } else if (good) {
      _goodTicks++;
      _badTicks = 0;
    } else {
      // The dead band: middling or stale evidence advances neither counter.
      // Without this, a link hovering between the thresholds would walk the
      // ladder continuously.
      _badTicks = 0;
      _goodTicks = 0;
    }

    final dwelt = o.nowMs - _lastChangeMs >= config.minDwellMs;

    if (_badTicks >= config.downgradeAfterBadTicks &&
        _index > survivalRungIndex) {
      // Downgrading ignores the dwell timer deliberately. Dwell exists to stop
      // oscillation on the way UP; making it also delay shedding load would
      // turn a safety feature into a cause of outages.
      final from = current;
      final target = _index - 1;
      _penaltyUntilMs[from.name] = o.nowMs + config.penaltyBoxMs;
      return _moveTo(
        target,
        o.nowMs,
        'delivery has been poor for ${config.downgradeAfterBadTicks} '
        'consecutive ticks, so quality steps down one rung',
      );
    }

    if (_goodTicks >= config.upgradeAfterGoodTicks && dwelt) {
      final target = _bestAffordableIndex(o.budgetBps, o.nowMs);
      if (target > _index) {
        return _moveTo(
          _index + 1,
          o.nowMs,
          'delivery has been good for ${config.upgradeAfterGoodTicks} '
          'consecutive ticks and the budget allows more, so quality steps up '
          'one rung',
        );
      }
    }

    if (stale) {
      return _stay(
        'the newest delivery sample is ${o.sampleAgeMs} ms old, which is too '
        'stale to justify climbing; the current rung continues',
      );
    }

    return _stay('conditions are unchanged; the current rung continues');
  }
}
