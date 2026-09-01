/// G8 load/soak gate — in-process tiers of the load harness.
///
/// The 100-room tier runs on every `dart test` (CI-fast). The 1k-room tier
/// is tagged `soak` and skipped by default; run it manually with:
///
///   dart test test/load_soak_test.dart -t soak --run-skipped
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:test/test.dart';

import '../bin/load_soak.dart' as harness;

/// Upper bound on PER-RUN steady-state RSS growth (see the leak predicate
/// below for how "steady-state" is established).
///
/// A single cold run's before/after RSS delta is NOT a leak signal here:
/// `dart test` runs suites concurrently inside one VM process (process-wide
/// RSS includes the other suites), the first run pays JIT compilation, and
/// the Dart VM almost never returns freed heap pages to the OS (measured on
/// this machine: cold-run delta ~200 MiB for 100 rooms, dominated by those
/// three effects). 64 MiB absorbs allocator/concurrent-suite noise while
/// still failing on any per-room leak of ~0.6 MiB or more.
/// The authoritative teardown signals remain `activeRoomsAfterTeardown == 0`
/// and zero errors; the RSS bound is a coarse backstop.
const int maxSteadyStateRssGrowthBytes = 64 * 1024 * 1024;

/// Max identical runs used to find an RSS plateau.
///
/// One warm-up run is NOT always enough for the VM's heap high-water mark
/// to settle: a Linux CI runner measured run1->run2 growth of 85,200,896
/// bytes with every functional signal clean (2000/2000 frames, 0 errors,
/// 0 rooms after teardown), while this Mac plateaus after run 1. So the
/// leak predicate is the MINIMUM growth over consecutive identical runs
/// (early-exit on the first delta under the bound): a plateauing high-water
/// mark produces a small delta within a few runs, while a genuine per-room
/// leak grows on EVERY run and keeps all deltas over the bound. At ~2-3 s
/// per 100-room run, the worst case (~5 runs) stays far inside the timeout.
const int maxLeakProbeRuns = 5;

void expectCleanRun(harness.LoadSoakSummary summary, int rooms, int messages) {
  expect(summary.errors, 0);
  expect(summary.framesSent, rooms * messages);
  expect(summary.framesDelivered, rooms * messages);
  expect(summary.peakActiveRooms, rooms);
  expect(summary.activeRoomsAfterTeardown, 0);
  expect(summary.reapedRooms, 0);
  expect(summary.setupMsP95, greaterThan(0));
  expect(summary.rttMsP95, greaterThan(0));
}

void main() {
  test('G8 100-room tier: zero errors, full delivery, clean teardown, '
      'no steady-state RSS growth', () async {
    // Identical runs until RSS plateaus (see maxLeakProbeRuns): the leak
    // signal is the MINIMUM growth over consecutive runs, so a heap
    // high-water mark still climbing after one warm-up run (measured on
    // Linux CI) cannot fail the gate, while a per-room leak — which grows
    // on every run — still does.
    harness.LoadSoakSummary? previous;
    final deltas = <int>[];
    for (var run = 1; run <= maxLeakProbeRuns; run++) {
      final summary = await harness.runLoadSoak(
        rooms: 100,
        messagesPerRoom: 20,
        tier: '100',
      );
      // The JSON summaries are this gate's evidence — always emit them.
      print('G8 100-tier run $run: ${jsonEncode(summary.toJson())}');
      expectCleanRun(summary, 100, 20);
      if (previous != null) {
        final delta = summary.rssAfterBytes - previous.rssAfterBytes;
        deltas.add(delta);
        print(
          'G8 100-tier RSS growth run ${run - 1} -> run $run: '
          '$delta bytes',
        );
      }
      previous = summary;
      // Plateau observed — no need to burn more runs.
      if (deltas.isNotEmpty && deltas.last < maxSteadyStateRssGrowthBytes) {
        break;
      }
    }

    final steadyStateGrowth = deltas.reduce(math.min);
    print(
      'G8 100-tier steady-state RSS growth '
      '(min over ${deltas.length} consecutive-run deltas): '
      '$steadyStateGrowth bytes',
    );
    expect(
      steadyStateGrowth,
      lessThan(maxSteadyStateRssGrowthBytes),
      reason:
          'RSS grew >= 64 MiB on every one of ${deltas.length} consecutive '
          'identical runs (deltas: $deltas). A plateauing VM high-water mark '
          'cannot do that; a per-room leak can.',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'G8 1k-room soak tier: zero errors, full delivery, clean teardown',
    () async {
      final summary = await harness.runLoadSoak(
        rooms: 1000,
        messagesPerRoom: 10,
        tier: '1k',
      );
      // The JSON summary is this gate's evidence — always emit it.
      print('G8 1k-tier summary: ${jsonEncode(summary.toJson())}');
      expectCleanRun(summary, 1000, 10);
    },
    tags: 'soak',
    skip:
        'soak tier — run manually: '
        'dart test test/load_soak_test.dart -t soak --run-skipped',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
