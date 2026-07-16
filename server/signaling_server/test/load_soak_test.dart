/// G8 load/soak gate — in-process tiers of the load harness.
///
/// The 100-room tier runs on every `dart test` (CI-fast). The 1k-room tier
/// is tagged `soak` and skipped by default; run it manually with:
///
///   dart test test/load_soak_test.dart -t soak --run-skipped
library;

import 'dart:convert';

import 'package:test/test.dart';

import '../bin/load_soak.dart' as harness;

/// Upper bound on steady-state RSS growth between two identical runs.
///
/// A single cold run's before/after RSS delta is NOT a leak signal here:
/// `dart test` runs suites concurrently inside one VM process (process-wide
/// RSS includes the other suites), the first run pays JIT compilation, and
/// the Dart VM almost never returns freed heap pages to the OS (measured on
/// this machine: cold-run delta ~200 MiB for 100 rooms, dominated by those
/// three effects). So the leak check compares RSS after run 1 vs after an
/// IDENTICAL run 2: a leak-free harness+server reuses the already-grown heap
/// and grows ~0; per-room retention (sockets, rooms, frame buffers) would
/// grow linearly and trip this. 64 MiB absorbs allocator/concurrent-suite
/// noise while still failing on any per-room leak of ~0.6 MiB or more.
/// The authoritative teardown signals remain `activeRoomsAfterTeardown == 0`
/// and zero errors; the RSS bound is a coarse backstop.
const int maxSteadyStateRssGrowthBytes = 64 * 1024 * 1024;

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
    final first = await harness.runLoadSoak(
      rooms: 100,
      messagesPerRoom: 20,
      tier: '100',
    );
    // The JSON summaries are this gate's evidence — always emit them.
    print('G8 100-tier run 1: ${jsonEncode(first.toJson())}');
    expectCleanRun(first, 100, 20);

    // Identical second run: its growth over run 1's end state is the
    // leak signal (see maxSteadyStateRssGrowthBytes).
    final second = await harness.runLoadSoak(
      rooms: 100,
      messagesPerRoom: 20,
      tier: '100',
    );
    print('G8 100-tier run 2: ${jsonEncode(second.toJson())}');
    expectCleanRun(second, 100, 20);

    final steadyStateGrowth = second.rssAfterBytes - first.rssAfterBytes;
    print('G8 100-tier steady-state RSS growth: $steadyStateGrowth bytes');
    expect(steadyStateGrowth, lessThan(maxSteadyStateRssGrowthBytes));
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
