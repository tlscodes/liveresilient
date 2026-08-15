import 'package:flutter_test/flutter_test.dart';
import 'package:reference_app/main.dart';

/// Ticket 3 gate 3a — the ICE failure count is real.
///
/// Before this, `iceFailureCount` was a parameter with a default of zero that
/// every caller accepted and nothing ever incremented. The rule it feeds —
/// two failures on the same call justify a relay-only profile — could
/// therefore never fire on its own; the only way the strict profile was ever
/// reached was an explicit feature flag. The count was decoration, and it is
/// the same failure class the project already measured once: an optional
/// parameter nobody supplied, sitting at its default in production while the
/// code read as though the rule was live.
void main() {
  group('IceFailureLedger', () {
    test('an unknown call starts at zero', () {
      final ledger = IceFailureLedger();
      expect(ledger.failureCountFor('call-a'), 0);
    });

    test('failures accumulate per call and the rule can actually fire', () {
      final ledger = IceFailureLedger();
      expect(ledger.recordFailure('call-a'), 1);
      expect(ledger.failureCountFor('call-a'), 1);
      expect(ledger.recordFailure('call-a'), 2);
      expect(
        ledger.failureCountFor('call-a'),
        greaterThanOrEqualTo(2),
        reason: 'two failures on the same call is the threshold the profile '
            'rule tests; below this it could never be reached',
      );
    });

    test('the count is per call, never shared', () {
      final ledger = IceFailureLedger();
      ledger.recordFailure('call-a');
      ledger.recordFailure('call-a');
      expect(ledger.failureCountFor('call-b'), 0);
    });

    test('a call that ends is forgotten, so a new call starts clean', () {
      final ledger = IceFailureLedger();
      ledger.recordFailure('call-a');
      ledger.recordFailure('call-a');
      ledger.forget('call-a');
      expect(ledger.failureCountFor('call-a'), 0);
    });

    test('memory is bounded: abandoned ids cannot accumulate forever', () {
      final ledger = IceFailureLedger(maxEntries: 4);
      for (var i = 0; i < 40; i++) {
        ledger.recordFailure('call-$i');
      }
      // The oldest ids must have been evicted rather than retained.
      expect(ledger.failureCountFor('call-0'), 0);
      expect(ledger.failureCountFor('call-39'), 1);
    });

    test('touching a call keeps it from being evicted', () {
      final ledger = IceFailureLedger(maxEntries: 3);
      ledger.recordFailure('keep');
      ledger.recordFailure('a');
      ledger.recordFailure('b');
      ledger.recordFailure('keep'); // touched again, becomes most recent
      ledger.recordFailure('c'); // evicts the least recently touched
      expect(
        ledger.failureCountFor('keep'),
        greaterThanOrEqualTo(2),
        reason: 'a live call must not be evicted ahead of an abandoned one',
      );
    });

    test('the process-wide ledger exists and is usable by name', () {
      // The point of naming it is that a caller cannot satisfy the API by
      // omission the way it could when the count was a defaulted parameter.
      final before = devIceFailureLedger.failureCountFor('probe-call');
      expect(before, 0);
      devIceFailureLedger.recordFailure('probe-call');
      expect(devIceFailureLedger.failureCountFor('probe-call'), 1);
      devIceFailureLedger.forget('probe-call');
    });
  });
}
