import 'package:call_core/call_core.dart';
import 'package:test/test.dart';

/// Ticket 2 acceptance gates 2a, 2e and 2f.
///
/// The bound is two-sided and the admissible interval may not exist at all.
/// The whole point of the sealed return is that "no admissible step exists"
/// is a value the caller must handle, not a number that understates the
/// problem. The house style in this class clamps every other derived budget,
/// because there any value inside the range is still physically meaningful;
/// here a clamp would manufacture a plausible figure with no physical
/// backing, so it is forbidden until the interval is known to be non-empty.
void main() {
  // The grid the class's own timing tests already sweep.
  final rttsMs = <int>[4, 20, 60, 120, 200, 400, 800, 1200, 2000];
  final losses = <double>[0, 0.1, 0.3, 0.6, 0.9];

  AdaptiveConnectionBudget budgetFor(int rttMs, double loss) =>
      AdaptiveConnectionBudget.fromConditions(
        NetworkConditions(
          rtt: Duration(milliseconds: rttMs),
          loss: loss,
        ),
      );

  group('maxSchedulerStepFor', () {
    test('2a  across the whole rtt x loss grid the result is always one of the '
        'three states, never negative, never zero, never a throw', () {
      for (final rttMs in rttsMs) {
        for (final loss in losses) {
          final budget = budgetFor(rttMs, loss);
          final bound = budget.maxSchedulerStepFor(
            NetworkConditions(
              rtt: Duration(milliseconds: rttMs),
              loss: loss,
            ),
            offeredRateBps: 10400,
            usableShareBps: 22400,
            frameBits: 1248,
          );
          switch (bound) {
            case SchedulerStepAdmissible(:final minStep, :final maxStep):
              expect(
                minStep,
                greaterThan(Duration.zero),
                reason: 'rtt=$rttMs loss=$loss',
              );
              expect(maxStep, greaterThan(Duration.zero));
              expect(minStep, lessThanOrEqualTo(maxStep));
              expect(
                maxStep,
                lessThanOrEqualTo(
                  AdaptiveConnectionBudget.interactiveLatencyBudget,
                ),
                reason: 'the upper bound can never exceed the budget itself',
              );
            case SchedulerStepImpossibleForCapacity(:final shortfallBps):
              expect(shortfallBps, greaterThanOrEqualTo(0));
            case SchedulerStepImpossibleForResponsiveness(
              :final interactiveBudget,
              :final oneWayNetwork,
              :final jitterBuffer,
            ):
              expect(
                interactiveBudget,
                AdaptiveConnectionBudget.interactiveLatencyBudget,
              );
              expect(oneWayNetwork, Duration(milliseconds: rttMs) ~/ 2);
              expect(jitterBuffer, AdaptiveConnectionBudget.jitterBufferDelay);
          }
        }
      }
    });

    test(
      '2e  an empty interval yields an impossible state, never a floor value',
      () {
        // The measured row: rtt 400ms, and the offered rate already over the
        // usable share. Both bounds dissolve, in two different ways.
        final budget = budgetFor(400, 0.1);
        final bound = budget.maxSchedulerStepFor(
          const NetworkConditions(rtt: Duration(milliseconds: 400), loss: 0.1),
          offeredRateBps: 20800, // two directions at the heavy carrier
          usableShareBps: 11200, // 0.7 * 16000
          frameBits: 2496,
        );
        expect(bound, isA<SchedulerStepImpossibleForCapacity>());
        final capacity = bound as SchedulerStepImpossibleForCapacity;
        expect(capacity.shortfallBps, 20800 - 11200);
        expect(
          bound,
          isNot(isA<SchedulerStepAdmissible>()),
          reason:
              'a clamp here would report a plausible step for a link that '
              'admits none — the exact failure this gate exists to prevent',
        );
      },
    );

    test('2f  the two impossible causes are distinguishable, because the '
        'caller remedy differs', () {
      final wideButSlow = budgetFor(800, 0).maxSchedulerStepFor(
        const NetworkConditions(rtt: Duration(milliseconds: 800), loss: 0),
        offeredRateBps: 32000,
        usableShareBps: 7000000, // ample capacity
        frameBits: 640,
      );
      expect(
        wideButSlow,
        isA<SchedulerStepImpossibleForResponsiveness>(),
        reason:
            'ample capacity, long round trip: capacity is not the cause '
            'and reporting it as such would send the caller to lower the '
            'rate, which cannot help',
      );

      final narrowButFast = budgetFor(20, 0).maxSchedulerStepFor(
        const NetworkConditions(rtt: Duration(milliseconds: 20), loss: 0),
        offeredRateBps: 40000,
        usableShareBps: 11200,
        frameBits: 640,
      );
      expect(narrowButFast, isA<SchedulerStepImpossibleForCapacity>());
    });

    test('the network term is HALF the round trip, because the interactive '
        'budget is one-way and a frame crosses the network once', () {
      const rtt = Duration(milliseconds: 120);
      final bound = budgetFor(120, 0).maxSchedulerStepFor(
        const NetworkConditions(rtt: rtt, loss: 0),
        offeredRateBps: 10000,
        usableShareBps: 200000,
        frameBits: 640,
      );
      final admissible = bound as SchedulerStepAdmissible;
      expect(
        admissible.maxStep,
        AdaptiveConnectionBudget.interactiveLatencyBudget -
            (rtt ~/ 2) -
            AdaptiveConnectionBudget.jitterBufferDelay,
      );
      // Taking the full round trip instead would have declared this row
      // impossible: 150 - 120 - 60 is negative.
      expect(
        AdaptiveConnectionBudget.interactiveLatencyBudget -
            rtt -
            AdaptiveConnectionBudget.jitterBufferDelay,
        lessThan(Duration.zero),
      );
    });

    test('2d  the buffering constant is pinned in exactly one place', () {
      expect(
        AdaptiveConnectionBudget.jitterBufferDelay,
        const Duration(milliseconds: 60),
      );
      expect(
        AdaptiveConnectionBudget.interactiveLatencyBudget,
        const Duration(milliseconds: 150),
      );
    });

    test('the lower bound is the time one frame needs at the spare rate', () {
      final bound = budgetFor(20, 0).maxSchedulerStepFor(
        const NetworkConditions(rtt: Duration(milliseconds: 20), loss: 0),
        offeredRateBps: 10000,
        usableShareBps: 110000,
        frameBits: 1000,
      );
      final admissible = bound as SchedulerStepAdmissible;
      // 1000 bits over 100000 bits/s spare = 10 ms.
      expect(admissible.minStep, const Duration(milliseconds: 10));
      // rtt 20 -> one-way 10; 150 - 10 - 60 = 80.
      expect(admissible.maxStep, const Duration(milliseconds: 80));
    });

    test('an inverted interval — both bounds defined but the floor above the '
        'ceiling — is a responsiveness refusal, not a clamp', () {
      // Capacity is fine (spare exists) and the upper bound is positive,
      // yet one frame needs longer than the budget allows: 1000 bits over
      // 10000 bits/s spare is 100 ms against an 80 ms ceiling. This is the
      // case a single clamp policy would have silently flattened.
      final bound = budgetFor(20, 0).maxSchedulerStepFor(
        const NetworkConditions(rtt: Duration(milliseconds: 20), loss: 0),
        offeredRateBps: 10000,
        usableShareBps: 20000,
        frameBits: 1000,
      );
      expect(bound, isA<SchedulerStepImpossibleForResponsiveness>());
      final refusal = bound as SchedulerStepImpossibleForResponsiveness;
      expect(refusal.resultingStep, const Duration(milliseconds: 80));
      expect(
        refusal.resultingStep,
        greaterThan(Duration.zero),
        reason: 'the ceiling itself was fine; the floor overran it',
      );
    });
  });
}
