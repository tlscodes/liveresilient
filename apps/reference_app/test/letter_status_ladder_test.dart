// One test per rung of the six-state ladder, each built from the
// smallest snapshot/probe/history combination that hits exactly that
// rung — no fabric, no socket, no clock.
import 'package:adaptive_transport/adaptive_transport.dart'
    show TxtProbeAnswer, TxtProbeOutcome;
import 'package:connection_orchestrator/connection_orchestrator.dart'
    show ConnectivitySnapshot, FabricMode, LaneStatus, ResilientLaneIds;
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/letter_status_ladder.dart';

LaneStatus lane(String id, double score, {bool eligible = true}) =>
    LaneStatus(id: id, eligible: eligible, score: score);

ConnectivitySnapshot snap(
  List<LaneStatus> lanes, {
  FabricMode mode = FabricMode.live,
}) => ConnectivitySnapshot(
  mode: mode,
  lanes: lanes,
  bestLaneId: lanes.isEmpty ? null : lanes.first.id,
  pendingBundles: 0,
  atMs: 0,
);

TxtProbeOutcome reached() => const TxtProbeOutcome(
  groupId: 'g',
  answers: [
    TxtProbeAnswer(
      index: 0,
      label: 'udp53:8.8.8.8:53',
      nonce: 'aa',
      winnerNonce: 'aa',
      rank: 1,
    ),
  ],
  winnerIndex: 0,
);

TxtProbeOutcome notReached() => const TxtProbeOutcome(
  groupId: 'g',
  answers: [TxtProbeAnswer(index: 0, label: 'udp53:8.8.8.8:53', nonce: 'aa')],
  winnerIndex: null,
);

void main() {
  test('normal: a live lane and the door both healthy', () {
    final status = classifyLetterLadder(
      snapshot: snap([
        lane(ResilientLaneIds.webSocketRelay, 0.9),
        lane(ResilientLaneIds.httpLongPoll, 0.8),
        lane(ResilientLaneIds.txtQuery, 0.6),
      ]),
    );
    expect(status.rung, LetterLadderRung.normal);
  });

  test('limited: one non-door lane is dead, the other still healthy', () {
    final status = classifyLetterLadder(
      snapshot: snap([
        lane(ResilientLaneIds.webSocketRelay, 0.9),
        lane(ResilientLaneIds.httpLongPoll, -1.10), // dead
        lane(ResilientLaneIds.txtQuery, 0.6),
      ]),
    );
    expect(status.rung, LetterLadderRung.limited);
  });

  test('weak: no live lane at all, no probe confirmation this round', () {
    final status = classifyLetterLadder(
      snapshot: snap([
        lane(ResilientLaneIds.webSocketRelay, -1.05),
        lane(ResilientLaneIds.httpLongPoll, -1.10),
        lane(ResilientLaneIds.txtQuery, -1.15),
      ]),
    );
    expect(status.rung, LetterLadderRung.weak);
  });

  test(
    'weak: a live lane is up but slow (below the 0.15 freshness ceiling)',
    () {
      final status = classifyLetterLadder(
        snapshot: snap([
          lane(ResilientLaneIds.webSocketRelay, 0.05), // alive, not healthy
          lane(ResilientLaneIds.httpLongPoll, -1.10),
        ]),
      );
      expect(status.rung, LetterLadderRung.weak);
    },
  );

  test('withCourier: no live lane, but this round the door answered', () {
    final status = classifyLetterLadder(
      snapshot: snap([
        lane(ResilientLaneIds.webSocketRelay, -1.05),
        lane(ResilientLaneIds.httpLongPoll, -1.10),
        lane(ResilientLaneIds.txtQuery, 0.6),
      ]),
      lastProbe: reached(),
    );
    expect(status.rung, LetterLadderRung.withCourier);
  });

  test('halfClosed: the door history is a mix of hits and misses', () {
    final status = classifyLetterLadder(
      snapshot: snap([
        lane(ResilientLaneIds.webSocketRelay, 0.9),
        lane(ResilientLaneIds.txtQuery, 0.6),
      ]),
      lastProbe: reached(),
      doorHistory: const {'udp53:8.8.8.8:53': (wins: 3, attempts: 10)},
    );
    expect(status.rung, LetterLadderRung.halfClosed);
  });

  test('closed: no probe reaches at all — reports the queue and next probe, '
      'starts nothing', () {
    final status = classifyLetterLadder(
      snapshot: snap([
        lane(ResilientLaneIds.webSocketRelay, -1.05),
        lane(ResilientLaneIds.txtQuery, -1.15),
      ]),
      lastProbe: notReached(),
      queueWaiting: 3,
      nextProbeIn: const Duration(seconds: 12),
    );
    expect(status.rung, LetterLadderRung.closed);
    expect(status.detail, contains('3 waiting'));
    expect(status.detail, contains('next probe in 12s'));
  });
}
