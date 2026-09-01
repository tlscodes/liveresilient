import 'dart:io';

import 'package:call_core/call_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_webrtc/media_webrtc.dart';

/// Ticket 2 gate 2b, against its REWRITTEN wording (2026-08-17).
///
/// WHAT THE GATE USED TO SAY, AND WHY IT CHANGED. The original wording asked
/// for an integration test proving the scheduler bound's VALUE is consumed by
/// the fixed-tick emitter. Measured on this date: the bound is consumed, but
/// only as a boolean admission predicate; `maxStep` has no consumer anywhere;
/// and the emitter is never constructed in production, its mode defaulting to
/// off. Satisfying the literal wording would have required switching fixed-rate
/// emission ON in a shipping app — a product change made to satisfy a test,
/// which is not a trade this project makes.
///
/// So the gate was narrowed to two claims that are true of today's code, and
/// the narrowing is recorded in docs/GATE_CLASSIFICATION.md and the plan ledger
/// rather than left implicit:
///
///   (1) the bound is consumed in the admission decision, across the two
///       packages that own the two halves of it;
///   (2) any construction of the emitter must derive its tick from the bound.
///
/// THE SECOND CLAIM IS VACUOUS TODAY, AND SAYS SO. There are zero production
/// emitter sites, so the guard protects nothing right now; it arms itself on the
/// day the first one appears with a hardcoded tick. A vacuous guard is worth
/// having — that day is exactly when the mistake is easiest to make and hardest
/// to notice — but calling it protection today would be a lie, so the test
/// asserts the count it found and fails if that count changes silently.
void main() {
  group('gate 2b — the bound decides admission (rewritten wording)', () {
    // A link with ample bandwidth. Capacity is not the constraint in any of
    // the rows below, which is what makes the bound's contribution visible.
    const wide = NetworkConditions(
      bandwidthBps: 1000000,
      rtt: Duration(milliseconds: 40),
      loss: 0,
    );

    test(
      '2b  the bound and the wire budget compose into ONE admission verdict',
      () {
        // The production wiring, reproduced: call_core computes the step bound
        // from the path's delay, media_webrtc prices the wire, and the two meet
        // in a single decision. Reproducing it here proves the two packages
        // compose; the source assertion below proves production does the wiring.
        final budget = AdaptiveConnectionBudget.fromConditions(wide);
        final admission = OpusWireBudget.forBandwidth(
          wide.bandwidthBps,
          concurrentStreams: 2,
          tickProbe:
              ({
                required int wireRateBps,
                required double perStreamBudgetBps,
                required int frameBitsOnWire,
              }) =>
                  budget.maxSchedulerStepFor(
                        wide,
                        offeredRateBps: wireRateBps,
                        usableShareBps: perStreamBudgetBps.round(),
                        frameBits: frameBitsOnWire,
                      )
                      is SchedulerStepAdmissible,
        );

        expect(
          admission,
          isA<OpusWireFitted>(),
          reason:
              'a fast, wide link must be admitted once, by both halves '
              'agreeing — not admitted here and refused downstream',
        );
      },
    );

    test('2b  a long path is refused for responsiveness, and the refusal comes '
        'from the bound rather than from capacity', () {
      // The same bandwidth, a 2-second round trip. Nothing about the wire
      // price changed, so if the verdict changes it can only be the bound
      // that changed it — which is what "consumed" has to mean to be worth
      // asserting.
      const slow = NetworkConditions(
        bandwidthBps: 1000000,
        rtt: Duration(milliseconds: 2000),
        loss: 0,
      );
      final budget = AdaptiveConnectionBudget.fromConditions(slow);
      final admission = OpusWireBudget.forBandwidth(
        slow.bandwidthBps,
        concurrentStreams: 2,
        tickProbe:
            ({
              required int wireRateBps,
              required double perStreamBudgetBps,
              required int frameBitsOnWire,
            }) =>
                budget.maxSchedulerStepFor(
                      slow,
                      offeredRateBps: wireRateBps,
                      usableShareBps: perStreamBudgetBps.round(),
                      frameBits: frameBitsOnWire,
                    )
                    is SchedulerStepAdmissible,
      );

      expect(admission, isA<OpusWireNoCandidateFits>());
      final refusal = admission as OpusWireNoCandidateFits;
      expect(
        refusal.cause,
        OpusWireRefusalCause.responsiveness,
        reason:
            'capacity was never the problem: the path is long, not narrow, '
            'and telling the caller to lower the rate cannot shorten a round '
            'trip',
      );
      expect(
        refusal.minimumBandwidthBps,
        isNull,
        reason:
            'there is no bandwidth that fixes a delay refusal, so the '
            'field that would name one must be absent rather than misleading',
      );
    });

    test(
      '2b  production wires the bound into admission, not a local constant',
      () {
        // Reproducing the composition in a test proves it is possible. This
        // proves the app does it — the distinction that ticket 6 was created to
        // enforce elsewhere in this repo.
        final session = File(
          '${Directory.current.path}/lib/src/call_session.dart',
        ).readAsStringSync();
        expect(
          session,
          contains('tickProbe:'),
          reason:
              'admission must receive the probe, or the bound is not part of '
              'the decision at all',
        );
        expect(
          session,
          contains('maxSchedulerStepFor('),
          reason: 'and the probe must be the real bound, not a local guess',
        );
      },
    );

    test('2b  any emitter construction must derive its tick from the bound — '
        'vacuous today, armed on the first site', () {
      // Scan every package's lib/ plus the app's lib/, skipping the file that
      // DEFINES the emitter. The claim: no production site may pass a literal
      // Duration as the tick. Today the offender list and the site list are
      // both empty, and the test asserts BOTH — an empty offender list on its
      // own would also be produced by a broken scanner.
      final repoRoot = Directory.current.parent.parent.path;
      final libDirs = <Directory>[
        Directory('$repoRoot/packages'),
        Directory('$repoRoot/apps'),
      ];
      final sites = <String>[];
      final offenders = <String>[];

      for (final root in libDirs) {
        if (!root.existsSync()) continue;
        for (final entity in root.listSync(recursive: true)) {
          if (entity is! File) continue;
          final path = entity.path;
          if (!path.endsWith('.dart')) continue;
          if (!path.contains('/lib/')) continue;
          // The declaration is not a construction site.
          if (path.endsWith('traffic_shaper.dart')) continue;
          final source = entity.readAsStringSync();
          final index = source.indexOf('FixedTickEmitter(');
          if (index < 0) continue;
          final relative = path.replaceFirst(repoRoot, '');
          sites.add(relative);
          // The argument text of the call, crudely bounded by the next `);`.
          final close = source.indexOf(');', index);
          final args = source.substring(
            index,
            close < 0 ? source.length : close,
          );
          final derivesFromBound =
              args.contains('maxStep') || args.contains('SchedulerStep');
          if (!derivesFromBound) offenders.add('$relative  ->  $args');
        }
      }

      expect(
        sites,
        isEmpty,
        reason:
            'a production emitter site now exists. That is not a failure '
            'in itself — it means this gate stops being vacuous, and the '
            'expectation here must be updated deliberately along with the '
            'ledger note that calls it vacuous: $sites',
      );
      expect(
        offenders,
        isEmpty,
        reason:
            'these sites construct the emitter without deriving the tick '
            'from the scheduler bound, which is the defect this gate exists '
            'to prevent: $offenders',
      );
    });
  });
}
