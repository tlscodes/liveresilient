// One case per rung of the six-state ladder, each the smallest
// snapshot/probe/history combination that hits exactly that rung — no
// fabric, no socket, no clock.
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

const reached = TxtProbeOutcome(
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

const notReached = TxtProbeOutcome(
  groupId: 'g',
  answers: [TxtProbeAnswer(index: 0, label: 'udp53:8.8.8.8:53', nonce: 'aa')],
  winnerIndex: null,
);

typedef _Case = ({
  String name,
  List<LaneStatus> lanes,
  TxtProbeOutcome? probe,
  Map<String, ({int wins, int attempts})> history,
  LetterLadderRung rung,
  String reason,
});

void main() {
  final cases = <_Case>[
    (
      name: 'normal: a live lane and the door both healthy',
      lanes: [
        lane(ResilientLaneIds.webSocketRelay, 0.9),
        lane(ResilientLaneIds.httpLongPoll, 0.8),
        lane(ResilientLaneIds.txtQuery, 0.6),
      ],
      probe: null,
      history: const {},
      rung: LetterLadderRung.normal,
      reason: 'ok',
    ),
    (
      name: 'limited: one non-door lane is dead, the other still healthy',
      lanes: [
        lane(ResilientLaneIds.webSocketRelay, 0.9),
        lane(ResilientLaneIds.httpLongPoll, -1.10), // dead
        lane(ResilientLaneIds.txtQuery, 0.6),
      ],
      probe: null,
      history: const {},
      rung: LetterLadderRung.limited,
      reason: 'down',
    ),
    (
      // The owner's real run: wss alive but below 0.15 — WHY it was weak.
      name:
          'weak/slow: a live lane is up but slow (below the 0.15 freshness '
          'ceiling)',
      lanes: [
        lane(ResilientLaneIds.webSocketRelay, 0.05), // alive, not healthy
        lane(ResilientLaneIds.httpLongPoll, -1.10),
      ],
      probe: null,
      history: const {},
      rung: LetterLadderRung.weak,
      reason: 'slow',
    ),
    (
      // No live lane, but the door still has a path (score-eligible),
      // just not freshly proven by a probe this round.
      name: 'weak/dead: no live lane, the door still has a path, no probe',
      lanes: [
        lane(ResilientLaneIds.webSocketRelay, -1.05),
        lane(ResilientLaneIds.httpLongPoll, -1.10),
        lane(ResilientLaneIds.txtQuery, 0.6),
      ],
      probe: null,
      history: const {},
      rung: LetterLadderRung.weak,
      reason: 'dead',
    ),
    (
      // Nothing has a path — not even the door: the reading is closed,
      // not weak (every lane at or below letterDeadAtOrBelow).
      name: 'closed/dead: every lane is dead, the door included, no probe',
      lanes: [
        lane(ResilientLaneIds.webSocketRelay, -1.05),
        lane(ResilientLaneIds.httpLongPoll, -1.10),
        lane(ResilientLaneIds.txtQuery, -1.15),
      ],
      probe: null,
      history: const {},
      rung: LetterLadderRung.closed,
      reason: 'dead',
    ),
    (
      name: 'withCourier: no live lane, but this round the door answered',
      lanes: [
        lane(ResilientLaneIds.webSocketRelay, -1.05),
        lane(ResilientLaneIds.httpLongPoll, -1.10),
        lane(ResilientLaneIds.txtQuery, 0.6),
      ],
      probe: reached,
      history: const {},
      rung: LetterLadderRung.withCourier,
      reason: 'door',
    ),
    (
      // Owner decision 2026-10-04: with a healthy live lane up, mixed door
      // history keeps the live lane's rung (normal) and only lowers the
      // reason to 'mixed' — it does not demote to halfClosed.
      name:
          'mixed over a healthy live lane: keeps normal, reason drops to '
          'mixed',
      lanes: [
        lane(ResilientLaneIds.webSocketRelay, 0.9),
        lane(ResilientLaneIds.txtQuery, 0.6),
      ],
      probe: reached,
      history: const {'udp53:8.8.8.8:53': (wins: 3, attempts: 10)},
      rung: LetterLadderRung.normal,
      reason: 'mixed',
    ),
  ];

  for (final (:name, :lanes, :probe, :history, :rung, :reason) in cases) {
    test(name, () {
      final status = classifyLetterLadder(
        snapshot: snap(lanes),
        lastProbe: probe,
        doorHistory: history,
      );
      expect(status.rung, rung);
      // The one-word WHY, from the same fabric predicate that chose the rung.
      expect(status.reason, reason);
    });
  }

  test('closed: no probe reaches at all — reports the queue and next probe, '
      'starts nothing', () {
    final status = classifyLetterLadder(
      snapshot: snap([
        lane(ResilientLaneIds.webSocketRelay, -1.05),
        lane(ResilientLaneIds.txtQuery, -1.15),
      ]),
      lastProbe: notReached,
      queueWaiting: 3,
      nextProbeIn: const Duration(seconds: 12),
    );
    expect(status.rung, LetterLadderRung.closed);
    // Closed because this round's probe logged no nonce — distinct from
    // the all-dead 'dead' closed above.
    expect(status.reason, 'nonce');
    expect(
      status.detail,
      stringContainsInOrder(['3 waiting', 'next probe in 12s']),
    );
  });

  // Owner decision 2026-10-04 — the three winner rules at the ladder level.
  // Rule 1: a healthy live lane keeps its own rung; mixed door history only
  // lowers the reason to 'mixed', never the rung, never past 'closed'.
  const mixed = {'r': (wins: 3, attempts: 10)}; // ratio 0.3 -> mixed

  group(
    'winner rule 1: a live lane keeps its rung, mixed only lowers reason',
    () {
      test('two healthy non-door lanes -> normal, reason mixed', () {
        final status = classifyLetterLadder(
          snapshot: snap([
            lane(ResilientLaneIds.webSocketRelay, 0.9),
            lane(ResilientLaneIds.httpLongPoll, 0.9),
            lane(ResilientLaneIds.txtQuery, 0.6),
          ]),
          doorHistory: mixed,
        );
        expect(status.rung, LetterLadderRung.normal);
        expect(status.reason, 'mixed');
      });

      test('one non-door lane down -> limited, reason mixed', () {
        final status = classifyLetterLadder(
          snapshot: snap([
            lane(ResilientLaneIds.webSocketRelay, 0.9),
            lane(ResilientLaneIds.httpLongPoll, -1.10), // dead
          ]),
          doorHistory: mixed,
        );
        expect(status.rung, LetterLadderRung.limited);
        expect(status.reason, 'mixed');
      });

      test('the one live lane is slow -> weak, reason mixed', () {
        final status = classifyLetterLadder(
          snapshot: snap([
            lane(ResilientLaneIds.webSocketRelay, 0.10), // alive, below 0.15
            lane(ResilientLaneIds.httpLongPoll, -1.10),
          ]),
          doorHistory: mixed,
        );
        expect(status.rung, LetterLadderRung.weak);
        expect(status.reason, 'mixed');
      });

      test(
        'a probe that logged no nonce still outranks mixed -> closed/nonce',
        () {
          final status = classifyLetterLadder(
            snapshot: snap([
              lane(ResilientLaneIds.webSocketRelay, 0.9),
              lane(ResilientLaneIds.httpLongPoll, 0.9),
              lane(ResilientLaneIds.txtQuery, 0.6),
            ]),
            lastProbe: notReached,
            doorHistory: mixed,
          );
          expect(status.rung, LetterLadderRung.closed);
          expect(status.reason, 'nonce');
        },
      );
    },
  );

  // Rule 2: no live lane has a path -> the door decides the rung. Here mixed
  // door history DOES set halfClosed (unchanged from before this decision),
  // because there is no live lane whose rung it could merely modify.
  group('winner rule 2: no live lane -> the door decides the rung', () {
    test('mixed door history, no live lane -> halfClosed/mixed', () {
      final status = classifyLetterLadder(
        snapshot: snap([
          lane(ResilientLaneIds.webSocketRelay, -1.05),
          lane(ResilientLaneIds.httpLongPoll, -1.10),
          lane(ResilientLaneIds.txtQuery, 0.6), // door still has a path
        ]),
        doorHistory: mixed,
      );
      expect(status.rung, LetterLadderRung.halfClosed);
      expect(status.reason, 'mixed');
    });

    test('no live lane, empty door history -> weak/dead', () {
      final status = classifyLetterLadder(
        snapshot: snap([
          lane(ResilientLaneIds.webSocketRelay, -1.05),
          lane(ResilientLaneIds.httpLongPoll, -1.10),
          lane(ResilientLaneIds.txtQuery, 0.6),
        ]),
      );
      expect(status.rung, LetterLadderRung.weak);
      expect(status.reason, 'dead');
    });
  });

  // Rule 3: not even the door has a path -> closed/dead. The courier then
  // parks the letter with best_lane null (pinned at the courier level by B3).
  test('winner rule 3: all three lanes dead -> closed/dead', () {
    final status = classifyLetterLadder(
      snapshot: snap([
        lane(ResilientLaneIds.webSocketRelay, -1.05),
        lane(ResilientLaneIds.httpLongPoll, -1.10),
        lane(ResilientLaneIds.txtQuery, -1.15),
      ]),
    );
    expect(status.rung, LetterLadderRung.closed);
    expect(status.reason, 'dead');
  });
}
