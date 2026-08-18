/// Champion/challenger generation arbitration («هوشمندی v4» pillar 3).
///
/// The replay benchmark graduated from a development tool to the app's
/// own permanent loop: the app periodically (nightly, on power) trains a
/// CLONE of its live brains on its own recorded history and promotes the
/// clone only when the measured score rose — otherwise the clone is
/// discarded and the champion generation stays untouched on disk. This
/// file holds the pure, deterministic pieces of that loop:
///
/// - [CallHistoryReplay]: scores a [BrainSet] against the device's own
///   [CallHistoryRecord]s — the on-device counterpart of the rig
///   benchmark's calibrator component. Predict-before-train per record,
///   per-network running-median budgets, relative-error score
///   1/(1+meanError). In-sample by design, exactly like the rig
///   benchmark's stated honesty note: the rise across epochs, not the
///   absolute number, is the signal.
/// - [decideGeneration]: the promotion rule — strict rise or rollback.
///
/// All IO (generation directories, promotion log files, power gating)
/// stays in the app layer; nothing here touches a disk or a clock.
library;

import 'call_history.dart';
import 'replay_benchmark.dart' show BrainSet;

/// Scores one [BrainSet] against recorded personal call history.
///
/// For each call, the deterministic budget is the running median of the
/// PREVIOUS connect times on the same network identity (no budget until
/// one prior call exists — the first call on a network scores nothing,
/// mirroring "no voice without samples"). The calibrator predicts, the
/// error is |budget*correction - actual|/actual, and only then does the
/// calibrator train on the pair. One [scoreEpoch] call = one full pass;
/// brains carry their learning across calls and across epochs.
class CallHistoryReplay {
  CallHistoryReplay({required List<CallHistoryRecord> records})
    : _records = List.of(records);

  final List<CallHistoryRecord> _records;

  /// How many records carried a scoreable (budget, actual) pair on the
  /// last [scoreEpoch] call. 0 means the score was vacuous (fresh
  /// device, single call per network) — the caller must not promote on
  /// a vacuous score.
  int lastScoredCount = 0;

  /// Runs one predict-before-train pass; returns 1/(1+meanRelError),
  /// or 0.0 when nothing was scoreable.
  double scoreEpoch(BrainSet brains) {
    final priorConnects = <String, List<int>>{};
    var errorSum = 0.0;
    var count = 0;
    for (final record in _records) {
      final connect = record.connectMs;
      if (connect <= 0) continue;
      final prior = priorConnects.putIfAbsent(
        record.networkIdentityHash,
        () => [],
      );
      if (prior.isNotEmpty) {
        final budget = _median(prior);
        final corrected = budget * brains.calibrator.correction();
        errorSum += (corrected - connect).abs() / connect;
        count += 1;
        brains.calibrator.observe(
          predictedMs: budget,
          actualMs: connect.toDouble(),
        );
      }
      // Sorted insertion keeps the median O(log n) to find, and the
      // list is per-network so it stays call-history sized.
      _insertSorted(prior, connect);
    }
    lastScoredCount = count;
    if (count == 0) return 0.0;
    // 1/(1+meanError): the rig benchmark's calibrator scale.
    return 1 / (1 + errorSum / count);
  }

  static void _insertSorted(List<int> sorted, int value) {
    var lo = 0;
    var hi = sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (sorted[mid] < value) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    sorted.insert(lo, value);
  }

  static double _median(List<int> sorted) {
    final n = sorted.length;
    // Even count: mean of the two middle values (standard median).
    return n.isOdd
        ? sorted[n ~/ 2].toDouble()
        : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2.0;
  }
}

/// The outcome of one champion/challenger round, ready for the
/// promotion log. Serializable so the log is inspectable forever.
class GenerationDecision {
  const GenerationDecision({
    required this.promoted,
    required this.championScore,
    required this.challengerScore,
    required this.scoredCount,
    required this.whenMs,
    required this.reason,
  });

  /// True = the trained challenger becomes the new champion.
  final bool promoted;

  /// The score walking in (epoch 0 of this round's data).
  final double championScore;

  /// The score after training (final epoch of this round's data).
  final double challengerScore;

  /// How many history records actually contributed to the scores.
  final int scoredCount;

  /// Caller-injected wall-clock ms (this library reads no clock).
  final int whenMs;

  /// Literal statement of the deciding comparison, numbers included.
  final String reason;

  Map<String, Object?> toJson() => {
    'promoted': promoted,
    'championScore': championScore,
    'challengerScore': challengerScore,
    'scoredCount': scoredCount,
    'whenMs': whenMs,
    'reason': reason,
  };

  /// Null on a malformed map (the log skips the entry).
  static GenerationDecision? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final promoted = raw['promoted'];
    final champion = raw['championScore'];
    final challenger = raw['challengerScore'];
    final scored = raw['scoredCount'];
    final when = raw['whenMs'];
    final reason = raw['reason'];
    if (promoted is! bool ||
        champion is! num ||
        challenger is! num ||
        scored is! int ||
        when is! int ||
        reason is! String) {
      return null;
    }
    return GenerationDecision(
      promoted: promoted,
      championScore: champion.toDouble(),
      challengerScore: challenger.toDouble(),
      scoredCount: scored,
      whenMs: when,
      reason: reason,
    );
  }
}

/// The promotion rule: a challenger is promoted ONLY on a strict score
/// rise over a non-vacuous sample. Ties, drops, and vacuous rounds all
/// keep the champion — the previous generation stays untouched.
GenerationDecision decideGeneration({
  required double championScore,
  required double challengerScore,
  required int scoredCount,
  required int nowMs,
}) {
  final bool promoted;
  final String reason;
  if (scoredCount <= 0) {
    promoted = false;
    reason = 'scoredCount 0: nothing measurable, champion kept';
  } else if (challengerScore > championScore) {
    promoted = true;
    reason =
        'challenger ${challengerScore.toStringAsFixed(4)} > '
        'champion ${championScore.toStringAsFixed(4)} over '
        '$scoredCount records';
  } else {
    promoted = false;
    reason =
        'challenger ${challengerScore.toStringAsFixed(4)} <= '
        'champion ${championScore.toStringAsFixed(4)} over '
        '$scoredCount records: rollback';
  }
  return GenerationDecision(
    promoted: promoted,
    championScore: championScore,
    challengerScore: challengerScore,
    scoredCount: scoredCount,
    whenMs: nowMs,
    reason: reason,
  );
}
