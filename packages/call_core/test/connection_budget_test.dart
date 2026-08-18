import 'package:call_core/call_core.dart';
import 'package:test/test.dart';

AdaptiveConnectionBudget budgetFor({
  required int rttMs,
  required double loss,
  int? bandwidthBps,
}) =>
    AdaptiveConnectionBudget.fromConditions(
      NetworkConditions(
        rtt: Duration(milliseconds: rttMs),
        loss: loss,
        bandwidthBps: bandwidthBps,
      ),
    );

void main() {
  group('AdaptiveConnectionBudget', () {
    // At zero loss the expected number of tries is 1, so the retransmit series
    // contributes exactly `2^1 - 1 = 1` timer unit: 1s.
    test('a healthy link falls back to the 30s floor', () {
      final b = budgetFor(rttMs: 70, loss: 0);
      // 70ms is below the 200ms sampling floor, so the model uses 200ms:
      // 200*8 + 1000 retransmit + 4000 fixed = 6.6s per attempt, 19.8s for
      // three — under the floor.
      expect(b.attemptCost, const Duration(milliseconds: 6600));
      expect(b.maxElapsed, AdaptiveConnectionBudget.minElapsed);
      expect(b.baseDelay, const Duration(milliseconds: 250));
    });

    test('1.8s round-trip with no loss needs about a minute', () {
      final b = budgetFor(rttMs: 1800, loss: 0);
      // 1800*8 + 1000 + 4000 = 19.4s per attempt.
      expect(b.attemptCost, const Duration(milliseconds: 19400));
      expect(b.maxElapsed, const Duration(milliseconds: 58200));
      // One attempt already exceeds the 15s constant this replaces.
      expect(b.attemptCost, greaterThan(const Duration(seconds: 15)));
    });

    test('60% loss is dominated by the doubling retransmit timers', () {
      final b = budgetFor(rttMs: 1800, loss: 0.6);
      // lossFactor = 1/0.4^2 = 6.25 tries expected. Round trips: 1800*8*6.25
      // = 90s. Retransmit series: 1s * (2^6 - 1) = 63s (doubling capped at
      // six), plus the serialized-TCP-stall term the 2026-08-07 timeline
      // measurement forced in: 63s * (3-1 deliveries) * 0.6 = 75.6s (a room
      // join alone took 43s and one offer send outlived 141s while the bare
      // ladder promised 63s). Plus 4s fixed = 232.6s for ONE attempt.
      expect(b.attemptCost, const Duration(milliseconds: 232600));
      // Three of those is ~698s, so the 450s cap is what binds.
      expect(b.maxElapsed, AdaptiveConnectionBudget.maxElapsedCap);
      expect(b.maxAttempts, 3);
    });

    test('the doubling term alone explains the measured 60%-loss floor', () {
      // A packet capture of the 60%-loss profile showed ICE and TURN still
      // negotiating past 125s, on a link whose propagation round-trip is
      // milliseconds. Only the retransmit series can account for that: a
      // linear loss factor puts the whole attempt at ~14s.
      final b = budgetFor(rttMs: 4, loss: 0.6);
      expect(b.attemptCost, greaterThan(const Duration(seconds: 60)));
      expect(b.maxElapsed, greaterThan(const Duration(seconds: 125)));
    });

    test('total loss is clamped rather than dividing by zero', () {
      final b = budgetFor(rttMs: 1800, loss: 1.0);
      expect(b.maxElapsed, AdaptiveConnectionBudget.maxElapsedCap);
      expect(b.attemptCost.inMilliseconds, isPositive);
    });

    test('a non-finite loss reading degrades to the worst case', () {
      final b = budgetFor(rttMs: 1800, loss: double.nan);
      expect(b.maxElapsed, AdaptiveConnectionBudget.maxElapsedCap);
    });

    test('a negative round-trip reading degrades to the floor', () {
      final b = budgetFor(rttMs: -500, loss: 0);
      expect(b.attemptCost, const Duration(milliseconds: 6600));
      expect(b.maxElapsed, AdaptiveConnectionBudget.minElapsed);
    });

    test('expectedConnectBy is tighter than the retry budget', () {
      final b = budgetFor(rttMs: 1800, loss: 0.6);
      // 1.5x the 232.6s attempt cost (see the 60%-loss test above).
      expect(b.expectedConnectBy, const Duration(milliseconds: 348900));
      expect(b.expectedConnectBy, lessThan(b.maxElapsed));
    });

    group('bandwidth term', () {
      test('a null bandwidth contributes nothing', () {
        expect(budgetFor(rttMs: 1800, loss: 0).attemptCost,
            const Duration(milliseconds: 19400));
      });

      test('16 kbit/s adds the serialization of one negotiation', () {
        final b = budgetFor(rttMs: 4, loss: 0, bandwidthBps: 16000);
        // 24 KiB * 8 bits / 16000 bps = 12.288s, on top of the 200ms round-trip
        // floor (200*8 = 1.6s), the 1s retransmit unit and the 4s fixed cost.
        expect(b.attemptCost, const Duration(milliseconds: 18888));
        expect(b.maxElapsed, const Duration(milliseconds: 56664));
      });

      test('a wide pipe costs almost nothing', () {
        final b = budgetFor(rttMs: 4, loss: 0, bandwidthBps: 10000000);
        expect(b.maxElapsed, AdaptiveConnectionBudget.minElapsed);
      });

      test('a zero or absurd bandwidth does not diverge', () {
        for (final bps in [0, -1, 1]) {
          final b = budgetFor(rttMs: 0, loss: 0, bandwidthBps: bps);
          expect(b.maxElapsed,
              lessThanOrEqualTo(AdaptiveConnectionBudget.maxElapsedCap),
              reason: 'bps=$bps');
        }
      });
    });

    group('over the whole condition grid', () {
      const rtts = [0, 70, 200, 700, 1800, 5000, 20000];
      const losses = [0.0, 0.1, 0.3, 0.6, 0.8, 0.95, 1.0];

      final grid = [
        for (final rtt in rtts)
          for (final loss in losses) budgetFor(rttMs: rtt, loss: loss),
      ];

      test('every output stays inside its declared bounds', () {
        for (final b in grid) {
          expect(
              b.maxElapsed,
              greaterThanOrEqualTo(AdaptiveConnectionBudget.minElapsed),
              reason: '$b');
          expect(b.maxElapsed,
              lessThanOrEqualTo(AdaptiveConnectionBudget.maxElapsedCap),
              reason: '$b');
          expect(b.maxAttempts, inInclusiveRange(3, 12), reason: '$b');
          expect(b.baseDelay, lessThanOrEqualTo(b.maxDelay), reason: '$b');
        }
      });

      test('a worse network never buys a smaller budget', () {
        for (final loss in losses) {
          for (var i = 1; i < rtts.length; i++) {
            expect(
                budgetFor(rttMs: rtts[i], loss: loss).maxElapsed,
                greaterThanOrEqualTo(
                    budgetFor(rttMs: rtts[i - 1], loss: loss).maxElapsed),
                reason: 'rtt ${rtts[i - 1]} -> ${rtts[i]} at loss $loss');
          }
        }
        for (final rtt in rtts) {
          for (var i = 1; i < losses.length; i++) {
            expect(
                budgetFor(rttMs: rtt, loss: losses[i]).maxElapsed,
                greaterThanOrEqualTo(
                    budgetFor(rttMs: rtt, loss: losses[i - 1]).maxElapsed),
                reason: 'loss ${losses[i - 1]} -> ${losses[i]} at rtt $rtt');
          }
        }
        // Same property for the bandwidth axis: a narrower pipe never costs
        // less than a wider one.
        const pipes = [16000, 32000, 128000, 1000000, 10000000];
        for (var i = 1; i < pipes.length; i++) {
          expect(
              budgetFor(rttMs: 4, loss: 0, bandwidthBps: pipes[i - 1])
                  .maxElapsed,
              greaterThanOrEqualTo(
                  budgetFor(rttMs: 4, loss: 0, bandwidthBps: pipes[i])
                      .maxElapsed),
              reason: 'pipe ${pipes[i - 1]} vs ${pipes[i]}');
        }
      });

      test('every cell builds a policy the existing contract accepts', () {
        for (final b in grid) {
          expect(b.toReconnectPolicy, returnsNormally, reason: '$b');
        }
      });
    });
  });
}
