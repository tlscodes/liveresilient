import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/src/lane_governor.dart';

void main() {
  test('a known link estimate is the floor of the budget, clamped, and the '
      'delay control may rise above it', () {
    var now = DateTime.utc(2026, 1, 1);
    int? available = 32000;
    var rtt = 40;
    final governor = LaneGovernor(
      readRttMs: () => rtt,
      readAvailableOutgoingBps: () => available,
      clock: Clock(() => now),
      initialBytesPerSec: 500,
    );
    // 25 % of 32 kbit/s = 1000 B/s is vouched for even from a lower start.
    expect(governor.budgetBytesPerSec(), 1000);
    expect(governor.lastReason, contains('held at link share'));
    // A clean round trip lets the budget climb past the share.
    for (var i = 0; i < 8; i++) {
      now = now.add(const Duration(milliseconds: 300));
      governor.budgetBytesPerSec();
    }
    expect(governor.budgetBytesPerSec(), greaterThan(1000));
    // An inflated round trip shrinks it, but never under the share.
    rtt = 900;
    for (var i = 0; i < 20; i++) {
      now = now.add(const Duration(seconds: 1));
      governor.budgetBytesPerSec();
    }
    expect(governor.budgetBytesPerSec(), 1000);
    available = 1000;
    for (var i = 0; i < 20; i++) {
      now = now.add(const Duration(seconds: 1));
      governor.budgetBytesPerSec();
    }
    expect(governor.budgetBytesPerSec(), 400); // the floor
    available = 800000000;
    expect(governor.budgetBytesPerSec(), 4 << 20); // the cap
  });

  test('a link estimate without a round trip yet raises the initial budget '
      'to the share', () {
    final governor = LaneGovernor(
      readRttMs: () => null,
      readAvailableOutgoingBps: () => 800000,
      initialBytesPerSec: 1000,
    );
    expect(governor.budgetBytesPerSec(), 25000);
    expect(governor.lastReason, contains('no rtt yet'));
  });

  test('without a link estimate the budget grows while the round trip stays '
      'near its floor and shrinks when it inflates', () {
    var now = DateTime.utc(2026, 1, 1);
    var rtt = 80;
    final governor = LaneGovernor(
      readRttMs: () => rtt,
      clock: Clock(() => now),
      initialBytesPerSec: 1000,
    );
    expect(governor.budgetBytesPerSec(), 1250); // first step: near floor
    for (var i = 0; i < 10; i++) {
      now = now.add(const Duration(milliseconds: 300));
      governor.budgetBytesPerSec();
    }
    final grown = governor.budgetBytesPerSec();
    expect(grown, greaterThan(9000));

    rtt = 1900; // the queue built up
    now = now.add(const Duration(seconds: 2));
    final shrunk = governor.budgetBytesPerSec();
    expect(shrunk, lessThan(grown));
    expect(governor.lastReason, contains('inflated'));
    for (var i = 0; i < 30; i++) {
      now = now.add(const Duration(seconds: 2));
      governor.budgetBytesPerSec();
    }
    expect(governor.budgetBytesPerSec(), 400); // never below the floor
  });

  test('steps are rate-limited to one per round trip', () {
    var now = DateTime.utc(2026, 1, 1);
    final governor = LaneGovernor(
      readRttMs: () => 1000,
      clock: Clock(() => now),
      initialBytesPerSec: 1000,
    );
    final first = governor.budgetBytesPerSec();
    now = now.add(const Duration(milliseconds: 300));
    expect(governor.budgetBytesPerSec(), first); // inside the same round trip
    now = now.add(const Duration(milliseconds: 800));
    expect(governor.budgetBytesPerSec(), greaterThan(first));
  });

  test('no readings at all leaves the initial budget in force', () {
    final governor = LaneGovernor(
      readRttMs: () => null,
      initialBytesPerSec: 2048,
    );
    expect(governor.budgetBytesPerSec(), 2048);
    expect(governor.lastReason, 'no readings yet');
    expect(governor.retransmitAfter(), const Duration(milliseconds: 700));
  });

  test('the retransmit floor follows the round trip within bounds', () {
    var rtt = 80;
    final governor = LaneGovernor(readRttMs: () => rtt);
    expect(governor.retransmitAfter(), const Duration(milliseconds: 700));
    rtt = 1900;
    expect(governor.retransmitAfter(), const Duration(milliseconds: 4750));
    rtt = 9000;
    expect(governor.retransmitAfter(), const Duration(seconds: 10));
  });
}
