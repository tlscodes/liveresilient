/// Pins the distributional BudgetCalibrator contract («هوشمندی v4»
/// pillar 1): center-aligned binning (identity stays exactly 1.0), the
/// minWeight fallback chain, global-shape inheritance, the 1/r-weighted
/// median as the relative-error minimizer, the [1/128, 128] output range,
/// budget-quantile role separation, v1-EWMA migration (voice kept, mass
/// capped, corrupt-safe), v2 JSON round-trip, and the observe() guard.
///
/// Every expected number is hand-computable: bins are k = round(4*log2 r)
/// clamped to [-28, 28] with center 2^(k/4); correction() takes the
/// weighted median (weights mass/center, ascending scan, cumulative >=
/// half); budgetQuantile() takes the smallest center with cumulative
/// mass >= p*total. Cell voice needs minWeight (3) raw samples; a voiced
/// cell is blended with the global histogram scaled to pseudo-count 3.
import 'dart:convert';
import 'dart:math' as math;

import 'package:connection_orchestrator/src/budget_calibrator.dart';
import 'package:test/test.dart';

void main() {
  // l0|r0 conditions (loss < 0.05, rtt < 150) and a far-away second cell
  // (l3|r2), per DeliveryContext bands in lane_experience.dart:70-87.
  const cellA = (loss: 0.001, rtt: 50.0);
  const cellB = (loss: 0.50, rtt: 2000.0);

  group('center-aligned identity', () {
    test('three ratio-1.0 samples make correction exactly 1.0', () {
      // All mass lands in bin k=0 (center 2^0 = 1.0); the scaled global
      // shares the single bin, so the weighted median is exactly 1.0.
      // Under edge-aligned bins this would read 2^0.125 ~= 1.0905 — this
      // pin locks the center-aligned convention.
      final cal = BudgetCalibrator();
      for (var i = 0; i < 3; i++) {
        cal.observe(
          predictedMs: 100,
          actualMs: 100,
          lossFraction: cellA.loss,
          rttMs: cellA.rtt,
        );
      }
      expect(cal.correction(lossFraction: cellA.loss, rttMs: cellA.rtt), 1.0);
    });
  });

  group('fallback chain', () {
    test('below 3 samples everywhere: exactly 1.0; at 3: exactly 2.0', () {
      final cal = BudgetCalibrator();
      for (var i = 0; i < 2; i++) {
        cal.observe(
          predictedMs: 100,
          actualMs: 200,
          lossFraction: cellA.loss,
          rttMs: cellA.rtt,
        );
      }
      // Cell mass 2 < 3 and global mass 2 < 3: no voice anywhere.
      expect(cal.correction(lossFraction: cellA.loss, rttMs: cellA.rtt), 1.0);
      cal.observe(
        predictedMs: 100,
        actualMs: 200,
        lossFraction: cellA.loss,
        rttMs: cellA.rtt,
      );
      // Single bin k=4 (log2 2.0 = 1, 4*1 = 4), center 2^1 = 2.0.
      expect(cal.correction(lossFraction: cellA.loss, rttMs: cellA.rtt), 2.0);
    });

    test('an untrained cell inherits the global shape (contract change)', () {
      // The v3 contract returned 1.0 for an untrained cell even with a
      // trained global; the distributional contract deliberately lets
      // the global histogram speak (measured to be what lifts the
      // benchmark's early-epoch predictions).
      final cal = BudgetCalibrator();
      for (var i = 0; i < 3; i++) {
        cal.observe(
          predictedMs: 100,
          actualMs: 200,
          lossFraction: cellA.loss,
          rttMs: cellA.rtt,
        );
      }
      expect(cal.correction(lossFraction: cellB.loss, rttMs: cellB.rtt), 2.0);
    });
  });

  group('weighted median (1/r weights), not the mass median', () {
    test('2x ratio 1.0 outvotes 4x ratio 4.0', () {
      // Cell bins: {k=0: 2, k=8: 4}; the global scaled to pseudo-count 3
      // has the same shape, so the blend preserves it. Weights are
      // mass/center: 2/1 = 2 vs 4/4 = 1; total 3, half 1.5; the
      // ascending scan reaches 2 >= 1.5 at center 1.0. Direct check of
      // the loss: mean|c/r - 1| is 0.5 at c=1, ~0.667 at c=2, 1.0 at
      // c=4 — c=1 is the true minimizer despite 2/3 of mass at 4.0.
      final cal = BudgetCalibrator();
      for (var i = 0; i < 2; i++) {
        cal.observe(
          predictedMs: 100,
          actualMs: 100,
          lossFraction: cellA.loss,
          rttMs: cellA.rtt,
        );
      }
      for (var i = 0; i < 4; i++) {
        cal.observe(
          predictedMs: 100,
          actualMs: 400,
          lossFraction: cellA.loss,
          rttMs: cellA.rtt,
        );
      }
      expect(cal.correction(lossFraction: cellA.loss, rttMs: cellA.rtt), 1.0);
    });
  });

  group('output range', () {
    test('a 1000x ratio clamps into the edge bin: correction 128.0', () {
      // log2 1000 ~= 9.966, k = round(39.86) = 40, clamped to 28,
      // center 2^7 = 128 — the documented ceiling of the new range.
      final cal = BudgetCalibrator();
      for (var i = 0; i < 3; i++) {
        cal.observe(
          predictedMs: 1,
          actualMs: 1000,
          lossFraction: cellA.loss,
          rttMs: cellA.rtt,
        );
      }
      expect(
        cal.correction(lossFraction: cellA.loss, rttMs: cellA.rtt),
        128.0,
      );
    });
  });

  group('budget quantile role separation', () {
    test('p80 boundary convention and quantile != correction', () {
      // Cell bins {k=0: 8, k=8: 2}; blended with the same-shape scaled
      // global the proportions stay 4:1. Mass quantile: cumulative at
      // center 1.0 is 0.8 of total, so p=0.80 -> 1.0 (boundary hits on
      // >=) and p=0.81 -> 4.0. The correction stays 1.0 (weighted
      // median), so on a skewed cell quantile(0.81) != correction —
      // the role-separation pin behind the measured 0.52 crash when p80
      // was misused as the point correction.
      final cal = BudgetCalibrator();
      for (var i = 0; i < 8; i++) {
        cal.observe(
          predictedMs: 100,
          actualMs: 100,
          lossFraction: cellA.loss,
          rttMs: cellA.rtt,
        );
      }
      for (var i = 0; i < 2; i++) {
        cal.observe(
          predictedMs: 100,
          actualMs: 400,
          lossFraction: cellA.loss,
          rttMs: cellA.rtt,
        );
      }
      expect(
        cal.budgetQuantile(lossFraction: cellA.loss, rttMs: cellA.rtt),
        1.0,
      );
      expect(
        cal.budgetQuantile(
          lossFraction: cellA.loss,
          rttMs: cellA.rtt,
          p: 0.81,
        ),
        4.0,
      );
      expect(
        cal.correction(lossFraction: cellA.loss, rttMs: cellA.rtt),
        1.0,
      );
    });
  });

  group('v1 migration', () {
    test('a legacy EWMA file keeps its voice instead of resetting', () {
      // v=1.3: log2 1.3 ~= 0.3785, k = round(1.514) = 2, center
      // 2^0.5 = sqrt(2). Cell mass 6 >= 3, global same bin -> the
      // correction is sqrt(2), NOT 1.0: the brain migrated.
      final restored = BudgetCalibrator.fromJson({
        'all': {'v': 1.3, 'w': 6},
        'cells': {
          'l0|r0': {'v': 1.3, 'w': 6},
        },
      });
      expect(
        restored.correction(lossFraction: cellA.loss, rttMs: cellA.rtt),
        closeTo(math.sqrt2, 1e-12),
      );
    });

    test('legacy mass is capped at 6 (EWMA effective sample size)', () {
      // alpha-0.3 EWMA carries ~(2-0.3)/0.3 ~= 5.7 effective samples;
      // w=50 must not outvote ~50 fresh observations forever.
      final restored = BudgetCalibrator.fromJson({
        'all': {'v': 2.0, 'w': 50},
        'cells': {
          'l0|r0': {'v': 2.0, 'w': 50},
        },
      });
      final json = restored.toJson();
      final cells = json['cells']! as Map<String, Object?>;
      final cell = cells['l0|r0']! as Map<String, Object?>;
      expect(cell['4'], 6.0);
      final all = json['all']! as Map<String, Object?>;
      expect(all['4'], 6.0);
    });

    test('corrupt v1 entries are skipped without a throw (NaN guard)', () {
      // v=-3.0 would make log2 produce NaN and Dart's round() throw —
      // validation must precede the math. All four shapes skip cleanly.
      final restored = BudgetCalibrator.fromJson({
        'all': {'v': 1.5, 'w': 6},
        'cells': {
          'l0|r0': {'v': -3.0, 'w': 2},
          'l0|r1': {'v': 'bad', 'w': 2},
          'l1|r1': {'v': 2.0, 'w': 0},
          'l1|r0': {'v': 2.0, 'w': -1},
        },
      });
      // Only the global survived (mass 6 at k=round(4*log2 1.5)=2);
      // every cell was dropped, so every lookup falls back to it.
      expect(
        restored.correction(lossFraction: cellA.loss, rttMs: cellA.rtt),
        closeTo(math.sqrt2, 1e-12),
      );
      expect(BudgetCalibrator.fromJson({}).correction(), 1.0);
    });
  });

  group('v2 JSON round-trip', () {
    test('encode/decode reproduces every correction, negative keys too', () {
      final cal = BudgetCalibrator();
      for (var i = 0; i < 3; i++) {
        // ratio 0.5 -> k = -4, serialized key "-4".
        cal.observe(
          predictedMs: 100,
          actualMs: 50,
          lossFraction: cellA.loss,
          rttMs: cellA.rtt,
        );
        cal.observe(
          predictedMs: 100,
          actualMs: 200,
          lossFraction: cellB.loss,
          rttMs: cellB.rtt,
        );
      }
      final decoded =
          jsonDecode(jsonEncode(cal.toJson())) as Map<String, Object?>;
      final restored = BudgetCalibrator.fromJson(decoded);
      for (final cell in [cellA, cellB]) {
        expect(
          restored.correction(lossFraction: cell.loss, rttMs: cell.rtt),
          cal.correction(lossFraction: cell.loss, rttMs: cell.rtt),
        );
        expect(
          restored.budgetQuantile(lossFraction: cell.loss, rttMs: cell.rtt),
          cal.budgetQuantile(lossFraction: cell.loss, rttMs: cell.rtt),
        );
      }
    });

    test('v2 masses arriving as JSON ints parse (web encode trap)', () {
      // dart2js encodes 3.0 as 3; fromJson must read num, not double.
      final restored = BudgetCalibrator.fromJson({
        'v': 2,
        'all': {'0': 3},
        'cells': {
          'l0|r0': {'0': 3},
        },
      });
      expect(
        restored.correction(lossFraction: cellA.loss, rttMs: cellA.rtt),
        1.0,
      );
      expect(restored.toJson()['v'], 2);
    });

    test('corrupt v2 entries are skipped: bad keys, bad masses', () {
      final restored = BudgetCalibrator.fromJson({
        'v': 2,
        'all': {'0': 3.0, 'zz': 5.0, '99': 5.0, '-99': 5.0, '4': -1.0},
        'cells': {
          'l0|r0': {'4': 'bad'},
        },
      });
      // Only the k=0 mass-3 global entry survived.
      expect(restored.correction(), 1.0);
      final all =
          (restored.toJson()['all']! as Map<String, Object?>);
      expect(all.length, 1);
      expect(all['0'], 3.0);
    });
  });

  group('observe guard', () {
    test('non-positive and non-finite timings are ignored', () {
      final cal = BudgetCalibrator();
      cal.observe(predictedMs: 0, actualMs: 200);
      cal.observe(predictedMs: -5, actualMs: 200);
      cal.observe(predictedMs: double.nan, actualMs: 200);
      cal.observe(predictedMs: double.infinity, actualMs: 200);
      cal.observe(predictedMs: 100, actualMs: 0);
      cal.observe(predictedMs: 100, actualMs: -1);
      cal.observe(predictedMs: 100, actualMs: double.nan);
      cal.observe(predictedMs: 100, actualMs: double.infinity);
      // Nothing was accepted: toJson carries zero mass and the
      // correction still has no voice.
      expect((cal.toJson()['all']! as Map<String, Object?>).isEmpty, true);
      expect(cal.correction(), 1.0);
    });
  });
}
