/// Six-rung status ladder for the letter's own path, built purely from
/// the fabric's live [ConnectivitySnapshot] and the letter probe's own
/// signals. No new probe runs here, no new lane, no new timer — this
/// only reads what the courier already measured. "بسته" (closed) is a
/// reading, not a scanner: [LetterLadderStatus.detail] reports the
/// existing queue and the existing next-probe schedule; it starts
/// nothing new.
library;

import 'package:adaptive_transport/adaptive_transport.dart'
    show ForgedAnswerException, TxtProbeOutcome;
import 'package:connection_orchestrator/connection_orchestrator.dart'
    show ConnectivitySnapshot, LaneStatus, ResilientLaneIds;

import 'letter_rung_ladder.dart' show DoorResolverLadder;

/// Ordered rungs, best (checked last) to worst (checked first).
enum LetterLadderRung {
  /// A live-call-capable lane AND the door are both healthy.
  normal,

  /// A live-call-capable lane is up, but not every non-door lane is
  /// (one is down) — the letter still has a healthy path.
  limited,

  /// No live-call-capable lane has a path, but the door still does
  /// (score-eligible, just not freshly proven this round, reason 'dead')
  /// — or a live lane is up but degraded, its score below the "freshly
  /// answering door" ceiling this codebase already documents, 0.15 (see
  /// letter_courier.dart's `_deadAtOrBelow` note on a fresh door sitting
  /// at 0.01–0.15, reason 'slow'). When nothing — not even the door —
  /// has a path, the reading is [closed], not weak.
  weak,

  /// No live-call-capable lane has a path, but THIS round's own probe
  /// confirmed the door reached the responder — a stronger, fresher
  /// signal than the fabric's score alone.
  withCourier,

  /// The door's recorded history shows a MIX of hits and misses on
  /// this network: it answers, just not every time.
  halfClosed,

  /// This round's own probe found no nonce logged anywhere (reason
  /// 'nonce'), or no lane at all has a path — not even the door (reason
  /// 'dead'). Either way the letter is queued.
  closed,
}

/// The one word the banner and the director both show for a rung — a
/// single vocabulary, so the two never disagree.
extension LetterLadderRungBanner on LetterLadderRung {
  String get bannerName => switch (this) {
    LetterLadderRung.normal => 'normal',
    LetterLadderRung.limited => 'limited',
    LetterLadderRung.weak => 'weak',
    LetterLadderRung.withCourier => 'configured',
    LetterLadderRung.halfClosed => 'half',
    LetterLadderRung.closed => 'closed',
  };
}

/// One classified reading.
class LetterLadderStatus {
  const LetterLadderStatus(this.rung, {this.reason = '', this.detail = ''});

  final LetterLadderRung rung;

  /// One word, drawn from the same fabric predicate that chose [rung] —
  /// why this reading is what it is, never a sentence and never a new
  /// metric: 'ok' / 'down' / 'slow' / 'dead' / 'door' / 'mixed' / 'nonce',
  /// plus 'late' when the courier's degraded latch pulls a later healthy
  /// reading back down. Empty only on a default-constructed status.
  final String reason;

  /// Populated only for [LetterLadderRung.closed]: queue size and when
  /// the existing watch will probe again — never a reason to probe
  /// sooner.
  final String detail;

  @override
  String toString() =>
      detail.isEmpty ? rung.bannerName : '${rung.bannerName} · $detail';
}

/// The fabric's line between a lane with a path and one without:
/// `deadLaneScore` is −1.0 minus the cost penalty, so every dead lane
/// scores at or below −1.0. The courier's selection and this ladder read
/// the SAME constant — a third ranking must not disagree with the two.
const double letterDeadAtOrBelow = -1.0;

/// Eligible and above [letterDeadAtOrBelow].
bool letterLaneHasPath(LaneStatus lane) =>
    lane.eligible && lane.score > letterDeadAtOrBelow;

