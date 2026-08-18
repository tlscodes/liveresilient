/// The first test in this file is the one that matters: across every input the
/// governor accepts — including a dead link, a zero budget, and adversarial
/// nonsense — it must never fail to name a rung. Everything else is detail.
library;

import 'package:quality_governor/quality_governor.dart';
import 'package:test/test.dart';

LinkObservation obs({
  int nowMs = 0,
  double score = 0.8,
  double observedWireBps = 200,
  double budgetBps = 5000,
  int sampleAgeMs = 0,
  bool pathDegraded = false,
}) => LinkObservation(
  nowMs: nowMs,
  score: score,
  observedWireBps: observedWireBps,
  budgetBps: budgetBps,
  sampleAgeMs: sampleAgeMs,
  pathDegraded: pathDegraded,
);

void main() {
  group('the invariant', () {
    test('voice is never cut, across a wide sweep of hostile inputs', () {
      final governor = QualityGovernor();
      var tick = 0;
      for (final score in [-1.0, 0.0, 0.001, 0.25, 0.5, 0.6, 1.0, 2.0]) {
        for (final budget in [0.0, 1.0, 100.0, 267.0, 1000.0, 1e9]) {
          for (final age in [0, 500, 3001, 600000]) {
            for (final degraded in [false, true]) {
              final d = governor.observe(
                obs(
                  nowMs: tick += 20,
                  score: score,
                  budgetBps: budget,
                  sampleAgeMs: age,
                  pathDegraded: degraded,
                ),
              );
              expect(d.keepsVoiceFlowing, isTrue);
              expect(
                d.rungIndex,
                inInclusiveRange(0, governor.ladder.length - 1),
              );
              expect(
                d.rung.frameRate,
                greaterThan(0),
                reason: 'a rung with no frames is a cut call',
              );
              expect(d.reason, isNotEmpty);
            }
          }
        }
      }
    });

    test('a zero budget still yields the survival rung, not a stop', () {
      final governor = QualityGovernor(startIndex: 5);
      final d = governor.observe(obs(budgetBps: 0));
      expect(d.rungIndex, survivalRungIndex);
      expect(d.rung.frameRate, greaterThan(0));
    });

    test('an empty ladder is rejected at construction, not at runtime', () {
      expect(
        () => QualityGovernor(ladder: const []),
        throwsArgumentError,
        reason:
            'the failure must surface where it can be fixed, not on the '
            'send path during a call',
      );
    });
  });

  group('downgrade', () {
    test('a degraded path drops to survival immediately, ignoring dwell', () {
      final governor = QualityGovernor(startIndex: 6);
      final d = governor.observe(obs(nowMs: 10, pathDegraded: true));
      expect(d.rungIndex, survivalRungIndex);
      expect(d.changed, isTrue);
    });

    test('three consecutive bad ticks step down exactly one rung', () {
      final governor = QualityGovernor(startIndex: 4);
      var last = governor.observe(obs(nowMs: 20, score: 0.1));
      expect(last.changed, isFalse, reason: 'one bad tick is not enough');
      last = governor.observe(obs(nowMs: 40, score: 0.1));
      expect(last.changed, isFalse, reason: 'two bad ticks are not enough');
      last = governor.observe(obs(nowMs: 60, score: 0.1));
      expect(last.changed, isTrue);
      expect(last.rungIndex, 3);
    });

    test('a good tick resets the bad streak', () {
      final governor = QualityGovernor(startIndex: 4);
      governor.observe(obs(nowMs: 20, score: 0.1));
      governor.observe(obs(nowMs: 40, score: 0.1));
      governor.observe(obs(nowMs: 60, score: 0.9));
      final d = governor.observe(obs(nowMs: 80, score: 0.1));
      expect(d.changed, isFalse, reason: 'the streak restarted');
    });

    test('a rung whose cost exceeds the budget is abandoned at once', () {
      final governor = QualityGovernor(startIndex: 6); // shaped-full, 4170 B/s
      final d = governor.observe(obs(nowMs: 20, budgetBps: 1400));
      expect(d.changed, isTrue);
      expect(governor.current.measuredWireBps!, lessThanOrEqualTo(1400 * 0.9));
    });
  });

  group('upgrade', () {
    test('climbing needs a long good streak, not a short one', () {
      final governor = QualityGovernor(startIndex: 0);
      for (var i = 1; i < 25; i++) {
        final d = governor.observe(obs(nowMs: i * 20, score: 0.95));
        expect(d.changed, isFalse, reason: 'climbed after only $i good ticks');
      }
      final d = governor.observe(obs(nowMs: 25 * 20 + 3000, score: 0.95));
      expect(d.changed, isTrue);
      expect(d.rungIndex, 1);
    });

    test('a stale sample never justifies climbing', () {
      final governor = QualityGovernor(startIndex: 0);
      for (var i = 1; i <= 60; i++) {
        final d = governor.observe(
          obs(nowMs: i * 20 + 5000, score: 0.99, sampleAgeMs: 4000),
        );
        expect(d.changed, isFalse);
      }
      expect(governor.currentIndex, survivalRungIndex);
    });

    test('the dwell timer blocks an immediate re-climb after a change', () {
      final governor = QualityGovernor(startIndex: 4);
      governor.observe(obs(nowMs: 20, score: 0.1));
      governor.observe(obs(nowMs: 40, score: 0.1));
      final down = governor.observe(obs(nowMs: 60, score: 0.1));
      expect(down.changed, isTrue);
      for (var i = 1; i <= 40; i++) {
        final d = governor.observe(obs(nowMs: 60 + i * 20, score: 0.99));
        expect(
          d.changed,
          isFalse,
          reason: 'climbed back within the ${2000}ms dwell window',
        );
      }
    });

    test(
      'a rung just downgraded from is not climbed back into immediately',
      () {
        final governor = QualityGovernor(startIndex: 4);
        final before = governor.current.name;
        governor.observe(obs(nowMs: 20, score: 0.1));
        governor.observe(obs(nowMs: 40, score: 0.1));
        governor.observe(obs(nowMs: 60, score: 0.1));
        for (var i = 1; i <= 200; i++) {
          governor.observe(obs(nowMs: 3000 + i * 20, score: 0.99));
        }
        // Within the penalty window it must not have returned to that rung.
        expect(governor.current.name, isNot(before));
      },
    );
  });

  group('the dead band', () {
    test('a middling score advances neither counter', () {
      final governor = QualityGovernor(startIndex: 4);
      for (var i = 1; i <= 100; i++) {
        final d = governor.observe(obs(nowMs: i * 20, score: 0.4));
        expect(
          d.changed,
          isFalse,
          reason: 'a score between the thresholds moved the ladder',
        );
      }
    });
  });

  group('the ladder itself', () {
    test('is ordered by measured cost, ascending', () {
      var previous = -1.0;
      for (final rung in qualityLadder) {
        expect(
          rung.measuredWireBps,
          isNotNull,
          reason: '${rung.name} has no measured cost',
        );
        expect(
          rung.measuredWireBps!,
          greaterThanOrEqualTo(previous),
          reason: '${rung.name} breaks the cost ordering',
        );
        previous = rung.measuredWireBps!;
      }
    });

    test('every rung names what it gives up', () {
      for (final rung in qualityLadder) {
        expect(rung.givesUp, isNotEmpty);
        expect(rung.frameRate, greaterThan(0));
      }
    });

    test('the survival rung is the cheapest', () {
      final cheapest = qualityLadder
          .map((r) => r.measuredWireBps!)
          .reduce((a, b) => a < b ? a : b);
      expect(qualityLadder[survivalRungIndex].measuredWireBps, cheapest);
    });

    test('shaping is the only lever that lowers leak', () {
      // Guards the finding the ladder is built on: among measured rungs, a
      // lower kl always comes with a higher shaped share. If a future edit
      // adds a rung that lowers leak some other way, this test should be
      // updated deliberately — not silently.
      // Rungs with no leak measurement (measuredKl == null, e.g. the
      // ultra-lean-31.8 codec rung, which was never leak-tested) are skipped
      // honestly rather than given an invented number. At least one rung must
      // still carry a measurement or this test would be vacuous.
      final byKl = qualityLadder.where((r) => r.measuredKl != null).toList()
        ..sort((a, b) => a.measuredKl!.compareTo(b.measuredKl!));
      expect(byKl, isNotEmpty, reason: 'no rung has a leak measurement');
      for (var i = 1; i < byKl.length; i++) {
        expect(
          byKl[i - 1].shapedShare,
          greaterThanOrEqualTo(byKl[i].shapedShare),
          reason:
              '${byKl[i - 1].name} has lower leak than ${byKl[i].name} '
              'without more shaping',
        );
      }
    });

    test(
      'the ultra-lean rung costs exactly the measured 32.0 bps wire rate',
      () {
        // FINAL-REPORT.md:110 reports wire_bitrate 32.0000 bps — BITS per
        // second, measured on a recording, not a live call. The ladder is in
        // bytes per second, so the rung's cost must equal 32.0 / 8. The 55%
        // framing-overhead divisor does not apply: the source figure is already
        // a wire figure.
        final rung = qualityLadder[survivalRungIndex];
        expect(rung.name, 'ultra-lean-31.8');
        expect(rung.measuredWireBps, 32.0 / 8);
        expect(
          rung.measuredKl,
          isNull,
          reason:
              'no leak measurement exists for this rung; a copied number '
              'would be a fabrication',
        );
      },
    );
  });
}
