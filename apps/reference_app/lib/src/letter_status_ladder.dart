/// Six-rung status ladder for the letter's own path, built purely from
/// the fabric's live [ConnectivitySnapshot] and the letter probe's own
/// signals. No new probe runs here, no new lane, no new timer — this
/// only reads what the courier already measured. "بسته" (closed) is a
/// reading, not a scanner: [LetterLadderStatus.detail] reports the
/// existing queue and the existing next-probe schedule; it starts
/// nothing new.
library;

import 'package:adaptive_transport/adaptive_transport.dart'
    show TxtProbeOutcome;
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

  /// No live-call-capable lane has a path, and this round's own probe
  /// did not confirm the door either (it may be score-eligible, just
  /// not freshly proven) — or a live lane is up but degraded (its
  /// score is below the "freshly answering door" ceiling this codebase
  /// already documents, 0.15 — see letter_courier.dart's
  /// `_deadAtOrBelow` note on a fresh door sitting at 0.01–0.15).
  weak,

  /// No live-call-capable lane has a path, but THIS round's own probe
  /// confirmed the door reached the responder — a stronger, fresher
  /// signal than the fabric's score alone.
  withCourier,

  /// The door's recorded history shows a MIX of hits and misses on
  /// this network: it answers, just not every time.
  halfClosed,

  /// This round's own probe found no nonce logged anywhere; the letter
  /// is queued.
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
  const LetterLadderStatus(this.rung, {this.detail = ''});

  final LetterLadderRung rung;

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

bool _hasPath(LaneStatus lane) => letterLaneHasPath(lane);

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
  final nonDoorUp = nonDoor.where(_hasPath).length;
  final liveReachable = nonDoorUp > 0;
  final slowRelay = nonDoor.any((l) => _hasPath(l) && l.score < 0.15);

  final doorReliability = DoorResolverLadder.totals(doorHistory).ratio;

  if (lastProbe != null && !lastProbe.reachedServer) {
    return LetterLadderStatus(
      LetterLadderRung.closed,
      detail:
          '$queueWaiting waiting · next probe in '
          '${nextProbeIn.inSeconds}s',
    );
  }
  if (doorReliability != null && doorReliability > 0 && doorReliability < 1) {
    return const LetterLadderStatus(LetterLadderRung.halfClosed);
  }
  if (!liveReachable && lastProbe?.reachedServer == true) {
    return const LetterLadderStatus(LetterLadderRung.withCourier);
  }
  if (!liveReachable || slowRelay) {
    return const LetterLadderStatus(LetterLadderRung.weak);
  }
  if (nonDoorUp < nonDoor.length) {
    return const LetterLadderStatus(LetterLadderRung.limited);
  }
  return const LetterLadderStatus(LetterLadderRung.normal);
}
