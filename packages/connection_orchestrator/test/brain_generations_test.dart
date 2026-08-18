/// Pins the champion/challenger contract («هوشمندی v4» pillar 3):
/// promote-on-rise, rollback-on-drop, rollback-on-tie, rollback-on-
/// vacuous, the champion-stays-untouched clone protocol, the on-device
/// CallHistoryReplay score with hand-computed numbers, and the
/// promotion-log record's JSON round-trip and corrupt safety.
import 'dart:convert';

import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:test/test.dart';

CallHistoryRecord _call({
  required int startedUtcMs,
  required int connectMs,
  required String network,
}) => CallHistoryRecord(
  startedUtcMs: startedUtcMs,
  connectMs: connectMs,
  recoveries: 0,
  dropsToFloor: 0,
  networkIdentityHash: network,
  endReason: 'hangup',
);

BrainSet _freshBrains() {
  var syntheticMs = 0;
  return BrainSet(
    atlas: NetworkAtlas(),
    laneChoice: LaneChoicePolicy(),
    calibrator: BudgetCalibrator(),
    journal: MeasurementJournal(nowMs: () => syntheticMs++),
  );
}

void main() {
  group('decideGeneration rule', () {
    test('strict rise promotes; drop, tie, and vacuous roll back', () {
      final rise = decideGeneration(
        championScore: 2 / 3,
        challengerScore: 1.0,
        scoredCount: 3,
        nowMs: 42,
      );
      expect(rise.promoted, isTrue);
      expect(rise.reason, contains('>'));
      expect(rise.whenMs, 42);

      final drop = decideGeneration(
        championScore: 0.8,
        challengerScore: 0.79,
        scoredCount: 3,
        nowMs: 43,
      );
      expect(drop.promoted, isFalse);
      expect(drop.reason, contains('rollback'));

      final tie = decideGeneration(
        championScore: 0.8,
        challengerScore: 0.8,
        scoredCount: 3,
        nowMs: 44,
      );
      expect(tie.promoted, isFalse);

      final vacuous = decideGeneration(
        championScore: 0.0,
        challengerScore: 1.0,
        scoredCount: 0,
        nowMs: 45,
      );
      expect(vacuous.promoted, isFalse);
      expect(vacuous.reason, contains('nothing measurable'));
    });
  });

  group('CallHistoryReplay hand-check', () {
    // Three networks, each connecting at 100ms then 200ms. Per network,
    // call 2's budget is median([100]) = 100 against actual 200:
    // epoch 1 sees a fresh calibrator (correction 1.0, no voice below 3
    // samples) -> three errors of 0.5 -> score 1/1.5 = 2/3. Every pair
    // trains ratio 2.0 into the same bin, so epoch 2's correction is
    // exactly 2.0 -> three errors of 0 -> score 1.0. The rise IS the
    // aliveness signal.
    List<CallHistoryRecord> history() => [
      for (final net in ['a', 'b', 'c'])
        _call(startedUtcMs: 1, connectMs: 100, network: net),
      for (final net in ['a', 'b', 'c'])
        _call(startedUtcMs: 2, connectMs: 200, network: net),
    ];

    test('epoch 1 scores 2/3 over 3 records, epoch 2 scores 1.0', () {
      final replay = CallHistoryReplay(records: history());
      final brains = _freshBrains();
      final epoch1 = replay.scoreEpoch(brains);
      expect(epoch1, closeTo(2 / 3, 1e-12));
      expect(replay.lastScoredCount, 3);
      final epoch2 = replay.scoreEpoch(brains);
      expect(epoch2, closeTo(1.0, 1e-12));
      expect(replay.lastScoredCount, 3);
    });

    test('single call per network scores nothing (vacuous round)', () {
      final replay = CallHistoryReplay(
        records: [
          _call(startedUtcMs: 1, connectMs: 100, network: 'a'),
          _call(startedUtcMs: 2, connectMs: 300, network: 'b'),
        ],
      );
      expect(replay.scoreEpoch(_freshBrains()), 0.0);
      expect(replay.lastScoredCount, 0);
    });

    test('the clone protocol leaves the champion untouched', () {
      // The app's loop trains a CLONE (BrainSet.fromJson of the champion
      // JSON) and only ever promotes files, never mutates the champion.
      final champion = _freshBrains();
      final championBefore = jsonEncode(champion.calibrator.toJson());
      var syntheticMs = 0;
      final challenger = BrainSet.fromJson(
        champion.toJson(),
        journal: MeasurementJournal(nowMs: () => syntheticMs++),
      );
      final replay = CallHistoryReplay(records: history());
      final e1 = replay.scoreEpoch(challenger);
      final e2 = replay.scoreEpoch(challenger);
      expect(e2, greaterThan(e1));
      // The challenger learned; the champion's serialized state did not
      // move a byte.
      expect(jsonEncode(champion.calibrator.toJson()), championBefore);
      expect(
        jsonEncode(challenger.calibrator.toJson()),
        isNot(championBefore),
      );
    });
  });

  group('GenerationDecision JSON', () {
    test('round-trips and skips corrupt entries', () {
      final decision = decideGeneration(
        championScore: 2 / 3,
        challengerScore: 1.0,
        scoredCount: 3,
        nowMs: 99,
      );
      final restored = GenerationDecision.fromJson(
        jsonDecode(jsonEncode(decision.toJson())),
      )!;
      expect(restored.promoted, decision.promoted);
      expect(restored.championScore, decision.championScore);
      expect(restored.challengerScore, decision.challengerScore);
      expect(restored.scoredCount, decision.scoredCount);
      expect(restored.whenMs, decision.whenMs);
      expect(restored.reason, decision.reason);

      expect(GenerationDecision.fromJson(null), isNull);
      expect(GenerationDecision.fromJson('nope'), isNull);
      expect(
        GenerationDecision.fromJson({'promoted': 'yes', 'whenMs': 1}),
        isNull,
      );
    });
  });
}