/// Classifies [snapshot] — plus [lastProbe] (the most recent door probe
/// this courier ran, or null when none ran this round) and
/// [doorHistory] (the door ladder's own wins/attempts, as
/// `DoorResolverLadder.history` already returns) — into one rung. Pure:
/// takes no action, reads no clock of its own.
LetterLadderStatus classifyLetterLadder({
  required ConnectivitySnapshot snapshot,
  TxtProbeOutcome? lastProbe,
  Map<String, ({int wins, int attempts})> doorHistory = const {},
  int queueWaiting = 0,
  Duration nextProbeIn = Duration.zero,
}) {
  final nonDoor = [
    for (final lane in snapshot.lanes)
      if (lane.id != ResilientLaneIds.txtQuery) lane,
  ];
  final nonDoorUp = nonDoor.where(letterLaneHasPath).length;
  final liveReachable = nonDoorUp > 0;
  final slowRelay = nonDoor.any((l) => letterLaneHasPath(l) && l.score < 0.15);
  final doorReliability = DoorResolverLadder.totals(doorHistory).ratio;
  // The door's own score, read through the same line every ranking uses:
  // at or below [letterDeadAtOrBelow] the valve's own health is 0 — its
  // own failed sends, the same evidence class as a probe miss, no new
  // probe of its own.
  final doorHasPath = snapshot.lanes.any(
    (l) => l.id == ResilientLaneIds.txtQuery && letterLaneHasPath(l),
  );
  final queueDetail =
      '$queueWaiting waiting · next probe in ${nextProbeIn.inSeconds}s';

  // Worst rung first: the first pattern that holds is the reading. The
  // one-word [LetterLadderStatus.reason] on each arm names the fabric
  // predicate that fired — the same score, read once, never a new metric.
  final status = switch ((lastProbe?.reachedServer, doorReliability)) {
    // This round's own probe found no nonce logged anywhere. A resolver
    // that answered with a forgery is named apart from one that was silent.
    (false, _) => LetterLadderStatus(
      LetterLadderRung.closed,
      reason:
          (lastProbe?.answers.any((a) => a.error is ForgedAnswerException) ??
              false)
          ? 'forged'
          : 'nonce',
      detail: queueDetail,
    ),
    // No live lane has a path AND the door has none either: nothing is
    // reachable right now, so the letter is parked — closed, not "weak".
    _ when !liveReachable && !doorHasPath => LetterLadderStatus(
      LetterLadderRung.closed,
      reason: 'dead',
      detail: queueDetail,
    ),
    // Only when NO live lane carries the letter does mixed door history set
    // the rung itself (halfClosed). With a live lane up, mixed history is a
    // reason modifier layered after the switch — never a rung of its own.
    (_, final ratio?) when !liveReachable && ratio > 0 && ratio < 1 =>
      const LetterLadderStatus(LetterLadderRung.halfClosed, reason: 'mixed'),
    (true, _) when !liveReachable => const LetterLadderStatus(
      LetterLadderRung.withCourier,
      reason: 'door',
    ),
    _ when !liveReachable || slowRelay => LetterLadderStatus(
      LetterLadderRung.weak,
      reason: !liveReachable ? 'dead' : 'slow',
    ),
    _ when nonDoorUp < nonDoor.length => const LetterLadderStatus(
      LetterLadderRung.limited,
      reason: 'down',
    ),
    _ => const LetterLadderStatus(LetterLadderRung.normal, reason: 'ok'),
  };
  // Owner decision 2026-10-04: a healthy live lane keeps the winner and its
  // own rung; flaky/mixed door history (0 < ratio < 1) only lowers the
  // reason word to 'mixed'. It never demotes a live lane's rung and never
  // overrides a 'closed' reading — nonce / all-dead still outrank.
  final mixedDoor =
      doorReliability != null && doorReliability > 0 && doorReliability < 1;
  if (liveReachable && mixedDoor && status.rung != LetterLadderRung.closed) {
    return LetterLadderStatus(
      status.rung,
      reason: 'mixed',
      detail: status.detail,
    );
  }
  return status;
}
