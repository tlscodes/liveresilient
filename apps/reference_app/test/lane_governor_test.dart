import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/lane_governor.dart';

void main() {
  test('before any reading the budget is the documented 570 B/s floor and '
      'a transport estimate does not raise it', () {
    final governor = LaneGovernor(readRttMs: () => null);
    expect(governor.budgetBytesPerSec(), 570);
    expect(
      governor.lastReason,
      'budget=570 measured=- rtt=- floor=- no-rtt estimate=-',
    );

    final withEstimate = LaneGovernor(
      readRttMs: () => null,
      readAvailableOutgoingBps: () => 800000,
    );
    expect(withEstimate.budgetBytesPerSec(), 570);
    expect(
      withEstimate.lastReason,
      'budget=570 measured=- rtt=- floor=- no-rtt estimate=800000',
    );
  });

  test('a bogus 4 MiB/s transport estimate never moves the budget: acks at '
      '500 B/s while the round trip inflates keep it within '
      '[minBytesPerSec, 2 × 500 B/s] over 10 steps', () {
    var now = DateTime.utc(2026, 1, 1);
    var rtt = 40;
    final governor = LaneGovernor(
      readRttMs: () => rtt,
      readAvailableOutgoingBps: () => (4 << 20) * 8, // 4 MiB/s in bit/s
      clock: Clock(() => now),
    );
    // The first step establishes the floor and doubles once (slow start).
    expect(governor.budgetBytesPerSec(), 1140);
    expect(governor.lastReason, contains('estimate=33554432'));

    // The queue builds: 2 s round trips, 100 bytes acked every 200 ms.
    // The first inflated step lands one round trip (2 s) after the
    // inflation is read — that reaction time is the control's, so the
    // bound is checked from the first inflated step onward.
    rtt = 2000;
    var lowest = 1 << 30;
    var highest = 0;
    for (var step = 0; step < 10; step++) {
      for (var tick = 0; tick < 10; tick++) {
        now = now.add(const Duration(milliseconds: 200));
        governor.reportAcked(100);
        final budget = governor.budgetBytesPerSec();
        if (step == 0 && tick < 9) {
          // Before the first inflated step: the slow-start step (1140)
          // or, once a measurement exists, twice the measured rate.
          expect(budget, inInclusiveRange(400, 1140));
          continue;
        }
        lowest = budget < lowest ? budget : lowest;
        highest = budget > highest ? budget : highest;
      }
    }
    expect(highest, lessThanOrEqualTo(1000));
    expect(lowest, greaterThanOrEqualTo(400));
    expect(governor.measuredBytesPerSec(), inInclusiveRange(490, 560));
    expect(governor.lastReason, contains('estimate=33554432'));
    // The last step was inflated; the floor call inside it is the measured
    // rate, so the budget reads as at least what the link delivered.
    expect(governor.budgetBytesPerSec(), greaterThanOrEqualTo(490));
  });

  test('a fast link doubles per round trip in slow start until the first '
      'inflation, then probes ×1.25', () {
    var now = DateTime.utc(2026, 1, 1);
    var rtt = 40;
    final governor = LaneGovernor(
      readRttMs: () => rtt,
      clock: Clock(() => now),
    );
    for (var step = 1; step <= 12; step++) {
      expect(governor.budgetBytesPerSec(), 570 << step, reason: 'step $step');
      expect(governor.lastReason, contains('slow-start'));
      now = now.add(const Duration(milliseconds: 200));
    }
    // 570 × 2^10 = 583680 ≥ 500 KB/s was reached at step 10; step 13 would
    // be 570 × 2^13 = 4669440, over the 4 MiB cap, so the cap holds.
    expect(governor.budgetBytesPerSec(), 4194304);

    rtt = 400; // over max(1.5 × 40, 40 + 150) = 190 ms
    now = now.add(const Duration(milliseconds: 400));
    expect(governor.budgetBytesPerSec(), 2936013); // 4194304 × 0.7
    expect(governor.lastReason, contains('inflated'));

    rtt = 40;
    now = now.add(const Duration(milliseconds: 400));
    expect(governor.budgetBytesPerSec(), 3670016); // 2936013 × 1.25
    expect(governor.lastReason, contains('probing'));

    // The cap holds.
    for (var i = 0; i < 20; i++) {
      now = now.add(const Duration(milliseconds: 200));
      governor.budgetBytesPerSec();
    }
    expect(governor.budgetBytesPerSec(), 4 << 20);
  });

  test('acked bytes are the measured rate and that rate is the floor of the '
      'budget, never a cap', () {
    var now = DateTime.utc(2026, 1, 1);
    final governor = LaneGovernor(
      readRttMs: () => null,
      clock: Clock(() => now),
    );
    governor.reportAcked(2000);
    expect(governor.measuredBytesPerSec(), isNull); // one sample is a burst
    now = now.add(const Duration(milliseconds: 500));
    governor.reportAcked(2000);
    expect(governor.measuredBytesPerSec(), isNull); // 0.5 s is not a second
    now = now.add(const Duration(milliseconds: 500));
    // 4000 bytes over the 1.0 s since the oldest sample.
    expect(governor.measuredBytesPerSec(), 4000);
    expect(governor.budgetBytesPerSec(), 4000);
    expect(
      governor.lastReason,
      'budget=4000 measured=4000 rtt=- floor=- no-rtt estimate=-',
    );

    // The window (4 s without a round trip) empties; the budget does not
    // fall with it.
    now = now.add(const Duration(seconds: 5));
    expect(governor.measuredBytesPerSec(), isNull);
    // It may still probe up to twice the last measurement, never below.
    expect(governor.budgetBytesPerSec(), inInclusiveRange(4000, 8000));

    // A measured rate above the cap is clamped to it.
    governor.reportAcked(8 << 20);
    now = now.add(const Duration(seconds: 1));
    governor.reportAcked(8 << 20);
    expect(governor.budgetBytesPerSec(), 4 << 20);
  });

  test('the measurement window widens to four round trips on a slow path', () {
    var now = DateTime.utc(2026, 1, 1);
    final governor = LaneGovernor(
      readRttMs: () => 2000, // window = max(4000, 8000) ms
      clock: Clock(() => now),
    );
    governor.reportAcked(1000);
    now = now.add(const Duration(seconds: 7));
    governor.reportAcked(1000);
    // Both samples are still inside the 8 s window: 2000 bytes over 7 s.
    expect(governor.measuredBytesPerSec(), 286);
    now = now.add(const Duration(milliseconds: 1500));
    // 8.5 s after the first sample it is gone; one sample is no rate.
    expect(governor.measuredBytesPerSec(), isNull);
  });

  test('lastReason names every input on one line', () {
    var now = DateTime.utc(2026, 1, 1);
    final governor = LaneGovernor(
      readRttMs: () => 40,
      readAvailableOutgoingBps: () => 32000,
      clock: Clock(() => now),
    );
    governor.reportAcked(1000);
    now = now.add(const Duration(seconds: 1));
    governor.reportAcked(1000);
    // First step: slow start doubles 570 → 1140, then the measured 2000 B/s
    // floor lifts it.
    expect(governor.budgetBytesPerSec(), 2000);
    expect(
      governor.lastReason,
      'budget=2000 measured=2000 rtt=40 floor=40 slow-start estimate=32000',
    );
  });

  test('steps are rate-limited to one per round trip; inside a step only the '
      'measured floor applies', () {
    var now = DateTime.utc(2026, 1, 1);
    final governor = LaneGovernor(
      readRttMs: () => 1000,
      clock: Clock(() => now),
      initialBytesPerSec: 1000,
    );
    expect(governor.budgetBytesPerSec(), 2000); // first step, slow start
    now = now.add(const Duration(milliseconds: 300));
    expect(governor.budgetBytesPerSec(), 2000); // inside the same round trip
    now = now.add(const Duration(milliseconds: 800));
    expect(governor.budgetBytesPerSec(), 4000); // the next step
  });

  test('the retransmit floor follows the round trip within bounds', () {
    int? rtt;
    final governor = LaneGovernor(readRttMs: () => rtt);
    expect(governor.retransmitAfter(), const Duration(milliseconds: 700));
    rtt = 80;
    expect(governor.retransmitAfter(), const Duration(milliseconds: 700));
    rtt = 1900;
    expect(governor.retransmitAfter(), const Duration(milliseconds: 4750));
    rtt = 9000;
    expect(governor.retransmitAfter(), const Duration(seconds: 10));
  });
}
