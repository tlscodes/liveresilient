/// The measured delivery rate bounds the lane budget on both sides, and the
/// budget is never pinned at the initial floor while the stats feed has no
/// round trip yet.
///
/// Refuted on the first measured-rate wave (2026-09-04): growth alone could
/// climb to the 4 MiB/s cap on a path whose round trip never reads as
/// inflated, and a photo sent before the first rtt sample would have stayed
/// at 570 B/s for its whole life.
library;

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/lane_governor.dart';

void main() {
  test('a fresh measurement floors the budget and twice it caps the '
      'budget, even when the round trip never inflates', () {
    var now = DateTime.utc(2026, 9, 4, 16, 55);
    final governor = LaneGovernor(
      readRttMs: () => 40, // never inflated: base 40, inflation above 190
      readAvailableOutgoingBps: () => 134 * 1000 * 1000, // the bogus estimate
      clock: Clock(() => now),
    );
    // With a round trip present the first call is the first slow-start
    // step (570 -> 1140); nothing higher before a measurement exists.
    expect(governor.budgetBytesPerSec(), lessThanOrEqualTo(1140));
    final budgets = <int>[];
    for (var step = 0; step < 40; step++) {
      now = now.add(const Duration(milliseconds: 200));
      governor.reportAcked(100); // 500 B/s delivered, whatever the budget
      budgets.add(governor.budgetBytesPerSec());
    }
    final measured = governor.measuredBytesPerSec();
    expect(measured, isNotNull);
    expect(measured!, inInclusiveRange(450, 560));
    // After the first measurement (about 1.2 s) the budget never leaves
    // [measured, 2 x measured]; the estimate changed nothing.
    for (final b in budgets.sublist(8)) {
      expect(b, lessThanOrEqualTo(2 * 600));
      expect(b, greaterThanOrEqualTo(400));
    }
    expect(budgets.last, lessThanOrEqualTo(2 * measured + 1));
    expect(governor.lastReason, contains('estimate=134000000'));
  });

  test('without a round trip the budget grows by measurement and stops at '
      '4x the floor until the first measurement exists', () {
    var now = DateTime.utc(2026, 9, 4, 16, 55);
    final governor = LaneGovernor(
      readRttMs: () => null,
      clock: Clock(() => now),
    );
    final unmeasured = <int>[];
    for (var step = 0; step < 20; step++) {
      now = now.add(const Duration(milliseconds: 200));
      unmeasured.add(governor.budgetBytesPerSec());
    }
    expect(unmeasured.last, 4 * 570, reason: 'nothing vouched for more');
    expect(unmeasured.every((b) => b <= 4 * 570), isTrue);
    // Acks at 3000 B/s: the budget follows the measurement upward.
    for (var step = 0; step < 15; step++) {
      now = now.add(const Duration(milliseconds: 200));
      governor.reportAcked(600);
      governor.budgetBytesPerSec();
    }
    final measured = governor.measuredBytesPerSec()!;
    expect(measured, inInclusiveRange(2700, 3400));
    final budget = governor.budgetBytesPerSec();
    expect(budget, greaterThanOrEqualTo(measured));
    expect(budget, lessThanOrEqualTo(2 * measured + 1));
    expect(governor.lastReason, contains('no-rtt'));
  });

  test('an inflated round trip still shrinks the budget when the last '
      'measurement is stale', () {
    var now = DateTime.utc(2026, 9, 4, 16, 55);
    var rtt = 40;
    final governor = LaneGovernor(
      readRttMs: () => rtt,
      clock: Clock(() => now),
    );
    for (var step = 0; step < 15; step++) {
      now = now.add(const Duration(milliseconds: 200));
      governor.reportAcked(2000); // 10 KB/s delivered
      governor.budgetBytesPerSec();
    }
    final before = governor.budgetBytesPerSec();
    expect(before, greaterThanOrEqualTo(9000));
    // The link degrades: no more acks, the queue inflates the round trip.
    rtt = 2000;
    now = now.add(const Duration(seconds: 6)); // the sample window empties
    var b = governor.budgetBytesPerSec();
    for (var step = 0; step < 6; step++) {
      now = now.add(const Duration(seconds: 2));
      b = governor.budgetBytesPerSec();
    }
    expect(b, lessThan(before ~/ 2), reason: 'a stale floor must not undo it');
    expect(governor.lastReason, contains('inflated'));
  });
}
